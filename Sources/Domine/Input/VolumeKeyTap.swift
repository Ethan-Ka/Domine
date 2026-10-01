import AppKit
import ApplicationServices
import CoreGraphics
import os

/// Intercepts the hardware volume keys while Domine is routing (SPEC 4b).
///
/// A session event tap on `NX_SYSDEFINED` events catches volume up, down, and
/// mute, reports key downs and repeats to the handler, and swallows both the
/// down and up halves so macOS never adjusts the (muted) default device.
/// Every other event passes through untouched. When stopped, no tap exists.
///
/// The caller decides when to start and stop: only while routing, and only
/// when the user enabled volume keys in Settings.
@MainActor
final class VolumeKeyTap {
    typealias Handler = @MainActor (VolumeKeyEvent) -> Void

    /// `NX_SYSDEFINED` as a `CGEventType` raw value.
    nonisolated static let systemDefinedEventType: UInt32 = 14
    nonisolated static let log = Logger(subsystem: "com.ethankawley.Domine", category: "VolumeKeys")

    private var port: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var context: Unmanaged<VolumeKeyTapContext>?

    var isRunning: Bool { port != nil }

    init() {}

    isolated deinit {
        stop()
    }

    // MARK: Accessibility

    /// True when Domine has Accessibility permission, which a swallowing
    /// event tap requires.
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    static let accessibilitySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    /// Adds Domine to the Accessibility list with the system prompt, then
    /// opens that list. The prompt does not appear when an entry already
    /// exists, including a stale one from an earlier build, so the list is
    /// opened either way.
    static func requestAccess() {
        // Literal value of kAXTrustedCheckOptionPrompt; the imported global is
        // a mutable var, which Swift 6 rejects as not concurrency safe.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(accessibilitySettingsURL)
    }

    // MARK: Lifecycle

    /// Installs the tap on the main run loop. Returns false and does nothing
    /// when Accessibility permission is missing or the tap cannot be created,
    /// so the keys keep their normal behavior. Calling start while running
    /// replaces the handler.
    @discardableResult
    func start(handler: @escaping Handler) -> Bool {
        if let context {
            context.takeUnretainedValue().handler = handler
            return true
        }
        guard Self.isTrusted else {
            Self.log.error("Not starting the tap: AXIsProcessTrusted is false")
            return false
        }

        let box = VolumeKeyTapContext(handler: handler)
        let retained = Unmanaged.passRetained(box)
        let mask = CGEventMask(1) << CGEventMask(Self.systemDefinedEventType)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: volumeKeyTapCallback,
            userInfo: retained.toOpaque())
        else {
            retained.release()
            Self.log.error("CGEvent.tapCreate returned nil for the session event tap")
            return false
        }
        box.port = port

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)

        self.port = port
        self.runLoopSource = source
        self.context = retained
        return true
    }

    /// Removes the tap. Afterwards every event reaches the system untouched.
    func stop() {
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let context {
            context.takeUnretainedValue().port = nil
            context.release()
        }
        port = nil
        runLoopSource = nil
        context = nil
    }
}

/// C callback for the event tap. Captures nothing; all state comes through
/// `userInfo`. The tap's run loop source is on the main run loop, so this runs
/// on the main thread. Only Sendable values cross into the main actor
/// closure: the decoded key, the event type, and the context address.
private func volumeKeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let key = decodeVolumeKey(type: type, event: event)
    let address = Int(bitPattern: userInfo)
    let swallow = MainActor.assumeIsolated {
        guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return false }
        let context = Unmanaged<VolumeKeyTapContext>.fromOpaque(pointer).takeUnretainedValue()
        return context.handle(type: type, key: key)
    }
    return swallow ? nil : Unmanaged.passUnretained(event)
}

/// Reads subtype and data1 through NSEvent, since CGEvent has no public field
/// for them. Returns nil for anything that is not a volume key event.
private func decodeVolumeKey(type: CGEventType, event: CGEvent) -> VolumeKeyEvent? {
    guard type.rawValue == VolumeKeyTap.systemDefinedEventType,
          let nsEvent = NSEvent(cgEvent: event),
          nsEvent.type == .systemDefined
    else { return nil }
    return VolumeKeyEvent.decode(
        subtype: Int(nsEvent.subtype.rawValue),
        data1: nsEvent.data1,
        flags: event.flags)
}
