/// CSS-style hex colors (`#RRGGBB` / `#RRGGBBAA`) → JankyBorders' 0xAARRGGBB.
public enum ColorHex {
    public static func argb(fromCSSHex hex: String) throws -> UInt32 {
        guard hex.hasPrefix("#") else {
            throw ConfigError.invalidColor(hex)
        }
        let digits = String(hex.dropFirst())
        guard digits.count == 6 || digits.count == 8,
            let value = UInt32(digits, radix: 16)
        else {
            throw ConfigError.invalidColor(hex)
        }
        if digits.count == 6 {
            return 0xFF00_0000 | value
        }
        // RRGGBBAA → AARRGGBB
        let alpha = value & 0xFF
        return (alpha << 24) | (value >> 8)
    }
}

/// Renders a ``PanewrightConfig/FocusBorder`` as JankyBorders CLI arguments.
public enum JankyBordersEmitter {
    public static func arguments(for border: PanewrightConfig.FocusBorder) throws -> [String] {
        let active = try ColorHex.argb(fromCSSHex: border.activeColor)
        let inactive = try ColorHex.argb(fromCSSHex: border.inactiveColor)
        return [
            String(format: "active_color=0x%08x", active),
            String(format: "inactive_color=0x%08x", inactive),
            "width=\(Double(border.width))",
            // Rounded to match native macOS window corners.
            "style=round",
        ]
    }
}
