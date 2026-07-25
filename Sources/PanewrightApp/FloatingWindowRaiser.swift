import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Keeps floating windows above the tiled ones.
///
/// A floating window is one the user has deliberately lifted out of the
/// layout, so having a tiled window render on top of it defeats the point —
/// it's the behavior i3 has, and the reason "float this" is useful at all.
/// AeroSpace doesn't enforce it.
///
/// Two deliberate constraints:
///
/// 1. **Only public Accessibility API.** The usual trick is the private
///    `_AXUIElementGetWindow`, which maps an AX element straight to a
///    CGWindowID. It's a private symbol that has moved between OS releases, so
///    windows are matched by owning process and frame instead. If an app has
///    two windows at identical geometry, either one may be raised — which is
///    harmless, since raising either satisfies the intent.
/// 2. **Only when actually occluded.** Raising on a timer regardless of
///    z-order would fight the user for control of their own stacking and make
///    windows flicker. CGWindowList returns front-to-back, so "a tiled window
///    is in front of this floater and overlaps it" is cheap to check exactly,
///    and nothing happens until it's true.
@MainActor
enum FloatingWindowRaiser {
    /// Raise any floating window that a tiled window is currently covering.
    /// `onScreen` must be in front-to-back order, as CGWindowList returns it.
    /// Returns the ids raised, for logging.
    @discardableResult
    static func raiseOccludedFloaters(
        onScreen: [OnScreenWindow], floating: Set<UInt32>, tiled: Set<UInt32>
    ) -> [UInt32] {
        guard !floating.isEmpty, !tiled.isEmpty else { return [] }
        var raised: [UInt32] = []
        for (index, window) in onScreen.enumerated() where floating.contains(window.id) {
            // Anything earlier in the list is in front of this window.
            let covered = onScreen.prefix(index).contains { front in
                tiled.contains(front.id) && front.frame.intersects(window.frame)
            }
            guard covered else { continue }
            if raise(window) { raised.append(window.id) }
        }
        return raised
    }

    /// Find the window's Accessibility element by owner and geometry, and
    /// raise it.
    private static func raise(_ window: OnScreenWindow) -> Bool {
        let app = AXUIElementCreateApplication(window.ownerPID)
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
                == .success,
            let windows = value as? [AXUIElement]
        else { return false }
        guard let match = windows.first(where: { matches($0, window.frame) }) else {
            return false
        }
        return AXUIElementPerformAction(match, kAXRaiseAction as CFString) == .success
    }

    /// AX reports position and size separately, both as AXValue boxes, in the
    /// same top-left-origin space CGWindowList uses.
    private static func matches(_ element: AXUIElement, _ frame: CGRect) -> Bool {
        guard let origin = point(element, kAXPositionAttribute),
            let size = size(element, kAXSizeAttribute)
        else { return false }
        // A couple of points of tolerance: AX and CGWindowList can disagree by
        // a fraction on scaled displays.
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
