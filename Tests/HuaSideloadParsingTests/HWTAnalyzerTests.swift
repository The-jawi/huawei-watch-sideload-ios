import XCTest
@testable import HuaSideloadParsing

final class HWTAnalyzerTests: XCTestCase {
    override func setUp() {
        UserDefaults.standard.set("en", forKey: AppLanguage.storageKey)
    }

    private func analyze(_ options: TestHWT.Options = TestHWT.Options(), watch: WatchFaceService.DeviceParams? = nil) -> HWTAnalysis {
        HWTAnalyzer.analyze(TestHWT.package(options), watch: watch).analysis
    }

    private func assert(_ analysis: HWTAnalysis, _ status: HWTAnalysis.Status, _ text: String,
                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(analysis.status, status, "\(analysis.reasons)", file: file, line: line)
        XCTAssertTrue(analysis.reasons.contains { $0.contains(text) }, "\(analysis.reasons)", file: file, line: line)
    }

    // MARK: - The real packages in WatchFaces/ (HWHD09, 466*466)

    func testRealSamplesAreIntactButMadeForARoundScreen() throws {
        for name in ["Donen.hwt", "Light Speed.hwt"] {
            let result = HWTAnalyzer.analyze(try TestHWT.sample(name))
            assert(result.analysis, .incompatible, "466*466")
            XCTAssertEqual(result.analysis.screen, "HWHD09")
            XCTAssertTrue(result.analysis.notes.contains("hashCode matches the package files"), "\(name): \(result.analysis.notes)")
            XCTAssertNotNil(result.preview)
        }
    }

    func testRealSamplesOnTheirOwnScreenAreCompatible() throws {
        let round = TargetProfile(name: "466×466 test watch", width: 466, height: 466)
        for name in ["Donen.hwt", "Light Speed.hwt"] {
            let analysis = HWTAnalyzer.analyze(try TestHWT.sample(name), target: round).analysis
            XCTAssertEqual(analysis.status, .compatible, "\(name): \(analysis.reasons)")
        }
    }

    func testRealSampleWithAChangedByteIsCorrupted() throws {
        var data = try TestHWT.sample("Donen.hwt")
        data[data.count / 2] ^= 0xFF
        XCTAssertEqual(HWTAnalyzer.analyze(data).analysis.status, .corrupted)
    }

    // MARK: - Valid packages

    func testValidFit4ProPackage() {
        let result = HWTAnalyzer.analyze(TestHWT.package())
        assert(result.analysis, .compatible, "does not guarantee")
        XCTAssertEqual(result.analysis.title, "Test Face")
        XCTAssertEqual(result.analysis.screen, "HWHD13")
        XCTAssertNotNil(result.preview)
        XCTAssertTrue(result.analysis.notes.contains("hashCode matches the package files"))
    }

    func testWithoutHashCodeTheChecksumsStillCount() {
        var o = TestHWT.Options()
        o.hashCode = .none
        let analysis = analyze(o)
        XCTAssertEqual(analysis.status, .compatible)
        XCTAssertTrue(analysis.notes.contains { $0.hasPrefix("No hashCode") })
    }

    func testTheWatchsOwnScreenWins() {
        assert(analyze(watch: WatchFaceService.DeviceParams(width: 466, height: 466)), .incompatible, "the connected watch is 466*466")
    }

    // MARK: - Corrupted

    func testEmptyAndForeignFiles() {
        assert(HWTAnalyzer.analyze(Data()).analysis, .corrupted, "empty")
        assert(HWTAnalyzer.analyze(Data("hello world".utf8)).analysis, .corrupted, "Not a ZIP container")
        assert(HWTAnalyzer.analyze(Data(TestHWT.jpeg(10, 10))).analysis, .corrupted, "FF D8 FF E0")
    }

    func testTruncatedArchive() {
        assert(HWTAnalyzer.analyze(TestHWT.package().dropLast(30)).analysis, .corrupted, "cut off")
    }

    func testChecksumMismatch() {
        var o = TestHWT.Options()
        o.badCRC = ["description.xml"]
        assert(analyze(o), .corrupted, "description.xml is damaged")
    }

