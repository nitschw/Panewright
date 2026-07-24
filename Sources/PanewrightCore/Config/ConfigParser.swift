import Foundation
import TOMLKit

public enum ConfigError: Error, Equatable, CustomStringConvertible {
    case invalidTOML(String)
    case invalidModifier(String)
    case invalidAction(String)
    case invalidWorkspaceNumber(String)
    case invalidColor(String)
    case invalidTheme(String)
    case invalidProfileName(String)

    public var description: String {
        switch self {
        case .invalidTOML(let detail):
            "invalid TOML: \(detail)"
        case .invalidModifier(let value):
            "unknown modifier '\(value)' (expected hyper, alt, cmd, ctrl, ctrl-alt, ctrl-cmd, or leader)"
        case .invalidAction(let value):
            "unrecognized action '\(value)'"
        case .invalidWorkspaceNumber(let value):
            "workspace-monitors keys must be workspace numbers, got '\(value)'"
        case .invalidColor(let value):
            "invalid color '\(value)' (expected #RRGGBB or #RRGGBBAA)"
        case .invalidTheme(let value):
            "unknown bar theme '\(value)' (expected native or technical)"
        case .invalidProfileName(let value):
            "invalid profile name '\(value)'"
        }
    }
}

/// Parses `panewright.toml` into a ``PanewrightConfig``.
///
/// Every key is optional; omitted keys fall back to ``PanewrightConfig/default``.
/// Unknown modifiers and actions are hard errors — the importer philosophy is
/// to flag what we can't translate, never to fail silently.
public enum ConfigParser {
    public static func parse(toml: String) throws -> PanewrightConfig {
        let raw: RawConfig
        do {
            raw = try TOMLDecoder().decode(RawConfig.self, from: toml)
        } catch {
            throw ConfigError.invalidTOML(String(describing: error))
        }

        var config = PanewrightConfig.default

        if let modifier = raw.modifier {
            guard let parsed = PanewrightConfig.Modifier(rawValue: modifier) else {
                throw ConfigError.invalidModifier(modifier)
            }
            config.modifier = parsed
        }
        if let leaderKey = raw.leaderKey {
            config.leaderKey = normalizeKeySpec(leaderKey)
        }
        if let focusFollowsMouse = raw.focusFollowsMouse {
            config.focusFollowsMouse = focusFollowsMouse
        }
        if let bar = raw.bar {
            config.statusBar.enabled = bar.enabled ?? config.statusBar.enabled
            if let theme = bar.theme {
                guard let parsed = PanewrightConfig.StatusBar.Theme(rawValue: theme) else {
                    throw ConfigError.invalidTheme(theme)
                }
                config.statusBar.theme = parsed
            }
            if let accent = bar.accentColor {
                // Fail loudly here rather than emitting a bar the daemon rejects.
                _ = try ColorHex.argb(fromCSSHex: accent)
                config.statusBar.accentColor = accent
            }
        }
        if let gaps = raw.gaps {
            config.gaps.inner = gaps.inner ?? config.gaps.inner
            config.gaps.outer = gaps.outer ?? config.gaps.outer
        }
        if let border = raw.border {
            config.focusBorder.enabled = border.enabled ?? config.focusBorder.enabled
            config.focusBorder.width = border.width ?? config.focusBorder.width
            config.focusBorder.activeColor = border.activeColor ?? config.focusBorder.activeColor
            config.focusBorder.inactiveColor = border.inactiveColor ?? config.focusBorder.inactiveColor
            // Fail loudly at parse time, not when the daemon launches.
            _ = try ColorHex.argb(fromCSSHex: config.focusBorder.activeColor)
            _ = try ColorHex.argb(fromCSSHex: config.focusBorder.inactiveColor)
        }
        if let bindings = raw.binding {
            config.bindings = try bindings.map { rawBinding in
                PanewrightConfig.Binding(
                    key: rawBinding.key,
                    actions: try parseActionChain(rawBinding.action)
                )
            }
        }
        if let modes = raw.mode {
            // Custom modes replace the defaults wholesale.
            config.modes = try modes.map { rawMode in
                PanewrightConfig.Mode(
                    name: rawMode.name,
                    bindings: try (rawMode.binding ?? []).map { rawBinding in
                        PanewrightConfig.Binding(
                            key: rawBinding.key,
                            actions: try parseActionChain(rawBinding.action))
                    })
            }
        }
        if let floatingApps = raw.floatingApps {
            config.floatingApps = floatingApps
        }
        if let assignments = raw.workspaceMonitors {
            var monitors: [Int: String] = [:]
            for (key, monitor) in assignments {
                guard let workspace = Int(key) else {
                    throw ConfigError.invalidWorkspaceNumber(key)
                }
                monitors[workspace] = monitor
            }
            config.workspaceMonitors = monitors
        }
        if let appWorkspaces = raw.workspaceApps {
            config.appWorkspaces = appWorkspaces
        }
        if let todo = raw.todo {
            config.todo.enabled = todo.enabled ?? config.todo.enabled
        }
        if let pills = raw.pills {
            config.pills.enabled = pills.enabled ?? config.pills.enabled
            config.pills.dragToBar = pills.dragToBar ?? config.pills.dragToBar
        }
        if let integrations = raw.integrations {
            func service(_ raw: RawConfig.RawService?) -> IntegrationsConfig.Service {
                IntegrationsConfig.Service(
                    enabled: raw?.enabled ?? false,
                    host: raw?.host ?? "",
                    user: raw?.user ?? "")
            }
            config.integrations = IntegrationsConfig(
                github: service(integrations.github),
                gitlab: service(integrations.gitlab),
                bitbucket: service(integrations.bitbucket),
                jira: service(integrations.jira),
                confluence: service(integrations.confluence))
        }
        if let hooks = raw.hooks {
            config.workspaceChangedHook = hooks.workspaceChanged
        }
        return config
    }

