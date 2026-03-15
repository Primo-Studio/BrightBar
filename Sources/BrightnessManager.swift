import AppKit
import CoreGraphics
import Foundation
import IOKit
import IOKit.i2c

// MARK: - Private API Declarations (loaded dynamically)

private let displayServicesLib: UnsafeMutableRawPointer? = {
    dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
}()

private typealias SetBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
private typealias GetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32

private let displayServicesSetBrightness: SetBrightnessFn? = {
    guard let lib = displayServicesLib,
          let sym = dlsym(lib, "DisplayServicesSetBrightness") else { return nil }
    return unsafeBitCast(sym, to: SetBrightnessFn.self)
}()

private let displayServicesGetBrightness: GetBrightnessFn? = {
    guard let lib = displayServicesLib,
          let sym = dlsym(lib, "DisplayServicesGetBrightness") else { return nil }
    return unsafeBitCast(sym, to: GetBrightnessFn.self)
}()

// MARK: - DDC/CI Constants

private let kDDCBrightnessVCPCode: UInt8 = 0x10

// MARK: - BrightnessManager

@MainActor
final class BrightnessManager: ObservableObject {
    @Published var displays: [DisplayInfo] = []
    @Published var nightModeActive: Bool = false

    private var overlayWindows: [CGDirectDisplayID: NSWindow] = [:]
    private var savedBrightness: [CGDirectDisplayID: Double] = [:]
    private let defaults = UserDefaults.standard
    private let prefsKey = "BrightBar_DisplayBrightness"

    init() {
        refreshDisplays()
        loadPreferences()
    }

    // MARK: - Display Discovery

    func refreshDisplays() {
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(16, &displayIDs, &displayCount)

        var newDisplays: [DisplayInfo] = []
        for i in 0..<Int(displayCount) {
            let displayID = displayIDs[i]
            let name = Self.displayName(for: displayID)
            let isBuiltIn = CGDisplayIsBuiltin(displayID) != 0
            let brightness = currentBrightness(for: displayID, isBuiltIn: isBuiltIn)

            newDisplays.append(DisplayInfo(
                id: displayID,
                name: name,
                isBuiltIn: isBuiltIn,
                brightness: brightness,
                isOverlayActive: overlayWindows[displayID] != nil
            ))
        }
        displays = newDisplays
    }

    // MARK: - Display Name

    private static func displayName(for displayID: CGDirectDisplayID) -> String {
        if CGDisplayIsBuiltin(displayID) != 0 {
            return "Built-in Display"
        }

        // Try IOKit to get the display product name
        var servicePortIterator = io_iterator_t()
        let matching = IOServiceMatching("IODisplayConnect")
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &servicePortIterator)
        guard result == kIOReturnSuccess else {
            return "Display \(displayID)"
        }
        defer { IOObjectRelease(servicePortIterator) }

