import XCTest
@testable import HuaSideloadParsing

// HiChain step replies as the watch sends them (tag 0x01 of 0x01/0x28), with made-up values
final class HiChainJSONTests: XCTestCase {
    private let secret = "A1B2C3D4E5F60718293A4B5C6D7E8F90"
    private var stepOne: String {
        #"{"authForm":0,"payload":{"version":{"minVersion":"1.0.0","currentVersion":"2.0.16"},"isoSalt":"\#(secret)","peerAuthId":"3132","peerUserType":0,"token":"\#(secret)"},"groupAndModuleVersion":"2.0.1","message":1}"#
    }

    private func decode(_ bytes: [UInt8]) throws -> HiChainJSON.Envelope {
        try HiChainJSON.decodeEnvelope(bytes)
    }

    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    func testStrictReplyIsUnchanged() throws {
        let e = try decode(bytes(stepOne))
        XCTAssertEqual(e.payload["isoSalt"] as? String, secret)
        XCTAssertEqual(e.payload["peerUserType"] as? Int, 0)
        XCTAssertFalse(e.report.adjusted)
        XCTAssertEqual(e.report.payloadKeys, ["isoSalt", "peerAuthId", "peerUserType", "token", "version"])
    }

    func testTrailingNULTerminator() throws {
        let e = try decode(bytes(stepOne) + [0x00])
        XCTAssertEqual(e.payload["token"] as? String, secret)
        XCTAssertEqual(e.report.trailingDropped, 1)
        XCTAssertEqual(e.report.trailingNULs, 1)
        XCTAssertTrue(e.report.adjusted)
    }

    func testPaddingAroundObject() throws {
        let e = try decode([0x00, 0x20, 0x0A] + bytes(stepOne) + [0x0D, 0x0A, 0x00, 0x00, 0x00])
        XCTAssertEqual(e.payload["isoSalt"] as? String, secret)
        XCTAssertEqual(e.report.leadingSkipped, 3)
        XCTAssertEqual(e.report.trailingDropped, 5)
        XCTAssertEqual(e.report.trailingNULs, 3)
    }

    func testBytesAfterTheObjectAreIgnoredLikeOrgJson() throws {
        let e = try decode(bytes(stepOne + #"{"second":1}garbage"#) + [0xFF])
        XCTAssertEqual(e.payload["isoSalt"] as? String, secret)
        XCTAssertEqual(e.report.topLevelKeys, ["authForm", "groupAndModuleVersion", "message", "payload"])
    }

    func testUTF8BOM() throws {
        let e = try decode([0xEF, 0xBB, 0xBF] + bytes(stepOne))
        XCTAssertEqual(e.payload["isoSalt"] as? String, secret)
    }

    func testBracesAndQuotesInsideStrings() throws {
        let json = #"{"payload":{"a":"x}y{z]","b":"quote \" and } brace","c":"back\\slash"}}"#
        let e = try decode(bytes(json) + [0x00])
        XCTAssertEqual(e.payload["a"] as? String, "x}y{z]")
        XCTAssertEqual(e.payload["b"] as? String, "quote \" and } brace")
        XCTAssertEqual(e.payload["c"] as? String, "back\\slash")
        XCTAssertEqual(e.report.trailingDropped, 1)
    }

    func testRawControlCharactersInsideStrings() throws {
        let e = try decode(bytes(#"{"payload":{"a":"line1"#) + [0x0A, 0x09] + bytes(#"line2"}}"#))
        XCTAssertEqual(e.payload["a"] as? String, "line1\n\tline2")
        XCTAssertEqual(e.report.escapedControls, 2)
    }

    func testInvalidUTF8IsReplacedLikeJava() throws {
        let e = try decode(bytes(#"{"payload":{"name":"a"#) + [0xC3, 0x28] + bytes(#"b","isoSalt":"00"}}"#))
        XCTAssertEqual(e.payload["isoSalt"] as? String, "00")
        XCTAssertTrue(e.report.invalidUTF8)
    }

    func testLooseSyntax() throws {
        // Unquoted keys and single quotes: org.json takes them, strict JSON does not (trailing commas are not a
        // good probe, newer Foundation accepts them in strict mode)
        let e = try decode(bytes(#"{payload:{isoSalt:'00'},message:1}"#))
        XCTAssertEqual(e.payload["isoSalt"] as? String, "00")
        XCTAssertTrue(e.report.lenientSyntax)
    }

    func testErrorCodeIsReadable() throws {
        let e = try decode(bytes(#"{"payload":{"errorCode":4}}"#))
        XCTAssertEqual(e.payload["errorCode"] as? Int, 4)
    }

    // MARK: - Malformed replies

    func testEmptyReply() {
        assertError(try decode([]), "no JSON")
        assertError(try decode([0x00, 0x00, 0x20]), "no JSON")
    }

    func testNotAnObject() {
        assertError(try decode(bytes(#"["payload"]"#)), "not a JSON object (starts with an array")
        assertError(try decode(bytes("hello")), "not a JSON object")
        assertError(try decode([0x83, 0x01, 0x02]), "not a JSON object (starts with byte class 0x80")
    }

    func testCutOffObject() {
        assertError(try decode(Array(bytes(stepOne).dropLast(5))), "cut off")
        assertError(try decode(bytes(#"{"payload":{"a":"unterminated}}"#)), "cut off")
    }

    func testInvalidJSONInsideObject() {
        assertError(try decode(bytes(#"{"payload":{"a":@@@}}"#)), "invalid JSON")
    }

    func testPayloadMissingOrWrongType() {
        assertError(try decode(bytes(#"{"message":1}"#)), "\"payload\" is missing")
        assertError(try decode(bytes(#"{"payload":"{\"isoSalt\":\"00\"}"}"#)), "\"payload\" is a string")
        assertError(try decode(bytes(#"{"payload":[1,2]}"#)), "\"payload\" is an array")
        assertError(try decode(bytes(#"{"payload":null}"#)), "\"payload\" is null")
    }

    // MARK: - Privacy: reports and errors carry sizes and key names, never values

    func testSummaryHasNoValues() throws {
        let e = try decode(bytes(stepOne) + [0x00])
        XCTAssertFalse(e.report.summary.contains(secret))
        XCTAssertTrue(e.report.summary.contains("dropped 1 trailing B (1 NUL)"))
    }

    func testErrorsHaveNoValues() {
        let inputs = [
            bytes(#"{"payload":{"isoSalt":"\#(secret)",@}}"#),
            bytes(#"{"payload":"\#(secret)"}"#),
            bytes(#"{"payload":{"isoSalt":"\#(secret)"#),
            bytes(secret),
        ]
        for input in inputs {
            do {
                _ = try decode(input)
                XCTFail("expected an error")
            } catch {
                XCTAssertFalse(String(describing: error).contains(secret), String(describing: error))
                XCTAssertFalse(String(describing: error).contains("@"), String(describing: error))
            }
        }
    }

    private func assertError(_ expression: @autoclosure () throws -> HiChainJSON.Envelope, _ text: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        do {
            _ = try expression()
            XCTFail("expected an error containing \(text)", file: file, line: line)
        } catch {
            XCTAssertTrue(String(describing: error).contains(text), "\(error)", file: file, line: line)
        }
    }
}
