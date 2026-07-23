/// The user-facing Panewright configuration.
///
/// This is the single source of truth the GUI editor, the i3 importer, and the
/// emitters (AeroSpace, JankyBorders, SketchyBar) all operate on. It is parsed
/// from `~/.config/panewright/panewright.toml`.
public struct PanewrightConfig: Equatable, Sendable {
    /// The modifier every binding hangs off — i3's `$mod`.
    public enum Modifier: String, Equatable, Sendable, CaseIterable {
        /// Caps Lock remapped to Cmd+Opt+Ctrl (via Karabiner-Elements).
        case hyper
        case alt
        case cmd
        /// Ctrl+Opt — types no characters, near-zero macOS collisions.
        case ctrlAlt = "ctrl-alt"
        /// Ctrl+Cmd — beware macOS's own ctrl-cmd-space/f/q shortcuts.
        case ctrlCmd = "ctrl-cmd"
        /// No chord at all: a tmux-style prefix (``PanewrightConfig/leaderKey``)
        /// enters a one-shot command mode where every binding is a bare key.
        case leader
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
        public var enabled: Bool
        public var width: Int
        public var activeColor: String
        public var inactiveColor: String

        public init(
            enabled: Bool = true,
            width: Int = 4,
            activeColor: String = "#0A84FF",
            inactiveColor: String = "#00000000"
        ) {
            self.enabled = enabled
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
        /// i3's split layout — windows share the screen.
        case layoutTiles
        /// i3's stacking/tabbed equivalent — windows layered full-screen.
        case layoutAccordion
        case fullscreen
        case toggleFloating
        case focusMonitor(MonitorTarget)
        case moveToMonitor(MonitorTarget)
        case resize(ResizeDimension, Int)
        /// Group the focused window with its neighbor into a nested
        /// opposite-orientation container (AeroSpace's `join-with`).
        case joinWith(Direction)
        /// Un-nest every container on the workspace back to flat columns —
        /// the layout panic button.
        case flattenWorkspace
        case enterMode(String)
        /// i3's `exec` — run a shell command (usually `open -a <App>`).
        case exec(String)
    }

    public enum MonitorTarget: String, Equatable, Sendable, CaseIterable {
        case left, down, up, right, next, prev
    }

    public enum ResizeDimension: String, Equatable, Sendable, CaseIterable {
        case width, height
    }

    /// A named binding mode (i3's `mode "resize"`). Keys inside a mode are
    /// bound bare, without the modifier.
    public struct Mode: Equatable, Sendable {
        public var name: String
        public var bindings: [Binding]

        public init(name: String, bindings: [Binding]) {
            self.name = name
            self.bindings = bindings
        }
    }

    public struct Binding: Equatable, Sendable {
        public var key: String
        /// One key can chain several commands (i3's `cmd; cmd` chains).
        public var actions: [Action]

        public init(key: String, actions: [Action]) {
            self.key = key
            self.actions = actions
        }

        public init(key: String, action: Action) {
            self.init(key: key, actions: [action])
        }
    }

    public var modifier: Modifier
    /// The prefix chord when `modifier == .leader`, in AeroSpace key syntax.
    public var leaderKey: String
    public var gaps: Gaps
    public var focusBorder: FocusBorder
    public var bindings: [Binding]
    public var modes: [Mode]
    /// Bundle IDs of apps that float instead of tiling (i3's `for_window … floating enable`).
    public var floatingApps: [String]
    /// Workspace number → AeroSpace monitor pattern (`main`, `secondary`, a
    /// 1-based index, or a display-name regex).
    public var workspaceMonitors: [Int: String]

    public init(
        modifier: Modifier = .hyper,
        leaderKey: String = "cmd-semicolon",
        gaps: Gaps = Gaps(),
        focusBorder: FocusBorder = FocusBorder(),
        bindings: [Binding] = [],
        modes: [Mode] = [],
        floatingApps: [String] = [],
        workspaceMonitors: [Int: String] = [:]
    ) {
        self.modifier = modifier
        self.leaderKey = leaderKey
        self.gaps = gaps
        self.focusBorder = focusBorder
        self.bindings = bindings
        self.modes = modes
        self.floatingApps = floatingApps
        self.workspaceMonitors = workspaceMonitors
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
        // i3's $mod+e (split) and $mod+s (stacking).
        bindings.append(Binding(key: "e", action: .layoutTiles))
        bindings.append(Binding(key: "s", action: .layoutAccordion))
        // i3's $mod+f, $mod+Shift+space, $mod+r, $mod+Return.
        bindings.append(Binding(key: "f", action: .fullscreen))
        bindings.append(Binding(key: "shift-space", action: .toggleFloating))
        bindings.append(Binding(key: "r", action: .enterMode("resize")))
        bindings.append(Binding(key: "enter", action: .exec("open -a Terminal")))
        // Multi-monitor flow on the arrow keys.
        bindings.append(Binding(key: "left", action: .focusMonitor(.left)))
        bindings.append(Binding(key: "right", action: .focusMonitor(.right)))
        bindings.append(Binding(key: "shift-left", action: .moveToMonitor(.left)))
        bindings.append(Binding(key: "shift-right", action: .moveToMonitor(.right)))
        // $mod+g: join mode — group the focused window with a neighbor.
        // $mod+shift+g: un-group everything on the workspace.
        bindings.append(Binding(key: "g", action: .enterMode("join")))
        bindings.append(Binding(key: "shift-g", action: .flattenWorkspace))

        // i3's default resize mode: h/l shrink and grow width, j/k grow and
        // shrink height; Enter or Escape returns to normal bindings.
        let resize = Mode(
            name: "resize",
            bindings: [
                Binding(key: "h", action: .resize(.width, -50)),
                Binding(key: "j", action: .resize(.height, 50)),
                Binding(key: "k", action: .resize(.height, -50)),
                Binding(key: "l", action: .resize(.width, 50)),
                Binding(key: "enter", action: .enterMode("main")),
                Binding(key: "esc", action: .enterMode("main")),
            ])

        // Join mode replaces i3's "split then open" pre-declaration, which
        // AeroSpace's flatten normalization rules out: group after the fact,
        // then fall straight back to the main bindings.
        let join = Mode(
            name: "join",
            bindings: [
                Binding(key: "h", actions: [.joinWith(.left), .enterMode("main")]),
                Binding(key: "j", actions: [.joinWith(.down), .enterMode("main")]),
                Binding(key: "k", actions: [.joinWith(.up), .enterMode("main")]),
                Binding(key: "l", actions: [.joinWith(.right), .enterMode("main")]),
                Binding(key: "enter", action: .enterMode("main")),
                Binding(key: "esc", action: .enterMode("main")),
            ])

        return PanewrightConfig(
            bindings: bindings,
            modes: [resize, join],
            floatingApps: [
                "com.apple.systempreferences",
                "com.apple.calculator",
                "com.apple.ScreenContinuity",
            ])
    }
}
