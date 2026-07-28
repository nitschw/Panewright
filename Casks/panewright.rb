cask "panewright" do
  version "0.6.25"
  sha256 "66e8bb732c161fafd4abdf71480305d54d73539fd2548eff903a4dd0f76406ef"

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

  # Sparkle updates the app in place, so brew's records go stale by design.
  # Without this, `brew outdated` reported every Sparkle update as pending —
  # including in Panewright's own brew widget, which nagged its user to
  # re-install the thing they'd just updated.
  auto_updates true

  depends_on macos: :sonoma

  # The tiling engine (Panewright's build of AeroSpace) ships INSIDE the app
  # and runs as a child process under Panewright's own permissions — it is
  # not a dependency any more. Only the visual layer comes from brew.
  depends_on formula: "felixkratz/formulae/borders"
  depends_on formula: "felixkratz/formulae/sketchybar"

  # A separately installed AeroSpace would fight the embedded engine for the
  # same windows (and this cask links the same `aerospace` binary name).
  conflicts_with cask: [
    "nikitabobko/tap/aerospace",
    "nikitabobko/tap/aerospace-dev",
    "nitschw/tap/aerospace-panewright",
  ]

  # Earlier engine-era installs (standalone AeroSpace, aerospace-panewright,
  # or a Panewright version that failed mid-upgrade) can leave orphaned
  # symlinks at the binary targets that no cask owns any more — and brew
  # refuses to overwrite an unowned file, failing the install with "there is
  # already a binary at…". Clear a stale link only when it demonstrably
  # points into one of our app bundles; a real file or a foreign link is
  # left for the user (rm it by hand), never silently deleted.
  preflight do
    ["aerospace", "panewright"].each do |name|
      stale = "#{HOMEBREW_PREFIX}/bin/#{name}"
      next unless File.symlink?(stale)
      dest = File.readlink(stale)
      if dest.include?("Panewright.app") || dest.include?("AeroSpace")
        File.delete(stale)
      end
    end
  end

  app "Panewright.app"
  # The engine's CLI, version-locked to the embedded engine.
  binary "#{appdir}/Panewright.app/Contents/Helpers/aerospace-cli", target: "aerospace"
  # Panewright's own CLI: `panewright import <i3-config>`, emit, apply, status.
  binary "#{appdir}/Panewright.app/Contents/Helpers/panewright-cli", target: "panewright"

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

      The tiling engine is built in — if you have AeroSpace installed
      separately (any flavor), uninstall it first; two engines fight over
      the same windows. Upgrading from an earlier Panewright:
        brew uninstall --cask aerospace-panewright
    EOS
  end
end
