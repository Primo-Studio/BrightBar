import SwiftUI
import Carbon.HIToolbox

@main
struct BrightBarApp: App {
    @StateObject private var brightnessManager = BrightnessManager()

    init() {
        // Hide from Dock — menu bar only
        NSApp.setActivationPolicy(.accessory)
    }

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

// MARK: - Global Hotkey Manager

final class HotkeyManager {
    static let shared = HotkeyManager()

    private var brightnessUp: EventHotKeyRef?
    private var brightnessDown: EventHotKeyRef?
    private var callback: ((Bool) -> Void)?

    func register(callback: @escaping (_ isUp: Bool) -> Void) {
        self.callback = callback

        // Install Carbon event handler for global hotkeys
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
                case 1: HotkeyManager.shared.callback?(true)   // brightness up
                case 2: HotkeyManager.shared.callback?(false)  // brightness down
                default: break
                }
            }

            return noErr
        }

        InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventType,
            nil,
            nil
        )

        // ⌥↑ (Option + Up Arrow) — brightness up
        let upID = EventHotKeyID(signature: OSType(0x42425550), id: 1) // "BBUP"
        RegisterEventHotKey(
            UInt32(kVK_UpArrow),
            UInt32(optionKey),
            upID,
            GetApplicationEventTarget(),
            0,
            &brightnessUp
        )

        // ⌥↓ (Option + Down Arrow) — brightness down
        let downID = EventHotKeyID(signature: OSType(0x4242444E), id: 2) // "BBDN"
        RegisterEventHotKey(
            UInt32(kVK_DownArrow),
            UInt32(optionKey),
            downID,
            GetApplicationEventTarget(),
            0,
            &brightnessDown
        )
    }
}

// MARK: - App Delegate for Hotkey Setup

class AppDelegate: NSObject, NSApplicationDelegate {
    var brightnessManager: BrightnessManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        HotkeyManager.shared.register { [weak self] isUp in
            guard let manager = self?.brightnessManager else { return }
            let delta: Double = isUp ? 0.05 : -0.05
            manager.adjustAllBrightness(by: delta)
        }
    }
}
