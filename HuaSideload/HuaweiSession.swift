import Foundation

enum HuaweiSessionError: Error, CustomStringConvertible {
    case timeout(String)
    case disconnected
    case notPaired
    case unsupported(String)

    var description: String {
        switch self {
        case .timeout(let label): return L("\(label): the watch did not answer (timeout)", "\(label): saat cevap vermedi (zaman aşımı)")
        case .disconnected: return L("Connection lost", "Bağlantı koptu")
        case .notPaired: return L("Pair with the watch first", "Önce eşleşmek gerekiyor")
        case .unsupported(let s): return L("Not supported: \(s)", "Desteklenmiyor: \(s)")
        }
    }
}

// The app's permanent identity towards the watch and the saved pairing keys
struct WatchStore {
    private let defaults = UserDefaults.standard

    // Same as Gadgetbridge's "androidID": 16 random bytes as upper-case hex
    var deviceId: [UInt8] {
        if let id = defaults.string(forKey: "deviceId") { return Array(id.utf8) }
        let id = HCrypto.random(16).hexCompact
        defaults.set(id, forKey: "deviceId")
        return Array(id.utf8)
    }

    // Pairing keys are in the Keychain (CredentialStore), moved there from UserDefaults by older builds on first read
    func authToken(for watch: String) -> [UInt8]? {
        CredentialStore.shared.string(CredentialStore.authTokenKey(watch)).flatMap { [UInt8](hex: $0) }
    }

    func setAuthToken(_ token: [UInt8]?, for watch: String) {
        CredentialStore.shared.set(token?.hexCompact, for: CredentialStore.authTokenKey(watch))
    }
}

// Request/response exchange with the watch, pairing and encryption
@MainActor
final class HuaweiSession {
    private struct Waiter {
        let id: UUID
        let serviceId: UInt8
        let commandId: UInt8
        let continuation: CheckedContinuation<HuaweiPacket, Error>
    }

    private(set) var link: LinkInfo?
    private(set) var isPaired = false
    private(set) var watchUDID: String?
    private var sessionKey: [UInt8]?
    private var waiters: [Waiter] = []
    private var notificationId: UInt16 = 0

    private struct Upload {
        let data: [UInt8]
        let sha256: [UInt8]
        let progress: (Double) -> Void
        let continuation: CheckedContinuation<Void, Error>
        var fileId: UInt8 = 0
        var unitSize = 0
        var encrypt = true
        var lastActivity = Date()
    }
    private var upload: Upload?

    // Post-upload trace (UploadTrace): from the last chunk on, every packet in and out is logged as service/command
    // and tag lengths, plus unhandled packets, so the log shows where the watch stops after a transfer
    private var traceUntil: Date?
    private var tracing: Bool { traceUntil.map { Date() < $0 } ?? false }

    func traceTraffic(for seconds: Double) {
        traceUntil = Date().addingTimeInterval(seconds)
    }

    func stopTrace() {
        traceUntil = nil
    }

    // The watch's 0x28/0x07 for the last upload: tag 0x02 (status) if it sent one
    private(set) var lastUploadResultStatus: Int?

    // P2P: replies are matched by sequence number (HuaweiBaseP2PService.waitPackets)
    private var p2pSequence: UInt16 = 1
    private var p2pWaiters: [UInt16: CheckedContinuation<P2P.Message, Error>] = [:]

    // The watch reports progress while installing an uploaded app (percent, 102 installed, 103 failed)
    var onAppInstallStatus: ((Int, String) -> Void)?

    // Pairing progress for the Watch tab (PairingStage); pair() reports up to .authenticated
    var onPairingStage: ((PairingStage) -> Void)?

    // The watch confirmed an uploaded watch face (0x27/0x05); the session has already answered it
    var onWatchFaceConfirm: ((WatchFaceService.ConfirmReport) -> Void)?

    // P2P data from apps on the watch (source package, data)
    var onAppMessage: ((String, [UInt8]) -> Void)?

    // The watch asks for the title and artist of an uploaded music file (index, file name)
    var onMusicFileInfo: ((Int, String) -> Void)?

    // Events from the watch's built-in music screen
    var onMusicScreenOpened: (() -> Void)?
    var onMusicButton: ((MusicControl.Button?, Int?) -> Void)?

    private let store = WatchStore()
    private let writeFrame: ([UInt8]) -> Void
    private let maxWriteLength: () -> Int
    private let log: (LogKind, String) -> Void

    init(writeFrame: @escaping ([UInt8]) -> Void, maxWriteLength: @escaping () -> Int, log: @escaping (LogKind, String) -> Void) {
        self.writeFrame = writeFrame
        self.maxWriteLength = maxWriteLength
        self.log = log
    }

