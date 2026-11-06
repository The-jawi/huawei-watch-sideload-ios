import AVFoundation
import CoreBluetooth
import Foundation
import UIKit

struct FoundDevice: Identifiable {
    let id: UUID
    let peripheral: CBPeripheral
    var name: String
    var rssi: Int?
    var systemConnected: Bool
    var looksHuawei: Bool
}

struct LogEntry: Identifiable {
    let id = UUID()
    let time = Date()
    let kind: LogKind
    let text: String
}

@MainActor
final class WatchLink: NSObject, ObservableObject {
    @Published private(set) var bluetoothState = L("Starting…", "Başlatılıyor…")
    @Published private(set) var devices: [FoundDevice] = []
    @Published private(set) var isScanning = false
    @Published private(set) var isConnecting = false
    @Published private(set) var connectedName: String?
    @Published private(set) var huaweiChannelReady = false
    // isPaired: the connection is encrypted, so commands work. pairingStage says whether pairing is really finished.
    @Published private(set) var isPaired = false
    @Published private(set) var pairingStage: PairingStage = .none
    @Published private(set) var busy: String?
    @Published private(set) var battery: Int?
    @Published private(set) var watchInfo: [String] = []
    @Published private(set) var log: [LogEntry] = []
    @Published private(set) var watchAppProgress: Double?
    @Published private(set) var installedApps: [WatchApps.Installed] = []
    @Published private(set) var watchUDID: String?
    // Identity details (UDID, serial number, MAC) stay hidden on screen and in the log, e.g. while filming
    @Published var revealIdentity = false
    private var secrets: [String] = []
    @Published private(set) var musicStorage: MusicControl.Storage?
    @Published private(set) var musicUploadStatus: String?
    @Published private(set) var watchFaceStatus: String?
    @Published private(set) var watchFaceStage: WatchFaceInstallStage = .idle
    @Published private(set) var watchFaceCompatibility: WatchFaceCompatibility?
    // The watch's watch face screen and engine (0x27/0x01), asked once per connection
    @Published private(set) var watchFaceParams: WatchFaceService.DeviceParams?
    // The connected watch is also held by another app on this iPhone (usually Huawei Health)
    @Published private(set) var sharedWithOtherApp = false
    private var faceConfirms: [String: WatchFaceService.ConfirmReport] = [:]
    // The latest WatchfaceConfirm, whatever name the watch used for the face
    private var lastFaceConfirm: WatchFaceService.ConfirmReport?
    // The watch asks for song info by file name: file name -> (title, artist)
    private var musicMetadata: [String: (title: String, artist: String)] = [:]
    private var lastInstallStatus: Int?

    private let huaweiService = CBUUID(string: HuaweiUUID.service)
    private let writeUUID = CBUUID(string: HuaweiUUID.write)
    private let notifyUUID = CBUUID(string: HuaweiUUID.notify)

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var servicesAwaitingCharacteristics = 0
    private let parser = HuaweiPacketParser()
    private var session: HuaweiSession!
    let features: [WatchFeature]
    let speaker = WatchSpeaker()
    private var bridges: [String: WatchAppBridge] = [:]

    // Reconnect and pair again automatically when the connection drops
    private var wantsConnection = false
    private static let lastWatchKey = "lastWatch"

    // Optional: the Huawei account ID the watch was set up with (Watch tab), kept in the Keychain. Sent in the setup
    // after HiChain; without it the watch is told "no account", as Gadgetbridge does.
    static var huaweiAccountId: String {
        PairingSetup.normalizedAccountId(CredentialStore.shared.string(CredentialStore.huaweiAccountKey) ?? "") ?? ""
    }

