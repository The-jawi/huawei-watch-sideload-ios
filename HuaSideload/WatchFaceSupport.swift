import Foundation

// Watch faces after the upload: Gadgetbridge packets/Watchface.java (service 0x27), AsynchronousResponse.handleWatchface
// and HuaweiInstallHandler. The file itself goes over FileUpload (0x28, type 1). When the watch has stored it, it sends
// WatchfaceConfirm (0x27/0x05) and waits for the phone's confirmation; Gadgetbridge answers it and, for report type 2,
// makes the face active. HuaSideload used to stop after the upload, so a watch that waits for this never adds the face.
enum WatchFaceService {
    static let serviceId: UInt8 = 0x27
    static let paramsCommand: UInt8 = 0x01      // WatchfaceParams
    static let listCommand: UInt8 = 0x02        // DeviceWatchInfo
    static let operationCommand: UInt8 = 0x03   // WatchfaceOperation
    static let confirmCommand: UInt8 = 0x05     // WatchfaceConfirm

    struct DeviceParams: Equatable {
        var maxVersion = ""
        var width = 0
        var height = 0
        var fileType = 0
        var sort = 0
        var otherVersions = ""

        // Same order as Gadgetbridge and the description.xml screen codes: height*width
        var resolution: String { "\(height)*\(width)" }
    }

    static func paramsRequest() -> HuaweiTLV {
        [0x01, 0x02, 0x03, 0x04, 0x05, 0x0E, 0x0F].reduce(HuaweiTLV()) { $0.with($1) }
    }

    static func parseParams(_ tlv: HuaweiTLV) -> DeviceParams? {
        guard let width = tlv.int(0x02), let height = tlv.int(0x03), width > 0, height > 0 else { return nil }
        return DeviceParams(maxVersion: text(tlv, 0x01), width: width, height: height,
                            fileType: tlv.int(0x04) ?? 0, sort: tlv.int(0x05) ?? 0, otherVersions: text(tlv, 0x06))
    }

    struct Installed: Equatable {
        var name: String
        var version: String
        var type: Int

        var isCurrent: Bool { type & 1 == 1 }
        var isFactory: Bool { (type >> 1) & 1 == 1 }
    }

    // DeviceWatchInfo: 0x06 = 3 (Gadgetbridge: "overseas non-test")
    static func listRequest() -> HuaweiTLV {
        HuaweiTLV().with(0x01).with(0x06, [0x03])
    }

    static func parseList(_ tlv: HuaweiTLV) -> [Installed] {
        guard let outer = tlv.value(0x81), let container = try? HuaweiTLV.parse(outer) else { return [] }
        return container.items.filter { $0.tag == 0x82 }.compactMap { item in
            guard let face = try? HuaweiTLV.parse(item.value) else { return nil }
            return Installed(name: text(face, 0x03), version: text(face, 0x04), type: face.int(0x05) ?? 0)
        }
    }

    // The upload name is "<name>_<version>" (FileUpload.info); the watch reports and lists the two parts separately
    static func split(_ fileName: String) -> (name: String, version: String) {
        let parts = fileName.split(separator: "_", maxSplits: 1).map(String.init)
        return (parts.first ?? fileName, parts.count > 1 ? parts[1] : "")
    }

    struct ConfirmReport: Equatable {
        var name: String
        var version: String
        var reportType: Int

        var fileName: String { name + "_" + version }
    }

    static func parseConfirm(_ tlv: HuaweiTLV) -> ConfirmReport? {
        guard tlv.value(0x01) != nil else { return nil }
        return ConfirmReport(name: text(tlv, 0x01), version: text(tlv, 0x02), reportType: tlv.int(0x03) ?? 0)
    }

    // WatchfaceConfirm.Request: name, version, 0x7F = 100000 (success)
    static func confirmReply(fileName: String) -> HuaweiTLV {
        let (name, version) = split(fileName)
        return HuaweiTLV().with(0x01, Array(name.utf8)).with(0x02, Array(version.utf8))
            .with(0x7F, .bigEndian(UInt32(HuaweiPacket.resultSuccess)))
    }

    static let activate: UInt8 = 1

    // WatchfaceOperation.Request: name, version, operation (1 = make active; 2 = delete, not used here)
    static func operation(fileName: String, _ operation: UInt8) -> HuaweiTLV {
        let (name, version) = split(fileName)
        return HuaweiTLV().with(0x01, Array(name.utf8)).with(0x02, Array(version.utf8)).with(0x03, [operation])
    }

