# Changelog

Notable, user-facing changes. Format follows [Keep a Changelog](https://keepachangelog.com);
the `Unreleased` section becomes the next release's notes.

## [Unreleased]

## [0.6.11] — 2026-07-27

### Fixed
- Bug reports (not just crash prompts) now attach any crash either process
  suffered in the last day — the symbolicated trace from macOS's own
  DiagnosticReports, for both the app and the engine. A hard crash dies
  without a log line, so "it crashed" reports used to arrive with logs
  showing nothing wrong while the whole story sat in an .ips file.

## [0.6.10] — 2026-07-27

### Fixed
- Rapid workspace switching ending on an empty workspace no longer gets
  yanked back (engine): an empty workspace leaves the old window holding
  native focus, and stale async focus grants from the switch before landed
  late — the engine followed both and dragged you to whatever workspace
  that window lived on. A one-second grace window after focusing an empty
  workspace swallows them. Verified with nine consecutive rapid 2→1→6 runs
  all ending on 6 (previously flaky).

## [0.6.9] — 2026-07-27

### Fixed
- Rapidly switching away from a workspace mid-render can no longer get your
  focused window evicted (and you dragged with it to an empty workspace).
  The fitter's visible-workspace roster could lag a switch by up to two
  seconds, so it judged a half-parked workspace's teleporting frames as
  overlap and "corrected" it. Visibility changes now get the same settle
  window as membership changes, the roster refreshes twice as often, and a
  convergence burst re-confirms its workspace is still on the glass before
  touching anything.

## [0.6.8] — 2026-07-27

### Fixed
- Switching to an empty workspace no longer bounces you elsewhere. Two
  culprits: app-activation events that are the switch's own exhaust (macOS
  re-activates whatever's still frontmost when the new workspace has no
  window to focus) were treated as "the user summoned this app" and
  followed to its workspace; and the orphan-adoption nudge could tug focus
  to the raised window — with apps that churn helper windows (Steam), every
  15-second sweep found a fresh "orphan" and dragged you to its workspace.
  The follower now ignores activations that arrive with a workspace change,
  and the adopter restores your workspace if a nudge moved it and limits
  itself to one nudge per app per ten minutes.

## [0.6.7] — 2026-07-27

### Changed
- Workspace switching got faster, most noticeably on machines with endpoint
  security: the switch pipeline spawned ~20 subprocesses per switch (an
  engine query per monitor, an awk or grep per pill), and security software
  taxes every single exec. It's now two engine queries and one bar call,
  everything else pure bash — the bar repaint runs in roughly half the
  time even on an untaxed machine.

## [0.6.6] — 2026-07-27

### Fixed
- Switching workspaces no longer sometimes lands you somewhere else
  ("pressed 0, arrived on 4"). The self-heal that replaces auto-invented
  workspaces on background monitors used to do it by focusing that monitor,
  summoning, and focusing back — racing your own switch, and the loser was
  you. The engine now places a workspace on a monitor with no focus
  movement at all (`summon-workspace --on-monitor --no-focus`).

## [0.6.5] — 2026-07-27

### Fixed
- Plugging in monitors no longer scatters windows: engine recovery is one
  actor, once, after the dust settles. During a docking storm the engine
  could crash and two health ticks both "recovered" it — two engines
  launched, the snapshot restored twice, all while workspaces redistributed
  to monitors that were still renumbering. Recovery now takes a lock and
  waits out the display storm (8s of quiet) before touching anything.

### Fixed
- The dropdown terminal is one designated window, not "whichever window of
  that app is nearby": with several iTerm windows open, `$mod+\`` used to
  dismiss any of them on the current workspace (tiled work terminals
  included) and summon an arbitrary other — cycling through them all. Now
  the first window you toggle earns the job and keeps it; every other
  window of the app is a civilian. To re-designate, focus the window you
  want and toggle it once.

## [0.6.4] — 2026-07-27

### Fixed
- The engine no longer deletes its own Accessibility entry while waiting
  for the grant (an upstream reset that, embedded, erased the very row the
  permission prompt creates — leaving nothing to enable). The
  waiting-for-permission notification now also covers adding the helper by
  hand (+, ⌘⇧G, Panewright.app/Contents/Helpers/AeroSpace).

## [0.6.3] — 2026-07-27

### Fixed
- When the engine is alive but waiting for the Accessibility grant (fresh
  installs: the first-launch prompt leaves an *unchecked* "AeroSpace" row
  that blocks it), Panewright now notices within a minute and tells you the
  exact switch to flip — instead of running a bar over a desktop that
  silently never tiles.

## [0.6.2] — 2026-07-27

