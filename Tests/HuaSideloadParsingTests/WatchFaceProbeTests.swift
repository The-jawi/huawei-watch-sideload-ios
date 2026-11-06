import XCTest
@testable import HuaSideloadParsing

// The experimental pre-install probe (WatchFaceProbe): what it sends, and how it reads the watch's answers
final class WatchFaceProbeTests: XCTestCase {
    override func setUp() {
        UserDefaults.standard.set("en", forKey: AppLanguage.storageKey)
    }

    private let ability = Array("<attribute/>".utf8)
    private let hash = Array("AA,BB,CC,DD".utf8)

    func testEveryVariantNamesOnlyTheNewFace() {
        let variants = WatchFaceProbe.variants(fileName: "2912345678_1.0.0", ability: ability, hashCode: hash)
        XCTAssertEqual(variants.count, 6)
        for v in variants {
            XCTAssertEqual(v.tlv.value(0x01), Array("2912345678".utf8), v.label)
            XCTAssertEqual(v.tlv.value(0x02), Array("1.0.0".utf8), v.label)
        }
    }

    // Activate (1) and delete (2) are never sent
    func testNoActivateOrDelete() {
        for v in WatchFaceProbe.variants(fileName: "2912345678_1.0.0", ability: ability, hashCode: hash) {
            if let op = v.tlv.value(0x03), op.count == 1 {
                XCTAssertFalse(WatchFaceProbe.forbiddenOperations.contains(op[0]), v.label)
            }
        }
    }

    func testLayouts() {
        let v = WatchFaceProbe.variants(fileName: "2912345678_1.0.0", ability: ability, hashCode: hash)
        XCTAssertEqual(v[0].tlv.value(0x03), [3])
        XCTAssertEqual(v[0].tlv.value(0x04), ability)
        XCTAssertEqual(v[0].tlv.value(0x05), hash)
        XCTAssertEqual(v[4].tlv.value(0x04), hash)
        XCTAssertEqual(v[4].tlv.value(0x05), ability)
        XCTAssertEqual(v[5].tlv.value(0x03), ability)
        XCTAssertEqual(v[5].tlv.value(0x04), hash)
    }

    // A package without ability.xml or hashCode: those tags are left out, nothing else changes
    func testMissingFilesAreLeftOut() {
        let v = WatchFaceProbe.variants(fileName: "2912345678_1.0.0", ability: nil, hashCode: nil)
        XCTAssertEqual(v[0].tlv.items.map(\.tag), [0x01, 0x02, 0x03])
        XCTAssertEqual(v[5].tlv.items.map(\.tag), [0x01, 0x02])
    }

    func testAccepted() {
        XCTAssertTrue(WatchFaceProbe.accepted(HuaweiTLV().with(0x7F, [0x00, 0x01, 0x86, 0xA0])))
        XCTAssertFalse(WatchFaceProbe.accepted(HuaweiTLV().with(0x7F, [0x00, 0x01, 0x86, 0xA3])))
        XCTAssertTrue(WatchFaceProbe.accepted(HuaweiTLV().with(0x01, Array("2912345678".utf8))))
        XCTAssertFalse(WatchFaceProbe.accepted(HuaweiTLV()))
        XCTAssertFalse(WatchFaceProbe.accepted(nil))
    }

    func testDescribe() {
        let reply = HuaweiTLV().with(0x01, Array("2912345678".utf8)).with(0x7F, [0x00, 0x01, 0x86, 0xA3])
            .with(0x04).with(0x09, Array(repeating: 0x01, count: 20))
        XCTAssertEqual(WatchFaceProbe.describe(reply), "01:\"2912345678\" 7F:000186A3=100003 04:- 09:20B")
        XCTAssertEqual(WatchFaceProbe.describe(nil), "no TLV")
        XCTAssertEqual(WatchFaceProbe.describe(HuaweiTLV()), "empty")
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
}