    override init() {
        features = WatchFeatures.load()
        super.init()
        speaker.log = { [weak self] kind, text in self?.append(kind, text) }
        session = HuaweiSession(
            writeFrame: { [weak self] frame in self?.write(frame) },
            maxWriteLength: { [weak self] in self?.maxWriteLength ?? 182 },
            log: { [weak self] kind, text in self?.append(kind, text) }
        )
        session.onMusicScreenOpened = { [weak self] in
            self?.append(.success, L("⌚ Music screen opened on the watch", "⌚ Saatte müzik ekranı açıldı"))
            self?.musicScreenOwner?.musicScreenOpened()
        }
        session.onMusicButton = { [weak self] button, volume in
            let name = button?.name ?? volume.map { L("volume \($0)", "ses \($0)") } ?? L("unknown button", "bilinmeyen tuş")
            self?.append(.success, L("⌚ Button on the watch: \(name)", "⌚ Saatten tuş: \(name)"))
            self?.musicScreenOwner?.musicButton(button, volume: volume)
        }
        session.onMusicFileInfo = { [weak self] index, fileName in
            guard let self else { return }
            let meta = self.musicMetadata[fileName] ?? ((fileName as NSString).deletingPathExtension, "")
            self.session.send(MusicControl.serviceId, MusicControl.uploadInfoCommand,
                              MusicControl.uploadInfoReply(index: index, title: meta.title, artist: meta.artist))
            self.append(.info, L("The watch asked for song info: \(fileName) → \(meta.title)", "Saat şarkı bilgisini sordu: \(fileName) → \(meta.title)"))
        }
        session.onPairingStage = { [weak self] stage in self?.pairingStage = stage }
        session.onWatchFaceConfirm = { [weak self] report in self?.watchFaceConfirmed(report) }
        session.onAppInstallStatus = { [weak self] status, package in
            let kind: LogKind = status == 102 ? .success : (status == 103 || status == 106 ? .error : .info)
            self?.append(kind, "⌚ Saat: \(WatchApps.describeStatus(status)) \(package)")
            self?.lastInstallStatus = status
        }
        session.onAppMessage = { [weak self] source, data in
            guard let self else { return }
            if source == NotificationIcon.watchPackage {
                self.notificationIconMessage(data)
                return
            }
            guard let bridge = self.bridge(for: source) else {
                self.append(.info, L("P2P data from \(source) (\(data.count) bytes), this package is not bundled in the app", "Saatten P2P veri: \(source) (\(data.count) bayt), bu paket uygulamanın içinde yok"))
                return
            }
            bridge.receive(from: source, data: data)
        }
        for feature in features { feature.attach(to: self) }
        append(.info, L("Features: ", "Özellikler: ") + features.map { String(describing: type(of: $0)) }.joined(separator: ", ")
               + L(" · bundled watch apps: ", " · paketli saat uygulamaları: ")
               + (WatchAppCatalog.all.isEmpty ? L("none", "yok") : WatchAppCatalog.all.map(\.name).joined(separator: ", ")))
        // State restoration: if iOS terminates the app in the background, it keeps the (pending) connection to the
        // watch and relaunches the app for its Bluetooth events, so notifications and the watch's buttons keep working
        central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionRestoreIdentifierKey: "HuaSideloadCentral"])
    }

    private var musicScreenOwner: WatchFeature? { features.first { $0.ownsMusicScreen } }

    // A message goes first to the features that know its package, then to the generic ones (e.g. HelloFeature)
    private func route(_ message: [String: Any], from package: String) {
        let ordered = features.filter { $0.watchPackages.contains(package) } + features.filter { $0.watchPackages.isEmpty }
        inBackground("Watch app") {
            for feature in ordered where await feature.handle(message, from: package) { return }
            self.append(.info, L("Unhandled message from \(package): \(message["t"] ?? "?")", "\(package) uygulamasından işlenmeyen mesaj: \(message["t"] ?? "?")"))
        }
    }

    var logText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return log.map { entry in
            let mark: String
            switch entry.kind {
            case .info: mark = "  "
            case .sent: mark = "→ "
            case .received: mark = "← "
            case .success: mark = "✓ "
            case .error: mark = "✗ "
            }
            return "[\(formatter.string(from: entry.time))] \(mark)\(display(entry.text))"
        }.joined(separator: "\n")
    }

    private var watchKey: String? { peripheral?.identifier.uuidString }

    var hasSavedPairing: Bool {
        guard let watchKey else { return false }
        return session.hasAuthToken(for: watchKey)
    }

    // MARK: - Scanning

    func startScan() {
        guard central.state == .poweredOn else {
            append(.error, L("Bluetooth is not ready: \(bluetoothState)", "Bluetooth hazır değil: \(bluetoothState)"))
            return
        }
        devices.removeAll()
        findSystemConnected()
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        isScanning = true
        append(.info, L("Scanning for nearby devices (15 s)…", "Çevredeki cihazlar taranıyor (15 sn)…"))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            self?.stopScan()
        }
    }

    func stopScan() {
        guard isScanning else { return }
        central.stopScan()
        isScanning = false
        append(.info, L("Scan finished: \(devices.count) devices, \(devices.filter(\.looksHuawei).count) look like Huawei", "Tarama bitti: \(devices.count) cihaz, \(devices.filter(\.looksHuawei).count) tanesi Huawei gibi görünüyor"))
    }

    // A watch connected to Huawei Health may not advertise; also ask for devices already connected to the system
    private func findSystemConnected() {
        let services = [huaweiService, CBUUID(string: "180A"), CBUUID(string: "180F"), CBUUID(string: "1812"), CBUUID(string: "1805")]
        let peripherals = central.retrieveConnectedPeripherals(withServices: services)
        for p in peripherals {
            upsert(p, name: p.name, rssi: nil, systemConnected: true, advertisesHuawei: false)
        }
        append(.info, L("Found \(peripherals.count) devices already connected to the phone", "Telefona zaten bağlı \(peripherals.count) cihaz bulundu"))
    }

    private func upsert(_ p: CBPeripheral, name: String?, rssi: Int?, systemConnected: Bool, advertisesHuawei: Bool) {
        let resolvedName = name ?? p.name
        let looksHuawei = advertisesHuawei || (resolvedName?.lowercased().contains("huawei") ?? false)

        if let i = devices.firstIndex(where: { $0.id == p.identifier }) {
            if let resolvedName { devices[i].name = resolvedName }
            if let rssi { devices[i].rssi = rssi }
            devices[i].systemConnected = devices[i].systemConnected || systemConnected
            devices[i].looksHuawei = devices[i].looksHuawei || looksHuawei
        } else {
            // Nameless devices clutter the list; keep only connected ones
            guard resolvedName != nil || systemConnected || looksHuawei else { return }
            devices.append(FoundDevice(id: p.identifier, peripheral: p, name: resolvedName ?? L("Unnamed device", "İsimsiz cihaz"),
                                       rssi: rssi, systemConnected: systemConnected, looksHuawei: looksHuawei))
            if looksHuawei {
                append(.success, L("Found a Huawei device: ", "Huawei cihaz bulundu: ") + (resolvedName ?? p.identifier.uuidString))
            }
        }
        devices.sort { ($0.looksHuawei ? 0 : 1, -($0.rssi ?? -200)) < ($1.looksHuawei ? 0 : 1, -($1.rssi ?? -200)) }
    }

    // MARK: - Connection

    func connect(_ device: FoundDevice) {
        stopScan()
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        resetConnectionState()

        peripheral = device.peripheral
        device.peripheral.delegate = self
        isConnecting = true
        wantsConnection = true
        UserDefaults.standard.set(device.id.uuidString, forKey: Self.lastWatchKey)
        append(.info, L("Connecting to \(device.name)…", "\(device.name) cihazına bağlanılıyor…"))
        // iOS shares one Bluetooth link per device between apps: if Huawei Health is connected too, both would talk
        // to the watch at the same time over the same channel
        sharedWithOtherApp = device.systemConnected
        if device.systemConnected {
            append(.error, L("Another app on this iPhone (usually Huawei Health) is connected to this watch. Force-quit Huawei Health before pairing or installing; do not use both at the same time.",
                             "Bu iPhone'daki başka bir uygulama (genelde Huawei Health) bu saate bağlı. Eşleşmeden veya yüklemeden önce Huawei Health'i tamamen kapat; ikisini aynı anda kullanma."))
        }
        central.connect(device.peripheral)

        Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, self.isConnecting, self.peripheral === device.peripheral else { return }
            self.wantsConnection = false
            self.central.cancelPeripheralConnection(device.peripheral)
            self.isConnecting = false
            self.append(.error, L("Could not connect within 15 s. Is the watch nearby and awake?", "15 saniyede bağlanamadı. Saat yakında ve açık mı?"))
        }
    }

    // Also "release the watch for Huawei Health": stops scanning and notifications, closes this app's connection and
    // does not reconnect on the next launch. The saved pairing key stays (Forget pairing is a separate action), and
    // nothing is sent to the watch, so its pairing with Huawei Health is not touched.
    func disconnect() {
        wantsConnection = false
        stopScan()
        // Disconnecting by hand means "start clean": don't reconnect on the next launch until a watch is picked again
        UserDefaults.standard.removeObject(forKey: Self.lastWatchKey)
        guard let peripheral else { return }
        for service in peripheral.services ?? [] where service.uuid == huaweiService {
            for c in service.characteristics ?? [] where c.uuid == notifyUUID && c.isNotifying {
                peripheral.setNotifyValue(false, for: c)
            }
        }
        central.cancelPeripheralConnection(peripheral)
        if isConnecting {
            isConnecting = false
            self.peripheral = nil
            append(.info, L("Connecting cancelled", "Bağlanma iptal edildi"))
        }
    }

    // On launch, connect to the last used watch automatically
    private func reconnectLastWatch() {
        // Relaunched by iOS with the watch restored (centralManager(_:willRestoreState:)): pick the connection up again
        if let restored = peripheral, wantsConnection, !huaweiChannelReady, !isConnecting {
            if restored.state == .connected {
                connectedName = restored.name
                append(.info, L("Still connected to \(restored.name ?? "the watch"), setting up the channel again…", "\(restored.name ?? "Saat") ile bağlantı sürüyor, kanal yeniden kuruluyor…"))
                restored.discoverServices(nil)
            } else {
                isConnecting = true
                central.connect(restored)
            }
            return
        }
        guard peripheral == nil,
              let id = UserDefaults.standard.string(forKey: Self.lastWatchKey).flatMap(UUID.init(uuidString:)),
              let known = central.retrievePeripherals(withIdentifiers: [id]).first else { return }
        peripheral = known
        known.delegate = self
        wantsConnection = true
        isConnecting = true
        append(.info, L("Reconnecting to the last watch: ", "Son saate otomatik bağlanılıyor: ") + (known.name ?? "watch"))
        // No timeout: iOS connects as soon as the watch is in range
        central.connect(known)
    }

    private func resetConnectionState() {
        bridges.values.forEach { $0.reset() }
        features.forEach { $0.connectionLost() }
        writeCharacteristic = nil
        huaweiChannelReady = false
        isPaired = false
        pairingStage = .none
        watchFaceParams = nil
        sharedWithOtherApp = false
        faceConfirms.removeAll()
        connectedName = nil
        battery = nil
        watchInfo = []
        servicesAwaitingCharacteristics = 0
        parser.reset()
        session.reset()
    }

    // MARK: - Watch commands

    func pair() {
        guard let watchKey else { return }
        run(L("Pairing…", "Eşleşiyor…")) { session in
            do {
                try await session.pair(watch: watchKey)
            } catch {
                self.pairingStage = .failed(String(String(describing: error).prefix(120)))
                throw error
            }
            self.isPaired = true

            // Before anything else, like Gadgetbridge: the watch waits for these after HiChain (PairingSetup)
            self.pairingStage = .finishingSetup
            let setup = await session.completeSetup(watchName: self.connectedName ?? "", accountId: Self.huaweiAccountId)
            if !setup.sent.isEmpty { self.append(.success, L("Setup sent: ", "Kurulum gönderildi: ") + setup.sent.joined(separator: ", ")) }
            if !setup.skipped.isEmpty { self.append(.info, L("Not asked for by the watch: ", "Saatin istemediği: ") + setup.skipped.joined(separator: ", ")) }
            if setup.failed.isEmpty {
                self.pairingStage = .paired
                self.append(.success, L("PAIRED: HiChain finished and the watch accepted the setup. Check that the watch shows no error.",
                                        "EŞLEŞTİ: HiChain bitti ve saat kurulumu kabul etti. Saatte hata çıkmadığını kontrol et."))
            } else {
                let why = setup.failed.joined(separator: ", ")
                self.pairingStage = .setupIncomplete(why)
                self.append(.error, L("Setup not accepted by the watch: ", "Saat kurulumu kabul etmedi: ") + why)
            }
            self.watchUDID = session.watchUDID
            if let udid = session.watchUDID { self.addSecret(udid) }
            let environment = ProcessInfo.processInfo.environment
            if environment["HUASIDELOAD_DIAG"] == "1" {
                Task { await self.runDiagnostics(session) }
            }
            // Testing from a Mac: upload a file from the app's Documents folder to the watch's music player
            if let file = environment["HUASIDELOAD_UPLOAD"] {
                Task {
                    try? await Task.sleep(for: .seconds(6))
                    self.uploadMusic([URL.documentsDirectory.appending(path: file)])
                }
            }
            self.features.forEach { $0.watchPaired() }
            try await self.refreshInfo(session)
            Task { await self.offerNotificationIcon(session) }
        }
    }

    // MARK: Notification icon (see NotificationIcon)

    // After pairing: offer this app to the watch's notification icon service (it answers if it needs the icon)
    private func offerNotificationIcon(_ session: HuaweiSession) async {
        do {
            let reply = try await sendToIconService(NotificationIcon.offer())
            if let code = reply.code, code != P2P.Code.ok {
                append(.info, String(format: L("Notification icon: the watch did not take the offer (0x%X)", "Bildirim ikonu: saat teklifi almadı (0x%X)"), code))
            }
        } catch {
            append(.info, L("Notification icon: the watch has no icon service (\(error))", "Bildirim ikonu: saatte ikon servisi yok (\(error))"))
        }
    }

    private func sendToIconService(_ data: [UInt8]) async throws -> P2P.Message {
        try await session.p2p(kind: P2P.Kind.data, source: NotificationIcon.phoneModule, destination: NotificationIcon.watchPackage,
                              sourceFingerprint: NotificationIcon.phoneFingerprint, destinationFingerprint: NotificationIcon.watchFingerprint,
                              data: data)
    }

    private func notificationIconMessage(_ data: [UInt8]) {
        guard let json = try? JSONSerialization.jsonObject(with: Data(data)) as? [String: Any],
              let type = json["msgType"] as? Int, let body = json["msgBody"] as? [String: Any] else { return }
        let retCode = body["retCode"] as? Int ?? 0
        switch (type, retCode) {
        case (6001, 10001...10003):
            let width = body["iconWidth"] as? Int ?? 0, height = body["iconHeight"] as? Int ?? 0
            guard width > 0, height > 0, width <= 512, height <= 512, let icon = NotificationIcon.iconData(width: width, height: height) else {
                append(.error, L("Notification icon: could not prepare the app icon", "Bildirim ikonu: uygulama ikonu hazırlanamadı"))
                return
            }
            append(.info, L("Notification icon: the watch wants a \(width)×\(height) icon, sending…", "Bildirim ikonu: saat \(width)×\(height) ikon istiyor, gönderiliyor…"))
            inBackground("Notification icon") {
                do {
                    let addressee = FileUpload.Addressee(source: NotificationIcon.phoneModule, destination: NotificationIcon.watchPackage,
                                                         sourceFingerprint: NotificationIcon.phoneFingerprint,
                                                         destinationFingerprint: NotificationIcon.watchFingerprint)
                    try await self.session.uploadFile(icon, name: NotificationIcon.fileName(for: retCode), type: NotificationIcon.fileType,
                                                      to: addressee) { _ in }
                    _ = try await self.sendToIconService(NotificationIcon.uploaded(for: retCode))
                    self.append(.success, L("Notification icon sent: this app's notifications show its icon now", "Bildirim ikonu gönderildi: bu uygulamanın bildirimleri artık kendi ikonuyla görünür"))
                } catch {
                    self.append(.error, L("Notification icon could not be sent: \(error)", "Bildirim ikonu gönderilemedi: \(error)"))
                }
            }
        case (6001, 10004), (6001, 10005):
            append(.info, L("Notification icon: the watch already has it", "Bildirim ikonu: saatte zaten var"))
        case (6002, _):
            append(.info, L("Notification icon: the watch closed the exchange (\(retCode))", "Bildirim ikonu: saat alışverişi kapattı (\(retCode))"))
        default:
            append(.info, L("Notification icon service: ", "Bildirim ikonu servisi: ") + String(decoding: data.prefix(300), as: UTF8.self))
        }
    }

    func refresh() {
        run(L("Reading…", "Okunuyor…")) { session in try await self.refreshInfo(session) }
    }

    func sendMessage(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        run(L("Sending…", "Gönderiliyor…")) { session in
            try await session.sendNotification(title: AppInfo.displayName, text: text)
            self.append(.success, L("Sent to the watch: \"\(text)\"", "Mesaj saate gönderildi: \"\(text)\""))
        }
    }

    func forgetPairing() {
        guard let watchKey else { return }
        session.forget(watch: watchKey)
        isPaired = false
        pairingStage = huaweiChannelReady ? .channelReady : .none
        append(.info, L("Saved pairing removed. The next pairing starts from the PIN step.", "Kayıtlı eşleşme silindi. Tekrar eşleşince PIN adımından başlanacak."))
        objectWillChange.send()
    }

    // Events from the watch wake the app in the background; ask iOS for time until the work is done
    func inBackground(_ name: String, _ work: @escaping () async -> Void) {
        var id: UIBackgroundTaskIdentifier = .invalid
        var task: Task<Void, Never>?
        id = UIApplication.shared.beginBackgroundTask(withName: name) {
            task?.cancel()
            if id != .invalid {
                UIApplication.shared.endBackgroundTask(id)
                id = .invalid
            }
        }
        task = Task {
            await work()
            if id != .invalid {
                UIApplication.shared.endBackgroundTask(id)
                id = .invalid
            }
        }
    }

    // Vibrating notification
    func notify(title: String, text: String) {
        append(.info, L("⌚ Alert: \(title) · \(text)", "⌚ Uyarı: \(title) · \(text)"))
        guard isPaired else { return }
        Task {
            do {
                try await session.sendNotification(title: title, text: text)
            } catch {
                append(.error, L("Could not send the alert: \(error)", "Uyarı gönderilemedi: \(error)"))
            }
        }
    }

    // When launched from a Mac with HUASIDELOAD_DIAG=1: asks the watch about its audio and music capabilities
    private func runDiagnostics(_ session: HuaweiSession) async {
        try? await Task.sleep(for: .seconds(4))
        append(.info, "=== DIAGNOSTICS ===")
        let audio = AVAudioSession.sharedInstance()
        try? audio.setCategory(.playback)
        try? audio.setActive(true)
        for output in audio.currentRoute.outputs {
            append(.info, "Audio output: \(output.portName) [\(output.portType.rawValue)]")
        }
        for input in audio.availableInputs ?? [] {
            append(.info, "Audio input: \(input.portName) [\(input.portType.rawValue)]")
        }
        try? audio.setActive(false, options: .notifyOthersOnDeactivation)

        let asked: [(service: UInt8, commands: [UInt8])] = [
            (0x01, [0x35, 0x37, 0x10, 0x3E, 0x3F]),
            (0x25, [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0D, 0x0E]),
            (0x2A, [0x01, 0x02, 0x03, 0x06]),
            (0x34, [0x01]),
        ]
        do {
            let supported = try await session.supportedCommands(asked)
            for (service, commands) in supported.sorted(by: { $0.key < $1.key }) {
                append(.info, String(format: "Servis 0x%02X destekli komutlar: ", service) + commands.map { String(format: "%02X", $0) }.joined(separator: " "))
            }
        } catch {
            append(.error, "Supported commands: \(error)")
        }
        do {
            let caps = try await session.expandCapabilities()
            let bits = caps.enumerated().flatMap { byte in (0..<8).compactMap { byte.element & (1 << $0) != 0 ? byte.offset * 8 + $0 : nil } }
            append(.info, "Extended capabilities (\(caps.count) bytes): \(caps.hexCompact)")
            append(.info, "Capability bits set: \(bits.map(String.init).joined(separator: " "))")
        } catch {
            append(.error, "Extended capabilities: \(error)")
        }
        for (service, command, tlv, label) in [
            (UInt8(0x25), UInt8(0x04), HuaweiTLV().with(0x01).with(0x02).with(0x03).with(0x04).with(0x05), "Music storage"),
            (UInt8(0x25), UInt8(0x0D), HuaweiTLV().with(0x01).with(0x02).with(0x03).with(0x04).with(0x05), "Extended music info"),
            (UInt8(0x01), UInt8(0x35), HuaweiTLV().with(0x01, [0x01]), "Connection status"),
        ] {
            do {
                let reply = try await session.rawRequest(service, command, tlv, label: label)
                append(.info, "\(label): \(reply?.description ?? "empty")")
            } catch {
                append(.error, "\(label): \(error)")
            }
        }
        append(.info, "=== DIAGNOSTICS DONE ===")
    }

    // MARK: - The watch's music player

    func loadMusicStorage() {
        run(L("Reading the watch's music storage…", "Saatin müzik hafızası okunuyor…")) { session in
            self.musicStorage = try await session.musicStorage()
        }
    }

    // Uploads the chosen audio files one by one to the watch's storage
    func uploadMusic(_ urls: [URL]) {
        let files = urls.filter { MusicControl.formats.contains($0.pathExtension.lowercased()) }
        if files.count < urls.count {
            append(.error, L("The watch only plays: ", "Saat sadece şunları çalıyor: ") + MusicControl.formats.joined(separator: ", ") + L(". Other files were skipped.", ". Diğerleri atlandı."))
        }
        guard !files.isEmpty else { return }
        watchAppProgress = 0
        run(L("Uploading music to the watch…", "Saate müzik yükleniyor…")) { session in
            defer {
                self.watchAppProgress = nil
                self.musicUploadStatus = nil
            }
            for (i, url) in files.enumerated() {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                let name = url.lastPathComponent
                let meta = await Self.audioMetadata(url)
                self.musicMetadata[name] = meta
                self.musicUploadStatus = "\(i + 1)/\(files.count): \(meta.title)"
                self.append(.info, L("Uploading music (\(i + 1)/\(files.count)): \(name), \(data.count / 1024) KB", "Müzik yükleniyor (\(i + 1)/\(files.count)): \(name), \(data.count / 1024) KB"))
                try await session.uploadFile([UInt8](data), name: name, type: MusicControl.fileType) { fraction in
                    self.watchAppProgress = (Double(i) + fraction) / Double(files.count)
                }
                self.append(.success, L("Uploaded to the watch: \(meta.title)", "Saate yüklendi: \(meta.title)"))
                // Give the watch a moment to add the song to its library
                try? await Task.sleep(for: .seconds(2))
            }
            self.musicStorage = try? await session.musicStorage()
        }
    }

    private static func audioMetadata(_ url: URL) async -> (title: String, artist: String) {
        let asset = AVURLAsset(url: url)
        var title = url.deletingPathExtension().lastPathComponent
        var artist = ""
        if let items = try? await asset.load(.commonMetadata) {
            for item in items {
                guard let key = item.commonKey, let value = try? await item.load(.stringValue), !value.isEmpty else { continue }
                if key == .commonKeyTitle { title = value }
                if key == .commonKeyArtist { artist = value }
            }
        }
        return (title, artist)
    }

    func loadInstalledApps() {
        run(L("Reading the apps on the watch…", "Saatteki uygulamalar okunuyor…")) { session in
            self.installedApps = try await session.installedApps()
        }
    }

    func deleteWatchApp(_ app: WatchApps.Installed) {
        run("\(app.name.isEmpty ? app.package : app.name) siliniyor…") { session in
            try await session.deleteApp(app.package)
            try? await Task.sleep(for: .seconds(1))
            let apps = try await session.installedApps()
            self.installedApps = apps
            let gone = !apps.contains { $0.package == app.package }
            self.append(gone ? .success : .error, gone ? L("Removed from the watch: \(app.name)", "Saatten silindi: \(app.name)")
                        : L("The watch did not remove \(app.name)", "Saat \(app.name) uygulamasını silmedi"))
        }
    }

    // Short result line for the screen (filming mode shows it instead of the log): ok nil = in progress
    struct AppInstallStatus { let text: String; let ok: Bool? }
    @Published private(set) var appInstallStatus: AppInstallStatus?

    // Installs a signed watch app bundled in the iPhone app (WatchApps/*.bin) on the watch
    func installWatchApp(_ app: BundledWatchApp) {
        watchAppProgress = 0
        appInstallStatus = AppInstallStatus(text: L("Sending \(app.name) to the watch…", "\(app.name) saate gönderiliyor…"), ok: nil)
        run(L("Installing \(app.name) on the watch…", "\(app.name) saate yükleniyor…")) { session in
            defer {
                self.watchAppProgress = nil
                if self.appInstallStatus?.ok == nil {
                    self.appInstallStatus = AppInstallStatus(text: L("\(app.name) could not be installed", "\(app.name) kurulamadı"), ok: false)
                }
            }
            self.append(.info, "\(app.name): \(app.package) \(app.version), \(app.data.count) \(L("bytes", "bayt"))")
            if let platform = try? await session.appPlatform() {
                self.append(.info, L("Watch app platform: ", "Saatin uygulama platformu: ") + WatchApps.describeParams(platform))
            }
            self.lastInstallStatus = nil
            try await session.uploadFile(app.data, name: app.package + "_INSTALL", type: FileUpload.FileType.app) { fraction in
                self.watchAppProgress = fraction
            }
            self.append(.success, L("Transfer finished, waiting for the watch to install…", "Dosya aktarımı bitti, saatin kurulumu bekleniyor…"))
            self.appInstallStatus = AppInstallStatus(text: L("The watch is installing \(app.name)…", "Saat \(app.name) uygulamasını kuruyor…"), ok: nil)
            // Wait up to 90 s for the watch to report 102 (installed) or 103 (failed)
            for _ in 0..<90 where self.lastInstallStatus != 102 && self.lastInstallStatus != 103 {
                try? await Task.sleep(for: .seconds(1))
            }
            if let apps = try? await session.installedApps() {
                self.installedApps = apps
                let mine = apps.contains { $0.package == app.package }
                self.append(mine ? .success : .error, mine ? L("\(app.name) is installed on the watch 🎉", "\(app.name) saatte kurulu 🎉")
                            : L("\(app.name) is not on the watch. For error 103 see README > Troubleshooting",
                                "\(app.name) saatin listesinde yok. 103 hatası için README > Troubleshooting"))
                // 103 wins: an older build of the same package may still be on the watch
                if self.lastInstallStatus == 103 {
                    self.appInstallStatus = AppInstallStatus(text: L("The watch rejected \(app.name): 103", "Saat \(app.name) uygulamasını reddetti: 103"), ok: false)
                } else {
                    self.appInstallStatus = mine ? AppInstallStatus(text: L("\(app.name) installed ✓", "\(app.name) kuruldu ✓"), ok: true)
                        : AppInstallStatus(text: L("\(app.name) could not be installed", "\(app.name) kurulamadı"), ok: false)
                }
            }
        }
    }

    // Uploads a watch face package (.hwt from Huawei Theme Studio), then follows it until the watch lists it
    // (WatchFaceService). Stages: checked → transferred → confirmed by the watch → installed (listed) → active.
    // onFinish gets the last stage reached (FaceLibrary keeps it as the install history)
    func installWatchFace(_ url: URL, title displayTitle: String? = nil, onFinish: ((WatchFaceInstallStage) -> Void)? = nil) {
        guard busy == nil else { return }
        watchAppProgress = nil
        setFaceStage(.validating)
        run(L("Installing the watch face…", "Kadran saate yükleniyor…")) { session in
            defer { self.watchAppProgress = nil }
            defer { onFinish?(self.watchFaceStage) }
            do {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                let face = try WatchFacePackage(hwt: Data(contentsOf: url))
                let title = displayTitle ?? face.title
                self.append(.info, L("Watch face: \(title), screen \(face.screen), version \(face.version), \(face.bin.count / 1024) KB, files: \(face.files.count)",
                                     "Kadran: \(title), ekran \(face.screen), sürüm \(face.version), \(face.bin.count / 1024) KB, dosya: \(face.files.count)"))
                face.warnings.forEach { self.append(.info, L("Package: ", "Paket: ") + $0) }

                if self.watchFaceParams == nil { self.watchFaceParams = try? await session.watchFaceParams() }
                let compatibility = WatchFaceCompatibility.evaluate(screenCode: face.screen, device: self.watchFaceParams)
                self.watchFaceCompatibility = compatibility
                self.append(compatibility.blocksInstall ? .error : .info, compatibility.label)
                guard !compatibility.blocksInstall else {
                    self.setFaceStage(.failed(compatibility.label))
                    return
                }

                // The list before the upload, to recognise the new face even if the watch lists it under another name
                let before = try? await session.installedWatchFaces()
                self.append(.info, L("Watch faces before the upload: ", "Yüklemeden önceki kadranlar: ") + WatchFaceInstallCheck.describe(before))

                // A random numeric name with a version suffix (Gadgetbridge: always 1.0.0); what is sent and the
                // version depend on the chosen upload method
                let method = WatchFaceUploadMethod.current
                let name = method.uploadName(number: Int.random(in: 0..<1_000_000_000), faceVersion: face.version)
                let payload = method.payload(bin: face.bin, package: face.package)
                let engine = self.watchFaceParams.map { L(", watch engine \($0.maxVersion.isEmpty ? "?" : $0.maxVersion)", ", saat motoru \($0.maxVersion.isEmpty ? "?" : $0.maxVersion)") } ?? ""
                self.append(.info, L("Upload method \(method.label): \(payload.count) bytes as \(name) (face version \(face.version)\(engine), watchface.bin \(face.binWasZipped ? "inside a zip" : "is the file itself"))",
                                     "Yükleme yöntemi \(method.label): \(payload.count) bayt, ad \(name) (kadran sürümü \(face.version)\(engine), watchface.bin \(face.binWasZipped ? "zip içinde" : "dosyanın kendisi"))"))
                let faceName = WatchFaceService.split(name).name
                self.faceConfirms[faceName] = nil
                self.lastFaceConfirm = nil
                self.setFaceStage(.transferring(0))
                try await session.uploadFile(payload, name: name, type: FileUpload.FileType.watchface) { fraction in
                    self.watchAppProgress = fraction
                    self.setFaceStage(.transferring(fraction))
                }
                self.watchAppProgress = nil
                self.setFaceStage(.transferred)
                self.append(.success, L("Transfer finished (the watch accepted the file as \(faceName)). Waiting for it to confirm and list the face…",
                                        "Aktarım bitti (saat dosyayı \(faceName) olarak aldı). Saatin kadranı onaylayıp listelemesi bekleniyor…"))

                // The watch sends WatchfaceConfirm (0x27/0x05) once it has stored the face; HuaweiSession answers it at
                // any time. Gadgetbridge has no deadline for it, and storing a face can take a while, so the list is
                // checked every few seconds for up to 90 s instead of once after 20 s.
                let started = Date()
                var after: [WatchFaceService.Installed] = []
                var listChecks = 0
                var outcome = WatchFaceInstallCheck.Outcome.notFound
                var nextListCheck = started.addingTimeInterval(4)
                while Date().timeIntervalSince(started) < 90 {
                    try? await Task.sleep(for: .milliseconds(500))
                    let confirm = self.faceConfirms[faceName] ?? self.lastFaceConfirm
                    if confirm != nil, self.watchFaceStage == .transferred { self.setFaceStage(.confirmedByWatch) }
                    guard Date() >= nextListCheck || (confirm != nil && listChecks == 0) else { continue }
                    nextListCheck = Date().addingTimeInterval(6)
                    listChecks += 1
                    guard let list = try? await session.installedWatchFaces() else { continue }
                    after = list
                    outcome = WatchFaceInstallCheck.evaluate(uploadName: faceName, before: before, after: list, confirm: confirm)
                    if case .listed = outcome { break }
                }
                session.stopTrace()
                let confirm = self.faceConfirms[faceName] ?? self.lastFaceConfirm
                let waited = Int(Date().timeIntervalSince(started))
                self.append(.info, L("Watch faces after the upload: ", "Yüklemeden sonraki kadranlar: ") + WatchFaceInstallCheck.describe(after)
                            + L(" (\(listChecks) checks in \(waited) s)", " (\(waited) sn içinde \(listChecks) kontrol)"))
                if let confirm, confirm.name != faceName {
                    self.append(.info, L("The watch confirmed the face as \(confirm.fileName), not \(name)", "Saat kadranı \(name) değil \(confirm.fileName) olarak onayladı"))
                }

                switch outcome {
                case .listed(let listed, let match):
                    if match != .uploadName {
                        self.append(.info, L("Found as \(listed.name) (", "\(listed.name) olarak bulundu (")
                                    + (match == .confirmedName ? L("the confirmed name)", "onaylanan ad)") : L("the one new face in the list)", "listedeki tek yeni kadran)")))
                    }
                    self.setFaceStage(listed.isCurrent ? .active : .installed)
                    self.append(.success, self.watchFaceStage.label)
                case .confirmedOnly:
                    self.append(.info, L("The watch confirmed the face but did not list it within \(waited) s. Check the watch face list on the watch.",
                                         "Saat kadranı onayladı ama \(waited) sn içinde listelemedi. Saatteki kadran listesine bak."))
                case .notFound:
                    // Where it stopped: the last thing the watch did, for the report
                    let status = session.lastUploadResultStatus.map { L(", status \($0)", ", durum \($0)") } ?? ""
                    self.setFaceStage(.failed(L("the watch took the whole file (0x28/0x07\(status), acknowledged) but sent no confirmation (0x27/0x05) and did not list the face within \(waited) s",
                                                "saat dosyanın tamamını aldı (0x28/0x07\(status), onaylandı) ama \(waited) sn içinde onay (0x27/0x05) göndermedi ve kadranı listelemedi")))
                    self.append(.error, self.watchFaceStage.label)
                }
            } catch {
                self.setFaceStage(.failed("\(error)"))
                throw error
            }
        }
    }

    private func setFaceStage(_ stage: WatchFaceInstallStage) {
        watchFaceStage = stage
        watchFaceStatus = stage == .idle ? nil : stage.label
    }

    // A WatchfaceConfirm from the watch (already answered by the session). Report type 2: make the face active,
    // as Gadgetbridge does.
    private func watchFaceConfirmed(_ report: WatchFaceService.ConfirmReport) {
        faceConfirms[report.name] = report
        lastFaceConfirm = report
        guard report.reportType == 2 else { return }
        Task {
            let code = try? await session.activateWatchFace(fileName: report.fileName)
            if let code, code != HuaweiPacket.resultSuccess {
                append(.error, String(format: L("The watch did not make the face active (0x%X)", "Saat kadranı etkinleştirmedi (0x%X)"), code))
            }
        }
    }

    private func refreshInfo(_ session: HuaweiSession) async throws {
        let level = try await session.batteryLevel()
        battery = level
        append(.success, L("Battery: \(level)%", "Pil: %\(level)"))
        let info = try await session.productInfo()
        let serialPrefix = ProductInfo.serialPrefix
        for line in info where line.hasPrefix(serialPrefix) { addSecret(String(line.dropFirst(serialPrefix.count))) }
        watchInfo = info
        info.forEach { append(.info, $0) }

        let services = try await session.supportedServices()
        append(.info, L("Services supported by the watch: ", "Saatin desteklediği servisler: ") + services.map { String(format: "%02X", $0) }.joined(separator: " "))
        func report(_ id: UInt8, _ name: String) {
            let has = services.contains(id)
            append(has ? .success : .error, "\(name) (0x\(String(format: "%02X", id))): \(has ? L("YES", "VAR") : L("NO", "YOK"))")
        }
        if services.contains(WatchApps.serviceId), let platform = try? await session.appPlatform() {
            append(.info, L("App platform: ", "Uygulama platformu: ") + WatchApps.describeParams(platform))
        }
        report(MusicControl.serviceId, L("Music control", "Müzik kontrolü"))
        report(0x2A, L("App install", "Uygulama kurma"))
        report(0x27, L("Watch faces", "Kadran kurma"))
        if services.contains(WatchFaceService.serviceId), let params = try? await session.watchFaceParams() {
            watchFaceParams = params
            let code = WatchFaceScreen.resolutions.first { $0.value == params.resolution }?.key ?? "?"
            let line = L("Watch face screen: \(params.resolution) (\(code)), engine \(params.maxVersion)",
                         "Kadran ekranı: \(params.resolution) (\(code)), motor \(params.maxVersion)")
            watchInfo.append(line)
            append(.info, line)
        }
    }

    private func run(_ label: String, _ work: @escaping (HuaweiSession) async throws -> Void) {
        guard busy == nil else { return }
        busy = label
        Task {
            do {
                try await work(session)
            } catch {
                append(.error, "\(error)")
            }
            busy = nil
        }
    }

    // MARK: - Writing

    private var maxWriteLength: Int {
        guard let peripheral, let writeCharacteristic else { return 182 }
        return peripheral.maximumWriteValueLength(for: writeType(writeCharacteristic))
    }

    private func writeType(_ characteristic: CBCharacteristic) -> CBCharacteristicWriteType {
        characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
    }

    // One frame; split raw if it is larger than the BLE write limit
    private func write(_ frame: [UInt8]) {
        guard let peripheral, let characteristic = writeCharacteristic else {
            append(.error, L("The Huawei channel is not ready", "Huawei kanalı hazır değil"))
            return
        }
        let type = writeType(characteristic)
        let maxChunk = peripheral.maximumWriteValueLength(for: type)
        var offset = 0
        while offset < frame.count {
            let end = min(offset + maxChunk, frame.count)
            peripheral.writeValue(Data(frame[offset..<end]), for: characteristic, type: type)
            offset = end
        }
    }

    private func handle(_ packet: HuaweiPacket) {
        var header = String(format: L("Packet: service 0x%02X, command 0x%02X", "Paket: servis 0x%02X, komut 0x%02X"), packet.serviceId, packet.commandId)
        if packet.isEncrypted { header += L(" (encrypted, could not decrypt)", " (şifreli, çözülemedi)") }
        append(.received, header)

        if let tlv = packet.tlv {
            append(.info, "TLV: \(String(tlv.description.prefix(300)))")
        } else {
            append(.info, L("Body: ", "Gövde: ") + Array(packet.body.prefix(100)).hex)
        }

        if let code = packet.resultCode, code != HuaweiPacket.resultSuccess {
            append(.error, String(format: L("The watch returned error code 0x%X (%d)", "Saat hata kodu döndü: 0x%X (%d)"), code, code))
        }

        if packet.serviceId == 0x01, packet.commandId == 0x08, let level = packet.tlv?.int(0x01) {
            battery = level
        }
    }

    // MARK: - Privacy

    // A value is masked both as text and as it appears in raw packets (hex of its ASCII)
    private func addSecret(_ value: String) {
        guard value.count >= 6 else { return }
        let hexCompact = Array(value.utf8).map { String(format: "%02X", $0) }.joined()
        let hexSpaced = Array(value.utf8).map { String(format: "%02X", $0) }.joined(separator: " ")
        for form in [value, hexCompact, hexSpaced] where !secrets.contains(form) {
            secrets.append(form)
        }
        secrets.sort { $0.count > $1.count }
        objectWillChange.send()
    }

    // MAC addresses (AA:BB:CC:DD:EE:FF) are always masked
    private static let macPattern = try! NSRegularExpression(pattern: "([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}")

    func display(_ text: String) -> String {
        guard !revealIdentity else { return text }
        // Raw packet dumps can contain pieces of identity details
        for prefix in ["Raw data", "Ham veri", "TLV: ", "Body: ", "Gövde: "] where text.hasPrefix(prefix) {
            let head = text.split(separator: ":", maxSplits: 1).first.map(String.init) ?? prefix
            return head + L(": (hidden)", ": (gizli)")
        }
        var result = text
        for secret in secrets { result = result.replacingOccurrences(of: secret, with: "••••") }
        let range = NSRange(result.startIndex..., in: result)
        return Self.macPattern.stringByReplacingMatches(in: result, range: range, withTemplate: "••:••:••:••:••:••")
    }

    func clearLog() { log.removeAll() }

    private func append(_ kind: LogKind, _ text: String) {
        print("[HuaSideload] \(text)")
        log.append(LogEntry(kind: kind, text: text))
        if log.count > 1000 { log.removeFirst(log.count - 1000) }
    }

    private static func describe(_ properties: CBCharacteristicProperties) -> String {
        var parts: [String] = []
        if properties.contains(.read) { parts.append("read") }
        if properties.contains(.write) { parts.append("write") }
        if properties.contains(.writeWithoutResponse) { parts.append("writeNoResp") }
        if properties.contains(.notify) { parts.append("notify") }
        if properties.contains(.indicate) { parts.append("indicate") }
        return parts.joined(separator: ",")
    }
}

