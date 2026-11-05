import CryptoKit
import Foundation

// Structural and compatibility check of a .hwt watch face, from what the file actually contains.
// Layout seen in Huawei Theme Studio packages (both bundled faces):
//   description.xml        <HwTheme> (Honor: <HnTheme>) with title, screen code, version
//   com.huawei.watchface   zip: watchface.bin, watchface/watch_face_info.xml, watchface/watch_face_config.xml,
//                          watchface/res/*.png (older packages: watchface.bin directly)
//   ability.xml            opaque bit masks (not interpreted)
//   hashCode               comma-separated SHA-256 (hex) of description.xml, com.huawei.watchface, ability.xml, and
//                          a fourth value that is identical in both samples (meaning unknown, not checked)
//   preview/*.jpg          previews
// A package names no device model, firmware or API level; the only compatibility data is the screen code, so a match
// can never prove the watch will accept the face.
struct HWTAnalysis: Codable, Equatable {
    enum Status: String, Codable {
        case compatible, incompatible, unknown, corrupted

        var label: String {
            switch self {
            case .compatible: return L("COMPATIBLE", "UYUMLU")
            case .incompatible: return L("INCOMPATIBLE", "UYUMSUZ")
            case .unknown: return L("UNKNOWN", "BİLİNMİYOR")
            case .corrupted: return L("CORRUPTED", "BOZUK")
            }
        }
    }

    var status: Status
    var reasons: [String]           // why this status, most important first
    var notes: [String] = []        // what was found (structure, images); informational
    var title = ""
    var screen = ""
    var version = ""

    var summary: String { reasons.first ?? "" }
}

// The watch a package is checked against
struct TargetProfile: Equatable {
    var name: String
    var width: Int
    var height: Int

    // Watch Fit 4 Pro: 408 wide, 480 tall (HWHD13, "height*width" = 480*408)
    static let fit4Pro = TargetProfile(name: "HUAWEI WATCH FIT 4 Pro", width: 408, height: 480)

    var resolution: String { "\(height)*\(width)" }
}

enum HWTAnalyzer {
    struct Result {
        var analysis: HWTAnalysis
        var preview: [UInt8]?       // preview/cover.jpg (or png) when it is a valid image
    }

    static let imageFormats = ["png", "jpg", "jpeg", "webp", "bmp", "gif"]