    /// Parses a `;`-separated chain of actions (i3's command chains).
    public static func parseActionChain(_ string: String) throws -> [PanewrightConfig.Action] {
        try string.split(separator: ";").map {
            try parseAction($0.trimmingCharacters(in: .whitespaces))
        }
    }

    /// Parses an i3-flavored action string: `workspace 3`, `move to workspace 3`,
    /// `focus left`, `move right`, `fullscreen`, `floating toggle`,
    /// `focus monitor next`, `resize width -50`, `join left`, `mode resize`,
    /// `exec …`.
    static func parseAction(_ string: String) throws -> PanewrightConfig.Action {
        if string.hasPrefix("exec ") {
            return .exec(String(string.dropFirst("exec ".count)))
        }
        let words = string.split(separator: " ").map(String.init)
        if words.count == 2, words[0] == "workspace", let n = Int(words[1]) {
            return .workspace(n)
        }
        if words.count == 4, words[0] == "move", words[1] == "to", words[2] == "workspace",
            let n = Int(words[3]) {
            return .moveToWorkspace(n)
        }
        if words.count == 2, words[0] == "focus",
            let direction = PanewrightConfig.Direction(rawValue: words[1]) {
            return .focus(direction)
        }
        if words.count == 2, words[0] == "move",
            let direction = PanewrightConfig.Direction(rawValue: words[1]) {
            return .move(direction)
        }
        if words.count == 2, words[0] == "layout", words[1] == "tiles" {
            return .layoutTiles
        }
        if words.count == 2, words[0] == "layout", words[1] == "accordion" {
            return .layoutAccordion
        }
        if words == ["fullscreen"] {
            return .fullscreen
        }
        if words == ["floating", "toggle"] {
            return .toggleFloating
        }
        if words.count == 3, words[0] == "focus", words[1] == "monitor",
            let target = PanewrightConfig.MonitorTarget(rawValue: words[2]) {
            return .focusMonitor(target)
        }
        if words.count == 4, words[0] == "move", words[1] == "to", words[2] == "monitor",
            let target = PanewrightConfig.MonitorTarget(rawValue: words[3]) {
            return .moveToMonitor(target)
        }
        if words.count == 3, words[0] == "resize",
            let dimension = PanewrightConfig.ResizeDimension(rawValue: words[1]),
            let delta = Int(words[2]) {
            return .resize(dimension, delta)
        }
        if words == ["todo", "add"] {
            return .todoAdd
        }
        if words == ["pill", "window"] {
            return .pillWindow
        }
        if words == ["scratchpad", "show"] {
            return .scratchpadShow
        }
        if words == ["workspace", "back_and_forth"] {
            return .workspaceBackAndForth
        }
        if words == ["move", "scratchpad"] {
            return .scratchpadMove
        }
        if words.count == 2, words[0] == "join",
            let direction = PanewrightConfig.Direction(rawValue: words[1]) {
            return .joinWith(direction)
        }
        if words == ["flatten"] {
            return .flattenWorkspace
        }
        if words == ["close"] {
            return .close
        }
        if words.count == 2, words[0] == "mode" {
            return .enterMode(words[1])
        }
        throw ConfigError.invalidAction(string)
    }

