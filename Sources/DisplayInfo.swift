import Foundation
import CoreGraphics

/// Represents a connected display with its properties.
struct DisplayInfo: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String
    let isBuiltIn: Bool
    var brightness: Double // 0.0 – 1.5 for built-in, 0.0 – 1.0 for external
    var isOverlayActive: Bool

    var maxBrightness: Double { isBuiltIn ? 1.5 : 1.0 }
    var minBrightness: Double { 0.0 }

    /// Human-readable brightness percentage
    var brightnessPercent: Int {
        Int((brightness * 100).rounded())
    }

    static func == (lhs: DisplayInfo, rhs: DisplayInfo) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
