import XCTest
@testable import HuaSideloadParsing

// The experimental pre-install message (WatchFaceProbe, operation 5): what it sends, and how it reads the answer
final class WatchFaceProbeTests: XCTestCase {
    override func setUp() {
        UserDefaults.standard.set("en", forKey: AppLanguage.storageKey)
    }

    private let ability = Array("<attribute/>".utf8)
    private let hashBytes = Array("AA,BB,CC,DD".utf8)

    private func message(_ layout: WatchFaceProbe.Layout, ability: [UInt8]? = nil, hashCode: [UInt8]? = nil) -> HuaweiTLV {
        WatchFaceProbe.message(fileName: "2912345678_1.0.0", ability: ability ?? self.ability, hashCode: hashCode ?? hashBytes, layout: layout)
    }

    // Every layout names only the new face and uses operation 5, never activate (1) or delete (2)
    func testEveryLayoutIsOperation5ForTheNewFace() {
        for layout in WatchFaceProbe.Layout.allCases {
            let tlv = message(layout)
            XCTAssertEqual(tlv.value(0x01), Array("2912345678".utf8), layout.rawValue)
            XCTAssertEqual(tlv.value(0x02), Array("1.0.0".utf8), layout.rawValue)
            XCTAssertEqual(tlv.value(0x03), [5], layout.rawValue)
            XCTAssertFalse(WatchFaceProbe.forbiddenOperations.contains(WatchFaceProbe.operation))
        }
    }

    func testLayouts() {
        XCTAssertEqual(message(.abilityHash).value(0x04), ability)
        XCTAssertEqual(message(.abilityHash).value(0x05), hashBytes)
        XCTAssertEqual(message(.hashAbility).value(0x04), hashBytes)
        XCTAssertEqual(message(.hashAbility).value(0x05), ability)
        XCTAssertEqual(message(.abilityHashHigh).value(0x06), ability)
        XCTAssertEqual(message(.abilityHashHigh).value(0x07), hashBytes)
        XCTAssertEqual(message(.bare).items.map(\.tag), [0x01, 0x02, 0x03])
    }

    // A package without ability.xml or hashCode: those tags are left out
    func testMissingFilesAreLeftOut() {
        let tlv = WatchFaceProbe.message(fileName: "2912345678_1.0.0", ability: nil, hashCode: nil, layout: .abilityHash)
        XCTAssertEqual(tlv.items.map(\.tag), [0x01, 0x02, 0x03])
    }

    // The watch's answer seen on a Watch Fit 4 Pro: name, version, 04 = 1, 7F = 0
    func testAccepted() {
        let name = "2944597081"
        let seen = HuaweiTLV().with(0x01, Array(name.utf8)).with(0x02, Array("1.0.0".utf8)).with(0x04, [1]).with(0x7F, [0, 0, 0, 0])
        XCTAssertTrue(WatchFaceProbe.accepted(seen, name: name))
        XCTAssertTrue(WatchFaceProbe.accepted(HuaweiTLV().with(0x01, Array(name.utf8)).with(0x7F, [0x00, 0x01, 0x86, 0xA0]), name: name))
        XCTAssertFalse(WatchFaceProbe.accepted(HuaweiTLV().with(0x7F, [0x00, 0x01, 0x86, 0xA7]), name: name))   // 100007
        XCTAssertFalse(WatchFaceProbe.accepted(HuaweiTLV().with(0x01, Array("1111111111".utf8)), name: name))
        XCTAssertFalse(WatchFaceProbe.accepted(nil, name: name))
    }

    func testDescribe() {
        let reply = HuaweiTLV().with(0x01, Array("2912345678".utf8)).with(0x7F, [0x00, 0x01, 0x86, 0xA3])
            .with(0x04).with(0x09, Array(repeating: 0x01, count: 20))
        XCTAssertEqual(WatchFaceProbe.describe(reply), "01:\"2912345678\" 7F:000186A3=100003 04:- 09:20B")
        XCTAssertEqual(WatchFaceProbe.describe(nil), "no TLV")
        XCTAssertEqual(WatchFaceProbe.describe(HuaweiTLV()), "empty")
    }

    func testStoredLayout() {
        UserDefaults.standard.removeObject(forKey: WatchFaceProbe.layoutKey)
        XCTAssertEqual(WatchFaceProbe.currentLayout, .abilityHash)
        UserDefaults.standard.set("bare", forKey: WatchFaceProbe.layoutKey)
        XCTAssertEqual(WatchFaceProbe.currentLayout, .bare)
        UserDefaults.standard.removeObject(forKey: WatchFaceProbe.layoutKey)
        XCTAssertEqual(WatchFaceProbe.Layout.allCases.map(\.shortLabel), ["1", "2", "3", "4"])
    }

    func testTenDigitUploadNames() {
        XCTAssertEqual(WatchFaceUploadMethod.bin.uploadName(number: 2_912_345_678, faceVersion: "2.0.1", digits: 10), "2912345678_1.0.0")
        XCTAssertEqual(WatchFaceUploadMethod.bin.uploadName(number: 42, faceVersion: "2.0.1", digits: 10), "0000000042_1.0.0")
        XCTAssertEqual(WatchFaceUploadMethod.bin.uploadName(number: 42, faceVersion: "2.0.1"), "000000042_1.0.0")
    }

    func testPackageExposesAbilityAndHashCode() throws {
        let face = try WatchFacePackage(hwt: TestHWT.package())
        XCTAssertEqual(face.ability.map { String(decoding: $0, as: UTF8.self).contains("<attribute>") }, true)
        XCTAssertEqual(face.hashCode.map { String(decoding: $0, as: UTF8.self).split(separator: ",").count }, 4)
    }

    // The bundled faces carry both files, so they can test the layouts
    func testBundledSampleHasAbilityAndHashCode() throws {
        let face = try WatchFacePackage(hwt: try TestHWT.sample("Donen.hwt"))
        XCTAssertEqual(face.ability?.count, 902)
        XCTAssertEqual(face.hashCode?.count, 259)
    }
}