    // "watch" (what the connected watch reports, 0x27/0x01) wins over the profile's screen when present
    static func analyze(_ data: Data, target: TargetProfile = .fit4Pro, watch: WatchFaceService.DeviceParams? = nil) -> Result {
        var corrupt: [String] = []
        var conflicts: [String] = []
        var unknowns: [String] = []
        var notes: [String] = []
        var analysis = HWTAnalysis(status: .corrupted, reasons: [])
        func finish(preview: [UInt8]? = nil) -> Result {
            analysis.notes = notes
            if !corrupt.isEmpty {
                analysis.status = .corrupted
                analysis.reasons = corrupt
            } else if !conflicts.isEmpty {
                analysis.status = .incompatible
                analysis.reasons = conflicts + unknowns
            } else if !unknowns.isEmpty {
                analysis.status = .unknown
                analysis.reasons = unknowns
            } else {
                analysis.status = .compatible
                analysis.reasons = [L("The screen code matches \(target.name) and the package is intact. It names no device, firmware or API level, so this does not guarantee the watch accepts it.",
                                      "Ekran kodu \(target.name) ile eşleşiyor ve paket sağlam. Paket cihaz, yazılım ya da API seviyesi belirtmiyor; bu yüzden saatin kabul edeceği garanti değil.")]
            }
            return Result(analysis: analysis, preview: analysis.status == .corrupted ? nil : preview)
        }

        // Container
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else {
            corrupt.append(L("The file is empty", "Dosya boş"))
            return finish()
        }
        guard bytes.starts(with: [0x50, 0x4B, 0x03, 0x04]) else {
            corrupt.append(L("Not a ZIP container (starts with \(Array(bytes.prefix(4)).hex))", "ZIP kabı değil (\(Array(bytes.prefix(4)).hex) ile başlıyor)"))
            return finish()
        }
        guard let outer = try? ZipArchive(bytes) else {
            corrupt.append(L("The archive directory is unreadable or cut off", "Arşiv dizini okunamıyor ya da eksik"))
            return finish()
        }
        let files = outer.names.filter { !$0.hasSuffix("/") }
        notes.append(L("\(files.count) files, \(bytes.count / 1024) KB", "\(files.count) dosya, \(bytes.count / 1024) KB"))
        var contents: [String: [UInt8]] = [:]
        for name in files {
            switch read(outer, name) {
            case .success(let value): contents[name] = value
            case .failure(let why): corrupt.append(why.description)
            }
        }
        guard corrupt.isEmpty else { return finish() }

        // description.xml
        guard let description = contents["description.xml"] else {
            corrupt.append(L("description.xml is missing", "description.xml yok"))
            return finish()
        }
        guard let meta = XMLFields(description) else {
            corrupt.append(L("description.xml is not well-formed XML", "description.xml geçerli XML değil"))
            return finish()
        }
        guard meta.root == "HwTheme" || meta.root == "HnTheme" else {
            corrupt.append(L("description.xml has no HwTheme/HnTheme root (found \(meta.root))", "description.xml'de HwTheme/HnTheme kökü yok (\(meta.root) bulundu)"))
            return finish()
        }
        analysis.title = meta["title"] ?? ""
        analysis.screen = meta["screen"] ?? ""
        analysis.version = meta["version"] ?? ""
        if analysis.title.isEmpty { unknowns.append(L("description.xml has no title", "description.xml'de başlık yok")) }

        // The face itself
        let faceName = contents["com.huawei.watchface"] != nil ? "com.huawei.watchface" : "com.honor.watchface"
        guard let face = contents[faceName] else {
            corrupt.append(L("com.huawei.watchface (the face itself) is missing", "com.huawei.watchface (kadranın kendisi) yok"))
            return finish()
        }
        var inner: [String: [UInt8]] = [:]
        if face.starts(with: [0x50, 0x4B, 0x03, 0x04]) {
            guard let innerZip = try? ZipArchive(face) else {
                corrupt.append(L("\(faceName) is a damaged archive", "\(faceName) bozuk bir arşiv"))
                return finish()
            }
            for name in innerZip.names where !name.hasSuffix("/") {
                switch read(innerZip, name) {
                case .success(let value): inner[name] = value
                case .failure(let why): corrupt.append(faceName + ": " + why.description)
                }
            }
            guard corrupt.isEmpty else { return finish() }
            guard let bin = inner["watchface.bin"], !bin.isEmpty else {
                corrupt.append(L("watchface.bin is missing or empty", "watchface.bin yok ya da boş"))
                return finish()
            }
            notes.append(L("watchface.bin: \(bin.count / 1024) KB", "watchface.bin: \(bin.count / 1024) KB"))
        } else {
            guard !face.isEmpty else {
                corrupt.append(L("watchface.bin is empty", "watchface.bin boş"))
                return finish()
            }
            notes.append(L("Older layout: watchface.bin stored directly", "Eski düzen: watchface.bin doğrudan duruyor"))
        }

        // hashCode: the package's own SHA-256 list
        if let hashText = contents["hashCode"] {
            let listed = Set(String(decoding: hashText, as: UTF8.self).uppercased()
                .components(separatedBy: CharacterSet(charactersIn: ",\n\r ")).filter { !$0.isEmpty })
            for name in ["description.xml", faceName, "ability.xml"] {
                guard let value = contents[name] else { continue }
                if !listed.contains(sha256(value)) {
                    corrupt.append(L("hashCode does not match \(name): the package was changed or damaged", "hashCode \(name) ile uyuşmuyor: paket değiştirilmiş ya da bozulmuş"))
                }
            }
            guard corrupt.isEmpty else { return finish() }
            notes.append(L("hashCode matches the package files", "hashCode paket dosyalarıyla uyuşuyor"))
        } else {
            notes.append(L("No hashCode file; integrity checked with the ZIP checksums only", "hashCode dosyası yok; bütünlük yalnızca ZIP sağlamalarıyla denetlendi"))
        }

        // Inner metadata and the resources the face uses
        if let info = inner["watchface/watch_face_info.xml"] {
            guard let innerMeta = XMLFields(info) else {
                corrupt.append(L("watch_face_info.xml is not well-formed XML", "watch_face_info.xml geçerli XML değil"))
                return finish()
            }
            if let innerScreen = innerMeta["screen"], !innerScreen.isEmpty, innerScreen != analysis.screen {
                unknowns.append(L("The inner screen code (\(innerScreen)) differs from description.xml (\(analysis.screen))",
                                  "İç ekran kodu (\(innerScreen)) description.xml'dekinden (\(analysis.screen)) farklı"))
            }
        }
        if let config = inner["watchface/watch_face_config.xml"] {
            guard XMLFields(config) != nil else {
                corrupt.append(L("watch_face_config.xml is not well-formed XML", "watch_face_config.xml geçerli XML değil"))
                return finish()
            }
            let missing = referencedResources(config).filter { inner["watchface/res/" + $0] == nil }
            if !missing.isEmpty {
                corrupt.append(L("Resources used by the face are missing: ", "Kadranın kullandığı kaynaklar eksik: ") + missing.prefix(5).joined(separator: ", "))
                return finish()
            }
        }

        // Images: the bytes must be what the extension says
        var largest = (width: 0, height: 0)
        var otherFormats = Set<String>()
        let images = contents.filter { isImage($0.key) } .merging(inner.filter { isImage($0.key) }) { a, _ in a }
        for (name, value) in images {
            let ext = (name as NSString).pathExtension.lowercased()
            guard let format = imageFormat(value) else {
                corrupt.append(L("\(name) is not a valid image", "\(name) geçerli bir görsel değil"))
                continue
            }
            if format != (ext == "jpeg" ? "jpg" : ext) {
                corrupt.append(L("\(name) is a \(format.uppercased()) file with a .\(ext) name", "\(name) .\(ext) adlı bir \(format.uppercased()) dosyası"))
                continue
            }
            if format != "png" && format != "jpg" { otherFormats.insert(format.uppercased()) }
            if name.hasPrefix("watchface/res/"), let size = imageSize(value) {
                largest = (max(largest.width, size.width), max(largest.height, size.height))
            }
        }
        guard corrupt.isEmpty else { return finish() }
        if !otherFormats.isEmpty {
            unknowns.append(L("Uses \(otherFormats.sorted().joined(separator: ", ")) images; only PNG and JPEG were seen in working packages",
                              "\(otherFormats.sorted().joined(separator: ", ")) görselleri kullanıyor; çalışan paketlerde yalnızca PNG ve JPEG görüldü"))
        }
        if largest.width > 0 {
            notes.append(L("Largest face image: \(largest.width)×\(largest.height)", "En büyük kadran görseli: \(largest.width)×\(largest.height)"))
        }

        // Screen: the only compatibility data a package carries
        let targetResolution = watch?.resolution ?? target.resolution
        let targetName = watch == nil ? target.name : L("the connected watch", "bağlı saat")
        if analysis.screen.isEmpty {
            unknowns.append(L("description.xml has no screen code", "description.xml'de ekran kodu yok"))
        } else if let faceScreen = WatchFaceScreen.resolutions[analysis.screen] {
            if faceScreen != targetResolution {
                conflicts.append(L("Made for a \(faceScreen) screen (\(analysis.screen)); \(targetName) is \(targetResolution)",
                                   "\(faceScreen) ekran için yapılmış (\(analysis.screen)); \(targetName) \(targetResolution)"))
            } else {
                let bounds = targetResolution.split(separator: "*").compactMap { Int($0) }   // height*width
                if bounds.count == 2, largest.width > bounds[1] || largest.height > bounds[0] {
                    unknowns.append(L("Some face images (\(largest.width)×\(largest.height)) are larger than the screen",
                                      "Bazı kadran görselleri (\(largest.width)×\(largest.height)) ekrandan büyük"))
                }
            }
        } else {
            unknowns.append(L("Screen code \(analysis.screen) is not in the known list", "\(analysis.screen) ekran kodu bilinen listede yok"))
        }

        let preview = ["preview/cover.jpg", "preview/cover.png"].lazy.compactMap { contents[$0] }.first { imageFormat($0) != nil }
        return finish(preview: preview)
    }

