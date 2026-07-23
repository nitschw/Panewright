import Foundation
import TOMLKit

public enum ConfigError: Error, Equatable, CustomStringConvertible {
    case invalidTOML(String)
    case invalidModifier(String)
    case invalidAction(String)

    public var description: String {
        switch self {
        case .invalidTOML(let detail):
            "invalid TOML: \(detail)"
        case .invalidModifier(let value):
            "unknown modifier '\(value)' (expected hyper, alt, or cmd)"
        case .invalidAction(let value):
            "unrecognized action '\(value)'"
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
        if let gaps = raw.gaps {
            config.gaps.inner = gaps.inner ?? config.gaps.inner
            config.gaps.outer = gaps.outer ?? config.gaps.outer
        }
        if let border = raw.border {
            config.focusBorder.width = border.width ?? config.focusBorder.width
            config.focusBorder.activeColor = border.activeColor ?? config.focusBorder.activeColor
            config.focusBorder.inactiveColor = border.inactiveColor ?? config.focusBorder.inactiveColor
        }
        if let bindings = raw.binding {
            config.bindings = try bindings.map { rawBinding in
                PanewrightConfig.Binding(
                    key: rawBinding.key,
                    action: try parseAction(rawBinding.action)
                )
            }
        }
        return config
    }

    /// Parses an i3-flavored action string: `workspace 3`, `move to workspace 3`,
    /// `focus left`, `move right`.
    static func parseAction(_ string: String) throws -> PanewrightConfig.Action {
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
        throw ConfigError.invalidAction(string)
    }
}

private struct RawConfig: Codable {
    var modifier: String?
    var gaps: RawGaps?
    var border: RawBorder?
    var binding: [RawBinding]?

    struct RawGaps: Codable {
        var inner: Int?
        var outer: Int?
    }

    struct RawBorder: Codable {
        var width: Int?
        var activeColor: String?
        var inactiveColor: String?

        enum CodingKeys: String, CodingKey {
            case width
            case activeColor = "active-color"
            case inactiveColor = "inactive-color"
        }
    }

    struct RawBinding: Codable {
        var key: String
        var action: String
    }
}
