import AppKit

/// Ghost overlays for drag-to-tile: red marks the source cell (what you're
/// moving), blue previews the target frame it will occupy on release.
@MainActor
final class DropOverlayWindow {
    enum Style {
        case source, target
    }

    private let window: NSWindow

    init(style: Style = .target) {
        let color: NSColor =
            switch style {
            case .source: .systemRed
            case .target: .controlAccentColor
            }
        window = NSWindow(
            contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .transient]
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = color.withAlphaComponent(0.28).cgColor
        view.layer?.borderColor = color.cgColor
        view.layer?.borderWidth = 2
        view.layer?.cornerRadius = 10
        window.contentView = view
    }

    /// Takes a CGWindowList (top-left-origin) frame.
    func show(cgFrame: CGRect) {
        window.setFrame(Self.cocoaRect(fromCG: cgFrame), display: true)
        window.orderFrontRegardless()
    }

    func hide() {
        window.orderOut(nil)
    }

    /// CG coordinates hang from the top of the *primary* screen; Cocoa's
    /// grow from its bottom. The flip is always relative to the primary
    /// (the zero-origin screen) — `screens.first` isn't guaranteed to be it,
    /// which put overlays on the wrong monitor in multi-display setups.
    static func cocoaRect(fromCG rect: CGRect) -> CGRect {
        let primaryHeight =
            (NSScreen.screens.first { $0.frame.origin == .zero }
                ?? NSScreen.screens.first)?.frame.height ?? 0
        return CGRect(
            x: rect.minX,
            y: primaryHeight - rect.maxY,
            width: rect.width,
            height: rect.height)
    }
}
