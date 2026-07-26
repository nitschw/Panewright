cask "panewright" do
  version "0.3.4"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/nitschw/Panewright/releases/download/v#{version}/Panewright-#{version}.dmg"
  name "Panewright"
  desc "Truly tiled windows for macOS"
  homepage "https://panewright.com"

  # A disk image rather than the zip that Sparkle uses. Homebrew extracts a
  # zip with `unzip`, which writes AppleDouble sidecar files inside
  # Sparkle.framework; those aren't covered by the signature, so the seal
  # breaks and Gatekeeper refuses to launch what it just installed. DMGs are
  # extracted with `ditto`, which handles them correctly.
  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sonoma

  # The whole point of the one-liner: Panewright supervises these three, and
  # without them it starts up with nothing to manage.
  #
  # The tiling engine comes from Panewright's own fork of AeroSpace — upstream
  # plus two patches Panewright relies on (dock-aware window hiding, hideable
  # menu bar icon). Anyone who already runs stock AeroSpace hits the conflict
  # declared in that cask rather than a silent double-install.
  depends_on cask: "nitschw/tap/aerospace-panewright"
  depends_on formula: "felixkratz/formulae/borders"
  depends_on formula: "felixkratz/formulae/sketchybar"

  app "Panewright.app"

  # Panewright generates the aerospace and sketchybar configs, so uninstalling
  # should offer to take them back out. Its own config, saved profiles and the
  # backups of whatever it replaced are left alone deliberately — those are
  # the user's, and a `zap` that deletes someone's saved layouts because they
  # ran `brew uninstall` would be indefensible.
  uninstall quit: "com.panewright.app"

  zap trash: [
    "~/Library/Caches/com.panewright.app",
    "~/Library/HTTPStorages/com.panewright.app",
    "~/Library/Preferences/com.panewright.app.plist",
    "~/Library/Logs/Panewright.log",
  ]

  caveats do
    <<~EOS
      Panewright needs Accessibility and Input Monitoring permissions.
      It asks for them on first launch — they can't be granted ahead of time.

      Your existing aerospace and sketchybar configs are copied to
      ~/.config/panewright/backups/ before Panewright writes its own.

      If AeroSpace is already installed WITHOUT Homebrew (a manually
      downloaded app), Homebrew will refuse to install over it. Remove it,
      or adopt it first and then replace it:
        brew install --cask --adopt nitschw/tap/aerospace-panewright
    EOS
  end
end
