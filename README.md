# Panewright

Truly tiled windows for MacOS — an i3-style tiling experience that stays
visually and behaviorally Mac-native.

Panewright is not a from-scratch window manager. It is a polished GUI and
config layer that orchestrates best-in-class existing tools:

- [AeroSpace](https://github.com/nikitabobko/AeroSpace) — tiling and virtual
  workspaces via the public Accessibility API (no SIP disable)
- [JankyBorders](https://github.com/FelixKratz/JankyBorders) — gaps and
  colored focus borders
- [SketchyBar](https://github.com/FelixKratz/SketchyBar) — themeable status
  bar

You write one i3-flavored `panewright.toml` (or, eventually, click through a
native SwiftUI editor); Panewright generates and supervises the configs of the
underlying tools. See [DESIGN.md](DESIGN.md) for the full architecture and
roadmap.

## Status

Early development. Working today: config parsing, AeroSpace config generation
(workspaces, focus/move, layouts, float rules, monitor bindings, resize mode),
and live control of a running AeroSpace instance.

## Requirements

- macOS 14+
- [AeroSpace](https://github.com/nikitabobko/AeroSpace):
  `brew install --cask nikitabobko/tap/aerospace`
- [JankyBorders](https://github.com/FelixKratz/JankyBorders):
  `brew install FelixKratz/formulae/borders`

## Build & test

```sh
swift build
swift test
```

Generate an AeroSpace config from a Panewright config:

```sh
swift run panewright-dev emit Examples/panewright.toml
```

## Configuration

See [Examples/panewright.toml](Examples/panewright.toml). Every key is
optional; the defaults give you i3's muscle memory (workspaces 1–9,
vim-style hjkl focus/move, `$mod+r` resize mode) with `$mod` as the hyper
key (Caps Lock via Karabiner-Elements, or `alt`/`cmd`).

## License

[MIT](LICENSE)
