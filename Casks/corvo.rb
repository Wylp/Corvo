cask "corvo" do
  version "0.1.0"
  # Replace with the digest of the published zip once the release exists:
  #   shasum -a 256 build/Corvo.zip
  sha256 :no_check

  url "https://github.com/Wylp/Corvo/releases/download/v#{version}/Corvo.zip"
  name "Corvo"
  desc "Clipboard history organized by source app and by tags"
  homepage "https://github.com/Wylp/Corvo"

  depends_on macos: ">= :sonoma"

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