// MARK: - What features use from the core

extension WatchLink: WatchFeatureHost {
    func bridge(for package: String) -> WatchAppBridge? {
        if let bridge = bridges[package] { return bridge }
        guard let fingerprint = WatchAppCatalog.app(for: package)?.fingerprint else { return nil }
        let bridge = WatchAppBridge(session: session, watchPackage: package, watchFingerprint: fingerprint,
                                    log: { [weak self] kind, text in self?.append(kind, text) })
        bridge.onMessage = { [weak self] message in self?.route(message, from: package) }
        bridges[package] = bridge
        return bridge
    }

    func showOnMusicScreen(top: String, main: String, playing: Bool, volumePercent: Int) {
        guard isPaired else { return }
        Task { await session.setMusicInfo(artist: top, title: main, playing: playing, volume: volumePercent * 15 / 100) }
    }

    func log(_ kind: LogKind, _ text: String) {
        append(kind, text)
    }
}

// MARK: - CBCentralManagerDelegate

extension WatchLink: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: bluetoothState = L("On", "Açık")
        case .poweredOff: bluetoothState = L("Off", "Kapalı")
        case .unauthorized: bluetoothState = L("Not allowed (Settings > this app > Bluetooth)", "İzin verilmedi (Ayarlar > bu uygulama > Bluetooth)")
        case .unsupported: bluetoothState = L("Not supported", "Desteklenmiyor")
        case .resetting: bluetoothState = L("Restarting", "Yeniden başlatılıyor")
        default: bluetoothState = L("Unknown", "Bilinmiyor")
        }
        append(.info, "Bluetooth: \(bluetoothState)")
        if central.state == .poweredOn { reconnectLastWatch() }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first else { return }
        peripheral = restored
        restored.delegate = self
        wantsConnection = true
        append(.info, L("iOS relaunched the app in the background for the watch", "iOS uygulamayı saat için arka planda yeniden açtı"))
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let rssi = RSSI.intValue == 127 ? nil : RSSI.intValue
        upsert(peripheral, name: name, rssi: rssi, systemConnected: false, advertisesHuawei: services.contains(huaweiService))
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        isConnecting = false
        let name = peripheral.name ?? L("Unnamed device", "İsimsiz cihaz")
        connectedName = name
        append(.success, L("Connected: \(name). Discovering services…", "Bağlandı: \(name). Servisler aranıyor…"))
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        isConnecting = false
        append(.error, L("Could not connect: ", "Bağlanamadı: ") + (error?.localizedDescription ?? L("unknown error", "bilinmeyen hata")))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        isConnecting = false
        let wasPairing = ![PairingStage.none, .channelReady].contains(pairingStage)
        resetConnectionState()
        if wasPairing { pairingStage = .connectionLost }
        if let error {
            append(.error, L("Connection lost: ", "Bağlantı koptu: ") + error.localizedDescription)
        } else {
            append(.info, L("Disconnected", "Bağlantı kesildi"))
        }
        if wantsConnection {
            append(.info, L("Trying to reconnect…", "Yeniden bağlanmaya çalışılıyor…"))
            self.peripheral = peripheral
            isConnecting = true
            central.connect(peripheral)
        } else {
            self.peripheral = nil
        }
    }
}

