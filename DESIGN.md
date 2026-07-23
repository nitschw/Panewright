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

**No App Store.** Confirmed technically impossible: the Mac App Store's
mandatory App Sandbox is incompatible with the Accessibility API
(`AXIsProcessTrusted` returns false under sandboxing regardless of
entitlements; Apple's own developer forums confirm this, and it's why
yabai/AeroSpace/Rectangle Pro all ship direct).

Instead:

- Free, open-source core on GitHub (MIT or GPL — undecided).
- Notarized direct-download builds.
- Patreon for monetization. Tiers TBD — early-build access, priority issues,
  and/or a gated Pro layer of theme packs and the visual config editor.

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
Cmd+Opt+Ctrl+Shift fired together, then bind all commands off that. This is
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

## Open questions

- Vendor vs. fork vs. subprocess-orchestrate AeroSpace / JankyBorders /
  SketchyBar.
- License choice (MIT vs. GPL).
- Ship our own Caps Lock → hyper-key remap, or delegate to Karabiner-Elements?
- Minimum supported macOS version.
- Onboarding flow for granting Accessibility permissions outside the App
  Store's trusted-install context.
