# Changelog

Notable, user-facing changes. Format follows [Keep a Changelog](https://keepachangelog.com);
the `Unreleased` section becomes the next release's notes.

## [Unreleased]

## [0.5.0] — 2026-07-26

### Added
- **Command palette** (`$mod+D`) — fuzzy-search open windows (jump), installed
  apps (launch), and Panewright commands. Nonactivating: dismissing it returns
  focus to wherever it was.
- **Workspace overview** (`$mod+O`) — one card per occupied workspace, windows
  named and iconed, click to go. The Mission Control that virtual workspaces
  otherwise take away.
- **Dropdown terminal** (`` $mod+` ``) — quake-style summon/dismiss of your
  terminal (auto-detects iTerm2, Ghostty, WezTerm, Alacritty, kitty, Warp,
  Terminal; any app via `[dropdown] app`). Holds the size you resize it to.
- **`panewright menu`** — the dmenu contract: lines in on stdin, pick out on
  stdout, exit 1 on Escape. Every rofi/dmenu pipeline ports by changing one
  word. Three classics ship ready: `menu-ssh.sh`, `menu-kill.sh`,
  `menu-power.sh` (also in the palette).
- **Numbered pills + `[PILLS]` mode** — every bar pill shows its number;
  `$mod+shift+P` then the digit summons it. Pilling Panewright's own windows
  (cheat sheet, Confluence) is intentionally supported.
- **Arrow keys, i3-style** — `$mod+arrows` focus, `+shift` move, equal to the
  vim keys. Monitor focus moved to `$mod+,` / `$mod+.` (`+shift` sends the
  window).
- **Auto-hiding bar** (`[bar] auto-hide`) — slides off its edge, back on
  pointer-touch, away again after a configurable delay. Tiles reclaim the
  strip while it hides.
- **Push-off-screen eviction** — resize a window until another is fully off
  the display and that window moves to a new workspace, instead of the fitter
  undoing your resize.
- **Richer hooks** — `window-opened`, `window-closed` (with the app's
  identity), and `mode-changed` join `workspace-changed` and `focus-changed`.
- **Vertical stacking in overlap rescue** — when no column can shrink, two
  columns become one stack before anything is evicted.
- **Workspace resilience** — window→workspace assignments are snapshotted
  continuously and restored across engine restarts and app reinstalls.
- **`panewright` CLI ships with the app** — `panewright import
  ~/.config/i3/config` works for brew installs; also `menu`, `emit`, `status`.
- **Report a Bug** menu item — pre-fills a GitHub issue with version,
  environment, and recent logs. Crash reports carry the log tail too.
- **Intel support** — release builds are universal.

### Changed
- **The defaults are the dogfooded config**: `alt` modifier (zero out-of-box
  binding conflicts, asserted in CI), all bar widgets on, bar thickness 25 /
  text 12 / opacity 0.39 with a green accent, gaps 10, red focus border,
  `cmd-backtick` leader. A fresh install's engine config is byte-identical to
  the development machine's — enforced by test.
- **Homebrew is the install path** (`brew trust nitschw/tap && brew install
  nitschw/tap/panewright`); docs no longer carry download links or hand-install
  steps. brew knows Sparkle owns updates (`auto_updates`).
- The separate engine cask is gone — the engine ships inside the app; the
  cask declares conflicts with standalone AeroSpace installs.
- Logs rotate at 1MB with one retired generation.

### Fixed
- Drag-to-tile can splice into nested containers (the descend direction
  followed the drop axis instead of the neighbour axis), and no longer
  computes directions from parked frames when a workspace flips mid-drop.
- Rapid workspace switching no longer evicts windows or poisons learned
  minimum sizes (mid-flight frames are ignored for a beat after the window
  set changes).
- Workspace restore waits for the engine to adopt windows (it once "restored"
  onto workspace 0 one second after launch), refuses stale snapshots, and
  reports the real moved count.
- Opening the palette no longer switches workspaces (`open -g`), and
  Panewright's own windows are never adopted by the tiling engine.
- The only window on a workspace is never evicted.

## [0.4.2] — 2026-07-27
Drag-to-tile fixes: joins only act on genuine pairs, successful descents
aren't reported as failures, frames (not container labels) judge every drop.

## [0.4.1] — 2026-07-26
First release with the engine embedded in the app: one permission grant,
engine respawn supervision, live Dock following, deterministic bar ordering.

## [0.4.0] — 2026-07-26
Homebrew debut (`brew install nitschw/tap/panewright`), notarized DMG + zip,
dock-aware bar clearance, wake guard, universal engine binaries.