// MARK: - CBPeripheralDelegate

extension WatchLink: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            append(.error, L("Could not read services: ", "Servisler alınamadı: ") + error.localizedDescription)
            return
        }
        let services = peripheral.services ?? []
        append(.info, L("\(services.count) services: ", "\(services.count) servis bulundu: ") + services.map(\.uuid.uuidString).joined(separator: ", "))
        servicesAwaitingCharacteristics = services.count
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        servicesAwaitingCharacteristics -= 1
        if let error {
            append(.error, L("Could not read characteristics of \(service.uuid.uuidString): ", "\(service.uuid.uuidString) karakteristikleri alınamadı: ") + error.localizedDescription)
        }
        for c in service.characteristics ?? [] {
            append(.info, "  \(service.uuid.uuidString) / \(c.uuid.uuidString) [\(Self.describe(c.properties))]")
            guard service.uuid == huaweiService else { continue }
            if c.uuid == writeUUID {
                writeCharacteristic = c
            } else if c.uuid == notifyUUID {
                peripheral.setNotifyValue(true, for: c)
            }
        }

        if servicesAwaitingCharacteristics == 0 && !(peripheral.services ?? []).contains(where: { $0.uuid == huaweiService }) {
            append(.error, L("This device has no Huawei service (FE86). Is it the right device? The watch may not expose it over BLE.", "Bu cihazda Huawei servisi (FE86) yok. Doğru cihaz mı? Saat BLE üzerinden bu servisi açmıyor olabilir."))
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == notifyUUID else { return }
        if let error {
            append(.error, L("Could not open the notify channel: ", "Bildirim kanalı açılamadı: ") + error.localizedDescription)
            return
        }
        huaweiChannelReady = characteristic.isNotifying && writeCharacteristic != nil
        if huaweiChannelReady {
            pairingStage = .channelReady
            append(.success, L("Huawei channel ready. BLE write limit: \(maxWriteLength) bytes", "Huawei kanalı hazır. BLE yazma sınırı: \(maxWriteLength) bayt"))
            if hasSavedPairing && sharedWithOtherApp {
                append(.info, L("Saved pairing found, but another app is connected to the watch: not pairing automatically. Close Huawei Health, then tap Pair.",
                                "Kayıtlı eşleşme var ama saate başka bir uygulama bağlı: otomatik eşleşilmiyor. Huawei Health'i kapat, sonra Eşleş'e dokun."))
            } else if hasSavedPairing {
                append(.info, L("Saved pairing found, pairing automatically…", "Kayıtlı eşleşme var, otomatik eşleşiliyor…"))
                pair()
            } else {
                append(.info, L("Not paired yet. Start with 'Pair'.", "Henüz eşleşme yok. 'Eşleş' ile başla."))
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            append(.error, L("Write error: ", "Yazma hatası: ") + error.localizedDescription)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            append(.error, L("Read error: ", "Okuma hatası: ") + error.localizedDescription)
            return
        }
        guard let data = characteristic.value, characteristic.uuid == notifyUUID else { return }
        let bytes = [UInt8](data)
        append(.received, L("Raw data (\(bytes.count) bytes): ", "Ham veri (\(bytes.count) bayt): ") + Array(bytes.prefix(64)).hex + (bytes.count > 64 ? " …" : ""))

        for result in parser.feed(bytes) {
            switch result {
            case .success(let packet): handle(session.receive(packet))
            case .failure(let error): append(.error, error.description)
            }
        }
    }
}
