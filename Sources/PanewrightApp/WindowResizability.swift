import AppKit
import ApplicationServices
import CoreGraphics

/// Asks a window, via Accessibility, whether its size can be set at all.
///
/// Some windows are simply not resizable — fixed-size utilities, mirroring
/// panels — and tiling one is a fight nobody wins: the tile grows, the
/// window doesn't, and the fitter learns nonsense floors from the refusals.
/// AX states this outright (`AXSize` not settable), so ask once instead of
/// discovering it experimentally.
///
/// Same public-API-only CG→AX bridge as `FloatingWindowRaiser`: match the
/// window by owner and geometry rather than the private
/// `_AXUIElementGetWindow`.
@MainActor
enum WindowResizability {
    /// nil when the window can't be found or AX won't answer — callers must
    /// treat unknown as resizable, never as a reason to float.
    static func isResizable(windowID: UInt32) -> Bool? {
        guard let frame = WindowSnapshot.frame(of: windowID),
            let pid = WindowSnapshot.ownerPID(of: windowID)
        else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
                == .success,
            let windows = value as? [AXUIElement],
            let match = windows.first(where: { matches($0, frame) })
        else { return nil }
        var settable = DarwinBoolean(false)
        guard
            AXUIElementIsAttributeSettable(match, kAXSizeAttribute as CFString, &settable)
                == .success
        else { return nil }
        return settable.boolValue
    }

    private static func matches(_ element: AXUIElement, _ frame: CGRect) -> Bool {
        guard let origin = point(element, kAXPositionAttribute),
            let size = size(element, kAXSizeAttribute)
        else { return false }
        return abs(origin.x - frame.minX) < 3 && abs(origin.y - frame.minY) < 3
            && abs(size.width - frame.width) < 3 && abs(size.height - frame.height) < 3
    }

    private static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
            let box = value, CFGetTypeID(box) == AXValueGetTypeID()
        else { return nil }
        var result = CGPoint.zero
        guard AXValueGetValue(box as! AXValue, .cgPoint, &result) else { return nil }
        return result
    }

    private static func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
            let box = value, CFGetTypeID(box) == AXValueGetTypeID()
        else { return nil }
        var result = CGSize.zero
        guard AXValueGetValue(box as! AXValue, .cgSize, &result) else { return nil }
        return result
    }
}
