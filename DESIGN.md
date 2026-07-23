        # Panewright — Design Document

An i3-style tiling window manager experience for macOS that stays visually and
behaviorally Mac-native.

**Positioning:** "the Rectangle Pro of i3-on-Mac" — a polished GUI/config layer
over best-in-class existing primitives, not a from-scratch window manager.

## Why not build the tiling engine from scratch

AeroSpace, JankyBorders, and SketchyBar already cover the hard, low-level parts:

- **AeroSpace** — BSP tiling via the public Accessibility API; no SIP disable
  required.
- **JankyBorders** — gaps and colored focus borders.
- **SketchyBar** — a themeable status bar.

The gap in the market is a polished, GUI-driven, i3-config-importing wrapper
around that stack — not a novel WM engine. Decide early whether to orchestrate
these as vendored dependencies/subprocesses or fork pieces of their source.
Don't reimplement AXUIElement tiling from zero unless there's a concrete reason
AeroSpace's model can't be extended.

## Distribution & monetization

**No App Store.** Re-verified 2026-07-22: new Mac App Store submissions must
enable the App Sandbox, and under the sandbox the Accessibility API is dead —
the permission prompt never fires, the app cannot be added manually in System
Settings, and `AXIsProcessTrusted` always returns false. The window managers
on the Store today (Magnet, BetterSnapTool, Divvy) were grandfathered in
unsandboxed before the 2012 sandbox mandate; Moom 4 had to leave the Store
over exactly this. New entrants ship direct — as do yabai, AeroSpace, and
Rectangle Pro.

Instead:

- Free, open-source core on GitHub (MIT — see resolved questions).
- Notarized direct-download builds (Developer ID signing + notarization,
  Sparkle for auto-updates).
- Monetization (settled 2026-07-23, refined same day): **fully open
  source, Patreon as a pure tip jar.** Everything ships MIT on the public
  repo; the Patreon pitch is simply "building this costs evenings and
  weekends — buy me a coffee." No gated features, no promised perks, no
  early-access obligations (the Sparkle second-channel infrastructure
  exists if that ever changes). Zero commitments is the point: no license
  keys, no support contracts, no delivery schedule owed to anyone. The
  open-core split was considered and rejected in favor of community trust
  with the i3 audience.

## Architecture decisions (settled)

### Workspaces: virtual, not native Spaces

Workspaces should **not** be built on native macOS Spaces — Spaces are
per-display, animate on every switch, and fragment around fullscreen apps.
Instead implement (or reuse AeroSpace's) virtual workspace model:

- Instant switching, no forced Mission-Control-style animation.
- Workspaces freely assignable to any display.

**Known tradeoff:** virtual workspaces keep every window in one native Space
(hidden windows are parked offscreen), so Mission Control shows *all* windows
from *all* workspaces at once — tiny thumbnails. Mitigations: macOS's "Group
windows by application" setting (System Settings → Desktop & Dock → Mission
Control); longer-term, Panewright's trackpad-gesture layer and a workspace
overview of its own should replace what Mission Control was used for.

### Mod key: hyper key, not fn

`fn` is not reliably capturable as a global hotkey modifier via public APIs.
Use the established "hyper key" pattern instead: remap Caps Lock to
Cmd+Opt+Ctrl fired together (leaving Shift out of the base combo so i3-style
`$mod+Shift+…` chords stay distinguishable), then bind all commands off that. This is
what AeroSpace/yabai/skhd users already do via Karabiner-Elements. Open
question: does Panewright ship its own remap mechanism, or document/automate
the Karabiner setup during onboarding?

### Multi-monitor flow: two coexisting layers

Both layers should coexist — neither replaces the other:

1. **i3-style keybinding layer** — move focused window to next display, pull a
   workspace onto the current display; instant, no animation.
2. **Optional Mac-native layer** — trackpad 3/4-finger swipe to switch
   workspaces.

### Visual identity: Mac-native, with a Linux preset

Preserve native macOS window chrome (traffic lights, shadows, rounded corners,
vibrancy) rather than stripping it Linux-bare. Gaps and a colored focus border
are added as a purely visual layer via JankyBorders.

The status bar defaults to a native-feeling look (SF Symbols, vibrancy) but is
themeable to a full "technical/Linux" preset as a one-toggle config option.
This dual-aesthetic support is a deliberate differentiator, not scope creep.

### Config format

TOML, with i3 syntax as the mental model: `$mod`, workspace numbers, modal
bindings.

**Flagship feature: i3-config importer.** A converter that reads a real
`~/.config/i3/config`, maps `$mod` to the hyper key, translates
workspace/keybinding syntax, and explicitly flags anything untranslatable
(X11-only commands, etc.) rather than failing silently.

## The product wedge

What justifies charging money when the underlying stack is free:

- A native SwiftUI GUI with live preview for editing config — replacing
  hand-edited TOML/Lua spread across three separate tools.
- The i3-config importer.
- Theme packs.
- Visual polish the underlying stack can't do alone — headlined by
  drag-to-tile (see below).
- Ongoing support and updates via Patreon.

## Drag-to-tile semantics (planned; the flagship interaction)

Modeled on i3 4.21's tiling drag. While a tiled window is dragged over
another window:

- Drop on the target's **center** → swap the two windows.
- Drop on an **edge zone** (left/right/top/bottom band) → split the target's
  cell on that axis and stack the dragged window on that side, within the
  cell the target occupies.
- From the moment the pointer enters a zone, a translucent accent-colored
  overlay previews the exact frame the dragged window will occupy on release.

