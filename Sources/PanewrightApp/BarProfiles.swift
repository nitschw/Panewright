import AppKit
import CoreGraphics
import PanewrightCore

/// Gives each display its own bar personality.
///
/// SketchyBar draws one bar definition on every display; items carry an
/// `associated_display` that limits where they appear. This applies the
/// config's `[[bar.monitor]]` profiles — and, with none configured, the
/// automatic policy: the main display carries the widget chips, every other
/// display gets a clean workspace strip. Nothing duplicates.
///
/// Runtime, not config-emission: display indices exist only while displays
/// are attached, so this re-runs after every display change and bar reload
/// (a reload rebuilds items from the rc and forgets these assignments). The
/// health tick re-applies every 20 seconds, which also picks up items that
/// appear later — to-do pills, integration chips.
enum BarProfiles {
    struct DisplayFacts {
        let index: Int  // SketchyBar's display number
        let name: String
        let isMain: Bool
        let isBuiltin: Bool
        let isPortrait: Bool
    }

    /// Item-name prefix → the widget key it belongs to (the `[modules]`
    /// vocabulary, plus `todo` and `integrations`). Strip furniture
    /// (workspace pills, mode badge, front app) is absent deliberately —
    /// it stays on every display.
    private static let itemKeys: [(prefix: String, key: String)] = [
        ("w.weather", "weather"), ("w.batt", "battery"), ("w.net", "network"),
        ("w.disk", "disk"), ("w.ports", "ports"), ("w.brew", "brew-updates"),
        ("w.docker", "docker"), ("w.cloud", "cloud-context"), ("w.scratch", "scratchpad"),
        ("w.mic", "mic-mute"), ("w.vol", "volume"), ("w.vpn", "vpn"),
        ("w.kbd", "keyboard-layout"), ("w.play", "now-playing"), ("w.focus", "focus"),
        ("sys", "system-monitor"), ("todo", "todo"), ("integration", "integrations"),
    ]

    /// Off the main thread except one hop for NSScreen names: this runs
    /// every 20 seconds and shells out to sketchybar — on machines whose
    /// endpoint security taxes each process spawn, doing that on the main
    /// actor contributed a rhythmic beachball.
    static func apply(_ config: PanewrightConfig) async {
        guard config.statusBar.enabled else { return }
        let displays = await currentDisplays()
        guard displays.count > 1 || !config.statusBar.monitorProfiles.isEmpty else {
            // One display and no profiles: today's bar, untouched.
            return
        }
        var shownDisplays: [Int] = []
        var displaysForKey: [String: [Int]] = [:]
        for display in displays {
            let profile = profile(for: display, in: config.statusBar.monitorProfiles)
            if profile.hidden { continue }
            shownDisplays.append(display.index)
            for entry in Self.itemKeys {
                let show = profile.widgets.map { normalized($0).contains(normalize(entry.key)) }
                    ?? true
                if show { displaysForKey[entry.key, default: []].append(display.index) }
            }
        }
        var args: [String] = [
            "--bar",
            "display=\(shownDisplays.isEmpty ? "all" : shownDisplays.map(String.init).joined(separator: ","))",
        ]
        for item in queryItems() {
            guard let key = key(forItem: item) else { continue }
            let indices = displaysForKey[key] ?? []
            // No display wants it: park it on an index that never exists.
            // (There is no "no display" value; drawing on/off belongs to the
            // widget drivers and must not be fought over.)
            let value = indices.isEmpty ? "64" : indices.map(String.init).joined(separator: ",")
            args += ["--set", item, "associated_display=\(value)"]
        }
        run(args)
    }

    /// First matching profile wins; no match falls back to the automatic
    /// policy — chips on the main display, clean strips elsewhere.
    private static func profile(
        for display: DisplayFacts, in profiles: [PanewrightConfig.StatusBar.MonitorProfile]
    ) -> PanewrightConfig.StatusBar.MonitorProfile {
        for profile in profiles where matches(profile.match, display) {
            return profile
        }
        return .init(match: "*", widgets: display.isMain ? nil : [])
    }

    private static func matches(_ pattern: String, _ display: DisplayFacts) -> Bool {
        switch normalize(pattern) {
        case "*", "any", "all": true
        case "builtin", "built-in": display.isBuiltin
        case "external": !display.isBuiltin
        case "portrait": display.isPortrait
        case "landscape": !display.isPortrait
        case "main", "primary": display.isMain
        default: normalize(display.name).contains(normalize(pattern))
        }
    }

    /// SketchyBar's display numbers pinned to physical displays by geometry —
    /// the same bridge the monitor map uses, for the same reason: SketchyBar
    /// does not number displays in CGGetActiveDisplayList order.
    private static func currentDisplays() async -> [DisplayFacts] {
        let origins = MonitorMap.sketchyBarDisplayOrigins()
        guard !origins.isEmpty else { return [] }
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        // NSScreen belongs to the main actor; everything else here is
        // thread-safe CG or a subprocess.
        let namesByID = await MainActor.run {
            Dictionary(
                uniqueKeysWithValues: NSScreen.screens.compactMap { screen in
                    (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                        as? CGDirectDisplayID).map { ($0, screen.localizedName) }
                })
        }
        var facts: [DisplayFacts] = []
        for (index, origin) in origins {
            guard let displayID = ids.first(where: { CGDisplayBounds($0).contains(origin) })
            else { continue }
            let bounds = CGDisplayBounds(displayID)
            facts.append(
                DisplayFacts(
                    index: index, name: namesByID[displayID] ?? "",
                    isMain: CGDisplayIsMain(displayID) != 0,
                    isBuiltin: CGDisplayIsBuiltin(displayID) != 0,
                    isPortrait: bounds.height > bounds.width))
        }
        return facts
    }

    private static func queryItems() -> [String] {
        let process = Process()
        process.executableURL = URL(filePath: "/opt/homebrew/bin/sketchybar")
        process.arguments = ["--query", "bar"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let items = json["items"] as? [String]
        else { return [] }
        return items
    }

    private static func key(forItem item: String) -> String? {
        // Longest prefix wins so "w.ports" isn't claimed by a shorter match.
        itemKeys
            .filter { item == $0.prefix || item.hasPrefix($0.prefix + ".") }
            .max { $0.prefix.count < $1.prefix.count }?.key
    }

    private static func normalized(_ keys: [String]) -> Set<String> {
        Set(keys.map(normalize))
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func run(_ args: [String]) {
        let process = Process()
        process.executableURL = URL(filePath: "/opt/homebrew/bin/sketchybar")
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        process.waitUntilExit()
    }
}