    func reset() {
        finishUpload(HuaweiSessionError.disconnected)
        let p2p = p2pWaiters
        p2pWaiters.removeAll()
        p2p.values.forEach { $0.resume(throwing: HuaweiSessionError.disconnected) }
        link = nil
        isPaired = false
        sessionKey = nil
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.continuation.resume(throwing: HuaweiSessionError.disconnected) }
    }

    func hasAuthToken(for watch: String) -> Bool {
        store.authToken(for: watch) != nil
    }

    func forget(watch: String) {
        store.setAuthToken(nil, for: watch)
        isPaired = false
        sessionKey = nil
    }

    // MARK: - Incoming packets

    // Decrypts if needed and hands the packet to the waiting request. Returns the (decrypted) packet for logging.
    func receive(_ packet: HuaweiPacket) -> HuaweiPacket {
        var packet = packet
        logDiagnostics(packet)
        if packet.isEncrypted {
            if let tlv = packet.tlv, let key = sessionKey, let link,
               let iv = tlv.value(0x7D), let cipher = tlv.value(0x7E) {
                do {
                    let plain = link.usesGCM
                        ? try HCrypto.gcmOpen(cipher, key: key, nonce: iv)
                        : try HCrypto.cbcDecrypt(cipher, key: key, iv: iv)
                    packet = HuaweiPacket(serviceId: packet.serviceId, commandId: packet.commandId, body: plain)
                } catch {
                    log(.error, L("Could not decrypt a packet: \(error)", "Şifreli paket çözülemedi: \(error)"))
                }
            }
        }

        let waiterIndex = waiters.firstIndex(where: { $0.serviceId == packet.serviceId && $0.commandId == packet.commandId })
        if tracing {
            log(.info, UploadTrace.line("in", service: packet.serviceId, command: packet.commandId, tlv: packet.tlv, bodySize: packet.body.count)
                + (waiterIndex != nil ? L(" -> answer to our request", " -> isteğimize yanıt") : L(" -> sent by the watch", " -> saatin kendi mesajı")))
        }
        if let i = waiterIndex {
            waiters.remove(at: i).continuation.resume(returning: packet)
        } else {
            handleUnsolicited(packet)
        }
        return packet
    }

    // Requests started by the watch (AsynchronousResponse in Gadgetbridge); most are acknowledged with 0x7F = success
    private func handleUnsolicited(_ packet: HuaweiPacket) {
        if isPaired, packet.serviceId == FileUpload.serviceId, let tlv = packet.tlv {
            handleUpload(packet.commandId, tlv)
            return
        }
        if isPaired, packet.serviceId == P2P.serviceId, let tlv = packet.tlv, let message = P2P.parse(tlv) {
            handleP2P(message)
            return
        }
        if isPaired, packet.serviceId == 0x01, packet.commandId == PhoneInfo.commandId, let tlv = packet.tlv {
            guard let tags = PhoneInfo.requestedTags(tlv) else { return }
            send(0x01, PhoneInfo.commandId, PhoneInfo.answer(tags))
            log(.info, L("The watch asked for phone info; answered as Android 14", "Saat telefon bilgisi istedi; Android 14 dedik"))
            return
        }
        if isPaired, packet.serviceId == WatchApps.serviceId, packet.commandId == WatchApps.installStatusCommand, let tlv = packet.tlv {
            let status = tlv.int(0x01) ?? -1
            let package = tlv.value(0x02).map { String(decoding: $0, as: UTF8.self) } ?? ""
            onAppInstallStatus?(status, package)
            return
        }
        // The watch stored an uploaded watch face and asks for confirmation (AsynchronousResponse.handleWatchface)
        if isPaired, packet.serviceId == WatchFaceService.serviceId, packet.commandId == WatchFaceService.confirmCommand,
           let tlv = packet.tlv, let report = WatchFaceService.parseConfirm(tlv) {
            send(WatchFaceService.serviceId, WatchFaceService.confirmCommand, WatchFaceService.confirmReply(fileName: report.fileName))
            log(.info, L("The watch confirmed watch face \(report.fileName) (report type \(report.reportType)); confirmation sent",
                         "Saat \(report.fileName) kadranını onayladı (bildirim türü \(report.reportType)); onay gönderildi"))
            onWatchFaceConfirm?(report)
            return
        }
        guard isPaired, packet.serviceId == MusicControl.serviceId, let tlv = packet.tlv else {
            logUnhandled(packet)
            return
        }
        switch packet.commandId {
        case MusicControl.statusCommand:
            if let status = tlv.int(0x7F), status != HuaweiPacket.resultSuccess { return }
            send(MusicControl.serviceId, MusicControl.statusCommand, MusicControl.ack())
            onMusicScreenOpened?()
        case MusicControl.uploadInfoCommand:
            let index = tlv.int(0x01) ?? 0
            let name = tlv.value(0x02).map { String(decoding: $0, as: UTF8.self) } ?? ""
            onMusicFileInfo?(index, name)
        case MusicControl.controlCommand:
            let raw = tlv.value(0x01)?.last
            let volume = tlv.value(0x02)?.last.map(Int.init)
            guard raw != nil || volume != nil else { return }
            send(MusicControl.serviceId, MusicControl.controlCommand, MusicControl.ack())
            onMusicButton?(raw.flatMap(MusicControl.Button.init(rawValue:)), volume)
        default:
            logUnhandled(packet)
        }
    }

    // Diagnostics, off by default: log unsolicited packets that nothing handles, e.g. to find out whether a button on
    // the watch sends anything. A feature turns it on with the UserDefaults key "HuaSideloadLogUnhandledPackets".
    private func logUnhandled(_ packet: HuaweiPacket) {
        guard tracing || UserDefaults.standard.bool(forKey: "HuaSideloadLogUnhandledPackets") else { return }
        let tags = packet.tlv?.items.map { item in
            String(format: "%02X=", item.tag) + (item.value.count <= 8 ? item.value.map { String(format: "%02X", $0) }.joined() : "\(item.value.count)B")
        }.joined(separator: " ") ?? "\(packet.body.count)B"
        log(.info, String(format: L("Unhandled packet from the watch: service 0x%02X, command 0x%02X", "Saatten işlenmeyen paket: servis 0x%02X, komut 0x%02X"),
                          packet.serviceId, packet.commandId) + " [\(tags)]")
    }

    // Pairing diagnostics, off by default (Log tab toggle, UserDefaults key "HuaSideloadPairingDiagnostics"): header,
    // TLV tags with lengths only, and the session state. Never logs values, so no keys, IVs, PIN, UDID or MAC.
    nonisolated static let diagnosticsKey = "HuaSideloadPairingDiagnostics"
    private var diagnostics: Bool { UserDefaults.standard.bool(forKey: Self.diagnosticsKey) }

    private func logDiagnostics(_ packet: HuaweiPacket) {
        guard diagnostics else { return }
        let tags = packet.tlv?.items.map { String(format: "%02X:%d", $0.tag, $0.value.count) }.joined(separator: " ") ?? "not TLV"
        let waiting = waiters.map { String(format: "0x%02X/0x%02X", $0.serviceId, $0.commandId) }.joined(separator: ", ")
        var line = String(format: "Diag in: service 0x%02X, command 0x%02X", packet.serviceId, packet.commandId)
        line += ", body \(packet.body.count) B, tags [\(tags)], encrypted \(packet.isEncrypted ? "yes" : "no")"
        line += ", session key \(sessionKey == nil ? "no" : "yes"), paired \(isPaired ? "yes" : "no")"
        line += ", waiting for [\(waiting.isEmpty ? "-" : waiting)], last request: \(lastRequest)"
        if packet.isEncrypted && sessionKey == nil {
            line += " -> not decrypted: no session key on this connection yet"
        }
        log(.info, line)
    }

    private var lastRequest = "-"

    // MARK: - Sending

    // Fire and forget (acknowledgements and updates)
    func send(_ serviceId: UInt8, _ commandId: UInt8, _ tlv: HuaweiTLV, encrypted: Bool = true) {
        if tracing { log(.info, UploadTrace.line("out", service: serviceId, command: commandId, tlv: tlv, bodySize: 0)) }
        do {
            try frames(serviceId, commandId, tlv, encrypted: encrypted, sliced: false).forEach(writeFrame)
        } catch {
            log(.error, L("Could not send: \(error)", "Gönderilemedi: \(error)"))
        }
    }

    func request(_ serviceId: UInt8, _ commandId: UInt8, _ tlv: HuaweiTLV, label: String,
                 encrypted: Bool = true, sliced: Bool = false, timeout: Double = 10, quiet: Bool = false) async throws -> HuaweiPacket {
        let frames = try frames(serviceId, commandId, tlv, encrypted: encrypted, sliced: sliced)
        lastRequest = String(format: "0x%02X/0x%02X ", serviceId, commandId) + label
        if tracing { log(.info, UploadTrace.line("out", service: serviceId, command: commandId, tlv: tlv, bodySize: 0) + " (\(label))") }
        if !quiet {
            let size = frames.reduce(0) { $0 + $1.count }
            let encryptedNote = encrypted ? L(" (encrypted)", " (şifreli)") : ""
            let partsNote = frames.count > 1 ? L(", \(frames.count) parts", ", \(frames.count) parça") : ""
            log(.sent, "\(label)\(encryptedNote): \(size) \(L("bytes", "bayt"))\(partsNote)")
        }

        return try await withCheckedThrowingContinuation { continuation in
            let id = UUID()
            waiters.append(Waiter(id: id, serviceId: serviceId, commandId: commandId, continuation: continuation))
            frames.forEach(writeFrame)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard let self, let i = self.waiters.firstIndex(where: { $0.id == id }) else { return }
                self.waiters.remove(at: i).continuation.resume(throwing: HuaweiSessionError.timeout(label))
            }
        }
    }

    private func frames(_ serviceId: UInt8, _ commandId: UInt8, _ tlv: HuaweiTLV, encrypted: Bool, sliced: Bool) throws -> [[UInt8]] {
        let body = encrypted ? try encryptRaw(tlv.serialize()) : tlv.serialize()
        if sliced {
            return HuaweiPacket.serializeSliced(serviceId: serviceId, commandId: commandId, body: body, sliceSize: sliceSize)
        }
        return [HuaweiPacket.serialize(serviceId: serviceId, commandId: commandId, body: body)]
    }

    private var sliceSize: Int { min(link?.sliceSize ?? 0xF4, maxWriteLength()) }

    // HuaweiTLV.encryptRaw: encrypts raw bytes and wraps them in a 7C/7D/7E TLV
    private func encryptRaw(_ bytes: [UInt8]) throws -> [UInt8] {
        guard let key = sessionKey, let link else { throw HuaweiSessionError.notPaired }
        let iv = HCrypto.random(16)
        let cipher = link.usesGCM
            ? try HCrypto.gcmSeal(bytes, key: key, nonce: iv)
            : try HCrypto.cbcEncrypt(bytes, key: key, iv: iv)
        return HuaweiTLV().with(0x7C, [0x01]).with(0x7D, iv).with(0x7E, cipher).serialize()
    }

    // MARK: - Pairing

    // HuaweiSupportProvider: LinkParams -> SecurityNegotiation -> (PinCode + HiChain op 1) -> HiChain op 2
    func pair(watch: String) async throws {
        isPaired = false
        sessionKey = nil
        onPairingStage?(.negotiating)

        let linkResponse = try await request(LinkParams.serviceId, LinkParams.commandId,
                                             HuaweiTLV().with(0x01).with(0x02).with(0x03).with(0x04),
                                             label: L("1/4 Link parameters", "1/4 Bağlantı parametreleri"), encrypted: false)
        guard let linkTLV = linkResponse.tlv else { throw HuaweiAuthError.unexpected("LinkParams TLV") }
        let link = LinkInfo(linkTLV)
        self.link = link
        log(.info, "Auth \(link.authVersion), support type \(link.deviceSupportType), \(link.usesGCM ? "AES-GCM" : "AES-CBC")")
        if diagnostics {
            log(.info, "Diag link: protocol \(link.protocolVersion), slice \(link.sliceSize), mtu \(link.mtu), auth version \(link.authVersion), "
                + "support type \(link.deviceSupportType), auth algo \(link.authAlgo), bond state \(link.bondState), encrypt method \(link.encryptMethod)")
        }

        guard [1, 2, 3, 4].contains(link.deviceSupportType) else {
            throw HuaweiSessionError.unsupported(L("pairing without HiChain (support type \(link.deviceSupportType))",
                                                   "HiChain'siz eşleşme (destek tipi \(link.deviceSupportType))"))
        }
        let deviceId = store.deviceId
        let negotiation = try await request(0x01, SecurityNegotiation.commandId,
                                            SecurityNegotiation.request(authMode: link.deviceSupportType == 4 ? 0x04 : 0x02,
                                                                        deviceId: deviceId, phoneModel: PhoneInfo.phoneModel,
                                                                        encryptMethod: link.encryptMethod),
                                            label: L("2/4 Security negotiation", "2/4 Güvenlik müzakeresi"), encrypted: false)
        guard let negotiationTLV = negotiation.tlv else { throw HuaweiAuthError.unexpected("SecurityNegotiation TLV") }
        // The watch sends its UDID (needed for debug profiles) in tag 0x05 as ASCII hex
        if let udid = negotiationTLV.value(0x05), udid.count == 64 {
            watchUDID = String(decoding: udid, as: UTF8.self)
            log(.info, L("Got the watch UDID (see Status)", "Saatin UDID'si alındı (Durum bölümünde)"))
        }
        let authType = SecurityNegotiation.authType(negotiationTLV)
        log(.info, String(format: L("Pairing type requested by the watch: 0x%X", "Saatin istediği eşleşme türü: 0x%X"), authType))
        guard SecurityNegotiation.isHiChain(authType) else {
            throw HuaweiSessionError.unsupported(String(format: L("HiChain Lite (type 0x%X) is not implemented yet",
                                                                  "HiChain Lite (tür 0x%X) henüz yazılmadı"), authType))
        }

        var authToken = store.authToken(for: watch)
        if authToken == nil {
            let pinResponse = try await request(0x01, PinCode.commandId, HuaweiTLV().with(0x01),
                                                label: L("3/4 PIN request", "3/4 PIN isteği"), encrypted: false)
            guard let pinTLV = pinResponse.tlv else { throw HuaweiAuthError.unexpected("PIN TLV") }
            let pin = try PinCode.decrypt(pinTLV, link: link)
            log(.success, L("PIN decrypted (\(pin.count) bytes)", "PIN çözüldü (\(pin.count) bayt)"))
            log(.info, L("⌚ If the watch asks for confirmation, ACCEPT it (60 s)", "⌚ Saatin ekranında onay çıkarsa ONAYLA (60 sn)"))
            onPairingStage?(.pinProcessed)

            onPairingStage?(.hiChain)
            let token = try await hiChain(operation: 1, key: HCrypto.sha256(Array(pin.hexCompact.utf8)), deviceId: deviceId)
            authToken = token
            log(.success, L("Permanent pairing key received", "Kalıcı eşleşme anahtarı alındı"))
        } else {
            log(.info, L("3/4 Saved pairing key found, PIN step skipped", "3/4 Kayıtlı eşleşme anahtarı var, PIN adımı atlandı"))
            onPairingStage?(.hiChain)
        }

        sessionKey = try await hiChain(operation: 2, key: authToken!, deviceId: deviceId)
        // Saved only now: a key from a handshake that did not finish would make every reconnect fail
        if store.authToken(for: watch) == nil {
            store.setAuthToken(authToken, for: watch)
            log(.success, L("Pairing key saved", "Eşleşme anahtarı kaydedildi"))
        }
        isPaired = true
        onPairingStage?(.authenticated)
        log(.success, L("HiChain finished: the connection to the watch is encrypted. Finishing setup…",
                        "HiChain bitti: saatle bağlantı şifreli. Kurulum tamamlanıyor…"))
    }

    // GetHiChainRequest: op 1 returns the permanent key (authToken), op 2 the session key
    private func hiChain(operation: UInt8, key: [UInt8], deviceId: [UInt8]) async throws -> [UInt8] {
        let message = HiChainMessage(operationCode: operation, requestId: UInt64(Date().timeIntervalSince1970 * 1000), selfAuthId: deviceId)
        let name = operation == 1 ? L("4/4 HiChain authentication", "4/4 HiChain doğrulama") : L("4/4 HiChain binding", "4/4 HiChain bağlama")
        let step = L("step", "adım")
        let seed = HCrypto.random(32)
        let randSelf = HCrypto.random(16)

        // Step 1: send salt and seed, verify the watch's token
        let first = try await hiChainStep(message.stepOne(isoSalt: randSelf, seed: seed), label: "\(name) \(step) 1",
                                          timeout: operation == 1 ? 60 : 10)
        guard case .step(1, let payload1) = first else { throw HuaweiAuthError.unexpected("\(name) \(step) 1: \(first)") }
        let randPeer = try HiChainMessage.hexField(payload1, "isoSalt")
        let authIdPeer = try HiChainMessage.hexField(payload1, "peerAuthId")
        let peerToken = try HiChainMessage.hexField(payload1, "token")

        let psk = HCrypto.hmac(key: key, seed)
        guard HCrypto.hmac(key: psk, randPeer + randSelf + deviceId + authIdPeer) == peerToken else {
            throw HuaweiAuthError.tokenMismatch(operation == 1
                ? L("the PIN may have been decrypted wrong", "PIN yanlış çözülmüş olabilir")
                : L("the saved key is no longer valid; tap 'Forget pairing' and pair again", "kayıtlı anahtar geçersiz; 'Eşleşmeyi unut' deyip tekrar dene"))
        }
        log(.success, L("\(name): the watch's token is valid", "\(name): saatin jetonu doğrulandı"))

        // Step 2: send our token
        let selfToken = HCrypto.hmac(key: psk, randSelf + randPeer + authIdPeer + deviceId)
        let second = try await hiChainStep(message.stepTwo(token: selfToken), label: "\(name) \(step) 2")
        guard case .step(2, let payload2) = second else { throw HuaweiAuthError.unexpected("\(name) \(step) 2: \(second)") }
        guard try HiChainMessage.hexField(payload2, "returnCodeMac") == HCrypto.hmac(key: psk, [0, 0, 0, 0]) else {
            throw HuaweiAuthError.tokenMismatch("returnCodeMac")
        }

        let salt = randSelf + randPeer
        let isoKey = HCrypto.hkdf(psk, salt: salt, info: "hichain_iso_session_key", count: 32)

        // Step 3 (op 1 only): receive the permanent key
        var authToken: [UInt8]?
        if operation == 1 {
            let nonce = HCrypto.random(12)
            let challenge = HCrypto.random(16)
            let encData = try HCrypto.gcmSeal(challenge, key: isoKey, nonce: nonce, aad: Array("hichain_iso_exchange".utf8))
            let third = try await hiChainStep(message.stepThree(nonce: nonce, encData: encData), label: "\(name) \(step) 3")
            guard case .step(3, let payload3) = third else { throw HuaweiAuthError.unexpected("\(name) \(step) 3: \(third)") }
            authToken = try HCrypto.gcmOpen(try HiChainMessage.hexField(payload3, "encAuthToken"), key: isoKey,
                                            nonce: try HiChainMessage.hexField(payload3, "nonce"), aad: challenge)
        }

        // Step 4: report the result
        let nonce = HCrypto.random(12)
        let encResult = try HCrypto.gcmSeal([0, 0, 0, 0], key: isoKey, nonce: nonce, aad: Array("hichain_iso_result".utf8))
        let fourth = try await hiChainStep(message.stepFour(nonce: nonce, encResult: encResult), label: "\(name) \(step) 4")
        guard case .finished = fourth else { throw HuaweiAuthError.unexpected("\(name) \(step) 4: \(fourth)") }

        if let authToken { return authToken }
        return HCrypto.hkdf(isoKey, salt: salt, info: "hichain_return_key", count: 32)
    }

    private func hiChainStep(_ tlv: HuaweiTLV, label: String, timeout: Double = 10) async throws -> HiChainMessage.Response {
        let response = try await request(0x01, HiChainMessage.commandId, tlv, label: label, encrypted: false, sliced: true, timeout: timeout)
        guard let responseTLV = response.tlv else { throw HuaweiAuthError.unexpected("\(label): no TLV") }
        return try HiChainMessage.parseResponse(responseTLV) { summary, adjusted in
            if adjusted || diagnostics { log(.info, "HiChain reply (\(label)): \(summary)") }
        }
    }

    // MARK: - Commands after pairing

    func batteryLevel() async throws -> Int {
        let response = try await request(0x01, 0x08, HuaweiTLV().with(0x01), label: L("Battery level", "Pil seviyesi"))
        guard let level = response.tlv?.int(0x01) else { throw HuaweiAuthError.unexpected("battery 0x01") }
        return level
    }

    func productInfo() async throws -> [String] {
        let response = try await request(0x01, ProductInfo.commandId, ProductInfo.request(), label: L("Watch info", "Saat bilgisi"))
        guard let tlv = response.tlv else { throw HuaweiAuthError.unexpected("ProductInfo TLV") }
        return ProductInfo.describe(tlv)
    }

    func appPlatform() async throws -> HuaweiTLV {
        let response = try await request(WatchApps.serviceId, WatchApps.paramsCommand, HuaweiTLV().with(0x81), label: L("App platform", "Uygulama platformu"))
        guard let tlv = response.tlv else { throw HuaweiAuthError.unexpected("AppInfoParams TLV") }
        return tlv
    }

    func installedApps() async throws -> [WatchApps.Installed] {
        let response = try await request(WatchApps.serviceId, WatchApps.listCommand, HuaweiTLV().with(0x81), label: L("Installed apps", "Kurulu uygulamalar"))
        guard let tlv = response.tlv else { throw HuaweiAuthError.unexpected("AppNames TLV") }
        return WatchApps.installed(tlv)
    }

    // The watch may not answer (Gadgetbridge doesn't wait either); the app list tells us the result
    func deleteApp(_ package: String) async throws {
        do {
            let response = try await request(WatchApps.serviceId, WatchApps.deleteCommand, WatchApps.delete(package: package),
                                             label: L("Delete app (\(package))", "Uygulama sil (\(package))"), timeout: 6)
            if let code = response.resultCode, code != HuaweiPacket.resultSuccess {
                throw HuaweiAuthError.watchError(String(format: L("delete refused: 0x%X", "silme reddedildi: 0x%X"), code))
            }
        } catch HuaweiSessionError.timeout {
        }
    }

    // MARK: - Diagnostics (DeviceConfig.SupportedCommands 0x03, ExpandCapability 0x37; MusicInfoParams 0x25/0x04)

    // Returns which of the asked commands the watch supports, per service
    func supportedCommands(_ asked: [(service: UInt8, commands: [UInt8])]) async throws -> [UInt8: [UInt8]] {
        var inner = HuaweiTLV()
        for entry in asked { inner = inner.with(0x02, [entry.service]).with(0x03, entry.commands) }
        let response = try await request(0x01, 0x03, HuaweiTLV().with(0x81, inner.serialize()), label: L("Supported commands", "Desteklenen komutlar"))
        guard let outer = response.tlv?.value(0x81), let container = try? HuaweiTLV.parse(outer) else {
            throw HuaweiAuthError.unexpected("SupportedCommands: \(response.tlv?.description ?? "-")")
        }
        var result: [UInt8: [UInt8]] = [:]
        var service: UInt8?
        for item in container.items {
            if item.tag == 0x02 {
                service = item.value.first
            } else if item.tag == 0x04, let current = service, let commands = asked.first(where: { $0.service == current })?.commands {
                result[current] = item.value.enumerated().compactMap { $0.element == 1 && $0.offset < commands.count ? commands[$0.offset] : nil }
            }
        }
        return result
    }

    func expandCapabilities() async throws -> [UInt8] {
        let response = try await request(0x01, 0x37, HuaweiTLV().with(0x01), label: L("Extended capabilities", "Genişletilmiş yetenekler"))
        return response.tlv?.value(0x01) ?? []
    }

    // MARK: - Watch faces (WatchFaceService, service 0x27)

    func watchFaceParams() async throws -> WatchFaceService.DeviceParams? {
        let response = try await request(WatchFaceService.serviceId, WatchFaceService.paramsCommand, WatchFaceService.paramsRequest(),
                                         label: L("Watch face parameters", "Kadran parametreleri"), timeout: 6)
        return response.tlv.flatMap(WatchFaceService.parseParams)
    }

    func installedWatchFaces() async throws -> [WatchFaceService.Installed] {
        let response = try await request(WatchFaceService.serviceId, WatchFaceService.listCommand, WatchFaceService.listRequest(),
                                         label: L("Watch faces on the watch", "Saatteki kadranlar"), timeout: 8)
        return response.tlv.map(WatchFaceService.parseList) ?? []
    }

    // Returns the watch's result code, nil when it sent none
    func activateWatchFace(fileName: String) async throws -> Int? {
        let response = try await request(WatchFaceService.serviceId, WatchFaceService.operationCommand,
                                         WatchFaceService.operation(fileName: fileName, WatchFaceService.activate),
                                         label: L("Make the watch face active", "Kadranı etkinleştir"), timeout: 8)
        return response.resultCode
    }

    // MARK: - Setup after HiChain (PairingSetup)

    struct SetupResult {
        var sent: [String] = []
        var skipped: [String] = []
        var failed: [String] = []
    }

    // Runs after every successful HiChain, like Gadgetbridge. A step the watch rejects or does not answer is reported
    // and the others still go out (Gadgetbridge also moves on after a timeout). The account ID is never logged.
    func completeSetup(watchName: String, accountId: String) async -> SetupResult {
        var result = SetupResult()
        func record(_ name: String, _ outcome: Result<HuaweiPacket, Error>) {
            switch outcome {
            case .success(let response):
                if let code = response.resultCode, code != HuaweiPacket.resultSuccess {
                    result.failed.append(String(format: "%@ (0x%X)", name, code))
                } else {
                    result.sent.append(name)
                }
            case .failure(let error):
                result.failed.append("\(name) (\(error))")
            }
        }
        func send(_ name: String, _ service: UInt8, _ command: UInt8, _ tlv: HuaweiTLV) async -> Result<HuaweiPacket, Error> {
            do {
                return .success(try await request(service, command, tlv, label: name, timeout: 6))
            } catch {
                return .failure(error)
            }
        }

        let timeName = L("Set time", "Saati ayarla")
        record(timeName, await send(timeName, PairingSetup.deviceConfig, PairingSetup.timeCommand,
                                    PairingSetup.time(Date(), timeZone: .current)))

        var support = PairingSetup.Support()
        do {
            support.commands = try await supportedCommands(PairingSetup.commandQuery)
        } catch {
            result.failed.append(L("Supported commands", "Desteklenen komutlar") + " (\(error))")
        }
        if support.asksExpandCapabilities {
            support.expandCapabilities = (try? await expandCapabilities()) ?? []
        }
        if diagnostics {
            log(.info, "Diag setup: account \(support.sendsAccount ? "yes" : "no"), agreements \(support.sendsAgreements ? "yes" : "no"), "
                + "setup status \(support.sendsSetUpStatus ? "yes" : "no"), diff-account pairing \(support.diffAccountPairing ? "yes" : "no"), "
                + "account ID given \(accountId.isEmpty ? "no" : "yes")")
        }

        let accountName = L("Huawei account", "Huawei hesabı")
        if support.sendsAccount {
            record(accountName, await send(accountName, PairingSetup.accountService, PairingSetup.extendedAccountCommand,
                                           PairingSetup.extendedAccount(accountId, diffAccountPairing: support.diffAccountPairing)))
        } else {
            result.skipped.append(accountName)
        }

        let agreementsName = L("Agreements", "Sözleşmeler")
        if support.sendsAgreements {
            record(agreementsName, await send(agreementsName, PairingSetup.deviceConfig, PairingSetup.acceptAgreementCommand,
                                              PairingSetup.acceptAgreements(Date())))
        } else {
            result.skipped.append(agreementsName)
        }

        let statusName = L("Setup status", "Kurulum durumu")
        if support.sendsSetUpStatus {
            record(statusName, await send(statusName, PairingSetup.deviceConfig, PairingSetup.setUpDeviceStatusCommand,
                                          PairingSetup.setUpDeviceStatus(watchName: watchName)))
        } else {
            result.skipped.append(statusName)
        }
        return result
    }

    func musicStorage() async throws -> MusicControl.Storage {
        let response = try await request(MusicControl.serviceId, MusicControl.storageCommand,
                                         HuaweiTLV().with(0x01).with(0x02).with(0x03).with(0x04).with(0x05),
                                         label: L("Watch music storage", "Saatin müzik hafızası"))
        guard let tlv = response.tlv else { throw HuaweiAuthError.unexpected("MusicInfoParams TLV") }
        return MusicControl.storage(tlv)
    }

    func rawRequest(_ service: UInt8, _ command: UInt8, _ tlv: HuaweiTLV, label: String) async throws -> HuaweiTLV? {
        try await request(service, command, tlv, label: label, timeout: 6).tlv
    }

    func supportedServices() async throws -> [UInt8] {
        let response = try await request(0x01, SupportedServices.commandId, SupportedServices.request(), label: L("Supported services", "Desteklenen servisler"))
        guard let tlv = response.tlv else { throw HuaweiAuthError.unexpected("SupportedServices TLV") }
        return SupportedServices.supported(tlv)
    }

    // Updates the two lines and the play/pause icon on the watch's music screen
    func setMusicInfo(artist: String, title: String, playing: Bool, volume: Int = 8, maxVolume: Int = 15) async {
        let tlv = MusicControl.info(artist: artist, title: title, playing: playing,
                                    volume: UInt8(clamping: volume), maxVolume: UInt8(clamping: maxVolume))
        do {
            let response = try await request(MusicControl.serviceId, MusicControl.infoCommand, tlv,
                                             label: L("Music screen", "Müzik ekranı"), timeout: 3, quiet: true)
            if let code = response.resultCode, code != HuaweiPacket.resultSuccess {
                log(.error, String(format: L("Music screen not updated, watch code 0x%X", "Müzik ekranı güncellenemedi, saat kodu 0x%X"), code))
            }
        } catch {
            log(.error, L("Music screen: \(error)", "Müzik ekranı: \(error)"))
        }
    }

    // Uploads a file to the watch (app: type 6, name "<package>_INSTALL"; music: type 2). The watch drives the flow.
    func uploadFile(_ data: [UInt8], name: String, type: UInt8, to addressee: FileUpload.Addressee? = nil,
                    progress: @escaping (Double) -> Void) async throws {
        guard upload == nil else { throw HuaweiAuthError.unexpected(L("another upload is running", "zaten bir yükleme sürüyor")) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            upload = Upload(data: data, sha256: HCrypto.sha256(data), progress: progress, continuation: continuation)
            lastUploadResultStatus = nil
            Task {
                do {
                    let response = try await request(FileUpload.serviceId, FileUpload.Command.info,
                                                     FileUpload.info(fileName: name, size: data.count, type: type, to: addressee),
                                                     label: L("File info (\(name), \(data.count) bytes)", "Dosya bilgisi (\(name), \(data.count) bayt)"))
                    if let result = response.tlv?.int(0x7F), result != FileUpload.success {
                        finishUpload(HuaweiAuthError.watchError(FileUpload.describe(error: result)))
                    }
                } catch {
                    finishUpload(error)
                }
            }
            watchUploadTimeout()
        }
    }

    private func finishUpload(_ error: Error?) {
        guard let current = upload else { return }
        upload = nil
        if let error {
            current.continuation.resume(throwing: error)
        } else {
            current.continuation.resume()
        }
    }

    // Give up if the watch asks for nothing for 30 s
    private func watchUploadTimeout() {
        Task { [weak self] in
            while let self, let current = self.upload {
                try? await Task.sleep(for: .seconds(5))
                if Date().timeIntervalSince(current.lastActivity) > 30 {
                    self.finishUpload(HuaweiSessionError.timeout(L("File upload", "Dosya yükleme")))
                    return
                }
            }
        }
    }

    private func handleUpload(_ command: UInt8, _ tlv: HuaweiTLV) {
        guard var current = upload else { return }
        current.lastActivity = Date()
        switch command {
        case FileUpload.Command.hash:
            current.fileId = tlv.value(0x01)?.first ?? 0
            upload = current
            log(.info, L("The watch asked for the hash (file \(current.fileId))", "Saat hash istedi (dosya no \(current.fileId))"))
            send(FileUpload.serviceId, FileUpload.Command.hash, FileUpload.hash(fileId: current.fileId, sha256: current.sha256))
        case FileUpload.Command.consult:
            current.unitSize = tlv.int(0x05) ?? 0
            let noEncrypt = tlv.int(0x09) == 1
            current.encrypt = !noEncrypt
            upload = current
            log(.info, L("Upload parameters: unit \(current.unitSize) bytes, encrypted \(current.encrypt ? "yes" : "no")",
                         "Yükleme parametreleri: birim \(current.unitSize) bayt, şifreli \(current.encrypt ? "evet" : "hayır")"))
            send(FileUpload.serviceId, FileUpload.Command.consult, FileUpload.consultAck(fileId: current.fileId, noEncrypt: noEncrypt))
        case FileUpload.Command.chunkParams:
            let offset = tlv.int(0x02) ?? 0
            let size = tlv.int(0x03) ?? 0
            upload = current
            guard offset < current.data.count, size > 0, current.unitSize > 0 else {
                log(.error, L("Invalid chunk request: offset \(offset), size \(size)", "Geçersiz parça isteği: konum \(offset), boyut \(size)"))
                return
            }
            let slice = current.data[offset..<min(offset + size, current.data.count)]
            do {
                for payload in FileUpload.chunkPayloads(slice, offset: offset, unitSize: current.unitSize, fileId: current.fileId) {
                    let body = current.encrypt ? try encryptRaw(payload) : payload
                    HuaweiPacket.serializeSliced(serviceId: FileUpload.serviceId, commandId: FileUpload.Command.chunk,
                                                 body: body, sliceSize: sliceSize).forEach(writeFrame)
                }
            } catch {
                finishUpload(error)
                return
            }
            current.progress(Double(offset + slice.count) / Double(current.data.count))
            if offset + slice.count >= current.data.count {
                traceTraffic(for: 150)
                log(.info, L("Last chunk sent: offset \(offset), \(slice.count) bytes (file \(current.fileId), \(current.data.count) bytes in all). Tracing the watch's replies…",
                             "Son parça gönderildi: konum \(offset), \(slice.count) bayt (dosya \(current.fileId), toplam \(current.data.count) bayt). Saatin yanıtları izleniyor…"))
            }
        case FileUpload.Command.result:
            // Gadgetbridge (FileUploadResult) answers 0x7F = success + file id and does not read the status; it is
            // logged here so a rejection by the watch is visible
            lastUploadResultStatus = tlv.int(0x02)
            let status = lastUploadResultStatus.map(String.init) ?? L("none", "yok")
            log(.info, L("Watch upload result 0x28/0x07: file \(tlv.value(0x01)?.first.map(String.init) ?? "?"), status \(status)",
                         "Saatin yükleme sonucu 0x28/0x07: dosya \(tlv.value(0x01)?.first.map(String.init) ?? "?"), durum \(status)"))
            send(FileUpload.serviceId, FileUpload.Command.result, FileUpload.complete(fileId: current.fileId))
            current.progress(1)
            log(.success, L("The watch received the whole file; result acknowledged", "Saat dosyayı tamamen aldı; sonuç onaylandı"))
            finishUpload(nil)
        case FileUpload.Command.deviceError:
            let code = tlv.int(0x7F) ?? -1
            log(.error, L("Watch upload error 0x28/0x08: code \(code)", "Saatin yükleme hatası 0x28/0x08: kod \(code)"))
            finishUpload(HuaweiAuthError.watchError(FileUpload.describe(error: code)))
        default:
            upload = current
        }
    }

    // MARK: - P2P (messaging with apps on the watch)

    func p2p(kind: UInt8, source: String, destination: String, sourceFingerprint: String? = nil,
             destinationFingerprint: String? = nil, data: [UInt8]? = nil, timeout: Double = 5) async throws -> P2P.Message {
        p2pSequence = p2pSequence % 32_766 + 1
        let sequence = p2pSequence
        let tlv = P2P.request(kind: kind, sequence: sequence, source: source, destination: destination,
                              sourceFingerprint: sourceFingerprint, destinationFingerprint: destinationFingerprint, data: data)
        let frames = try frames(P2P.serviceId, P2P.commandId, tlv, encrypted: true, sliced: true)
        return try await withCheckedThrowingContinuation { continuation in
            p2pWaiters[sequence] = continuation
            frames.forEach(writeFrame)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.p2pWaiters.removeValue(forKey: sequence)?.resume(throwing: HuaweiSessionError.timeout("P2P \(destination)"))
            }
        }
    }

    private func handleP2P(_ message: P2P.Message) {
        // A data message started by the watch may carry the same sequence number as one of our pending requests; it is not a reply
        if message.kind != P2P.Kind.data, let waiter = p2pWaiters.removeValue(forKey: message.sequence) {
            waiter.resume(returning: message)
            return
        }
        // Ping/data started by the watch: acknowledge like HuaweiBaseP2PService.handlePacket
        guard message.kind == P2P.Kind.ping || message.kind == P2P.Kind.data else { return }
        let code = message.kind == P2P.Kind.ping ? P2P.Code.pingReply : P2P.Code.ok
        send(P2P.serviceId, P2P.commandId, P2P.request(kind: P2P.Kind.ack, sequence: message.sequence,
                                                       source: message.destination, destination: message.source, code: code))
        if message.kind == P2P.Kind.data, let data = message.data, let onAppMessage {
            onAppMessage(message.source, data)
        } else {
            log(.info, "P2P \(message.kind == P2P.Kind.ping ? "ping" : "data"): \(message.source) -> \(message.destination)")
        }
    }

    func sendNotification(title: String, text: String, appId: String? = Bundle.main.bundleIdentifier) async throws {
        notificationId &+= 1
        let tlv = WatchNotification.request(id: notificationId, title: title, sender: AppInfo.displayName, text: text, appId: appId)
        do {
            let response = try await request(WatchNotification.serviceId, WatchNotification.commandId, tlv,
                                             label: L("Notification", "Bildirim"), timeout: 5)
            if let code = response.resultCode, code != HuaweiPacket.resultSuccess {
                throw HuaweiAuthError.watchError(String(format: L("notification result 0x%X", "bildirim sonuç kodu 0x%X"), code))
            }
        } catch HuaweiSessionError.timeout {
            // Some watches never answer notifications; treat as sent
        }
    }
}