        var service = IOIteratorNext(servicePortIterator)
        while service != 0 {
            if let info = IODisplayCreateInfoDictionary(service, IOOptionBits(kIODisplayOnlyPreferredName)).takeRetainedValue() as? [String: Any],
               let names = info[kDisplayProductName] as? [String: String],
               let name = names.values.first {
                IOObjectRelease(service)
                return name
            }
            IOObjectRelease(service)
            service = IOIteratorNext(servicePortIterator)
        }
        return "External Display \(displayID)"
    }

    // MARK: - Read Brightness

    private func currentBrightness(for displayID: CGDirectDisplayID, isBuiltIn: Bool) -> Double {
        // Check saved preferences first
        if let saved = loadBrightness(for: displayID) {
            return saved
        }

        if isBuiltIn {
            var brightness: Float = 0.5
            if let getBrightness = displayServicesGetBrightness {
                let result = getBrightness(displayID, &brightness)
                if result == kIOReturnSuccess {
                    return Double(brightness)
                }
            }
            return 0.5
        } else {
            // Try DDC read
            if let val = ddcRead(displayID: displayID, command: kDDCBrightnessVCPCode) {
                return Double(val) / 100.0
            }
            return 0.5
        }
    }

    // MARK: - Set Brightness

    func setBrightness(for displayID: CGDirectDisplayID, to value: Double) {
        guard let index = displays.firstIndex(where: { $0.id == displayID }) else { return }

        let display = displays[index]
        let clamped = min(max(value, display.minBrightness), display.maxBrightness)
        displays[index].brightness = clamped

        if display.isBuiltIn {
            setBuiltInBrightness(displayID: displayID, value: clamped)
        } else {
            setExternalBrightness(displayID: displayID, value: clamped)
        }

        saveBrightness(clamped, for: displayID)
    }

    // MARK: - Built-in Display Brightness

    private func setBuiltInBrightness(displayID: CGDirectDisplayID, value: Double) {
        if value <= 1.0 {
            // Use DisplayServices for normal 0–100% range
            removeOverlay(for: displayID)

            if value < 0.01 {
                // Below system minimum: use overlay to simulate darkness
                let _ = displayServicesSetBrightness?(displayID, 0.0)
                let overlayOpacity = 1.0 - (value / 0.01)
                showOverlay(for: displayID, opacity: min(overlayOpacity, 0.95))
            } else {
                let _ = displayServicesSetBrightness?(displayID, Float(value))
            }
        } else {
            // Above 100%: set hardware to max, boost via gamma
            let _ = displayServicesSetBrightness?(displayID, 1.0)
            removeOverlay(for: displayID)
            let boostFactor = Float(value) // 1.0 – 1.5
            applyGammaBoost(displayID: displayID, factor: boostFactor)
        }
    }

    // MARK: - External Display Brightness (DDC/CI)

    private func setExternalBrightness(displayID: CGDirectDisplayID, value: Double) {
        let ddcValue = UInt16(min(max(value * 100, 0), 100))
        ddcWrite(displayID: displayID, command: kDDCBrightnessVCPCode, value: ddcValue)
    }

    // MARK: - Overlay Window (below-minimum darkness)

    private func showOverlay(for displayID: CGDirectDisplayID, opacity: Double) {
        if let existing = overlayWindows[displayID] {
            existing.alphaValue = CGFloat(opacity)
            updateOverlayState(for: displayID, active: true)
            return
        }

        guard let screen = NSScreen.screens.first(where: {
            $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == displayID
        }) else { return }

        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.backgroundColor = .black
        window.alphaValue = CGFloat(opacity)
        window.isOpaque = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.orderFrontRegardless()

        overlayWindows[displayID] = window
        updateOverlayState(for: displayID, active: true)
    }

    private func removeOverlay(for displayID: CGDirectDisplayID) {
        overlayWindows[displayID]?.close()
        overlayWindows.removeValue(forKey: displayID)
        updateOverlayState(for: displayID, active: false)
    }

    private func updateOverlayState(for displayID: CGDirectDisplayID, active: Bool) {
        if let index = displays.firstIndex(where: { $0.id == displayID }) {
            displays[index].isOverlayActive = active
        }
    }

    // MARK: - Gamma Boost (above-maximum brightness)

    private func applyGammaBoost(displayID: CGDirectDisplayID, factor: Float) {
        CGSetDisplayTransferByFormula(
            displayID,
            0, factor, 1,   // red
            0, factor, 1,   // green
            0, factor, 1    // blue
        )
    }

    func resetGamma(displayID: CGDirectDisplayID) {
        CGDisplayRestoreColorSyncSettings()
    }

    // MARK: - DDC/CI via IOKit I2C

    private func ddcWrite(displayID: CGDirectDisplayID, command: UInt8, value: UInt16) {
        guard let framebufferPort = Self.framebufferPort(for: displayID) else { return }
        defer { IOObjectRelease(framebufferPort) }

        var busCount: IOItemCount = 0
        guard IOFBGetI2CInterfaceCount(framebufferPort, &busCount) == kIOReturnSuccess,
              busCount > 0 else { return }

        var i2cInterface: io_service_t = 0
        guard IOFBCopyI2CInterfaceForBus(framebufferPort, 0, &i2cInterface) == kIOReturnSuccess else { return }
        defer { IOObjectRelease(i2cInterface) }

        var connect: IOI2CConnectRef? = nil
        guard IOI2CInterfaceOpen(i2cInterface, 0, &connect) == kIOReturnSuccess,
              let connection = connect else { return }
        defer { IOI2CInterfaceClose(connection, 0) }

        // DDC/CI write command: set VCP feature
        let valueHigh = UInt8((value >> 8) & 0xFF)
        let valueLow = UInt8(value & 0xFF)

        var data: [UInt8] = [
            0x51,  // source address (host)
            0x84,  // length (following bytes | 0x80)
            0x03,  // set VCP feature opcode
            command,
            valueHigh,
            valueLow,
        ]
        // XOR checksum
        var checksum: UInt8 = 0x6E  // destination address for checksum
        for byte in data { checksum ^= byte }
        data.append(checksum)

        var sendBuffer = data
        var request = IOI2CRequest()
        request.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
        request.sendAddress = 0x6E  // DDC display address
        request.sendBytes = UInt32(sendBuffer.count)
        sendBuffer.withUnsafeMutableBufferPointer { buf in
            request.sendBuffer = vm_address_t(bitPattern: buf.baseAddress)
        }

        request.replyTransactionType = IOOptionBits(kIOI2CNoTransactionType)
        request.replyBytes = 0

        IOI2CSendRequest(connection, 0, &request)
    }

    private func ddcRead(displayID: CGDirectDisplayID, command: UInt8) -> UInt16? {
        guard let framebufferPort = Self.framebufferPort(for: displayID) else { return nil }
        defer { IOObjectRelease(framebufferPort) }

        var busCount: IOItemCount = 0
        guard IOFBGetI2CInterfaceCount(framebufferPort, &busCount) == kIOReturnSuccess,
              busCount > 0 else { return nil }

        var i2cInterface: io_service_t = 0
        guard IOFBCopyI2CInterfaceForBus(framebufferPort, 0, &i2cInterface) == kIOReturnSuccess else { return nil }
        defer { IOObjectRelease(i2cInterface) }

        var connect: IOI2CConnectRef? = nil
        guard IOI2CInterfaceOpen(i2cInterface, 0, &connect) == kIOReturnSuccess,
              let connection = connect else { return nil }
        defer { IOI2CInterfaceClose(connection, 0) }

        // DDC/CI read: first send the "get VCP feature" command
        var sendData: [UInt8] = [
            0x51,  // source
            0x82,  // length
            0x01,  // get VCP feature opcode
            command,
        ]
        var checksum: UInt8 = 0x6E
        for byte in sendData { checksum ^= byte }
        sendData.append(checksum)

        var replyData = [UInt8](repeating: 0, count: 12)

        var request = IOI2CRequest()
        request.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
        request.sendAddress = 0x6E
        request.sendBytes = UInt32(sendData.count)

        var sendBuffer = sendData
        sendBuffer.withUnsafeMutableBufferPointer { buf in
            request.sendBuffer = vm_address_t(bitPattern: buf.baseAddress)
        }

        request.replyTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
        request.replyAddress = 0x6F
        request.replyBytes = UInt32(replyData.count)
        replyData.withUnsafeMutableBufferPointer { buf in
            request.replyBuffer = vm_address_t(bitPattern: buf.baseAddress)
        }

        let result = IOI2CSendRequest(connection, 0, &request)
        guard result == kIOReturnSuccess, request.result == kIOReturnSuccess else { return nil }

        // Parse DDC reply: byte 9 = current value high, byte 10 = current value low
        guard replyData.count >= 11 else { return nil }
        let currentValue = (UInt16(replyData[9]) << 8) | UInt16(replyData[10])
        return currentValue
    }

    private static func framebufferPort(for displayID: CGDirectDisplayID) -> io_service_t? {
        var servicePortIterator = io_iterator_t()
        let matching = IOServiceMatching("IOFramebuffer")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &servicePortIterator) == kIOReturnSuccess else {
            return nil
        }
        defer { IOObjectRelease(servicePortIterator) }

        var service = IOIteratorNext(servicePortIterator)
        while service != 0 {
            // Return first available framebuffer for DDC
            // A more robust implementation would match by display vendor/product
            let port = service
            service = IOIteratorNext(servicePortIterator)
            while service != 0 {
                IOObjectRelease(service)
                service = IOIteratorNext(servicePortIterator)
            }
            return port
        }
        return nil
    }

    // MARK: - Night Mode

    func toggleNightMode() {
        nightModeActive.toggle()
        if nightModeActive {
            // Save current brightness values and set all to 10%
            for display in displays {
                savedBrightness[display.id] = display.brightness
                setBrightness(for: display.id, to: 0.1)
            }
        } else {
            // Restore saved brightness values
            for display in displays {
                let restored = savedBrightness[display.id] ?? 0.5
                setBrightness(for: display.id, to: restored)
            }
            savedBrightness.removeAll()
        }
    }

    // MARK: - Global Keyboard Shortcuts

    func adjustAllBrightness(by delta: Double) {
        for display in displays {
            let newValue = display.brightness + delta
            setBrightness(for: display.id, to: newValue)
        }
    }

    // MARK: - Preferences

    private func saveBrightness(_ value: Double, for displayID: CGDirectDisplayID) {
        var prefs = defaults.dictionary(forKey: prefsKey) as? [String: Double] ?? [:]
        prefs[String(displayID)] = value
        defaults.set(prefs, forKey: prefsKey)
    }

    private func loadBrightness(for displayID: CGDirectDisplayID) -> Double? {
        let prefs = defaults.dictionary(forKey: prefsKey) as? [String: Double] ?? [:]
        return prefs[String(displayID)]
    }

    private func loadPreferences() {
        for i in displays.indices {
            if let saved = loadBrightness(for: displays[i].id) {
                displays[i].brightness = saved
            }
        }
    }
}
