import AppKit
import AppleSiliconDDC
import CoreGraphics
import Foundation
import IOKit
import IOKit.i2c

private let displayServicesLib: UnsafeMutableRawPointer? = {
    dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
}()

private typealias SetBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
private typealias GetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32

private let displayServicesSetBrightness: SetBrightnessFn? = {
    guard let lib = displayServicesLib,
          let symbol = dlsym(lib, "DisplayServicesSetBrightness") else { return nil }
    return unsafeBitCast(symbol, to: SetBrightnessFn.self)
}()

private let displayServicesGetBrightness: GetBrightnessFn? = {
    guard let lib = displayServicesLib,
          let symbol = dlsym(lib, "DisplayServicesGetBrightness") else { return nil }
    return unsafeBitCast(symbol, to: GetBrightnessFn.self)
}()

private let ddcBrightnessCommand: UInt8 = 0x10

@MainActor
final class BrightnessManager: ObservableObject {
    @Published var displays: [DisplayInfo] = []
    @Published var optionHotkeysEnabled = false
    @Published var brightnessKeyMode: BrightnessKeyMode = .disabled
    @Published var lastErrorMessage: String?

    private let defaults = UserDefaults.standard
    private let prefsKey = "BrightBar.DisplayBrightness.v2"
    private let nitsPrefsKey = "BrightBar.DisplayMaxNits.v1"
    private let hotkeyStep = 0.05
    private let hardwareDimmingFloor = 0.2
    private let maxSoftwareDimOpacity = 0.88
    private var dimmingWindows: [CGDirectDisplayID: NSWindow] = [:]
    private var pendingKeyboardDelta = 0.0
    private var keyboardAdjustmentTask: Task<Void, Never>?
    private var appleSiliconDDCServices: [CGDirectDisplayID: AppleSiliconDDC.IOregService] = [:]

    var averageBrightness: Double {
        let controllable = displays.filter(\.isControllable)
        guard !controllable.isEmpty else { return 0.5 }
        let total = controllable.reduce(0.0) { $0 + $1.brightness }
        return total / Double(controllable.count)
    }

    var averageBrightnessPercent: Int {
        Int((averageBrightness * 100).rounded())
    }

    var statusSummary: String {
        let controllable = displays.filter(\.isControllable).count
        let total = displays.count

        if total == 0 {
            return "Aucun ecran"
        }

        if controllable == total {
            return "\(total) ecran\(total > 1 ? "s" : "") controle\(total > 1 ? "s" : "")"
        }

        return "\(controllable)/\(total) ecrans controles"
    }

    init() {
        refreshDisplays()
        let hotkeyStatus = HotkeyManager.shared.register { [weak self] isUp in
            Task { @MainActor in
                guard let self else { return }
                self.queueKeyboardAdjustment(isUp: isUp)
            }
        }
        optionHotkeysEnabled = hotkeyStatus.optionHotkeys
        brightnessKeyMode = hotkeyStatus.brightnessKeyMode
    }

    func refreshDisplays() {
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 32)
        var displayCount: UInt32 = 0
        let result = CGGetActiveDisplayList(UInt32(displayIDs.count), &displayIDs, &displayCount)

        guard result == .success else {
            lastErrorMessage = "Impossible de lire la liste des ecrans."
            displays = []
            return
        }

        let activeDisplayIDs = Set(displayIDs.prefix(Int(displayCount)))
        for staleID in Array(dimmingWindows.keys) where !activeDisplayIDs.contains(staleID) {
            closeSoftwareDimming(for: staleID)
        }

        var nextDisplays: [DisplayInfo] = []
        var savedValuesToApply: [(CGDirectDisplayID, Double)] = []
        appleSiliconDDCServices = Self.appleSiliconDDCServices(for: Array(displayIDs.prefix(Int(displayCount))))

        for displayID in displayIDs.prefix(Int(displayCount)) {
            let isBuiltIn = CGDisplayIsBuiltin(displayID) != 0
            let persistentID = Self.persistentDisplayID(for: displayID)
            let name = Self.displayName(for: displayID)
            let loadedBrightness = loadBrightness(for: persistentID)
            let current = readBrightness(for: displayID, isBuiltIn: isBuiltIn)
            let brightness = loadedBrightness ?? current.value ?? 0.5
            let maxNits = loadMaxNits(for: persistentID) ?? defaultMaxNits(isBuiltIn: isBuiltIn)
            let clampedBrightness = min(max(brightness, 0), 1)

            nextDisplays.append(
                DisplayInfo(
                    id: displayID,
                    persistentID: persistentID,
                    name: name,
                    isBuiltIn: isBuiltIn,
                    brightness: clampedBrightness,
                    controlKind: current.kind,
                    lastWriteFailed: false,
                    isSoftwareDimmed: dimmingWindows[displayID]?.isVisible == true,
                    maxNits: maxNits,
                    luminanceFactor: luminanceFactor(forRequestedBrightness: clampedBrightness, controlKind: current.kind)
                )
            )

            if let loadedBrightness {
                savedValuesToApply.append((displayID, loadedBrightness))
            }
        }