    /// Translates a human-friendly key chord into AeroSpace's binding syntax so
    /// a natural `cmd+`` or `cmd+~` doesn't silently emit an invalid binding and
    /// break every keybinding. Accepts `+` or `-` separators and punctuation
    /// glyphs, and expands shifted glyphs (`~` → `shift-backtick`). AeroSpace
    /// modifiers are dash-joined and keys are named, never glyphs.
    static func normalizeKeySpec(_ raw: String) -> String {
        // Named keys for punctuation; `~` and friends carry an implicit shift.
        let glyphs: [String: [String]] = [
            "`": ["backtick"], "~": ["shift", "backtick"],
            "-": ["minus"], "_": ["shift", "minus"],
            "=": ["equal"], "+": ["shift", "equal"],
        ]
        // Split on `+`/`-` into modifiers + key. (The literal minus key is
        // inherently ambiguous with the separator — write it as `cmd-minus`.)
        let tokens = raw.replacingOccurrences(of: "+", with: "-")
            .split(separator: "-", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard !tokens.isEmpty else { return raw }
        var out: [String] = []
        for token in tokens {
            out.append(contentsOf: glyphs[token] ?? [token])
        }
        // De-dupe an implicit shift that was also written explicitly.
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }.joined(separator: "-")
    }
}

private struct RawConfig: Codable {
    var modifier: String?
    var gaps: RawGaps?
    var border: RawBorder?
    var bar: RawBar?
    var binding: [RawBinding]?
    var mode: [RawMode]?
    var leaderKey: String?
    var focusFollowsMouse: Bool?
    var floatingApps: [String]?
    var workspaceMonitors: [String: String]?
    var workspaceApps: [String: Int]?
    var hooks: RawHooks?
    var todo: RawTodo?
    var integrations: RawIntegrations?
    var pills: RawPills?

    enum CodingKeys: String, CodingKey {
        case modifier, gaps, border, bar, binding, mode, hooks, todo, integrations, pills
        case leaderKey = "leader-key"
        case focusFollowsMouse = "focus-follows-mouse"
        case floatingApps = "floating-apps"
        case workspaceMonitors = "workspace-monitors"
        case workspaceApps = "workspace-apps"
    }

    struct RawTodo: Codable {
        var enabled: Bool?
    }

    struct RawPills: Codable {
        var enabled: Bool?
        var dragToBar: Bool?

        enum CodingKeys: String, CodingKey {
            case enabled
            case dragToBar = "drag-to-bar"
        }
    }

    struct RawService: Codable {
        var enabled: Bool?
        var host: String?
        var user: String?
    }

    struct RawIntegrations: Codable {
        var github: RawService?
        var gitlab: RawService?
        var bitbucket: RawService?
        var jira: RawService?
        var confluence: RawService?
    }

    struct RawHooks: Codable {
        var workspaceChanged: String?

        enum CodingKeys: String, CodingKey {
            case workspaceChanged = "workspace-changed"
        }
    }

    struct RawMode: Codable {
        var name: String
        var binding: [RawBinding]?
    }

    struct RawBar: Codable {
        var enabled: Bool?
        var theme: String?
        var accentColor: String?

        enum CodingKeys: String, CodingKey {
            case enabled, theme
            case accentColor = "accent-color"
        }
    }

    struct RawGaps: Codable {
        var inner: Int?
        var outer: Int?
    }

    struct RawBorder: Codable {
        var enabled: Bool?
        var width: Int?
        var activeColor: String?
        var inactiveColor: String?

        enum CodingKeys: String, CodingKey {
            case enabled, width
            case activeColor = "active-color"
            case inactiveColor = "inactive-color"
        }
    }

    struct RawBinding: Codable {
        var key: String
        var action: String
    }
}
