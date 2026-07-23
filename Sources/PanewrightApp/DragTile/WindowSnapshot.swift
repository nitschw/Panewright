import AppKit
import CoreGraphics

struct OnScreenWindow: Equatable, Sendable {
    let id: CGWindowID
    let ownerPID: pid_t
    /// Process name of the owner (available without any TCC permission).
    let ownerName: String
    /// Top-left-origin (CGWindowList) coordinates.
    let frame: CGRect
}

/// Point-in-time view of normal-level on-screen windows, front to back.
/// CGWindowList needs no TCC permission for ids/frames (only names are gated).
enum WindowSnapshot {
    static func capture() -> [OnScreenWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard
            let entries = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
                as? [[String: Any]]
        else {
            return []
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var windows: [OnScreenWindow] = []
        for entry in entries {
            guard
                let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                let id = entry[kCGWindowNumber as String] as? CGWindowID,
                let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                pid != ownPID,
                let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                let frame = CGRect(dictionaryRepresentation: boundsDict)
            else {
                continue
            }
            let ownerName = entry[kCGWindowOwnerName as String] as? String ?? ""
            windows.append(
                OnScreenWindow(id: id, ownerPID: pid, ownerName: ownerName, frame: frame))
        }
        return windows
    }

    static func frame(of id: CGWindowID) -> CGRect? {
        capture().first { $0.id == id }?.frame
    }

    /// Topmost window containing the point (the list is front-to-back).
    static func topmost(at point: CGPoint, excluding: Set<CGWindowID> = []) -> OnScreenWindow? {
        capture().first { !excluding.contains($0.id) && $0.frame.contains(point) }
    }
}
