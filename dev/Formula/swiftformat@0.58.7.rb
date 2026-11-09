class SwiftformatAT0587 < Formula
  desc "Formatting tool for Swift code"
  homepage "https://github.com/nicklockwood/SwiftFormat"
  version "0.58.7"
  license "MIT"

  on_macos do
    url "https://github.com/nicklockwood/SwiftFormat/releases/download/0.58.7/swiftformat.zip"
    sha256 "7e43f8e14e2089eeb83d6958ce162ffa90c9330f3f309ca054693614b2b1b241"
  end

  on_linux do
    if Hardware::CPU.arm?
      url "https://github.com/nicklockwood/SwiftFormat/releases/download/0.58.7/swiftformat_linux_aarch64.zip"
      sha256 "33c3b3b4d66d17513177e0a4f9b943611d64a16aa12ea52cbfba39595c098621"
    else
      url "https://github.com/nicklockwood/SwiftFormat/releases/download/0.58.7/swiftformat_linux.zip"
      sha256 "be1b4bb76ee134cbc6b30c55939ea5b4dbe947c7373cc2015e9718d4bad00ae9"
    end
  end

  keg_only :versioned_formula

  def install
    bin.install File.basename(stable.url, ".zip") => "swiftformat"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/swiftformat --version")
  end
end
