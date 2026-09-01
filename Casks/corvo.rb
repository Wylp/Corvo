cask "corvo" do
  version "0.2.0"
  # Of the *published* artifact, not of a local `make release` — the digest has
  # to be the bytes Homebrew will actually download:
  #   curl -sL https://github.com/Wylp/Corvo/releases/download/v#{version}/Corvo.zip | shasum -a 256
  sha256 "d14c2e0211180a0e796c604af0a87f0c6c0eb2bed214336af868a9e810ffdd81"

  url "https://github.com/Wylp/Corvo/releases/download/v#{version}/Corvo.zip"
  name "Corvo"
  desc "Clipboard history organized by source app and by tags"
  homepage "https://github.com/Wylp/Corvo"

  depends_on macos: :sonoma

  app "Corvo.app"

  caveats <<~EOS
    Corvo is not notarized. On first launch macOS will refuse to open it; go to
    System Settings > Privacy & Security and click "Open Anyway".

    Pasting straight into the app you came from needs Accessibility permission.
    Without it Corvo still copies to the clipboard.
  EOS

  zap trash: [
    "~/Library/Application Support/Corvo",
    "~/Library/Preferences/com.wylp.corvo.plist",
  ]
end
