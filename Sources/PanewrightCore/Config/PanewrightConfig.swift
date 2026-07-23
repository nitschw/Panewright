/// The user-facing Panewright configuration.
///
/// This is the single source of truth the GUI editor, the i3 importer, and the
/// emitters (AeroSpace, JankyBorders, SketchyBar) all operate on. It is parsed
/// from `~/.config/panewright/panewright.toml`.
public struct PanewrightConfig: Equatable, Sendable {
    /// The modifier every binding hangs off — i3's `$mod`.
    public enum Modifier: String, Equatable, Sendable, CaseIterable {
        /// Caps Lock remapped to Cmd+Opt+Ctrl+Shift (via Karabiner-Elements).
        case hyper
        case alt
        case cmd
    }

    public struct Gaps: Equatable, Sendable {
        public var inner: Int
        public var outer: Int

        public init(inner: Int = 8, outer: Int = 8) {
            self.inner = inner
            self.outer = outer
        }
    }

    /// Focus border drawn by JankyBorders. Colors are `#RRGGBB` or `#RRGGBBAA` hex.
    public struct FocusBorder: Equatable, Sendable {
        public var width: Int
        public var activeColor: String
        public var inactiveColor: String

        public init(width: Int = 4, activeColor: String = "#0A84FF", inactiveColor: String = "#00000000") {
            self.width = width
            self.activeColor = activeColor
            self.inactiveColor = inactiveColor
        }
    }

    public enum Direction: String, Equatable, Sendable, CaseIterable {
        case left, down, up, right
    }

    /// A window-management command, named with i3's vocabulary.
    public enum Action: Equatable, Sendable {
        case workspace(Int)
        case moveToWorkspace(Int)
        case focus(Direction)
        case move(Direction)
    }

    public struct Binding: Equatable, Sendable {
        public var key: String
        public var action: Action

        public init(key: String, action: Action) {
            self.key = key
            self.action = action
        }
    }

    public var modifier: Modifier
    public var gaps: Gaps
    public var focusBorder: FocusBorder
    public var bindings: [Binding]

    public init(
        modifier: Modifier = .hyper,
        gaps: Gaps = Gaps(),
        focusBorder: FocusBorder = FocusBorder(),
        bindings: [Binding] = []
    ) {
        self.modifier = modifier
        self.gaps = gaps
        self.focusBorder = focusBorder
        self.bindings = bindings
    }

    /// i3-familiar defaults: workspaces 1–9 on number keys, vim-style focus/move.
    public static var `default`: PanewrightConfig {
        var bindings: [Binding] = []
        for n in 1...9 {
            bindings.append(Binding(key: "\(n)", action: .workspace(n)))
            bindings.append(Binding(key: "shift-\(n)", action: .moveToWorkspace(n)))
        }
        let vim: [(String, Direction)] = [("h", .left), ("j", .down), ("k", .up), ("l", .right)]
        for (key, direction) in vim {
            bindings.append(Binding(key: key, action: .focus(direction)))
            bindings.append(Binding(key: "shift-\(key)", action: .move(direction)))
        }
        return PanewrightConfig(bindings: bindings)
    }
}