Implementation sketch: detect the drag via a CGEventTap / AX window-moved
observers, hit-test the pointer against AeroSpace's window frames, draw the
overlay (Panewright's own windows — no private APIs), and on drop realize
the layout with window-id-addressed AeroSpace commands (`focus --window-id`,
`join-with`, `move`). AeroSpace's native drag behavior — an instant swap on
any frame overlap, verified unconfigurable (no disable/threshold options) —
must be neutralized: on drag-start, immediately float the dragged window
(floating windows are exempt from AeroSpace's drag-swap), run the
zone/overlay interaction under Panewright's control, and re-tile on drop.

Prerequisite: Panewright itself needs Accessibility/Input Monitoring
permission for the event tap, which requires the stable code signature of a
real .app bundle — the bundle work is a hard dependency of this feature.

## Long-term: self-contained Panewright

End-state goal (decided 2026-07-22): Panewright should eventually depend on
no external software — one app, no Homebrew, no third-party daemons. The
orchestration architecture stays the launch strategy; absorption happens in
shippable stages, cheapest first:

1. **Bundle the binaries** (no rewrite). AeroSpace is MIT and may be embedded
   inside Panewright.app; JankyBorders/SketchyBar are GPL-3.0 and may only be
   *shipped alongside* as separate unmodified programs with license texts and
   a source pointer. Result: one download, zero prerequisites.
2. **Replace JankyBorders with native borders.** Panewright already draws
   overlay windows (drag ghosts); a focus border is the same tech tracking
   the focused window's frame. Small, drops one GPL dependency.
3. **Replace SketchyBar with a native bar.** An AppKit/SwiftUI bar window
   gives us the native/technical themes end-to-end without generating shell
   scripts. Drops the other GPL dependency.
4. **Absorb the tiling engine last.** AeroSpace's MIT license permits porting
   its core into Panewright (with attribution) — a port, not a from-scratch
   rewrite. Keep the internal command surface CLI-shaped so the emitters and
   executor survive. Highest risk; undertake once the product has
   users/revenue to justify owning that layer.

**Licensing rule for all stages:** never absorb GPL source into MIT
Panewright. Replacements for JankyBorders/SketchyBar must be original code;
only AeroSpace's MIT code may be absorbed.

## Keyboard-complete + scripting (the "full tiling WM" milestone)

Decided 2026-07-23: lean fully into keyboard-first workflows and user
scripting.

**Shipped:** `exec` bindings run anything (Python included); the
`[hooks]` section runs a user command on every workspace switch with
`WORKSPACE`/`PREV_WORKSPACE` env; the `aerospace` CLI doubles as the
query/control API for scripts; `workspace back_and_forth` on `$mod+Tab`.

**Next: the launcher.** A dmenu/rofi-class fuzzy panel on `$mod+D`:
type-to-filter across open windows (jump via `focus --window-id`),
installed apps (launch), and Panewright commands. Keyboard-only, instant,
themed with the accent. This replaces the i3 refugee's single most-missed
muscle memory and is the natural home for future command-palette features.

**Later:** richer hook events (window created/focused, mode changed,
display changed) once the engine is absorbed; a `panewright` Python
helper module (thin wrapper over the CLI) as an example, not a runtime.

## Integrations (work items in the bar)

Shipped 2026-07-23: a provider-agnostic subsystem — bar pills with counts,
a searchable/sortable panel, links straight to the browser. GitHub (review
requests + your open PRs, falling back to the `gh` CLI token so it needs no
setup), GitLab (MRs authored/assigned, with head-pipeline bubbles), and
Jira (assigned unresolved issues) ship; Bitbucket conforms to the same
`IntegrationProvider` protocol when written.

**Credentials rule:** tokens live in the login Keychain, never in
`panewright.toml` — that file travels in profiles, issue reports, and
dotfile repos. Config holds only non-secrets (enabled, host, account).
Credential entry is a real window, not an NSAlert accessory: secure fields
inside alerts silently truncate pasted tokens in accessory apps.

### Confluence browser (planned, its own project)

Not a list like the others — a full reader:

- **Large window**, split view: sources on the left, article on the right.
- **Search** across spaces, plus **favorites** pinned for instant return.
- **Full page rendering** in-app (Confluence's REST API returns storage-format
  HTML; render it in a WKWebView with the site's auth, or convert to
  attributed text for a native look).
- **Collapsible sections that preserve scroll position** — the point is
  keeping your place across a work session, so expansion state and scroll
  offset persist per article between launches.

Sizeable enough to schedule separately from the list-shaped providers.

## Build order

1. MVP wrapping AeroSpace for tiling + workspace switching + config parsing.
2. JankyBorders integration for gaps/borders.
3. SketchyBar integration for the status bar.
4. i3-config importer.
5. SwiftUI visual config editor — the real product differentiator.
6. Patreon-gated theme packs / Pro features.

## Resolved questions (2026-07-22)

- **Orchestration model:** subprocess-orchestrate AeroSpace / JankyBorders /
  SketchyBar via their CLIs and generated config files. Fork only if a
  concrete feature can't be expressed through the CLI surface.
- **License:** MIT for Panewright. JankyBorders and SketchyBar are GPL-3.0,
  but running them as separate processes (never linking or vendoring their
  source) keeps Panewright's own code MIT-clean, which the paid Pro layer
  requires.
- **Hyper key:** delegate to Karabiner-Elements for the MVP; automate its
  setup during onboarding later. The remap emits Cmd+Opt+Ctrl without Shift
  (see "Mod key" above).
- **Minimum macOS:** 14 (Sonoma). AeroSpace itself requires 13+.

## Open questions

- Onboarding flow for granting Accessibility permissions outside the App
  Store's trusted-install context.
- Patreon tier structure (what goes in early-access vs. gated Pro).
