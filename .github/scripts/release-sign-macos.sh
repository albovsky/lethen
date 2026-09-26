#!/usr/bin/env bash
# Signs, notarizes, and packages the macOS lethen binary for a release.
#
# The Developer ID certificate goes into a throwaway keychain with a random password,
# which is deleted on exit. The binary is signed with hardened runtime and a secure
# timestamp, zipped with the license, and the zip is submitted for notarization. A bare
# executable cannot carry a stapled ticket, so Gatekeeper looks the ticket up online;
# the check at the end waits until that lookup succeeds.
#
# Inputs (environment): MACOS_CERTIFICATE_P12 (base64), MACOS_CERTIFICATE_PASSWORD,
# APPLE_TEAM_ID, NOTARY_KEY_P8 (base64), NOTARY_KEY_ID, NOTARY_ISSUER_ID, RUNNER_TEMP.
#
# Usage: release-sign-macos.sh <binary> <license> <output-zip>
set -euo pipefail

binary="${1:?usage: $0 <binary> <license> <output-zip>}"
license="${2:?usage: $0 <binary> <license> <output-zip>}"
output_zip="${3:?usage: $0 <binary> <license> <output-zip>}"
team_id="${APPLE_TEAM_ID:?APPLE_TEAM_ID is required}"

work="$(mktemp -d "${RUNNER_TEMP:-/tmp}/lethen-sign.XXXXXX")"
keychain="$work/signing.keychain-db"
original_keychains=()
while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    original_keychains+=("${line//\"/}")
done < <(security list-keychains -d user)

cleanup() {
    security list-keychains -d user -s "${original_keychains[@]}" || true
    security delete-keychain "$keychain" 2> /dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT

keychain_password="$(openssl rand -base64 32)"
printf '%s' "${MACOS_CERTIFICATE_P12:?MACOS_CERTIFICATE_P12 is required}" | base64 --decode > "$work/certificate.p12"
printf '%s' "${NOTARY_KEY_P8:?NOTARY_KEY_P8 is required}" | base64 --decode > "$work/notary.p8"

security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$work/certificate.p12" -k "$keychain" \
    -P "${MACOS_CERTIFICATE_PASSWORD:?MACOS_CERTIFICATE_PASSWORD is required}" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" > /dev/null
security list-keychains -d user -s "$keychain" "${original_keychains[@]}"

identity="$(security find-identity -v -p codesigning "$keychain" \
    | awk -v team="($team_id)" 'index($0, "\"Developer ID Application:") && index($0, team) { print $2; exit }')"
if [ -z "$identity" ]; then
    echo "::error::No Developer ID Application identity for team $team_id in MACOS_CERTIFICATE_P12" >&2
    exit 1
fi

codesign --force --timestamp --options runtime --identifier com.github.albovsky.lethen \
    --keychain "$keychain" --sign "$identity" "$binary"

details="$(codesign --display --verbose=4 "$binary" 2>&1)"
codesign --verify --strict --verbose=2 "$binary"
for required in "Authority=Developer ID Application:" "($team_id)" "flags=0x10000(runtime)" "Timestamp="; do
    if [[ "$details" != *"$required"* ]]; then
        echo "::error::Signature is missing '$required'" >&2
        echo "$details" >&2
        exit 1
    fi
done
if [ "$(lipo -archs "$binary")" != "arm64" ]; then
    echo "::error::Expected an arm64 binary, got: $(lipo -archs "$binary")" >&2
    exit 1
fi

staging="$work/package"
mkdir -p "$staging"
cp "$binary" "$staging/lethen"
cp "$license" "$staging/LICENSE.md"
rm -f "$output_zip"
ditto -c -k "$staging" "$output_zip"

submission="$(xcrun notarytool submit "$output_zip" --key "$work/notary.p8" \
    --key-id "${NOTARY_KEY_ID:?NOTARY_KEY_ID is required}" --issuer "${NOTARY_ISSUER_ID:?NOTARY_ISSUER_ID is required}" \
    --wait --timeout 1h --output-format json)"
echo "$submission"
submission_id="$(jq -r '.id' <<< "$submission")"
if [ "$(jq -r '.status' <<< "$submission")" != "Accepted" ]; then
    echo "::error::Notarization was not accepted" >&2
    xcrun notarytool log "$submission_id" --key "$work/notary.p8" \
        --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" >&2 || true
    exit 1
fi

# The ticket reaches Apple's lookup service shortly after acceptance.
for attempt in $(seq 1 20); do
    if assessment="$(spctl --assess --type install --verbose=4 "$binary" 2>&1)" \
        && [[ "$assessment" == *"source=Notarized Developer ID"* ]]; then
        echo "$assessment"
        exit 0
    fi
    echo "Gatekeeper assessment attempt $attempt: $assessment"
    sleep 30
done
echo "::error::Gatekeeper does not accept the notarized binary" >&2
exit 1
