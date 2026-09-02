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

  # Corvo is a background agent, so upgrading almost always happens with it
  # running — and without this, that upgrade silently does nothing.
  #
  # Measured: `brew upgrade` over the running app replaces the binary on disk
  # (the inode changes) and leaves the old process alive on the deleted one.
  # Homebrew prints "successfully installed" and the user goes on running the
  # version they just replaced, with nothing on screen saying so, until they
  # happen to quit and relaunch.
  #
  # `quit` sends the app a quit event before the swap, so what comes back is
  # the version that was installed.
  uninstall quit: "com.wylp.corvo"

  # Homebrew quarantines what it downloads, and Gatekeeper reads that flag to
  # refuse the first launch of a bundle it cannot verify — which this one is:
  # ad-hoc signed, no Developer ID, not notarized. Removing it here is a
  # deliberate trade, not a tidy-up. It buys an app that opens, and it costs
  # the warning that would have told you nobody vouched for this binary.
  #
  # The honest fix is notarization, which would make the flag harmless rather
  # than something to strip. Until then this is stated in the caveats below
  # instead of being done quietly.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Corvo.app"]
  end

  caveats <<~EOS
    Corvo is ad-hoc signed and not notarized. This cask removes the quarantine
    flag after installing, so the app opens without the trip through System
    Settings > Privacy & Security. That flag is how macOS warns you an app is
    unverified, so what you get is the app launching and not that warning.
    Build it from source instead if you would rather keep the check.

    Pasting straight into the app you came from needs Accessibility permission.
    Without it Corvo still copies to the clipboard.

    Upgrading replaces the bundle, and an ad-hoc signed app changes identity
    when it does. macOS may go on showing Corvo switched on under Accessibility
    while the permission no longer applies to the new binary: select Corvo,
    remove it with the minus button, then add it again.
  EOS

  zap trash: [
    "~/Library/Application Support/Corvo",
    "~/Library/Preferences/com.wylp.corvo.plist",
  ]
end