### Fixed
- **The engine now starts on machines that aren't the development machine.**
  Its default-config lookup fell through to a compile-time source path that
  exists exactly one place in the world, so on every other machine the
  engine died with an assertion on every launch — the bar drew, tiling
  silently never worked. The config now ships in the app bundle and the
  engine knows where to find it. (Issues #1, #2 — thank you, work MacBook.)

## [0.6.1] — 2026-07-27

### Fixed
- Bug and crash reports include the engine's log alongside the app's — an
  engine that dies on every launch writes its reason there and nowhere
  else, and the first field report of exactly that arrived without it.

## [0.6.0] — 2026-07-27

### Added
- **Multi-monitor support, for real.** Every visible workspace — one per
  monitor — is now fitted against the screen its monitor actually occupies;
  previously all fitting judged windows against the primary display, and
  windows on a second monitor were ignored entirely (or worse, "corrected"
  with the wrong screen's dimensions). The palette, overview, toasts, and
  the dropdown terminal open on the focused monitor, i3-style; the
  auto-hiding bar can be summoned from any display's edge; the dropdown's
  remembered size only replays on a screen it fits.
- `$mod+,` / `$mod+.` (and `+shift`) wrap around at the last monitor, so
  with three displays they cycle.
- **Workspaces have a home monitor.** `$mod+N` activates a workspace on its
  own monitor, i3-style — it no longer migrates the workspace to wherever
  you happen to be. Deliberately re-homing one is `$mod+shift+tab`, then
  the digit: summon mode pulls that workspace to the focused monitor.
- Sleep is survivable: a zombie SketchyBar (process alive, socket dead, a
  bare grey strip) is detected and replaced; the engine-stall check no
  longer runs while the displays are asleep (a lid-close false positive
  used to kill a healthy engine, which then stayed down all night); an
  engine restarted after a stall gets its windows restored from the
  snapshot; and the snapshot remembers which workspace each monitor was
  showing, so waking puts every workspace back on its own display.
- **Unfillable windows float themselves.** A window whose size can't be set
  at all floats on sight; one with a maximum size that leaves a persistent
  hole in the layout gets one chance to grow into it, then floats — with a
  toast saying why. The iPhone Mirroring class of app stops being fought
  over. `[fitting] float-unfillable`, on by default.
- Switching to an empty, hidden workspace opens it on the monitor you're on
  (i3 semantics, second half — it used to appear on the main display).
- The workspace snapshot now records each window's layout, so a floating
  window — an expanded pill, a hand-floated utility — comes back from an
  engine restart floating instead of being handed a grid slot.
- `$mod+tab` (back & forth) only remembers workspaces you actually dwelt
  on. Panewright's own machinery — restore, distribution, pill dances —
  bounces focus through workspaces in milliseconds, and every bounce used
  to become "the previous workspace": one press then teleported you to an
  empty workspace and spawned it on your monitor.
- Focus crossing to another monitor brings the pointer along, i3's
  `mouse_warping output` (`mouse-follows-focus`, on by default; lazy — the
  pointer stays put when it's already on the right display).
- **Per-monitor bar personalities.** By default the main display carries the
  widget chips and every other display gets a clean workspace strip —
  nothing duplicates. `[[bar.monitor]]` blocks override per display, matched
  by name fragment or class (`builtin`, `portrait`, `external`, `*`): pick a
  widget subset, or hide a display's bar entirely. Re-applies automatically
  as displays come and go — and editable in Settings → Appearance → "Bar
  per monitor".
- **Your scripts in the palette.** Anything executable in
  `~/.config/panewright/scripts/user-scripts/` appears in `$mod+D`
  automatically — `deploy-staging.sh` becomes "Deploy Staging", no
  registration step. Scripts using `panewright menu` get their picker;
  plain scripts just run.
- **Orphan windows get adopted.** A window the engine never learned about —
  born during an engine restart, or an app whose windows misreport their
  type until touched (Steam) — used to lurk outside the tiling and snap
  into the grid the first time it was clicked. A background sweep now spots
  windows that belong to no workspace and nudges them into adoption (an AX
  raise — no focus theft); resisters are logged and left alone.
- Hidden windows (including pills) park at the cheapest corner of the whole
  arrangement — with a second display, its far corner — so the primary
  display's corners stay completely clean.

### Fixed
- Docking no longer churns the desktop: display changes settle for four
  seconds before anything reacts (a dock's link negotiation can flap a
  monitor six times in under a minute, and every flap used to reload the bar
  and re-spread workspaces — workspaces visibly "disappearing").
- The monitor map (the M1/M2/M3 badges and per-display workspace strips)
  retries until SketchyBar reports geometry for every display, instead of
  silently keeping a stale single-display map forever.
- Plugging in a monitor gives it the lowest *empty* workspace, i3-style,
  instead of stealing workspace 0 — and a monitor already showing one of
  your workspaces is left completely alone.
- Hidden-workspace windows no longer paint a strip along a neighboring
  display's bottom edge (the engine now weighs "this corner bleeds onto
  another monitor" above "this corner is behind the Dock" when parking).
- A floating window that can't be raised above the tiling (cross-app
  z-order) is asked once per situation instead of four times a second.
- Plugging or unplugging a monitor no longer rebuilds the bar three times:
  the bar reloads only when the monitor map actually changed, and the
  zombie-bar check needs three silent probes (a bar busy re-laying-out for
  a new display is not a zombie — killing it mid-transition was most of
  the 15-second settle).

## [0.5.1] — 2026-07-26

### Added
- **Scripting tab in Settings** — all five hooks with their environment
  variables captioned inline (previously TOML-only), a listing of the
  built-in menu scripts and your own `user-scripts/`, and "New Script from
  Template" which drops a commented `panewright menu` starter into
  user-scripts/ and opens it in your editor. Every hook explains when it
  fires, what it's for, and what each variable means — with a
  paste-and-feel example.

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
