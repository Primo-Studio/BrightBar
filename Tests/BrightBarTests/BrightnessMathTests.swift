import XCTest
@testable import BrightBar

final class BrightnessMathTests: XCTestCase {
    func testBrightnessClamping() {
        XCTAssertEqual(BrightnessMath.clampedBrightness(-0.5), 0)
        XCTAssertEqual(BrightnessMath.clampedBrightness(0.42), 0.42)
        XCTAssertEqual(BrightnessMath.clampedBrightness(1.4), 1)
    }

    func testHardwareBrightnessNeverDropsBelowFloor() {
        XCTAssertEqual(BrightnessMath.hardwareBrightness(forRequestedBrightness: 0), 0.2)
        XCTAssertEqual(BrightnessMath.hardwareBrightness(forRequestedBrightness: 0.05), 0.2)
        XCTAssertEqual(BrightnessMath.hardwareBrightness(forRequestedBrightness: 0.8), 0.8)
    }

    func testSubZeroOpacityOnlyAppliesBelowHardwareFloor() {
        XCTAssertEqual(BrightnessMath.hardwareSubZeroOpacity(forRequestedBrightness: 0.2), 0)
        XCTAssertEqual(BrightnessMath.hardwareSubZeroOpacity(forRequestedBrightness: 1), 0)
        XCTAssertEqual(BrightnessMath.hardwareSubZeroOpacity(forRequestedBrightness: 0), 0.88)
    }

    func testSoftwareOnlyOpacityDimsAcrossWholeRange() {
        XCTAssertEqual(BrightnessMath.softwareOnlyOpacity(forRequestedBrightness: 1), 0)
        XCTAssertEqual(BrightnessMath.softwareOnlyOpacity(forRequestedBrightness: 0), 0.88)
        XCTAssertEqual(BrightnessMath.softwareOnlyOpacity(forRequestedBrightness: 0.5), 0.44, accuracy: 0.0001)
    }

    func testEstimatedNitsForNativeDisplays() {
        XCTAssertEqual(BrightnessMath.estimatedNits(maxNits: 500, brightness: 1, controlKind: .native), 500)
        XCTAssertEqual(BrightnessMath.estimatedNits(maxNits: 500, brightness: 0.5, controlKind: .native), 250)
        XCTAssertEqual(BrightnessMath.estimatedNits(maxNits: 500, brightness: 0, controlKind: .native), 12)
    }

    func testEstimatedNitsForSoftwareOnlyDisplays() {
        XCTAssertEqual(BrightnessMath.estimatedNits(maxNits: 350, brightness: 1, controlKind: .software), 350)
        XCTAssertEqual(BrightnessMath.estimatedNits(maxNits: 350, brightness: 0.5, controlKind: .software), 196)
        XCTAssertEqual(BrightnessMath.estimatedNits(maxNits: 350, brightness: 0, controlKind: .software), 42)
    }
}
