import XCTest
@testable import HuaSideloadParsing

// What is uploaded as the watch face file, and under which name, for each upload method
final class WatchFaceUploadMethodTests: XCTestCase {
    override func setUp() {
        UserDefaults.standard.set("en", forKey: AppLanguage.storageKey)
    }

    func testPackageKeepsTheInnerFileUnchanged() throws {
        let face = try WatchFacePackage(hwt: TestHWT.package())
        XCTAssertTrue(face.binWasZipped)
        XCTAssertEqual(face.bin, [0x02, 0x00, 0x3C, 0x03])
        XCTAssertEqual(Array(face.package.prefix(4)), [0x50, 0x4B, 0x03, 0x04])   // the com.huawei.watchface zip
        XCTAssertNotNil(try? ZipArchive(face.package).file("watchface.bin"))
    }

    func testPayloadPerMethod() throws {
        let face = try WatchFacePackage(hwt: TestHWT.package())
        XCTAssertEqual(WatchFaceUploadMethod.bin.payload(bin: face.bin, package: face.package), face.bin)
        XCTAssertEqual(WatchFaceUploadMethod.binFaceVersion.payload(bin: face.bin, package: face.package), face.bin)
        XCTAssertEqual(WatchFaceUploadMethod.package.payload(bin: face.bin, package: face.package), face.package)
        XCTAssertEqual(WatchFaceUploadMethod.packageFaceVersion.payload(bin: face.bin, package: face.package), face.package)
    }

    // An older package whose com.huawei.watchface is the bin itself: every method sends the same bytes
    func testUnzippedBinIsTheSameForEveryMethod() {
        let bin: [UInt8] = [9, 8, 7]
        for method in WatchFaceUploadMethod.allCases {
            XCTAssertEqual(method.payload(bin: bin, package: bin), bin)
        }
    }

    func testUploadNames() {
        XCTAssertEqual(WatchFaceUploadMethod.bin.uploadName(number: 42, faceVersion: "2.0.1"), "000000042_1.0.0")
        XCTAssertEqual(WatchFaceUploadMethod.package.uploadName(number: 123456789, faceVersion: "2.0.1"), "123456789_1.0.0")
        XCTAssertEqual(WatchFaceUploadMethod.binFaceVersion.uploadName(number: 42, faceVersion: "2.0.1"), "000000042_2.0.1")
        XCTAssertEqual(WatchFaceUploadMethod.packageFaceVersion.uploadName(number: 42, faceVersion: "3.1"), "000000042_3.1")
        XCTAssertEqual(WatchFaceService.split(WatchFaceUploadMethod.packageFaceVersion.uploadName(number: 7, faceVersion: "2.0.1")).version, "2.0.1")
    }

    // A version that would break the "<name>_<version>" split or is not a version falls back to 1.0.0
    func testUnusableFaceVersionsFallBack() {
        for bad in ["?", "", "2_0", "v2.0", ".2", "2.", "２.0"] {
            XCTAssertEqual(WatchFaceUploadMethod.packageFaceVersion.uploadName(number: 1, faceVersion: bad), "000000001_1.0.0", bad)
        }
    }

    func testStoredChoice() {
        UserDefaults.standard.removeObject(forKey: WatchFaceUploadMethod.storageKey)
        XCTAssertEqual(WatchFaceUploadMethod.current, .bin)
        UserDefaults.standard.set("package", forKey: WatchFaceUploadMethod.storageKey)
        XCTAssertEqual(WatchFaceUploadMethod.current, .package)
        UserDefaults.standard.set("nonsense", forKey: WatchFaceUploadMethod.storageKey)
        XCTAssertEqual(WatchFaceUploadMethod.current, .bin)
        UserDefaults.standard.removeObject(forKey: WatchFaceUploadMethod.storageKey)
    }

    func testLabels() {
        XCTAssertEqual(WatchFaceUploadMethod.allCases.map(\.shortLabel), ["A", "B", "C", "D"])
    }
}