        displays = nextDisplays
        lastErrorMessage = nil

        for (displayID, value) in savedValuesToApply {
            setBrightness(for: displayID, to: value)
        }
    }

    func setAllBrightness(to value: Double) {
        for display in displays where display.isControllable {
            setBrightness(for: display.id, to: value)
        }
    }

    func adjustAllBrightness(by delta: Double) {
        for display in displays where display.isControllable {
            setBrightness(for: display.id, to: display.brightness + delta)
        }
    }

    private func queueKeyboardAdjustment(isUp: Bool) {
        pendingKeyboardDelta += isUp ? hotkeyStep : -hotkeyStep

        guard keyboardAdjustmentTask == nil else { return }

        keyboardAdjustmentTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 25_000_000)
            let delta = pendingKeyboardDelta
            pendingKeyboardDelta = 0
            keyboardAdjustmentTask = nil
            adjustAllBrightness(by: delta)
        }
    }

    func setMaxNits(for displayID: CGDirectDisplayID, to value: Double) {
        guard let index = displays.firstIndex(where: { $0.id == displayID }) else { return }

        let clamped = min(max(value, 80), 2_000)
        displays[index].maxNits = clamped
        saveMaxNits(clamped, for: displays[index].persistentID)
    }

    func setBrightness(for displayID: CGDirectDisplayID, to value: Double) {
        guard let index = displays.firstIndex(where: { $0.id == displayID }) else { return }
        guard displays[index].isControllable else { return }

        let clamped = min(max(value, displays[index].minBrightness), displays[index].maxBrightness)
        let display = displays[index]
        let hardwareValue = hardwareBrightness(forRequestedBrightness: clamped)
        let dimmingOpacity = display.controlKind == .software
            ? softwareOnlyDimOpacity(forRequestedBrightness: clamped)
            : softwareDimOpacity(forRequestedBrightness: clamped)
        let success: Bool

        switch display.controlKind {
        case .native:
            success = setBuiltInBrightness(displayID: displayID, value: hardwareValue)
        case .ddc:
            success = setExternalBrightness(displayID: displayID, value: hardwareValue)
        case .software:
            success = true
        case .unsupported:
            success = false
        }

        displays[index].brightness = clamped
        displays[index].lastWriteFailed = !success
        displays[index].luminanceFactor = luminanceFactor(forRequestedBrightness: clamped, controlKind: display.controlKind)

        if success {
            setSoftwareDimming(for: displayID, opacity: dimmingOpacity)
            displays[index].isSoftwareDimmed = dimmingOpacity > 0
            saveBrightness(clamped, for: display.persistentID)
            lastErrorMessage = nil
        } else {
            lastErrorMessage = "Impossible de regler \(display.name)."
        }
    }

    private func readBrightness(for displayID: CGDirectDisplayID, isBuiltIn: Bool) -> (value: Double?, kind: BrightnessControlKind) {
        if isBuiltIn {
            guard let getBrightness = displayServicesGetBrightness else {
                return (nil, .software)
            }

            var brightness: Float = 0.5
            guard getBrightness(displayID, &brightness) == kIOReturnSuccess else {
                return (nil, .native)
            }

            return (Double(brightness), .native)
        }

        if let service = appleSiliconDDCServices[displayID],
           let value = AppleSiliconDDC.read(service: service.service, command: ddcBrightnessCommand) {
            let maxValue = max(Double(value.max), 1)
            return (Double(value.current) / maxValue, .ddc)
        }

        guard let framebuffer = Self.framebufferPort(for: displayID) else {
            return (nil, .software)
        }
        IOObjectRelease(framebuffer)

        if let value = ddcRead(displayID: displayID, command: ddcBrightnessCommand) {
            return (Double(value) / 100.0, .ddc)
        }

        return (nil, .software)
    }

    private func setBuiltInBrightness(displayID: CGDirectDisplayID, value: Double) -> Bool {
        guard let setBrightness = displayServicesSetBrightness else { return false }
        return setBrightness(displayID, Float(value)) == kIOReturnSuccess
    }

    private func setExternalBrightness(displayID: CGDirectDisplayID, value: Double) -> Bool {
        let ddcValue = UInt16(min(max(value * 100, 0), 100))
        if let service = appleSiliconDDCServices[displayID] {
            return AppleSiliconDDC.write(service: service.service, command: ddcBrightnessCommand, value: ddcValue)
        }
        return ddcWrite(displayID: displayID, command: ddcBrightnessCommand, value: ddcValue)
    }

    private func hardwareBrightness(forRequestedBrightness value: Double) -> Double {
        value <= hardwareDimmingFloor ? hardwareDimmingFloor : value
    }

    private func softwareDimOpacity(forRequestedBrightness value: Double) -> Double {
        guard value < hardwareDimmingFloor else { return 0 }

        let progress = 1 - (value / hardwareDimmingFloor)
        return min(max(progress * maxSoftwareDimOpacity, 0), maxSoftwareDimOpacity)
    }

    private func softwareOnlyDimOpacity(forRequestedBrightness value: Double) -> Double {
        let progress = 1 - value
        return min(max(progress * maxSoftwareDimOpacity, 0), maxSoftwareDimOpacity)
    }

    private func luminanceFactor(forRequestedBrightness value: Double, controlKind: BrightnessControlKind) -> Double {
        if controlKind == .software {
            let opacity = softwareOnlyDimOpacity(forRequestedBrightness: value)
            return min(max(1 - opacity, 0), 1)
        }

        let hardwareValue = hardwareBrightness(forRequestedBrightness: value)
        let opacity = softwareDimOpacity(forRequestedBrightness: value)
        return min(max(hardwareValue * (1 - opacity), 0), 1)
    }

    private func setSoftwareDimming(for displayID: CGDirectDisplayID, opacity: Double) {
        guard opacity > 0.001 else {
            hideSoftwareDimming(for: displayID)
            return
        }

        guard let screen = NSScreen.screen(for: displayID) else { return }

        if let window = dimmingWindows[displayID] {
            window.setFrame(screen.frame, display: true)
            window.alphaValue = CGFloat(opacity)
            if !window.isVisible {
                window.orderFrontRegardless()
            }
            return
        }

        let window = DimmingWindow(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.backgroundColor = .black
        window.alphaValue = CGFloat(opacity)
        window.animationBehavior = .none
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.isOpaque = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.orderFrontRegardless()

        dimmingWindows[displayID] = window
    }

    private func hideSoftwareDimming(for displayID: CGDirectDisplayID) {
        guard let window = dimmingWindows[displayID] else { return }

        window.alphaValue = 0
        window.orderOut(nil)
    }

    private func closeSoftwareDimming(for displayID: CGDirectDisplayID) {
        dimmingWindows[displayID]?.orderOut(nil)
        dimmingWindows[displayID]?.close()
        dimmingWindows.removeValue(forKey: displayID)
    }

    private func saveBrightness(_ value: Double, for persistentID: String) {
        var prefs = defaults.dictionary(forKey: prefsKey) as? [String: Double] ?? [:]
        prefs[persistentID] = value
        defaults.set(prefs, forKey: prefsKey)
    }

    private func loadBrightness(for persistentID: String) -> Double? {
        let prefs = defaults.dictionary(forKey: prefsKey) as? [String: Double] ?? [:]
        return prefs[persistentID]
    }

    private func saveMaxNits(_ value: Double, for persistentID: String) {
        var prefs = defaults.dictionary(forKey: nitsPrefsKey) as? [String: Double] ?? [:]
        prefs[persistentID] = value
        defaults.set(prefs, forKey: nitsPrefsKey)
    }

    private func loadMaxNits(for persistentID: String) -> Double? {
        let prefs = defaults.dictionary(forKey: nitsPrefsKey) as? [String: Double] ?? [:]
        return prefs[persistentID]
    }

    private func defaultMaxNits(isBuiltIn: Bool) -> Double {
        isBuiltIn ? 500 : 300
    }
}