    private static func text(_ tlv: HuaweiTLV, _ tag: UInt8) -> String {
        guard let v = tlv.value(tag) else { return "" }
        return String(decoding: v, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
    }
}

// Screen codes in description.xml (<screen>), "height*width" (Gadgetbridge HuaweiWatchfaceManager.Resolution)
enum WatchFaceScreen {
    static let resolutions: [String: String] = [
        "HWHD01": "390*390", "HWHD02": "454*454", "HWHD03": "240*120", "HWHD04": "160*80",
        "HWHD05": "460*188", "HWHD06": "456*280", "HWHD07": "368*194", "HWHD08": "320*320",
        "HWHD09": "466*466", "HWHD10": "360*320", "HWHD11": "480*336", "HWHD12": "240*240",
        "HWHD13": "480*408", "HWHD14": "482*286",
        "HNHD01": "466*466", "HNHD02": "368*194", "HNHD03": "450*390", "HNHD04": "454*454",
        "HNHD05": "402*256", "QXHD01": "402*256", "QXHD02": "502*410",
    ]
}

// Whether a package fits the connected watch. Only the screen is checked, as Gadgetbridge does; there is no public
// rule tying a face's <version> to a firmware, so that is never claimed either way.
enum WatchFaceCompatibility: Equatable {
    case compatible(String)
    case incompatible(String)
    case unknown(String)

    static func evaluate(screenCode: String, device: WatchFaceService.DeviceParams?) -> WatchFaceCompatibility {
        guard let faceScreen = WatchFaceScreen.resolutions[screenCode] else {
            return .unknown(L("screen code \"\(screenCode)\" is not in the known list", "\"\(screenCode)\" ekran kodu bilinen listede yok"))
        }
        guard let device else {
            return .unknown(L("made for \(faceScreen); the watch did not report its screen", "\(faceScreen) için yapılmış; saat ekranını bildirmedi"))
        }
        if device.resolution == faceScreen {
            return .compatible(L("made for \(faceScreen), the watch's screen", "\(faceScreen) için yapılmış, saatin ekranı bu"))
        }
        return .incompatible(L("made for \(faceScreen), the watch is \(device.resolution)", "\(faceScreen) için yapılmış, saat \(device.resolution)"))
    }

    var label: String {
        switch self {
        case .compatible(let why): return L("Compatible: ", "Uyumlu: ") + why
        case .incompatible(let why): return L("Not for this watch: ", "Bu saate uygun değil: ") + why
        case .unknown(let why): return L("Compatibility unknown: ", "Uyumluluk bilinmiyor: ") + why
        }
    }

    var blocksInstall: Bool {
        if case .incompatible = self { return true }
        return false
    }
}

// Where an installation stands. "Installed" only once the watch lists the face; a finished transfer is not enough.
enum WatchFaceInstallStage: Equatable {
    case idle
    case validating
    case transferring(Double)
    case transferred            // FileUpload finished, waiting for the watch
    case confirmedByWatch       // the watch sent WatchfaceConfirm and got our confirmation
    case installed              // the watch lists the face
    case active                 // the watch lists it as the current face
    case failed(String)

    var label: String {
        switch self {
        case .idle: return ""
        case .validating: return L("Checking the package…", "Paket kontrol ediliyor…")
        case .transferring: return L("Transferring…", "Aktarılıyor…")   // the progress bar shows the percentage
        case .transferred: return L("Transferred; waiting for the watch to confirm…", "Aktarıldı; saatin onayı bekleniyor…")
        case .confirmedByWatch: return L("The watch confirmed the face; checking its list…", "Saat kadranı onayladı; listesi kontrol ediliyor…")
        case .installed: return L("Installed: the watch lists the face. Touch and hold the watch face to pick it.",
                                  "Kuruldu: saat kadranı listeliyor. Seçmek için kadrana basılı tut.")
        case .active: return L("Installed and active on the watch", "Kuruldu ve saatte etkin")
        case .failed(let why): return L("Failed: ", "Başarısız: ") + why
        }
    }
}

// Deciding whether an uploaded face reached the watch's list. The watch may report the face under a name other than
// the upload name, so besides the exact name this also accepts the name the watch confirmed, and a single face that
// was not on the watch before the upload (compared with the list fetched just before it).
enum WatchFaceInstallCheck {
    enum Match: Equatable {
        case uploadName         // listed under the name we uploaded
        case confirmedName      // listed under the name the watch confirmed
        case newEntry           // the one face that was not in the list before the upload
    }

    enum Outcome: Equatable {
        case listed(WatchFaceService.Installed, Match)
        case confirmedOnly(WatchFaceService.ConfirmReport)
        case notFound
    }

