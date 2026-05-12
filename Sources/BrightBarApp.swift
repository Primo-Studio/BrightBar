import ApplicationServices
import Carbon.HIToolbox
import IOKit.hidsystem
import SwiftUI

@main
struct BrightBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var brightnessManager = BrightnessManager()

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(brightnessManager)
        } label: {
            Image(systemName: "sun.max.fill")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}

final class HotkeyManager {
    static let shared = HotkeyManager()

    private var brightnessUp: EventHotKeyRef?
    private var brightnessDown: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var brightnessKeyController: BrightnessKeyController?
    private var callback: ((_ isUp: Bool) -> Void)?
    private var registrationStatus = HotkeyRegistrationStatus(optionHotkeys: false, brightnessKeyMode: .disabled)

    @discardableResult
    func register(callback: @escaping (_ isUp: Bool) -> Void) -> HotkeyRegistrationStatus {
        self.callback = callback

        if registrationStatus.optionHotkeys || registrationStatus.brightnessKeyMode != .disabled {
            return registrationStatus
        }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handler: EventHandlerUPP = { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )

            DispatchQueue.main.async {
                switch hotKeyID.id {
                case 1:
                    HotkeyManager.shared.callback?(true)
                case 2:
                    HotkeyManager.shared.callback?(false)
                default:
                    break
                }
            }

            return noErr
        }

        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventType,
            nil,
            &eventHandler
        )

        let upID = EventHotKeyID(signature: OSType(0x42425550), id: 1) // BBUP
        let upStatus = RegisterEventHotKey(
            UInt32(kVK_UpArrow),
            UInt32(optionKey),
            upID,
            GetApplicationEventTarget(),
            0,
            &brightnessUp
        )

        let downID = EventHotKeyID(signature: OSType(0x4242444E), id: 2) // BBDN
        let downStatus = RegisterEventHotKey(
            UInt32(kVK_DownArrow),
            UInt32(optionKey),
            downID,
            GetApplicationEventTarget(),
            0,
            &brightnessDown
        )

        brightnessKeyController = BrightnessKeyController(callback: callback)
        let brightnessKeyMode = brightnessKeyController?.start() ?? .disabled

        registrationStatus = HotkeyRegistrationStatus(
            optionHotkeys: handlerStatus == noErr && upStatus == noErr && downStatus == noErr,
            brightnessKeyMode: brightnessKeyMode
        )
        return registrationStatus
    }
}

struct HotkeyRegistrationStatus {
    let optionHotkeys: Bool
    let brightnessKeyMode: BrightnessKeyMode
}

enum BrightnessKeyMode: Equatable {
    case disabled
    case observing
    case intercepting
}

fileprivate final class BrightnessKeyController {
    private let callback: (_ isUp: Bool) -> Void
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var lastFallbackEventTime: TimeInterval = 0

    init(callback: @escaping (_ isUp: Bool) -> Void) {
        self.callback = callback
    }

    deinit {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }

        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }

        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
    }

    func start() -> BrightnessKeyMode {
        if startInterceptingTap() {
            return .intercepting
        }

        startFallbackMonitors()
        return localMonitor != nil || globalMonitor != nil ? .observing : .disabled
    }

    private func startInterceptingTap() -> Bool {
        let trustOptions = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        guard AXIsProcessTrustedWithOptions(trustOptions) else {
            return false
        }

        let systemDefinedEventType = CGEventType(rawValue: 14)!
        let mask = CGEventMask(1 << systemDefinedEventType.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: brightnessEventTapCallback,
            userInfo: context
        ) else {
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            return false
        }

        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func startFallbackMonitors() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            guard let self, let direction = Self.brightnessDirection(from: event) else {
                return event
            }

            self.handleFallback(direction: direction)
            return event
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            guard let self, let direction = Self.brightnessDirection(from: event) else { return }
            self.handleFallback(direction: direction)
        }
    }

    private func handleFallback(direction: BrightnessDirection) {
        let now = Date.timeIntervalSinceReferenceDate
        guard now - lastFallbackEventTime > 0.035 else { return }
        lastFallbackEventTime = now

        callback(direction == .up)
    }

    fileprivate func handleTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard let direction = Self.brightnessDirection(from: event) else {
            return Unmanaged.passUnretained(event)
        }

        DispatchQueue.main.async {
            self.callback(direction == .up)
        }

        return nil
    }

    private static func brightnessDirection(from event: CGEvent) -> BrightnessDirection? {
        guard let nsEvent = NSEvent(cgEvent: event) else { return nil }
        return brightnessDirection(from: nsEvent)
    }

    private static func brightnessDirection(from event: NSEvent) -> BrightnessDirection? {
        guard event.type == .systemDefined,
              event.subtype.rawValue == 8 else {
            return nil
        }

        let keyCode = Int32((event.data1 & 0xFFFF0000) >> 16)
        let keyState = (event.data1 & 0xFF00) >> 8
        guard keyState == 0xA else { return nil }

        if keyCode == NX_KEYTYPE_BRIGHTNESS_UP {
            return .up
        }

        if keyCode == NX_KEYTYPE_BRIGHTNESS_DOWN {
            return .down
        }

        return nil
    }
}

private func brightnessEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }

    let controller = Unmanaged<BrightnessKeyController>
        .fromOpaque(userInfo)
        .takeUnretainedValue()

    return controller.handleTap(type: type, event: event)
}

private enum BrightnessDirection {
    case up
    case down
}
