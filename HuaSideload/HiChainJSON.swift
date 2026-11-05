import Foundation

// The JSON envelope of a HiChain reply (0x01/0x28, tag 0x01): {"payload": {...}, "message": ..., ...}.
// Gadgetbridge reads it with new String(bytes, UTF_8) and Android's org.json, which replaces invalid UTF-8,
// stops after the first complete object and accepts loose syntax. JSONSerialization is strict, so a reply that
// Gadgetbridge pairs with could fail here ("HiChain JSON could not be decoded" on a Watch Fit 4 Pro). This
// accepts the same replies: NUL/whitespace around the object (C strings from the watch end in 0x00), bytes
// after the top-level object, raw control characters inside strings, invalid UTF-8 and loose syntax (JSON5).
// Nothing is trusted because of this: every value is still checked by the HiChain steps (HMACs, AES-GCM).
// Reports only sizes, counts and key names, never values (they carry salts, tokens and IDs).
enum HiChainJSON {
    struct Report {
        var length = 0
        var leadingSkipped = 0
        var trailingDropped = 0
        var trailingNULs = 0
        var escapedControls = 0
        var invalidUTF8 = false
        var lenientSyntax = false
        var topLevelKeys: [String] = []
        var payloadKeys: [String] = []

        // True when the reply was not strict JSON as it came
        var adjusted: Bool {
            leadingSkipped > 0 || trailingDropped > 0 || escapedControls > 0 || invalidUTF8 || lenientSyntax
        }

        var summary: String {
            var parts = ["\(length) B"]
            if leadingSkipped > 0 { parts.append("skipped \(leadingSkipped) leading B") }
            if trailingDropped > 0 { parts.append("dropped \(trailingDropped) trailing B (\(trailingNULs) NUL)") }
            if escapedControls > 0 { parts.append("escaped \(escapedControls) control chars") }
            if invalidUTF8 { parts.append("invalid UTF-8 replaced") }
            parts.append(lenientSyntax ? "lenient JSON" : "strict JSON")
            if !topLevelKeys.isEmpty { parts.append("keys [\(topLevelKeys.joined(separator: ","))]") }
            if !payloadKeys.isEmpty { parts.append("payload keys [\(payloadKeys.joined(separator: ","))]") }
            return parts.joined(separator: ", ")
        }
    }

    enum DecodeError: Error, CustomStringConvertible {
        case empty(Report)
        case notAnObject(Report, firstByte: String)
        case unterminated(Report)
        case invalidJSON(Report, position: String)
        case noPayload(Report, found: String)

        var description: String {
            switch self {
            case .empty(let r): return "no JSON in the reply (\(r.summary))"
            case .notAnObject(let r, let first): return "the reply is not a JSON object (starts with \(first); \(r.summary))"
            case .unterminated(let r): return "the JSON object is cut off (\(r.summary))"
            case .invalidJSON(let r, let position): return "invalid JSON\(position) (\(r.summary))"
            case .noPayload(let r, let found): return "\"payload\" is \(found), not an object (\(r.summary))"
            }
        }
    }

    struct Envelope {
        let value: [String: Any]
        let payload: [String: Any]
        let report: Report
    }

    static func decodeEnvelope(_ raw: [UInt8]) throws -> Envelope {
        var report = Report()
        report.length = raw.count
        var object = try extractObject(raw, &report)

        if String(bytes: object, encoding: .utf8) == nil {
            report.invalidUTF8 = true
            object = Array(String(decoding: object, as: UTF8.self).utf8)
        }

        let parsed: Any
        if let strict = try? JSONSerialization.jsonObject(with: Data(object)) {
            parsed = strict
        } else {
            report.lenientSyntax = true
            do {
                parsed = try JSONSerialization.jsonObject(with: Data(object), options: .json5Allowed)
            } catch {
                throw DecodeError.invalidJSON(report, position: position(of: error))
            }
        }

        guard let value = parsed as? [String: Any] else {
            throw DecodeError.notAnObject(report, firstByte: "a non-object value")
        }
        report.topLevelKeys = value.keys.sorted()
        guard let payload = value["payload"] as? [String: Any] else {
            throw DecodeError.noPayload(report, found: typeName(value["payload"]))
        }
        report.payloadKeys = payload.keys.sorted()
        return Envelope(value: value, payload: payload, report: report)
    }

    // The first complete top-level object, like org.json's JSONObject(String); raw control characters inside
    // strings become \u00XX escapes. Works on bytes: every structural character is ASCII, UTF-8 sequences are >= 0x80.
    private static func extractObject(_ raw: [UInt8], _ report: inout Report) throws -> [UInt8] {
        var start = 0
        if raw.count >= 3, raw[0] == 0xEF, raw[1] == 0xBB, raw[2] == 0xBF { start = 3 }   // UTF-8 BOM
        while start < raw.count, isFiller(raw[start]) { start += 1 }
        report.leadingSkipped = start
        guard start < raw.count else { throw DecodeError.empty(report) }
        guard raw[start] == UInt8(ascii: "{") else {
            throw DecodeError.notAnObject(report, firstByte: byteClass(raw[start]))
        }

        var out: [UInt8] = []
        out.reserveCapacity(raw.count - start)
        var depth = 0
        var inString = false
        var escaped = false
        var end: Int?
        for i in start..<raw.count {
            let b = raw[i]
            if inString {
                if escaped {
                    escaped = false
                    out.append(b)
                } else if b == UInt8(ascii: "\\") {
                    escaped = true
                    out.append(b)
                } else if b == UInt8(ascii: "\"") {
                    inString = false
                    out.append(b)
                } else if b < 0x20 {
                    out += Array(String(format: "\\u%04X", Int(b)).utf8)
                    report.escapedControls += 1
                } else {
                    out.append(b)
                }
                continue
            }
            out.append(b)
            switch b {
            case UInt8(ascii: "\""): inString = true
            case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
            case UInt8(ascii: "}"), UInt8(ascii: "]"): depth -= 1
            default: break
            }
            if depth == 0 {
                end = i
                break
            }
        }
        guard let end else { throw DecodeError.unterminated(report) }
        let rest = raw[(end + 1)...]
        report.trailingDropped = rest.count
        report.trailingNULs = rest.filter { $0 == 0 }.count
        return out
    }

    private static func isFiller(_ b: UInt8) -> Bool {
        b == 0x00 || b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D
    }

    private static func byteClass(_ b: UInt8) -> String {
        switch b {
        case UInt8(ascii: "["): return "an array"
        case UInt8(ascii: "\""): return "a string"
        case 0x30...0x39, UInt8(ascii: "-"): return "a number"
        case 0x20...0x7E: return "a text character"
        default: return String(format: "byte class 0x%02X", b & 0xF0)
        }
    }

    // JSONSerialization's debug description quotes the offending character; keep only its position
    private static func position(of error: Error) -> String {
        let text = ((error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String) ?? ""
        guard let range = text.range(of: #"line \d+, column \d+"#, options: .regularExpression) else { return "" }
        return " around " + String(text[range])
    }

    private static func typeName(_ value: Any?) -> String {
        switch value {
        case nil: return "missing"
        case is String: return "a string"
        case is [Any]: return "an array"
        case is NSNull: return "null"
        case is NSNumber: return "a number"
        default: return "another type"
        }
    }
}