private extension BrightnessManager {
    static func displayName(for displayID: CGDirectDisplayID) -> String {
        if let screen = NSScreen.screen(for: displayID) {
            return screen.localizedName
        }

        if CGDisplayIsBuiltin(displayID) != 0 {
            return "Ecran integre"
        }

        guard let info = displayInfoDictionary(for: displayID),
              let names = info[kDisplayProductName] as? [String: String],
              let name = names.values.first else {
            return "Ecran externe \(displayID)"
        }

        return name
    }

    static func persistentDisplayID(for displayID: CGDirectDisplayID) -> String {
        let vendor = CGDisplayVendorNumber(displayID)
        let model = CGDisplayModelNumber(displayID)
        let serial = CGDisplaySerialNumber(displayID)

        if vendor != 0 || model != 0 || serial != 0 {
            return "\(vendor)-\(model)-\(serial)"
        }

        return String(displayID)
    }

    static func appleSiliconDDCServices(for displayIDs: [CGDirectDisplayID]) -> [CGDirectDisplayID: AppleSiliconDDC.IOregService] {
        let services = AppleSiliconDDC.getIoregServicesForMatching()
            .filter { $0.service != nil && !$0.productName.isEmpty }

        guard !services.isEmpty else { return [:] }

        var matches: [CGDirectDisplayID: AppleSiliconDDC.IOregService] = [:]
        var usedServiceLocations = Set<Int>()

        for displayID in displayIDs where CGDisplayIsBuiltin(displayID) == 0 {
            let displayName = Self.displayName(for: displayID).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let displaySerial = Int64(CGDisplaySerialNumber(displayID))

            let scored = services
                .filter { !usedServiceLocations.contains($0.serviceLocation) }
                .map { service -> (service: AppleSiliconDDC.IOregService, score: Int) in
                    var score = 0
                    if service.productName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == displayName {
                        score += 100
                    }
                    if service.serialNumber != 0 && service.serialNumber == displaySerial {
                        score += 25
                    }
                    if service.location == "External" {
                        score += 5
                    }
                    if service.transportUpstream != "" || service.transportDownstream != "" {
                        score += 2
                    }
                    return (service, score)
                }
                .sorted { $0.score > $1.score }

            guard let best = scored.first, best.score > 0 else { continue }
            matches[displayID] = best.service
            usedServiceLocations.insert(best.service.serviceLocation)
        }

        return matches
    }

