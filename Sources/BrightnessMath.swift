import Foundation

enum BrightnessMath {
    static let hardwareDimmingFloor = 0.2
    static let maxSoftwareDimOpacity = 0.88

    static func clampedBrightness(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    static func clampedMaxNits(_ value: Double) -> Double {
        min(max(value, 80), 2_000)
    }

    static func hardwareBrightness(forRequestedBrightness value: Double) -> Double {
        clampedBrightness(value) <= hardwareDimmingFloor ? hardwareDimmingFloor : clampedBrightness(value)
    }

    static func hardwareSubZeroOpacity(forRequestedBrightness value: Double) -> Double {
        let brightness = clampedBrightness(value)
        guard brightness < hardwareDimmingFloor else { return 0 }

        let progress = 1 - (brightness / hardwareDimmingFloor)
        return min(max(progress * maxSoftwareDimOpacity, 0), maxSoftwareDimOpacity)
    }

    static func softwareOnlyOpacity(forRequestedBrightness value: Double) -> Double {
        let progress = 1 - clampedBrightness(value)
        return min(max(progress * maxSoftwareDimOpacity, 0), maxSoftwareDimOpacity)
    }

    static func estimatedNits(maxNits: Double, brightness: Double, controlKind: BrightnessControlKind) -> Int {
        let factor: Double

        if controlKind == .software {
            factor = min(max(1 - softwareOnlyOpacity(forRequestedBrightness: brightness), 0), 1)
        } else {
            let hardwareValue = hardwareBrightness(forRequestedBrightness: brightness)
            let opacity = hardwareSubZeroOpacity(forRequestedBrightness: brightness)
            factor = min(max(hardwareValue * (1 - opacity), 0), 1)
        }

        return Int((maxNits * factor).rounded())
    }
}
