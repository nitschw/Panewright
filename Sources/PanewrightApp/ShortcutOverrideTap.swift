import AppKit
import CoreGraphics
import Foundation
import PanewrightCore

/// Takes the chords macOS reserves for itself, so a binding on one can work.
///
/// Some chords never reach AeroSpace at all: ⌃⌘F is Enter Full Screen, ⌘Space
/// is Spotlight, and the system consumes them before any window manager sees
/// the key. No AeroSpace binding can win that race — which is why the
/// conflicts window's normal advice is to rebind. This is the other answer:
/// intercept the chord in our own event tap, run the binding, and swallow the
/// event so nothing downstream acts on it.
///
/// Deliberately session-scoped. A tap that eats keystrokes is a good way to
/// make a keyboard feel broken, so this is never written to the config and is
/// always off at launch: quitting or restarting Panewright is a guaranteed way
/// out, without having to edit a file with a keyboard that's misbehaving.
///
/// Only chords the detector flagged as system-reserved are taken. Grabbing
/// every binding would put this tap in the path of ordinary typing for no
/// benefit, since bindings that aren't contested already work.
@MainActor
final class ShortcutOverrideTap {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// (key code, modifier set) → the AeroSpace commands to run.
    private var overrides: [Signature: [String]] = [:]

    struct Signature: Hashable {
        let code: UInt16
        let modifiers: Set<String>
    }

    var isRunning: Bool { tap != nil }

    /// The chords being taken, for the menu to describe what's active.
    var overriddenChords: [String] = []

    /// Rebuild from the current config: every binding whose resolved chord the
    /// detector flags as system-reserved.
    func configure(with config: PanewrightConfig) {
        overrides = [:]
        overriddenChords = []
        let contested = Set(
            BindingConflicts.find(in: config)
                .filter { if case .systemShortcut = $0.kind { true } else { false } }
                .map { $0.chord.lowercased() })
        guard !contested.isEmpty else { return }
        for binding in config.bindings {
            let chord = AeroSpaceConfigEmitter.keyCombo(
                modifier: config.modifier, key: binding.key)
            guard contested.contains(chord.lowercased()),
                let parsed = KeyCodes.parse(chord: chord)
            else { continue }
            let commands = binding.actions.flatMap(AeroSpaceConfigEmitter.commands(for:))
            overrides[Signature(code: parsed.code, modifiers: parsed.modifiers)] = commands
            overriddenChords.append(KeyChordFormatter.pretty(chord))
        }
    }

    func start() {
        stop()
        guard !overrides.isEmpty else {
            DragLog.log("override: nothing contested to take")
            return
        }
        let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                // Ahead of the system's own handling — the whole point is to
                // see the chord before macOS claims it.
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: { _, type, event, refcon in
                    guard let refcon else { return Unmanaged.passUnretained(event) }
                    let tap = Unmanaged<ShortcutOverrideTap>.fromOpaque(refcon)
                        .takeUnretainedValue()
                    let consume = MainActor.assumeIsolated { tap.handle(type: type, event: event) }
                    return consume ? nil : Unmanaged.passUnretained(event)
                },
                userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            DragLog.log("override: tapCreate FAILED (Accessibility not effective?)")
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        DragLog.log("override: taking \(overriddenChords.joined(separator: ", "))")
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        source = nil
    }

    /// Returns true to swallow the event.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        // The system disables a tap that takes too long or is denied
        // permission. Re-arm rather than silently dying, which would look like
        // the override randomly stopping.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        guard type == .keyDown else { return false }
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        var modifiers: Set<String> = []
        let flags = event.flags
        if flags.contains(.maskCommand) { modifiers.insert("cmd") }
        if flags.contains(.maskAlternate) { modifiers.insert("alt") }
        if flags.contains(.maskControl) { modifiers.insert("ctrl") }
        if flags.contains(.maskShift) { modifiers.insert("shift") }
        guard let commands = overrides[Signature(code: code, modifiers: modifiers)] else {
            return false
        }
        run(commands)
        return true
    }

    /// Run through a shell so the command strings — which can carry quoted
    /// paths and $HOME — behave exactly as they do from AeroSpace's own config.
    private func run(_ commands: [String]) {
        guard let cli = AeroSpaceCLI.locate() else { return }
        let script = commands
            .map { "\(cli.executableURL.path) \($0)" }
            .joined(separator: "; ")
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", script]
        try? process.run()
    }
}