    static func displayInfoDictionary(for displayID: CGDirectDisplayID) -> [String: Any]? {
        var iterator = io_iterator_t()
        let matching = IOServiceMatching("IODisplayConnect")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == kIOReturnSuccess else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        let targetVendor = CGDisplayVendorNumber(displayID)
        let targetProduct = CGDisplayModelNumber(displayID)
        let targetSerial = CGDisplaySerialNumber(displayID)

        var service = IOIteratorNext(iterator)
        while service != 0 {
            let currentService = service
            service = IOIteratorNext(iterator)
            defer { IOObjectRelease(currentService) }

            guard let info = IODisplayCreateInfoDictionary(currentService, IOOptionBits(kIODisplayOnlyPreferredName))
                .takeRetainedValue() as? [String: Any] else {
                continue
            }

            let vendor = uint32Value(info[kDisplayVendorID])
            let product = uint32Value(info[kDisplayProductID])
            let serial = uint32Value(info[kDisplaySerialNumber])

            if vendor == targetVendor && product == targetProduct && (targetSerial == 0 || serial == targetSerial) {
                return info
            }
        }

        return nil
    }

    static func framebufferPort(for displayID: CGDirectDisplayID) -> io_service_t? {
        var iterator = io_iterator_t()
        let matching = IOServiceMatching("IODisplayConnect")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == kIOReturnSuccess else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        let targetVendor = CGDisplayVendorNumber(displayID)
        let targetProduct = CGDisplayModelNumber(displayID)
        let targetSerial = CGDisplaySerialNumber(displayID)

        var service = IOIteratorNext(iterator)

        while service != 0 {
            let currentService = service
            service = IOIteratorNext(iterator)
            defer { IOObjectRelease(currentService) }

            guard let info = IODisplayCreateInfoDictionary(currentService, IOOptionBits(kIODisplayOnlyPreferredName))
                .takeRetainedValue() as? [String: Any] else {
                continue
            }

            let vendor = uint32Value(info[kDisplayVendorID])
            let product = uint32Value(info[kDisplayProductID])
            let serial = uint32Value(info[kDisplaySerialNumber])
            let isMatch = vendor == targetVendor && product == targetProduct && (targetSerial == 0 || serial == targetSerial)
            let parent = framebufferParent(of: currentService)

            if isMatch, let parent {
                return parent
            }

            if let parent {
                IOObjectRelease(parent)
            }
        }

        return nil
    }

    static func framebufferParent(of displayService: io_service_t) -> io_service_t? {
        var current = displayService
        var parent: io_registry_entry_t = 0

        while IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == kIOReturnSuccess {
            if current != displayService {
                IOObjectRelease(current)
            }

            if IOObjectConformsTo(parent, "IOFramebuffer") != 0 {
                return parent
            }

            current = parent
        }

        if current != displayService {
            IOObjectRelease(current)
        }

        return nil
    }