    static func evaluate(uploadName: String, before: [WatchFaceService.Installed]?, after: [WatchFaceService.Installed],
                         confirm: WatchFaceService.ConfirmReport?) -> Outcome {
        if let face = after.first(where: { $0.name == uploadName }) { return .listed(face, .uploadName) }
        if let confirm, let face = after.first(where: { $0.name == confirm.name }) { return .listed(face, .confirmedName) }
        if let before {
            let known = Set(before.map(\.name))
            let added = after.filter { !known.contains($0.name) }
            if added.count == 1 { return .listed(added[0], .newEntry) }
        }
        if let confirm { return .confirmedOnly(confirm) }
        return .notFound
    }

    // Names only (upload names are random numbers; built-in faces have plain names), for the log
    static func describe(_ faces: [WatchFaceService.Installed]?) -> String {
        guard let faces else { return L("not available", "alınamadı") }
        guard !faces.isEmpty else { return L("empty", "boş") }
        return "\(faces.count): " + faces.map { $0.name + ($0.isCurrent ? "*" : "") }.joined(separator: ", ")
    }
}

// The post-upload trace: one line per packet, service/command and TLV tags with their lengths. Values are shown only
// for result and status codes (0x7F, and tag 0x02 of the watch's 0x28/0x07 upload result), never anything else, so a
// line can hold no key, IV, token, PIN or identifier.
enum UploadTrace {
    static func line(_ direction: String, service: UInt8, command: UInt8, tlv: HuaweiTLV?, bodySize: Int) -> String {
        let text = String(format: "Trace %@: 0x%02X/0x%02X", direction, service, command)
        guard let tlv else { return text + " [\(bodySize) B, not TLV]" }
        let tags = tlv.items.map { item -> String in
            var s = String(format: "%02X:%d", item.tag, item.value.count)
            if showsValue(service: service, command: command, tag: item.tag), !item.value.isEmpty, item.value.count <= 4 {
                s += "=" + String(item.value.reduce(0) { $0 << 8 | Int($1) })
            }
            return s
        }
        return text + " [" + (tags.isEmpty ? "-" : tags.joined(separator: " ")) + "]"
    }

    static func showsValue(service: UInt8, command: UInt8, tag: UInt8) -> Bool {
        tag == 0x7F || (service == 0x28 && command == 0x07 && tag == 0x02)   // FileUpload result (HuaweiFeatures)
    }
}

// What is sent as the watch face file, and under which name. Watches differ (Gadgetbridge PR #3910): LiteOS watches
// take watchface.bin from inside com.huawei.watchface; full HarmonyOS watches take com.huawei.watchface itself, a zip,
// unchanged. Gadgetbridge always names the file "<random>_1.0.0"; the face's own <version> is the other choice.
// Nothing tells the phone which one a watch wants, so it is a setting to try.
enum WatchFaceUploadMethod: String, CaseIterable, Identifiable {
    case bin                    // watchface.bin, "<random>_1.0.0" (Gadgetbridge, LiteOS watches)
    case binFaceVersion         // watchface.bin, "<random>_<face version>"
    case package                // com.huawei.watchface unchanged, "<random>_1.0.0" (full HarmonyOS watches)
    case packageFaceVersion     // com.huawei.watchface unchanged, "<random>_<face version>"

    static let storageKey = "HuaSideloadFaceUploadMethod"
    static var current: WatchFaceUploadMethod {
        UserDefaults.standard.string(forKey: storageKey).flatMap(WatchFaceUploadMethod.init(rawValue:)) ?? .bin
    }

    var id: String { rawValue }
    var sendsPackage: Bool { self == .package || self == .packageFaceVersion }
    var usesFaceVersion: Bool { self == .binFaceVersion || self == .packageFaceVersion }

    var label: String {
        switch self {
        case .bin: return L("A: watchface.bin, version 1.0.0 (standard)", "A: watchface.bin, sürüm 1.0.0 (standart)")
        case .binFaceVersion: return L("B: watchface.bin, the face's version", "B: watchface.bin, kadranın sürümü")
        case .package: return L("C: whole com.huawei.watchface, version 1.0.0", "C: tüm com.huawei.watchface, sürüm 1.0.0")
        case .packageFaceVersion: return L("D: whole com.huawei.watchface, the face's version", "D: tüm com.huawei.watchface, kadranın sürümü")
        }
    }

    var shortLabel: String { String(label.prefix(1)) }

    // The bytes to upload. Without a zipped watchface.bin both are the same file.
    func payload(bin: [UInt8], package: [UInt8]) -> [UInt8] {
        sendsPackage ? package : bin
    }

