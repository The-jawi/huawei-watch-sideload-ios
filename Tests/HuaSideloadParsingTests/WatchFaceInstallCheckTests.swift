import XCTest
@testable import HuaSideloadParsing

// After a watch face upload: deciding whether the watch lists the face, and the post-upload trace lines
final class WatchFaceInstallCheckTests: XCTestCase {
    override func setUp() {
        UserDefaults.standard.set("en", forKey: AppLanguage.storageKey)
    }

    private func face(_ name: String, current: Bool = false) -> WatchFaceService.Installed {
        WatchFaceService.Installed(name: name, version: "1.0.0", type: current ? 1 : 0)
    }

    private let builtIn = [WatchFaceService.Installed(name: "Classic", version: "1.0.0", type: 3)]

    func testListedUnderTheUploadName() {
        let after = builtIn + [face("123456789")]
        XCTAssertEqual(WatchFaceInstallCheck.evaluate(uploadName: "123456789", before: builtIn, after: after, confirm: nil),
                       .listed(face("123456789"), .uploadName))
    }

    func testListedUnderTheConfirmedName() {
        let confirm = WatchFaceService.ConfirmReport(name: "987654321", version: "1.0.0", reportType: 2)
        let after = builtIn + [face("987654321", current: true)]
        XCTAssertEqual(WatchFaceInstallCheck.evaluate(uploadName: "123456789", before: nil, after: after, confirm: confirm),
                       .listed(face("987654321", current: true), .confirmedName))
    }

    // The watch may rename the face (e.g. to an id from the package): the one new entry is the uploaded face
    func testOneNewEntryUnderAnotherName() {
        let after = builtIn + [face("Night Sky")]
        XCTAssertEqual(WatchFaceInstallCheck.evaluate(uploadName: "123456789", before: builtIn, after: after, confirm: nil),
                       .listed(face("Night Sky"), .newEntry))
    }

    // Without the list from before the upload, or with several new faces, nothing is guessed
    func testNoGuessWithoutABaselineOrWithSeveralNewFaces() {
        let after = builtIn + [face("A"), face("B")]
        XCTAssertEqual(WatchFaceInstallCheck.evaluate(uploadName: "123456789", before: nil, after: after, confirm: nil), .notFound)
        XCTAssertEqual(WatchFaceInstallCheck.evaluate(uploadName: "123456789", before: builtIn, after: after, confirm: nil), .notFound)
    }

    func testUnchangedListIsNotAnInstall() {
        XCTAssertEqual(WatchFaceInstallCheck.evaluate(uploadName: "123456789", before: builtIn, after: builtIn, confirm: nil), .notFound)
        XCTAssertEqual(WatchFaceInstallCheck.evaluate(uploadName: "123456789", before: builtIn, after: [], confirm: nil), .notFound)
    }

    func testConfirmedButNotListed() {
        let confirm = WatchFaceService.ConfirmReport(name: "123456789", version: "1.0.0", reportType: 1)
        XCTAssertEqual(WatchFaceInstallCheck.evaluate(uploadName: "123456789", before: builtIn, after: builtIn, confirm: confirm),
                       .confirmedOnly(confirm))
    }

    func testListDescription() {
        XCTAssertEqual(WatchFaceInstallCheck.describe(nil), "not available")
        XCTAssertEqual(WatchFaceInstallCheck.describe([]), "empty")
        XCTAssertEqual(WatchFaceInstallCheck.describe(builtIn + [face("123456789")]), "2: Classic*, 123456789")
    }

    // MARK: - Trace

    func testTraceShowsTagLengthsAndOnlyResultCodes() {
        let secret: [UInt8] = Array(repeating: 0xAB, count: 16)
        let tlv = HuaweiTLV().with(0x01, [0x07]).with(0x7D, secret).with(0x7F, [0x00, 0x01, 0x86, 0xA0])
        let line = UploadTrace.line("in", service: 0x27, command: 0x05, tlv: tlv, bodySize: 0)
        XCTAssertEqual(line, "Trace in: 0x27/0x05 [01:1 7D:16 7F:4=100000]")
        XCTAssertFalse(line.contains("AB"))
        XCTAssertFalse(line.contains("171"))   // 0xAB as a number
    }

    func testTraceShowsTheUploadResultStatus() {
        let tlv = HuaweiTLV().with(0x01, [0x03]).with(0x02, [0x01])
        XCTAssertEqual(UploadTrace.line("in", service: 0x28, command: 0x07, tlv: tlv, bodySize: 0), "Trace in: 0x28/0x07 [01:1 02:1=1]")
        // The same tag elsewhere stays a length
        XCTAssertEqual(UploadTrace.line("in", service: 0x27, command: 0x07, tlv: tlv, bodySize: 0), "Trace in: 0x27/0x07 [01:1 02:1]")
    }

    func testTraceOfNonTLVAndEmptyPackets() {
        XCTAssertEqual(UploadTrace.line("in", service: 0x28, command: 0x06, tlv: nil, bodySize: 12), "Trace in: 0x28/0x06 [12 B, not TLV]")
        XCTAssertEqual(UploadTrace.line("out", service: 0x27, command: 0x02, tlv: HuaweiTLV(), bodySize: 0), "Trace out: 0x27/0x02 [-]")
    }
}
