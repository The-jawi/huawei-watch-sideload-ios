import Foundation

// Where pairing stands, for the Watch tab. "Paired" only after HiChain finished AND the watch accepted every setup
// step it asked for; an encrypted connection or watch info on screen alone is not a finished pairing.
enum PairingStage: Equatable {
    case none
    case channelReady
    case negotiating            // link parameters and security negotiation
    case pinProcessed
    case hiChain                // HiChain authentication / binding in progress
    case authenticated          // HiChain finished, the connection is encrypted
    case finishingSetup         // PairingSetup messages going out
    case paired
    case setupIncomplete(String)
    case failed(String)
    case connectionLost

    var isFullyPaired: Bool { self == .paired }

    var label: String {
        switch self {
        case .none: return L("None", "Yok")
        case .channelReady: return L("Channel ready, not paired", "Kanal hazır, eşleşilmedi")
        case .negotiating: return L("Negotiating security…", "Güvenlik müzakere ediliyor…")
        case .pinProcessed: return L("PIN processed, confirm on the watch…", "PIN işlendi, saatte onayla…")
        case .hiChain: return L("Authenticating (HiChain)…", "Doğrulanıyor (HiChain)…")
        case .authenticated: return L("Authenticated, setup not finished", "Doğrulandı, kurulum bitmedi")
        case .finishingSetup: return L("Finishing setup…", "Kurulum tamamlanıyor…")
        case .paired: return L("Paired", "Eşleşti")
        case .setupIncomplete(let why): return L("Encrypted, setup incomplete: ", "Şifreli, kurulum eksik: ") + why
        case .failed(let why): return L("Pairing failed: ", "Eşleşme başarısız: ") + why
        case .connectionLost: return L("Connection lost", "Bağlantı koptu")
        }
    }
}

// After HiChain: the messages Gadgetbridge (and Huawei's own app) send before the watch treats the phone as set up
// (HuaweiSupportProvider.initializeDeviceConfigure + initializeDynamicServices). HuaSideload used to stop after
// HiChain and a few queries; a Watch Fit 4 Pro accepts that, shows the data, then reports "Pairing failed".
// Each message is sent only when the watch lists its command (DeviceConfig.SupportedCommands 0x01/0x03) or
// capability bit (ExpandCapability 0x01/0x37), the same checks Gadgetbridge makes (HuaweiState).
enum PairingSetup {
    static let deviceConfig: UInt8 = 0x01
    static let timeCommand: UInt8 = 0x05                // DeviceConfig.TimeRequest
    static let acceptAgreementCommand: UInt8 = 0x30     // DeviceConfig.AcceptAgreement
    static let expandCapabilityCommand: UInt8 = 0x37    // DeviceConfig.ExpandCapability
    static let setUpDeviceStatusCommand: UInt8 = 0x3E   // DeviceConfig.SetUpDeviceStatusRequest
    static let accountService: UInt8 = 0x1A             // AccountRelated
    static let extendedAccountCommand: UInt8 = 0x05     // AccountRelated.SendExtendedAccountToDevice
    static let accountSwitchCommand: UInt8 = 0x06

    // ExpandCapability bits (HuaweiState.supportsMultiDevice / supportsDiffAccountPairingOptimization)
    static let multiDeviceCapability = 109
    static let diffAccountPairingCapability = 0xAC

    // Asked in one SupportedCommands request
    static let commandQuery: [(service: UInt8, commands: [UInt8])] = [
        (deviceConfig, [acceptAgreementCommand, expandCapabilityCommand, setUpDeviceStatusCommand]),
        (accountService, [extendedAccountCommand, accountSwitchCommand]),
    ]

    // What the watch reported, and what follows from it
    struct Support {
        var commands: [UInt8: [UInt8]] = [:]
        var expandCapabilities: [UInt8] = []

        func has(_ service: UInt8, _ command: UInt8) -> Bool { commands[service]?.contains(command) == true }

        // HuaweiState.supportsExpandCapability: bit (which % 8) of byte (which / 8)
        func hasCapability(_ which: Int) -> Bool {
            guard which / 8 < expandCapabilities.count else { return false }
            return expandCapabilities[which / 8] & (1 << (which % 8)) != 0
        }

        var sendsAccount: Bool { has(accountService, extendedAccountCommand) && has(accountService, accountSwitchCommand) }
        var sendsAgreements: Bool { has(deviceConfig, acceptAgreementCommand) }
        var asksExpandCapabilities: Bool { has(deviceConfig, expandCapabilityCommand) }
        var sendsSetUpStatus: Bool { asksExpandCapabilities && hasCapability(multiDeviceCapability) }
        var diffAccountPairing: Bool { asksExpandCapabilities && hasCapability(diffAccountPairingCapability) }
    }

    // DeviceConfig.TimeRequest (HuaweiUtil.getTimeAndZoneId): Unix time, then the UTC offset as hours
    // (+128 when negative) and minutes, as Java's (byte) casts produce them
    static func time(_ date: Date, timeZone: TimeZone) -> HuaweiTLV {
        let offset = timeZone.secondsFromGMT(for: date)
        let hours = UInt8(truncatingIfNeeded: offset < 0 ? -offset / 3600 + 128 : offset / 3600)
        let minutes = UInt8(truncatingIfNeeded: offset / 60 % 60)
        return HuaweiTLV()
            .with(0x01, .bigEndian(UInt32(truncatingIfNeeded: Int(date.timeIntervalSince1970))))
            .with(0x02, [hours, minutes])
    }

    // AccountRelated.SendExtendedAccountToDevice: the Huawei account ID the watch was set up with, or a single 0x00
    // when none is known; 0x03 = 1 asks for the different-account pairing path when the watch offers it
    static func extendedAccount(_ accountId: String, diffAccountPairing: Bool) -> HuaweiTLV {
        var tlv = HuaweiTLV().with(0x01, accountId.isEmpty ? [0x00] : Array(accountId.utf8))
        if diffAccountPairing { tlv = tlv.with(0x03, [0x01]) }
        return tlv
    }

    // DeviceConfig.AcceptAgreement: the three statements Gadgetbridge accepts, with its version string
    static func acceptAgreements(_ date: Date) -> HuaweiTLV {
        let timestamp = Array(String(Int64(date.timeIntervalSince1970 * 1000)).utf8)
        var list = HuaweiTLV()
        for name in ["software_update_service_statement", "device_information_management", "user_license_agreement"] {
            let item = HuaweiTLV()
                .with(0x03, Array(name.utf8))
                .with(0x04, [0x01])
                .with(0x05, Array("20230508-20230508-0-0".utf8))
                .with(0x06, timestamp)
            list = list.with(0x82, item.serialize())
        }
        return HuaweiTLV().with(0x81, list.serialize())
    }

    // DeviceConfig.SetUpDeviceStatusRequest: this phone is the main device (relationship 1)
    static func setUpDeviceStatus(watchName: String) -> HuaweiTLV {
        HuaweiTLV().with(0x01, [0x01]).with(0x02, Array(watchName.utf8)).with(0x03, [0x00])
    }

    // A Huawei account ID is a 17-digit number (Gadgetbridge: "Auth key"); anything else is ignored
    static func normalizedAccountId(_ text: String) -> String? {
        let digits = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard digits.count >= 6, digits.count <= 32, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber) else { return nil }
        return digits
    }
}
