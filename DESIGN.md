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
- Monetization: Patreon-first — tiers for early-build access, priority
  issues, and/or gated Pro features (theme packs, visual config editor).
  Deliberately low-commitment: patronage sets lighter support expectations
  than selling licenses. Direct website sales (merchant-of-record such as
  Paddle, the Rectangle Pro model) stay open as a later option if demand
  warrants.

## Architecture decisions (settled)

### Workspaces: virtual, not native Spaces

Workspaces should **not** be built on native macOS Spaces — Spaces are
per-display, animate on every switch, and fragment around fullscreen apps.
Instead implement (or reuse AeroSpace's) virtual workspace model:

- Instant switching, no forced Mission-Control-style animation.
- Workspaces freely assignable to any display.

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
- Ongoing support and updates via Patreon.

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