    // "<9 digits>_<version>"; the version must be digits and dots (it is split off at the first "_"), else 1.0.0
    // digits: 9 like Gadgetbridge; 10 like the store faces on newer watches (and Huawei Health's file info)
    func uploadName(number: Int, faceVersion: String, digits: Int = 9) -> String {
        let digitsAndDots = !faceVersion.isEmpty && faceVersion.allSatisfy { $0.isASCII && ($0.isNumber || $0 == ".") }
            && faceVersion.first != "." && faceVersion.last != "."
        let version = usesFaceVersion && digitsAndDots ? faceVersion : "1.0.0"
        var limit = 1
        for _ in 0..<digits { limit *= 10 }
        return String(format: "%0\(digits)ld_", number % limit) + version
    }
}

// Experiment, from a Bluetooth capture of Huawei Health installing a face. Before the file info Huawei Health sends
// WatchfaceOperation (0x27/0x03) with ~1180 bytes of (encrypted) data; the watch answers with name, version, tag 04
// and a result code, and after the transfer confirms the face at once. Probing showed operation 5 is the only one the
// watch answers that way (3, 4, 0 and none: 100007). The rest of Huawei Health's message is unknown; its size matches
// ability.xml + hashCode from the .hwt, so the layout (which tags carry them) is a setting. One message per install,
// naming only the new face (a fresh random ID that is on no watch). Operations 1 (activate) and 2 (delete) are never
// sent by the probe. The watch's answer is logged in full: it is about this face only and holds no keys or account data.
enum WatchFaceProbe {
    static let storageKey = "HuaSideloadFaceProbe"
    static let layoutKey = "HuaSideloadFaceProbeLayout"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: storageKey) }

    static let operation: UInt8 = 5
    static let forbiddenOperations: Set<UInt8> = [1, 2]

    enum Layout: String, CaseIterable, Identifiable {
        case abilityHash        // 04 = ability.xml, 05 = hashCode
        case hashAbility        // 04 = hashCode, 05 = ability.xml
        case abilityHashHigh    // 06 = ability.xml, 07 = hashCode
        case bare               // name, version and operation only

        var id: String { rawValue }

        var label: String {
            switch self {
            case .abilityHash: return L("1: ability.xml in 04, hashCode in 05", "1: ability.xml 04'te, hashCode 05'te")
            case .hashAbility: return L("2: hashCode in 04, ability.xml in 05", "2: hashCode 04'te, ability.xml 05'te")
            case .abilityHashHigh: return L("3: ability.xml in 06, hashCode in 07", "3: ability.xml 06'da, hashCode 07'de")
            case .bare: return L("4: name and version only", "4: yalnızca ad ve sürüm")
            }
        }

        var shortLabel: String { String(label.prefix(1)) }
    }

    static var currentLayout: Layout {
        UserDefaults.standard.string(forKey: layoutKey).flatMap(Layout.init(rawValue:)) ?? .abilityHash
    }

    static func message(fileName: String, ability: [UInt8]?, hashCode: [UInt8]?, layout: Layout) -> HuaweiTLV {
        let (name, version) = WatchFaceService.split(fileName)
        var tlv = HuaweiTLV().with(0x01, Array(name.utf8)).with(0x02, Array(version.utf8)).with(0x03, [operation])
        let fields: [(UInt8, [UInt8]?)]
        switch layout {
        case .abilityHash: fields = [(0x04, ability), (0x05, hashCode)]
        case .hashAbility: fields = [(0x04, hashCode), (0x05, ability)]
        case .abilityHashHigh: fields = [(0x06, ability), (0x07, hashCode)]
        case .bare: fields = []
        }
        for (tag, value) in fields { if let value { tlv = tlv.with(tag, value) } }
        return tlv
    }

    // The watch took it: it echoes the face's name and reports no error (0x7F absent, 0 or 100000)
    static func accepted(_ reply: HuaweiTLV?, name: String) -> Bool {
        guard let reply, reply.value(0x01) == Array(name.utf8) else { return false }
        guard let code = reply.int(0x7F) else { return true }
        return code == 0 || code == HuaweiPacket.resultSuccess
    }

    // Every tag: short values as hex and number, printable text quoted, longer data as its length
    static func describe(_ reply: HuaweiTLV?) -> String {
        guard let reply else { return L("no TLV", "TLV yok") }
        guard !reply.items.isEmpty else { return L("empty", "boş") }
        return reply.items.map { item -> String in
            let v = item.value
            let s = String(format: "%02X:", item.tag)
            if v.isEmpty { return s + "-" }
            if v.count >= 3, v.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
                return s + "\"" + String(decoding: v.prefix(48), as: UTF8.self) + (v.count > 48 ? "…" : "") + "\""
            }
            if v.count <= 8 {
                return s + v.map { String(format: "%02X", $0) }.joined() + "=" + String(v.reduce(0) { $0 << 8 | Int($1) })
            }
            return s + "\(v.count)B"
        }.joined(separator: " ")
    }
}
