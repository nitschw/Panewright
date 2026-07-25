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
        /// Ctrl alone — pairs with macOS's built-in Caps Lock → Control
        /// remap for a Caps Lock mod key with no third-party software.
        /// Beware terminal bindings (Ctrl+C, Ctrl+L…).
        case ctrl
        /// Ctrl+Opt — types no characters, near-zero macOS collisions.
        case ctrlAlt = "ctrl-alt"
        /// Ctrl+Cmd — beware macOS's own ctrl-cmd-space/f/q shortcuts.
        case ctrlCmd = "ctrl-cmd"
        /// No chord at all: a tmux-style prefix (``PanewrightConfig/leaderKey``)
        /// enters a one-shot command mode where every binding is a bare key.
        case leader
    }

    /// What to do when tiled windows overlap because an app won't shrink past
    /// its minimum size. See `WindowFitting` for why this can't just be a
    /// layout calculation.
    public struct Fitting: Equatable, Sendable {
        /// Watch for overlap and correct it at all.
        public var enabled: Bool
        /// When no arrangement of the windows fits, move the newest arrival to
        /// another workspace. On by default, but never silently — overlapping
        /// windows are broken tiling, so fixing it is the right default as
        /// long as we always say we did.
        public var overflow: Bool
        /// Points to ask for per shrink attempt. Large enough to make progress
        /// in a few passes, small enough not to overshoot a fitting layout.
        public var step: Int

        public init(enabled: Bool = true, overflow: Bool = true, step: Int = 60) {
            self.enabled = enabled
            self.overflow = overflow
            self.step = step
        }
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
        /// i3's `kill` — close the focused window.
        case close
        /// i3's `scratchpad show` — summon the stashed window, floating.
        case scratchpadShow
        /// i3's `move scratchpad` — stash the focused window away.
        case scratchpadMove
        /// i3's `workspace back_and_forth` — bounce to the previous workspace.
        case workspaceBackAndForth
        /// Prompt for a new to-do item.
        case todoAdd
        /// Stash the focused window into a bar pill you can peek at later.
        case pillWindow
        /// Open the keybinding cheat-sheet window.
        case help
        /// Equalize every window's size in the workspace (AeroSpace's
        /// `balance-sizes`).
        case balanceSizes
        /// The real macOS green-button fullscreen, distinct from the virtual
        /// `fullscreen` toggle.
        case nativeFullscreen
        /// Minimize the focused window to the Dock.
        case minimize
        /// Close every window on the workspace except the focused one.
        case closeOthers
        /// Window-level back-and-forth — jump to the previously focused window
        /// (the counterpart to `workspaceBackAndForth`).
        case focusBackAndForth
        /// Move the whole focused workspace to another monitor.
        case moveWorkspaceToMonitor(MonitorTarget)
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

    /// SketchyBar-driven status bar. The theme toggle is the dual-aesthetic
    /// differentiator: native (SF Pro, vibrancy, floating pill) vs technical
    /// (monospace, square, solid — the Linux look).
    public struct StatusBar: Equatable, Sendable {
        public enum Theme: String, Equatable, Sendable, CaseIterable {
            case native, technical
        }

        public var enabled: Bool
        public var theme: Theme
        /// Highlight color for the active workspace pill. `nil` follows
        /// ``FocusBorder/activeColor`` so one accent drives the whole system;
        /// set it to break the bar's highlight away from the window border.
        public var accentColor: String?

        public init(enabled: Bool = true, theme: Theme = .native, accentColor: String? = nil) {
            self.enabled = enabled
            self.theme = theme
            self.accentColor = accentColor
        }
    }

    /// A plain-text to-do list surfaced in the status bar. Storage is
    /// `~/.config/panewright/todo.txt`, one task per line — editable by any
    /// tool, not just Panewright.
    public struct TodoList: Equatable, Sendable {
        public var enabled: Bool

        public init(enabled: Bool = true) {
            self.enabled = enabled
        }
    }

    /// Optional bar widgets beyond the window manager. Every one is off by
    /// default — the bar stays pure WM unless you opt in. All are polled by a
    /// single batched driver (never one process per widget), and none needs
    /// sudo or SIP disabled.
    public struct Modules: Equatable, Sendable {
        /// CPU/memory chip that unfurls a mini-htop perf panel.
        public var systemMonitor: Bool
        /// The two sparkline plots beside the CPU/memory readout. Separate
        /// from `systemMonitor` so the numbers can stay without the graphics.
        public var systemGraphs: Bool
        /// Live ↓/↑ throughput for the default interface.
        public var network: Bool
        /// Ports currently listening, click to see what owns them.
        public var ports: Bool
        /// Boot-volume usage.
        public var disk: Bool
        /// Charge, time remaining, and draw — the parts the menu bar hides.
        public var battery: Bool
        /// Running container count.
        public var docker: Bool
        /// kubectl context / AWS profile, highlighted when it looks like prod.
        public var cloudContext: Bool
        /// How many windows are stashed on the scratchpad.
        public var scratchpad: Bool
        /// Microphone live/muted — click to toggle.
        public var micMute: Bool
        /// Output volume — click to mute.
        public var volume: Bool
        /// Outdated Homebrew packages waiting to be upgraded.
        public var brewUpdates: Bool
        /// Whether a VPN/tunnel interface is up.
        public var vpn: Bool
        /// Active keyboard input source.
        public var keyboardLayout: Bool
        /// Whether a macOS Focus (Do Not Disturb) is on.
        public var focusMode: Bool
        /// Now playing from Music/Spotify.
        public var nowPlaying: Bool
        /// Current conditions, refreshed hourly.
        public var weather: Bool
        /// Bar order, left to right, by config key. Keys missing from this list
        /// fall in behind it in catalog order, so a new widget appears without
        /// anyone having to edit their ordering.
        public var order: [String]

        public init(
            systemMonitor: Bool = false, systemGraphs: Bool = true, network: Bool = false, ports: Bool = false,
            disk: Bool = false, battery: Bool = false, docker: Bool = false,
            cloudContext: Bool = false, scratchpad: Bool = false, micMute: Bool = false, volume: Bool = false,
            brewUpdates: Bool = false, vpn: Bool = false, keyboardLayout: Bool = false,
            focusMode: Bool = false, nowPlaying: Bool = false, weather: Bool = false,
            order: [String] = []
        ) {
            self.systemMonitor = systemMonitor
            self.systemGraphs = systemGraphs
            self.network = network
            self.ports = ports
            self.disk = disk
            self.battery = battery
            self.docker = docker
            self.cloudContext = cloudContext
            self.scratchpad = scratchpad
            self.micMute = micMute
            self.volume = volume
            self.brewUpdates = brewUpdates
            self.vpn = vpn
            self.keyboardLayout = keyboardLayout
            self.focusMode = focusMode
            self.nowPlaying = nowPlaying
            self.weather = weather
            self.order = order
        }

        /// Every widget as (config key, human name, keypath) — the single list
        /// the menu, the parser, and the serializer all work from, so adding a
        /// widget never means remembering to update three places.
        public static var catalog: [(key: String, name: String, category: String, path: WritableKeyPath<Modules, Bool>)] {
            [
            ("system-monitor", "CPU & Memory", "System", \.systemMonitor),
            ("system-graphs", "CPU & Memory Graphs", "System", \.systemGraphs),
            ("network", "Network", "System", \.network),
            ("ports", "Listening Ports", "Developer", \.ports),
            ("disk", "Disk", "System", \.disk),
            ("battery", "Battery", "System", \.battery),
            ("docker", "Docker", "Developer", \.docker),
            ("cloud-context", "Cloud Context", "Developer", \.cloudContext),
            ("scratchpad", "Scratchpad", "Window Manager", \.scratchpad),
            ("mic-mute", "Microphone", "Media & Input", \.micMute),
            ("volume", "Volume", "Media & Input", \.volume),
            ("brew-updates", "Homebrew Updates", "Developer", \.brewUpdates),
            ("vpn", "VPN", "Developer", \.vpn),
            ("keyboard-layout", "Keyboard Layout", "Media & Input", \.keyboardLayout),
            ("focus-mode", "Focus / DND", "Media & Input", \.focusMode),
            ("now-playing", "Now Playing", "Media & Input", \.nowPlaying),
            ("weather", "Weather", "Ambient", \.weather),
            ]
        }

        /// Every widget key in bar order — the configured order first, then
        /// anything new appended in catalog order.
        public var resolvedOrder: [String] {
            let known = Set(Self.catalog.map(\.key))
            var result = order.filter(known.contains)
            let seen = Set(result)
            result.append(contentsOf: Self.catalog.map(\.key).filter { !seen.contains($0) })
            return result
        }

        /// Display order for the picker's sections.
        public static var categories: [String] {
            ["Window Manager", "System", "Developer", "Media & Input", "Ambient"]
        }

        /// True when any driver-polled widget is on (the system monitor has its
        /// own item and plugin, so it doesn't count here).
        public var anyDriverWidget: Bool {
            network || ports || disk || battery || docker || cloudContext
                || scratchpad || micMute || volume || brewUpdates || vpn || keyboardLayout
                || focusMode || nowPlaying || weather
        }
    }

    public var modifier: Modifier
    /// The prefix chord when `modifier == .leader`, in AeroSpace key syntax.
    public var leaderKey: String
    /// Parking windows into bar pills.
    public struct Pills: Equatable, Sendable {
        public var enabled: Bool
        /// Drop a dragged window on an empty part of the bar to park it.
        public var dragToBar: Bool

        public init(enabled: Bool = true, dragToBar: Bool = true) {
            self.enabled = enabled
            self.dragToBar = dragToBar
        }
    }

    public var todo: TodoList
    public var pills: Pills
    public var modules: Modules
    public var integrations: IntegrationsConfig
    /// i3's `focus_follows_mouse` — hover moves focus, no click. Implemented
    /// by Panewright's event tap (AeroSpace has no native support).
    public var focusFollowsMouse: Bool
    public var statusBar: StatusBar
    public var gaps: Gaps
    public var fitting: Fitting
    public var focusBorder: FocusBorder
    public var bindings: [Binding]
    public var modes: [Mode]
    /// Bundle IDs of apps that float instead of tiling (i3's `for_window … floating enable`).
    public var floatingApps: [String]
    /// Workspace number → AeroSpace monitor pattern (`main`, `secondary`, a
    /// 1-based index, or a display-name regex).
    public var workspaceMonitors: [Int: String]
    /// Bundle ID → workspace number: apps that always open on a given
    /// workspace (i3's `assign`).
    public var appWorkspaces: [String: Int]
    /// Shell command run on every workspace switch, with `WORKSPACE` and
    /// `PREV_WORKSPACE` set — the scripting hook (`python3 ~/hooks/ws.py`).
    public var workspaceChangedHook: String?
    /// Shell command run whenever window focus changes, with `FOCUSED_APP`,
    /// `FOCUSED_WINDOW_ID`, and `WORKSPACE` set. Fires often (every focus
    /// change) — keep the command light.
    public var focusChangedHook: String?
    /// Conflict IDs the user has chosen to live with. Kept in the config
    /// rather than app preferences so "Ignore" also silences the bar's ⚠ chip
    /// — a warning you dismissed that keeps glowing is worse than no warning.
    public var ignoredConflicts: [String]

    public init(
        // Ctrl+Cmd: a real chord (one keypress per command), types no
        // characters, and needs no third-party remapper — the best default
        // that works out of the box. Caps-Lock hyper remains one line away.
        modifier: Modifier = .ctrlCmd,
        // Same chord as the default modifier, plus a key — a prefix can't be
        // modifiers alone. Space keeps it one thumb press away.
        leaderKey: String = "ctrl-cmd-space",
        todo: TodoList = TodoList(),
        pills: Pills = Pills(),
        modules: Modules = Modules(),
        integrations: IntegrationsConfig = IntegrationsConfig(),
        focusFollowsMouse: Bool = false,
        statusBar: StatusBar = StatusBar(),
        gaps: Gaps = Gaps(),
        fitting: Fitting = Fitting(),
        focusBorder: FocusBorder = FocusBorder(),
        bindings: [Binding] = [],
        modes: [Mode] = [],
        floatingApps: [String] = [],
        workspaceMonitors: [Int: String] = [:],
        appWorkspaces: [String: Int] = [:],
        workspaceChangedHook: String? = nil,
        focusChangedHook: String? = nil,
        ignoredConflicts: [String] = []
    ) {
        self.modifier = modifier
        self.leaderKey = leaderKey
        self.todo = todo
        self.pills = pills
        self.modules = modules
        self.integrations = integrations
        self.focusFollowsMouse = focusFollowsMouse
        self.statusBar = statusBar
        self.gaps = gaps
        self.fitting = fitting
        self.focusBorder = focusBorder
        self.bindings = bindings
        self.modes = modes
        self.floatingApps = floatingApps
        self.workspaceMonitors = workspaceMonitors
        self.appWorkspaces = appWorkspaces
        self.workspaceChangedHook = workspaceChangedHook
        self.focusChangedHook = focusChangedHook
        self.ignoredConflicts = ignoredConflicts
    }

    /// i3-familiar defaults: workspaces 1–9 on number keys, vim-style focus/move.
    public static var `default`: PanewrightConfig {
        var bindings: [Binding] = []
        // Keyboard-row order: 1–9, then 0 as the tenth workspace.
        for n in Array(1...9) + [0] {
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
        // i3's scratchpad: $mod+minus summons, $mod+shift+minus stashes.
        bindings.append(Binding(key: "minus", action: .scratchpadShow))
        bindings.append(Binding(key: "shift-minus", action: .scratchpadMove))
        // i3's $mod+Tab reflex: bounce to the previous workspace.
        bindings.append(Binding(key: "tab", action: .workspaceBackAndForth))
        // $mod+t: capture a to-do without leaving the keyboard.
        bindings.append(Binding(key: "t", action: .todoAdd))
        // $mod+p: park the focused window in the bar.
        bindings.append(Binding(key: "p", action: .pillWindow))
        // $mod+?: the cheat sheet. ($mod+shift+h is taken by "move left".)
        bindings.append(Binding(key: "shift-slash", action: .help))

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
