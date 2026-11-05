import XCTest
@testable import HuaSideloadParsing

// The setup messages after HiChain, byte for byte as Gadgetbridge builds them (DeviceConfig / AccountRelated)
final class PairingSetupTests: XCTestCase {
    private func items(_ tlv: HuaweiTLV) -> [String] {
        tlv.items.map { String(format: "%02X=", $0.tag) + $0.value.hexCompact }
    }

    private func hex(_ s: String) -> String { Array(s.utf8).hexCompact }

    // MARK: - DeviceConfig.TimeRequest

    func testTimeEastOfUTC() {
        let tlv = PairingSetup.time(Date(timeIntervalSince1970: 1_700_000_000), timeZone: TimeZone(secondsFromGMT: 3 * 3600)!)
        XCTAssertEqual(items(tlv), ["01=6553F100", "02=0300"])
    }

    func testTimeWestOfUTCWithHalfHour() {
        // Java: (byte)(3 + 128) and (byte)(-210 % 60) = (byte)-30
        let tlv = PairingSetup.time(Date(timeIntervalSince1970: 1_700_000_000), timeZone: TimeZone(secondsFromGMT: -(3 * 3600 + 1800))!)
        XCTAssertEqual(items(tlv), ["01=6553F100", "02=83E2"])
    }

    func testTimeUTC() {
        let tlv = PairingSetup.time(Date(timeIntervalSince1970: 0), timeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertEqual(items(tlv), ["01=00000000", "02=0000"])
    }

    // MARK: - AccountRelated.SendExtendedAccountToDevice

    func testAccountWithoutId() {
        XCTAssertEqual(items(PairingSetup.extendedAccount("", diffAccountPairing: false)), ["01=00"])
    }

    func testAccountWithIdAndDiffAccountPairing() {
        let tlv = PairingSetup.extendedAccount("12345678901234567", diffAccountPairing: true)
        XCTAssertEqual(items(tlv), ["01=" + hex("12345678901234567"), "03=01"])
    }

    // MARK: - DeviceConfig.AcceptAgreement

    func testAgreements() throws {
        let tlv = PairingSetup.acceptAgreements(Date(timeIntervalSince1970: 1_700_000_000.5))
        XCTAssertEqual(tlv.items.count, 1)
        XCTAssertEqual(tlv.items[0].tag, 0x81)
        let list = try HuaweiTLV.parse(tlv.items[0].value)
        XCTAssertEqual(list.items.map { $0.tag }, [0x82, 0x82, 0x82])
        let names = try list.items.map { try HuaweiTLV.parse($0.value) }
        XCTAssertEqual(names.map { String(decoding: $0.value(0x03) ?? [], as: UTF8.self) },
                       ["software_update_service_statement", "device_information_management", "user_license_agreement"])
        for item in names {
            XCTAssertEqual(item.value(0x04), [0x01])
            XCTAssertEqual(item.value(0x05).map { String(decoding: $0, as: UTF8.self) }, "20230508-20230508-0-0")
            XCTAssertEqual(item.value(0x06).map { String(decoding: $0, as: UTF8.self) }, "1700000000500")
        }
    }

    // MARK: - DeviceConfig.SetUpDeviceStatusRequest

    func testSetUpDeviceStatus() {
        let tlv = PairingSetup.setUpDeviceStatus(watchName: "HUAWEI WATCH FIT 4 Pro")
        XCTAssertEqual(items(tlv), ["01=01", "02=" + hex("HUAWEI WATCH FIT 4 Pro"), "03=00"])
    }

    // MARK: - Which steps are sent (HuaweiState checks)

    private func capabilities(_ bits: [Int]) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 24)
        for bit in bits { bytes[bit / 8] |= 1 << (bit % 8) }
        return bytes
    }

    func testEverythingSupported() {
        let support = PairingSetup.Support(commands: [0x01: [0x30, 0x37, 0x3E], 0x1A: [0x05, 0x06]],
                                           expandCapabilities: capabilities([109, 0xAC]))
        XCTAssertTrue(support.sendsAccount)
        XCTAssertTrue(support.sendsAgreements)
        XCTAssertTrue(support.sendsSetUpStatus)
        XCTAssertTrue(support.diffAccountPairing)
    }

    func testCapabilityBitPositions() {
        let support = PairingSetup.Support(commands: [0x01: [0x37]], expandCapabilities: capabilities([109]))
        XCTAssertTrue(support.hasCapability(109))
        XCTAssertFalse(support.hasCapability(108))
        XCTAssertFalse(support.hasCapability(110))
        XCTAssertFalse(support.hasCapability(1000))     // beyond the reported bytes
        XCTAssertEqual(capabilities([109])[13], 0x20)
    }

    func testNothingReported() {
        let support = PairingSetup.Support()
        XCTAssertFalse(support.sendsAccount)
        XCTAssertFalse(support.sendsAgreements)
        XCTAssertFalse(support.sendsSetUpStatus)
        XCTAssertFalse(support.diffAccountPairing)
    }

    func testAccountNeedsBothCommands() {
        XCTAssertFalse(PairingSetup.Support(commands: [0x1A: [0x05]]).sendsAccount)
        XCTAssertFalse(PairingSetup.Support(commands: [0x1A: [0x06]]).sendsAccount)
    }

    func testCapabilitiesOnlyCountWhenTheWatchHasTheCommand() {
        let support = PairingSetup.Support(commands: [0x01: [0x30]], expandCapabilities: capabilities([109, 0xAC]))
        XCTAssertFalse(support.sendsSetUpStatus)
        XCTAssertFalse(support.diffAccountPairing)
    }

    func testCommandQueryAsksForEveryCheckedCommand() {
        let asked = Dictionary(uniqueKeysWithValues: PairingSetup.commandQuery.map { ($0.service, Set($0.commands)) })
        XCTAssertEqual(asked[0x01], [0x30, 0x37, 0x3E])
        XCTAssertEqual(asked[0x1A], [0x05, 0x06])
    }

    // MARK: - Account ID input

    func testAccountIdValidation() {
        XCTAssertEqual(PairingSetup.normalizedAccountId(" 12345678901234567\n"), "12345678901234567")
        XCTAssertNil(PairingSetup.normalizedAccountId(""))
        XCTAssertNil(PairingSetup.normalizedAccountId("12345"))
        XCTAssertNil(PairingSetup.normalizedAccountId("1234567890123456a"))
        XCTAssertNil(PairingSetup.normalizedAccountId("١٢٣٤٥٦٧٨٩٠"))      // non-ASCII digits
    }

    // MARK: - Pairing stages

    func testOnlyPairedIsFullyPaired() {
        let notYet: [PairingStage] = [.none, .channelReady, .negotiating, .pinProcessed, .hiChain, .authenticated,
                                      .finishingSetup, .setupIncomplete("x"), .failed("x"), .connectionLost]
        for stage in notYet {
            XCTAssertFalse(stage.isFullyPaired, "\(stage)")
            XCTAssertNotEqual(stage.label, PairingStage.paired.label, "\(stage)")
        }
        XCTAssertTrue(PairingStage.paired.isFullyPaired)
    }
}