    static func uint32Value(_ value: Any?) -> UInt32 {
        if let value = value as? UInt32 {
            return value
        }
        if let value = value as? Int {
            return UInt32(value)
        }
        if let value = value as? NSNumber {
            return value.uint32Value
        }
        return 0
    }
}

private extension BrightnessManager {
    func ddcWrite(displayID: CGDirectDisplayID, command: UInt8, value: UInt16) -> Bool {
        guard let framebufferPort = Self.framebufferPort(for: displayID) else { return false }
        defer { IOObjectRelease(framebufferPort) }

        var busCount: IOItemCount = 0
        guard IOFBGetI2CInterfaceCount(framebufferPort, &busCount) == kIOReturnSuccess,
              busCount > 0 else { return false }

        let valueHigh = UInt8((value >> 8) & 0xFF)
        let valueLow = UInt8(value & 0xFF)

        var data: [UInt8] = [
            0x51,
            0x84,
            0x03,
            command,
            valueHigh,
            valueLow,
        ]

        var checksum: UInt8 = 0x6E
        for byte in data {
            checksum ^= byte
        }
        data.append(checksum)

        for bus in 0..<busCount {
            if sendDDC(bytes: data, to: framebufferPort, bus: bus, expectsReply: false) != nil {
                return true
            }
        }

        return false
    }

    func ddcRead(displayID: CGDirectDisplayID, command: UInt8) -> UInt16? {
        guard let framebufferPort = Self.framebufferPort(for: displayID) else { return nil }
        defer { IOObjectRelease(framebufferPort) }

        var busCount: IOItemCount = 0
        guard IOFBGetI2CInterfaceCount(framebufferPort, &busCount) == kIOReturnSuccess,
              busCount > 0 else { return nil }

        var data: [UInt8] = [
            0x51,
            0x82,
            0x01,
            command,
        ]

        var checksum: UInt8 = 0x6E
        for byte in data {
            checksum ^= byte
        }
        data.append(checksum)

        for bus in 0..<busCount {
            guard let reply = sendDDC(bytes: data, to: framebufferPort, bus: bus, expectsReply: true),
                  let value = parseDDCBrightnessReply(reply, command: command) else {
                continue
            }

            return value
        }

        return nil
    }

    func sendDDC(bytes: [UInt8], to framebufferPort: io_service_t, bus: IOItemCount, expectsReply: Bool) -> [UInt8]? {
        var i2cInterface: io_service_t = 0
        guard IOFBCopyI2CInterfaceForBus(framebufferPort, bus, &i2cInterface) == kIOReturnSuccess else {
            return nil
        }
        defer { IOObjectRelease(i2cInterface) }

        var connect: IOI2CConnectRef?
        guard IOI2CInterfaceOpen(i2cInterface, 0, &connect) == kIOReturnSuccess,
              let connection = connect else {
            return nil
        }
        defer { IOI2CInterfaceClose(connection, 0) }

        var sendBuffer = bytes
        var replyBuffer = [UInt8](repeating: 0, count: expectsReply ? 12 : 0)
        var request = IOI2CRequest()
        request.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
        request.sendAddress = 0x6E
        request.sendBytes = UInt32(sendBuffer.count)
        request.replyTransactionType = expectsReply
            ? IOOptionBits(kIOI2CSimpleTransactionType)
            : IOOptionBits(kIOI2CNoTransactionType)
        request.replyAddress = 0x6F
        request.replyBytes = UInt32(replyBuffer.count)

        let result = sendBuffer.withUnsafeMutableBufferPointer { sendPointer -> kern_return_t in
            request.sendBuffer = vm_address_t(bitPattern: sendPointer.baseAddress)

            if expectsReply {
                return replyBuffer.withUnsafeMutableBufferPointer { replyPointer -> kern_return_t in
                    request.replyBuffer = vm_address_t(bitPattern: replyPointer.baseAddress)
                    return IOI2CSendRequest(connection, 0, &request)
                }
            }

            return IOI2CSendRequest(connection, 0, &request)
        }

        guard result == kIOReturnSuccess, request.result == kIOReturnSuccess else {
            return nil
        }

        return expectsReply ? replyBuffer : []
    }

    func parseDDCBrightnessReply(_ reply: [UInt8], command: UInt8) -> UInt16? {
        guard let commandIndex = reply.firstIndex(of: command) else { return nil }

        let candidates = [
            commandIndex + 4,
            commandIndex + 5,
        ]

        for index in candidates where index + 1 < reply.count {
            let value = (UInt16(reply[index]) << 8) | UInt16(reply[index + 1])
            if value <= 100 {
                return value
            }
        }

        return nil
    }
}

private extension NSScreen {
    static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }

            return number.uint32Value == displayID
        }
    }
}

private final class DimmingWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