    // MARK: - Pieces

    private static func read(_ zip: ZipArchive, _ name: String) -> Swift.Result<[UInt8], ReadError> {
        guard let info = zip.info(name) else { return .failure(ReadError(L("\(name) cannot be found", "\(name) bulunamıyor"))) }
        guard info.method == 0 || info.method == 8 else {
            return .failure(ReadError(L("\(name) uses an unsupported compression (method \(info.method))", "\(name) desteklenmeyen sıkıştırma kullanıyor (yöntem \(info.method))")))
        }
        guard let value = zip.file(name), value.count == info.size else {
            return .failure(ReadError(L("\(name) cannot be decompressed", "\(name) açılamıyor")))
        }
        guard crc32(value) == info.crc else {
            return .failure(ReadError(L("\(name) is damaged (checksum mismatch)", "\(name) bozuk (sağlama uyuşmuyor)")))
        }
        return .success(value)
    }

    private struct ReadError: Error, CustomStringConvertible {
        let description: String
        init(_ text: String) { description = text }
    }

    private static func isImage(_ name: String) -> Bool {
        imageFormats.contains((name as NSString).pathExtension.lowercased())
    }

    static func imageFormat(_ b: [UInt8]) -> String? {
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "png" }
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if b.count >= 12, b.starts(with: Array("RIFF".utf8)), Array(b[8..<12]) == Array("WEBP".utf8) { return "webp" }
        if b.starts(with: Array("GIF8".utf8)) { return "gif" }
        if b.starts(with: Array("BM".utf8)) { return "bmp" }
        return nil
    }

    // PNG: IHDR; JPEG: the first SOFn marker
    static func imageSize(_ b: [UInt8]) -> (width: Int, height: Int)? {
        func be(_ i: Int, _ n: Int) -> Int { (0..<n).reduce(0) { $0 << 8 | Int(b[i + $1]) } }
        if imageFormat(b) == "png", b.count >= 24 { return (be(16, 4), be(20, 4)) }
        guard imageFormat(b) == "jpg" else { return nil }
        var i = 2
        while i + 9 < b.count {
            guard b[i] == 0xFF else { return nil }
            let marker = b[i + 1]
            if (0xC0...0xCF).contains(marker), ![0xC4, 0xC8, 0xCC].contains(marker) { return (be(i + 7, 2), be(i + 5, 2)) }
            i += 2 + be(i + 2, 2)
        }
        return nil
    }

    // Image file names in the face configuration's attributes (res_name, res_left, …)
    static func referencedResources(_ xml: [UInt8]) -> [String] {
        let text = String(decoding: xml, as: UTF8.self)
        guard let regex = try? NSRegularExpression(pattern: #""([A-Za-z0-9_\-.]+\.(?:png|jpg|jpeg|webp|bmp|gif))""#, options: [.caseInsensitive]) else { return [] }
        let found = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
        return Array(Set(found)).sorted()
    }

    static func sha256(_ value: [UInt8]) -> String {
        SHA256.hash(data: value).map { String(format: "%02X", $0) }.joined()
    }

    static func crc32(_ value: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in value {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let crcTable: [UInt32] = (0..<256).map { n in
        (0..<8).reduce(UInt32(n)) { c, _ in c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    }
}

// Well-formedness check plus the root element and the text of its direct children (title, screen, …)
private struct XMLFields {
    private(set) var root = ""
    private var fields: [String: String] = [:]

    subscript(_ key: String) -> String? { fields[key] }

    init?(_ bytes: [UInt8]) {
        var data = bytes
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data.removeFirst(3) }
        let parser = XMLParser(data: Data(data))
        let collector = Collector()
        parser.delegate = collector
        guard parser.parse(), !collector.root.isEmpty else { return nil }
        root = collector.root
        fields = collector.fields
    }

    private final class Collector: NSObject, XMLParserDelegate {
        var root = ""
        var fields: [String: String] = [:]
        private var depth = 0
        private var current: String?
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            depth += 1
            if depth == 1 { root = name }
            if depth == 2 { current = name; text = "" }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if depth == 2 { text += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if depth == 2, let current, fields[current] == nil {
                fields[current] = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            depth -= 1
        }
    }
}
