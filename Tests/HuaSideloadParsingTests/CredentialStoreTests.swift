import XCTest
@testable import HuaSideloadParsing

// Moving pairing keys and the account ID from UserDefaults to the Keychain without ever losing one.
// The Keychain itself is replaced by an in-memory backend (CI machines have no unlocked keychain to rely on).
final class CredentialStoreTests: XCTestCase {
    private final class MemoryBackend: SecretBackend {
        var values: [String: String] = [:]
        var failWrites = false
        func read(_ key: String) -> String? { values[key] }
        func write(_ value: String, for key: String) -> Bool {
            guard !failWrites else { return false }
            values[key] = value
            return true
        }
        func delete(_ key: String) { values[key] = nil }
    }

    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() {
        suite = "CredentialStoreTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testOldValueIsMovedOnFirstRead() {
        let backend = MemoryBackend()
        defaults.set("A1B2", forKey: "authToken.watch")
        let store = CredentialStore(secure: backend, legacy: defaults)
        XCTAssertEqual(store.string("authToken.watch"), "A1B2")
        XCTAssertEqual(backend.values["authToken.watch"], "A1B2")
        XCTAssertNil(defaults.string(forKey: "authToken.watch"))
        XCTAssertEqual(store.string("authToken.watch"), "A1B2")    // still there after the move
    }

    func testOldValueStaysWhenTheKeychainRefuses() {
        let backend = MemoryBackend()
        backend.failWrites = true
        defaults.set("A1B2", forKey: "authToken.watch")
        let store = CredentialStore(secure: backend, legacy: defaults)
        XCTAssertEqual(store.string("authToken.watch"), "A1B2")
        XCTAssertEqual(defaults.string(forKey: "authToken.watch"), "A1B2")
    }

    func testWriteGoesToTheKeychain() {
        let backend = MemoryBackend()
        defaults.set("old", forKey: "k")
        let store = CredentialStore(secure: backend, legacy: defaults)
        store.set("new", for: "k")
        XCTAssertEqual(backend.values["k"], "new")
        XCTAssertNil(defaults.string(forKey: "k"))
    }

    func testFailedWriteFallsBackInsteadOfLosingTheValue() {
        let backend = MemoryBackend()
        backend.failWrites = true
        let store = CredentialStore(secure: backend, legacy: defaults)
        store.set("new", for: "k")
        XCTAssertEqual(store.string("k"), "new")
    }

    func testKeychainValueWins() {
        let backend = MemoryBackend()
        backend.values["k"] = "keychain"
        defaults.set("legacy", forKey: "k")
        XCTAssertEqual(CredentialStore(secure: backend, legacy: defaults).string("k"), "keychain")
    }

    func testClearingRemovesBoth() {
        let backend = MemoryBackend()
        backend.values["k"] = "keychain"
        defaults.set("legacy", forKey: "k")
        let store = CredentialStore(secure: backend, legacy: defaults)
        store.set(nil, for: "k")
        XCTAssertNil(store.string("k"))
        store.set("x", for: "k")
        store.set("", for: "k")
        XCTAssertNil(store.string("k"))
    }

    func testKeys() {
        XCTAssertEqual(CredentialStore.authTokenKey("ABC"), "authToken.ABC")     // same key older builds used
        XCTAssertEqual(CredentialStore.huaweiAccountKey, "HuaSideloadHuaweiAccountId")
    }
}
