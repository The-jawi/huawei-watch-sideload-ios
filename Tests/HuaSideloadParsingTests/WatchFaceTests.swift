import XCTest
@testable import HuaSideloadParsing

// .hwt packages, the screen check and the watch face messages (service 0x27), as in Gadgetbridge
final class WatchFaceTests: XCTestCase {
    override func setUp() {
        UserDefaults.standard.set("en", forKey: AppLanguage.storageKey)
    }

    // MARK: - A minimal zip writer (stored entries) to build test packages

    private func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
    private func le32(_ v: Int) -> [UInt8] { le16(v & 0xFFFF) + le16(v >> 16 & 0xFFFF) }

    private func zip(_ files: [(String, [UInt8])]) -> [UInt8] {
        var out: [UInt8] = []
        var central: [UInt8] = []
        for (name, data) in files {
            let offset = out.count
            let n = Array(name.utf8)
            out += le32(0x0403_4B50) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0)
                + le32(data.count) + le32(data.count) + le16(n.count) + le16(0) + n + data
            central += le32(0x0201_4B50) + le16(20) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0)
                + le32(data.count) + le32(data.count) + le16(n.count) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0)
                + le32(offset) + n
        }
        let centralOffset = out.count
        out += central
        out += le32(0x0605_4B50) + le16(0) + le16(0) + le16(files.count) + le16(files.count) + le32(central.count) + le32(centralOffset) + le16(0)
        return out
    }

    private func description(root: String = "HwTheme", screen: String? = "HWHD13", version: String? = "1.0.0") -> [UInt8] {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<\(root)>\n<title>Test Face</title>\n"
        if let screen { xml += "<screen>\(screen)</screen>\n" }
        if let version { xml += "<version>\(version)</version>\n" }
        xml += "</\(root)>"
        return Array(xml.utf8)
    }

    private let bin: [UInt8] = [0x57, 0x46, 0x01, 0x02, 0x03]

    // MARK: - Package parsing

    func testModernPackage() throws {
        let hwt = zip([("description.xml", description()), ("com.huawei.watchface", zip([("watchface.bin", bin)])),
                       ("preview/cover.jpg", [0xFF, 0xD8]), ("ability.xml", []), ("hashCode", [])])
        let face = try WatchFacePackage(hwt: Data(hwt))
        XCTAssertEqual(face.title, "Test Face")
        XCTAssertEqual(face.screen, "HWHD13")
        XCTAssertEqual(face.version, "1.0.0")
        XCTAssertEqual(face.bin, bin)
        XCTAssertTrue(face.binWasZipped)
        XCTAssertEqual(face.root, "HwTheme")
        XCTAssertTrue(face.hasPreview)
        XCTAssertEqual(face.warnings, [])
        XCTAssertEqual(face.files, ["ability.xml", "com.huawei.watchface", "description.xml", "hashCode", "preview/cover.jpg"])
    }

    func testOlderPackageWithBinDirectly() throws {
        let face = try WatchFacePackage(hwt: Data(zip([("description.xml", description()), ("com.huawei.watchface", bin),
                                                       ("preview/cover.jpg", [1])])))
        XCTAssertEqual(face.bin, bin)
        XCTAssertFalse(face.binWasZipped)
    }

    func testHonorPackageAndBOM() throws {
        let face = try WatchFacePackage(hwt: Data(zip([("description.xml", [0xEF, 0xBB, 0xBF] + description(root: "HnTheme", screen: "HNHD01")),
                                                       ("com.honor.watchface", zip([("watchface.bin", bin)])), ("preview/cover.jpg", [1])])))
        XCTAssertEqual(face.root, "HnTheme")
        XCTAssertEqual(face.screen, "HNHD01")
        XCTAssertEqual(face.bin, bin)
    }

    func testWarnings() throws {
        let face = try WatchFacePackage(hwt: Data(zip([("description.xml", description(root: "Other", screen: nil, version: nil)),
                                                       ("com.huawei.watchface", [])])))
        XCTAssertEqual(face.screen, "?")
        XCTAssertEqual(face.warnings.count, 5)
    }

    func testMalformedPackages() {
        XCTAssertThrowsError(try WatchFacePackage(hwt: Data([1, 2, 3])))
        XCTAssertThrowsError(try WatchFacePackage(hwt: Data(Array(repeating: 0, count: 100))))
        XCTAssertThrowsError(try WatchFacePackage(hwt: Data(zip([("com.huawei.watchface", bin)]))))          // no description.xml
        XCTAssertThrowsError(try WatchFacePackage(hwt: Data(zip([("description.xml", description())]))))   // no face
        XCTAssertThrowsError(try WatchFacePackage(hwt: Data(zip([("description.xml", description())]).dropLast(10))))
    }

    // MARK: - Screen compatibility

    private let fit4Pro = WatchFaceService.DeviceParams(maxVersion: "2.1", width: 408, height: 480)

    func testFit4ProScreen() {
        XCTAssertEqual(fit4Pro.resolution, "480*408")
        XCTAssertEqual(WatchFaceScreen.resolutions["HWHD13"], "480*408")
        guard case .compatible = WatchFaceCompatibility.evaluate(screenCode: "HWHD13", device: fit4Pro) else { return XCTFail() }
    }

    func testRoundFaceOnFit4ProIsBlocked() {
        let result = WatchFaceCompatibility.evaluate(screenCode: "HWHD09", device: fit4Pro)
        guard case .incompatible = result else { return XCTFail("\(result)") }
        XCTAssertTrue(result.blocksInstall)
        XCTAssertTrue(result.label.contains("466*466"))
    }

    func testUnknownIsNotBlockedAndNotCalledCompatible() {
        for result in [WatchFaceCompatibility.evaluate(screenCode: "HWHD99", device: fit4Pro),
                       WatchFaceCompatibility.evaluate(screenCode: "HWHD13", device: nil),
                       WatchFaceCompatibility.evaluate(screenCode: "?", device: fit4Pro)] {
            guard case .unknown = result else { return XCTFail("\(result)") }
            XCTAssertFalse(result.blocksInstall)
            XCTAssertTrue(result.label.hasPrefix("Compatibility unknown"))
        }
    }

    // MARK: - Service 0x27 messages

    private func items(_ tlv: HuaweiTLV) -> [String] {
        tlv.items.map { String(format: "%02X=", $0.tag) + $0.value.hexCompact }
    }

    func testParamsRequestAndResponse() {
        XCTAssertEqual(WatchFaceService.paramsRequest().items.map { $0.tag }, [0x01, 0x02, 0x03, 0x04, 0x05, 0x0E, 0x0F])
        let response = HuaweiTLV().with(0x01, Array("2.1".utf8)).with(0x02, [0x01, 0x98]).with(0x03, [0x01, 0xE0])
            .with(0x04, [0x01]).with(0x05, [0x01])
        XCTAssertEqual(WatchFaceService.parseParams(response), fit4Pro.with(fileType: 1, sort: 1))
        XCTAssertNil(WatchFaceService.parseParams(HuaweiTLV().with(0x01, Array("2.1".utf8))))
        XCTAssertNil(WatchFaceService.parseParams(HuaweiTLV().with(0x02, [0]).with(0x03, [0])))
    }

    func testInstalledList() {
        let first = HuaweiTLV().with(0x03, Array("123456789".utf8)).with(0x04, Array("1.0.0".utf8)).with(0x05, [0x01])
        let second = HuaweiTLV().with(0x03, Array("factory".utf8)).with(0x04, Array("2.0".utf8)).with(0x05, [0x02])
        let list = HuaweiTLV().with(0x82, first.serialize()).with(0x82, second.serialize())
        let faces = WatchFaceService.parseList(HuaweiTLV().with(0x81, list.serialize()))
        XCTAssertEqual(faces.map { $0.name }, ["123456789", "factory"])
        XCTAssertTrue(faces[0].isCurrent)
        XCTAssertFalse(faces[0].isFactory)
        XCTAssertTrue(faces[1].isFactory)
        XCTAssertFalse(faces[1].isCurrent)
        XCTAssertEqual(WatchFaceService.parseList(HuaweiTLV()), [])
        XCTAssertEqual(WatchFaceService.parseList(HuaweiTLV().with(0x81, [0x82, 0x05])), [])   // malformed inner TLV
        XCTAssertEqual(items(WatchFaceService.listRequest()), ["01=", "06=03"])
    }

    func testConfirmFromWatch() {
        let report = WatchFaceService.parseConfirm(HuaweiTLV().with(0x01, Array("123456789".utf8)).with(0x02, Array("1.0.0".utf8)).with(0x03, [0x02]))
        XCTAssertEqual(report, WatchFaceService.ConfirmReport(name: "123456789", version: "1.0.0", reportType: 2))
        XCTAssertEqual(report?.fileName, "123456789_1.0.0")
        XCTAssertEqual(WatchFaceService.parseConfirm(HuaweiTLV().with(0x01, Array("1".utf8)))?.reportType, 0)
        XCTAssertNil(WatchFaceService.parseConfirm(HuaweiTLV().with(0x02, Array("1.0.0".utf8))))
    }

    func testConfirmReplyAndOperation() {
        XCTAssertEqual(items(WatchFaceService.confirmReply(fileName: "123456789_1.0.0")),
                       ["01=" + Array("123456789".utf8).hexCompact, "02=" + Array("1.0.0".utf8).hexCompact, "7F=000186A0"])
        XCTAssertEqual(items(WatchFaceService.operation(fileName: "123456789_1.0.0", WatchFaceService.activate)),
                       ["01=" + Array("123456789".utf8).hexCompact, "02=" + Array("1.0.0".utf8).hexCompact, "03=01"])
        XCTAssertTrue(WatchFaceService.split("noversion") == ("noversion", ""))
        XCTAssertTrue(WatchFaceService.split("a_b_c") == ("a", "b_c"))
    }

    // MARK: - Install stages

    func testOnlyListedFacesCountAsInstalled() {
        for stage in [WatchFaceInstallStage.validating, .transferring(1), .transferred, .confirmedByWatch, .failed("x")] {
            XCTAssertFalse(stage.label.hasPrefix("Installed"), "\(stage)")
        }
        XCTAssertTrue(WatchFaceInstallStage.installed.label.hasPrefix("Installed"))
        XCTAssertTrue(WatchFaceInstallStage.active.label.hasPrefix("Installed and active"))
        XCTAssertEqual(WatchFaceInstallStage.idle.label, "")
    }
}

private extension WatchFaceService.DeviceParams {
    func with(fileType: Int, sort: Int) -> Self {
        var copy = self
        copy.fileType = fileType
        copy.sort = sort
        return copy
    }
}