    func testMissingRequiredParts() {
        assert(HWTAnalyzer.analyze(Data(TestHWT.zip([("com.huawei.watchface", [1])]))).analysis, .corrupted, "description.xml is missing")
        var o = TestHWT.Options()
        o.faceName = "something.else"
        assert(analyze(o), .corrupted, "com.huawei.watchface")
        o = TestHWT.Options()
        o.bin = nil
        assert(analyze(o), .corrupted, "watchface.bin is missing")
        o.bin = []
        assert(analyze(o), .corrupted, "watchface.bin is missing or empty")
    }

    func testMalformedMetadata() {
        var o = TestHWT.Options()
        o.description = Array("<HwTheme><title>Broken</HwTheme>".utf8)
        o.hashCode = .none
        assert(analyze(o), .corrupted, "not well-formed")
        o.description = Array("<Theme><title>x</title></Theme>".utf8)
        assert(analyze(o), .corrupted, "no HwTheme/HnTheme root")
    }

    func testHashCodeMismatch() {
        var o = TestHWT.Options()
        o.hashCode = .wrongDescription
        assert(analyze(o), .corrupted, "hashCode does not match description.xml")
    }

    func testMissingResources() {
        var o = TestHWT.Options()
        o.references = ["bg.png", "hand.png", "second.png"]
        assert(analyze(o), .corrupted, "second.png")
    }

    func testImagesThatAreNotWhatTheySay() {
        var o = TestHWT.Options()
        o.resources["bg.png"] = TestHWT.jpeg(408, 480)
        assert(analyze(o), .corrupted, "bg.png is a JPG file with a .png name")
        o.resources["bg.png"] = [1, 2, 3, 4]
        assert(analyze(o), .corrupted, "bg.png is not a valid image")
    }

    // MARK: - Incompatible

    func testResolutionMismatch() {
        var o = TestHWT.Options()
        o.screen = "HWHD09"
        assert(analyze(o), .incompatible, "Made for a 466*466 screen (HWHD09)")
    }

    func testOtherDeviceFamily() {
        var o = TestHWT.Options()
        o.root = "HnTheme"
        o.faceName = "com.honor.watchface"
        o.screen = "HNHD01"
        let analysis = analyze(o)
        assert(analysis, .incompatible, "HNHD01")
    }

    // MARK: - Unknown

    func testMissingCompatibilityMetadata() {
        var o = TestHWT.Options()
        o.screen = ""
        assert(analyze(o), .unknown, "no screen code")
        o.screen = nil
        assert(analyze(o), .unknown, "no screen code")
    }

    func testUnknownScreenCode() {
        var o = TestHWT.Options()
        o.screen = "HWHD99"
        assert(analyze(o), .unknown, "HWHD99 is not in the known list")
    }

    func testInnerMetadataDisagrees() {
        var o = TestHWT.Options()
        o.infoScreen = "HWHD09"
        assert(analyze(o), .unknown, "differs from description.xml")
    }

    func testUnsupportedImageFormat() {
        var o = TestHWT.Options()
        o.resources["anim.webp"] = Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WEBP".utf8)
        o.references.append("anim.webp")
        assert(analyze(o), .unknown, "Uses WEBP images")
    }

    func testImagesLargerThanTheScreen() {
        var o = TestHWT.Options()
        o.resources["bg.png"] = TestHWT.png(466, 466)
        assert(analyze(o), .unknown, "larger than the screen")
    }

    // MARK: - Pieces

    func testChecksumAndImageHelpers() {
        XCTAssertEqual(HWTAnalyzer.crc32(Array("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(HWTAnalyzer.imageSize(TestHWT.png(408, 480))?.width, 408)
        XCTAssertEqual(HWTAnalyzer.imageSize(TestHWT.png(408, 480))?.height, 480)
        XCTAssertEqual(HWTAnalyzer.imageSize(TestHWT.jpeg(320, 240))?.width, 320)
        XCTAssertEqual(HWTAnalyzer.imageSize(TestHWT.jpeg(320, 240))?.height, 240)
        XCTAssertNil(HWTAnalyzer.imageSize([1, 2, 3]))
        XCTAssertEqual(HWTAnalyzer.referencedResources(Array("<a res_name=\"x.png\" b=\"y.JPG\" c=\"1,2\"/>".utf8)), ["x.png", "y.JPG"])
    }
}
