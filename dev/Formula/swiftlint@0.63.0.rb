class SwiftlintAT0630 < Formula
  desc "Tool to enforce Swift style and conventions"
  homepage "https://github.com/realm/SwiftLint"
  version "0.63.0"
  license "MIT"

  on_macos do
    url "https://github.com/realm/SwiftLint/releases/download/0.63.0/portable_swiftlint.zip"
    sha256 "6a9cc0e3e09466fce5eabd4b920cd7169e9e56b60e12ee1340a793ea8b60ceb9"
  end

  on_linux do
    if Hardware::CPU.arm?
      url "https://github.com/realm/SwiftLint/releases/download/0.63.0/swiftlint_linux_arm64.zip"
      sha256 "8260b6d9e69c94776b6f1631263367ab1b05fe985b8e9726f3ba403efdc9083e"
    else
      url "https://github.com/realm/SwiftLint/releases/download/0.63.0/swiftlint_linux_amd64.zip"
      sha256 "f77f94ffed467c6f027f4348ca41d99fd6268a02a584f8fb0fa139a48ace39cb"
    end
  end

  keg_only :versioned_formula

  def install
    bin.install "swiftlint"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/swiftlint version")
  end
end
