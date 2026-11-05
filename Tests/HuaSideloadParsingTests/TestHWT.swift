import Foundation
@testable import HuaSideloadParsing

// Builds .hwt packages laid out like the real ones (see HWTAnalyzer): stored zip entries with real CRC-32s,
// description.xml, com.huawei.watchface (watchface.bin + info + config + res/), ability.xml, hashCode, preview.
enum TestHWT {
    // The two real packages in the repository (WatchFaces/, made for HWHD09 = 466*466)
    static func sample(_ name: String) throws -> Data {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: root.appendingPathComponent("WatchFaces").appendingPathComponent(name))
    }

    private static func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
    private static func le32(_ v: Int) -> [UInt8] { le16(v & 0xFFFF) + le16(v >> 16 & 0xFFFF) }

    static func zip(_ files: [(String, [UInt8])], badCRC: Set<String> = []) -> [UInt8] {
        var out: [UInt8] = []
        var central: [UInt8] = []
        for (name, data) in files {
            let offset = out.count
            let n = Array(name.utf8)
            let crc = Int(HWTAnalyzer.crc32(data) ^ (badCRC.contains(name) ? 1 : 0))
            out += le32(0x0403_4B50) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0) + le32(crc)
                + le32(data.count) + le32(data.count) + le16(n.count) + le16(0) + n + data
            central += le32(0x0201_4B50) + le16(20) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0) + le32(crc)
                + le32(data.count) + le32(data.count) + le16(n.count) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0)
                + le32(offset) + n
        }
        let centralOffset = out.count
        out += central
        out += le32(0x0605_4B50) + le16(0) + le16(0) + le16(files.count) + le16(files.count) + le32(central.count) + le32(centralOffset) + le16(0)
        return out
    }

    static func png(_ width: Int, _ height: Int) -> [UInt8] {
        func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        bytes += be32(13)
        bytes += Array("IHDR".utf8)
        bytes += be32(width)
        bytes += be32(height)
        bytes += [8, 6, 0, 0, 0, 0, 0, 0, 0]
        return bytes
    }

    // JPEG start with an SOF0 marker giving its size
    static func jpeg(_ width: Int, _ height: Int) -> [UInt8] {
        let h: [UInt8] = [UInt8(height >> 8), UInt8(height & 0xFF)]
        let w: [UInt8] = [UInt8(width >> 8), UInt8(width & 0xFF)]
        var bytes: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00, 0xFF, 0xC0, 0x00, 0x0B, 0x08]
        bytes += h
        bytes += w
        bytes += [0x01, 0x01, 0x11, 0x00, 0xFF, 0xD9]
        return bytes
    }

    struct Options {
        var root = "HwTheme"
        var title = "Test Face"
        var screen: String? = "HWHD13"
        var infoScreen: String?                      // defaults to screen
        var faceName = "com.huawei.watchface"
        var resources: [String: [UInt8]] = ["bg.png": TestHWT.png(408, 480), "hand.png": TestHWT.png(20, 200)]
        var references = ["bg.png", "hand.png"]
        var bin: [UInt8]? = [0x02, 0x00, 0x3C, 0x03]
        var description: [UInt8]?                    // replaces the generated description.xml
        var hashCode: HashCode = .correct
        var preview: [UInt8]? = TestHWT.jpeg(480, 480)
        var badCRC: Set<String> = []

        enum HashCode { case correct, none, wrongDescription }
    }

    static func package(_ o: Options = Options()) -> Data {
        func meta(_ screen: String?) -> [UInt8] {
            var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<\(o.root)>\n<title>\(o.title)</title>\n"
            if let screen { xml += "<screen>\(screen)</screen>\n" }
            xml += "<version>1.0.0</version>\n</\(o.root)>"
            return Array(xml.utf8)
        }
        let config = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<watchface>\n<element label=\"background\">\n"
            + o.references.map { "<layer index=\"1\" draw_type=\"single_res\" res_name=\"\($0)\" res_position=\"0,0\"/>\n" }.joined()
            + "</element>\n</watchface>"
        var inner: [(String, [UInt8])] = []
        if let bin = o.bin { inner.append(("watchface.bin", bin)) }
        inner.append(("watchface/watch_face_info.xml", meta(o.infoScreen ?? o.screen)))
        inner.append(("watchface/watch_face_config.xml", Array(config.utf8)))
        inner += o.resources.sorted { $0.key < $1.key }.map { ("watchface/res/" + $0.key, $0.value) }
        let face = zip(inner)
        let description = o.description ?? meta(o.screen)
        let ability = Array("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<attribute><dataType>0</dataType></attribute>".utf8)

        var files: [(String, [UInt8])] = [("description.xml", description), (o.faceName, face), ("ability.xml", ability)]
        switch o.hashCode {
        case .none: break
        case .correct, .wrongDescription:
            let first = o.hashCode == .correct ? HWTAnalyzer.sha256(description) : String(repeating: "0", count: 64)
            let list = [first, HWTAnalyzer.sha256(face), HWTAnalyzer.sha256(ability), String(repeating: "A", count: 64)]
            files.append(("hashCode", Array(list.joined(separator: ",").utf8)))
        }
        if let preview = o.preview { files.append(("preview/cover.jpg", preview)) }
        return Data(zip(files, badCRC: o.badCRC))
    }
}
