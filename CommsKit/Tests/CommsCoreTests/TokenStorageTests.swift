import CommsCore
import PrismAuth
import XCTest

final class TokenStorageTests: XCTestCase {
    let origin = try! ServerOrigin("https://prism.example.com")

    func testKeychainFlavourPerPlatform() throws {
        let store = CommsTokenStorage.keychain()
        #if os(macOS)
        // The test runner carries no application identifier: the login keychain, no migration
        // wrapper. (The signed Release app has one → data-protection keychain + migration.)
        XCTAssertFalse(CommsTokenStorage.usesDataProtectionKeychain)
        let k = try XCTUnwrap(store as? KeychainTokenStore)
        XCTAssertFalse(k.useDataProtectionKeychain)
        #else
        let k = try XCTUnwrap(store as? KeychainTokenStore)
        XCTAssertTrue(k.useDataProtectionKeychain)
        #endif
        XCTAssertEqual(k.service, "com.example.comms")
        XCTAssertNil(k.accessGroup)
    }

    func testMigrationMovesALegacyTokenOnceAndClearsTheOldItem() throws {
        let primary = InMemoryTokenStore()
        let legacy = InMemoryTokenStore()
        try legacy.setToken("pd_old", for: origin)
        let store = MigratingTokenStore(primary: primary, legacy: legacy)
        XCTAssertEqual(try store.token(for: origin), "pd_old")
        XCTAssertEqual(try primary.token(for: origin), "pd_old", "written to the new keychain")
        XCTAssertNil(try legacy.token(for: origin), "the old item is gone after a successful write")
        XCTAssertEqual(try store.token(for: origin), "pd_old")
    }

    func testPrimaryWinsAndNothingToMigrateIsNil() throws {
        let primary = InMemoryTokenStore()
        let legacy = InMemoryTokenStore()
        let store = MigratingTokenStore(primary: primary, legacy: legacy)
        XCTAssertNil(try store.token(for: origin))
        try primary.setToken("pd_new", for: origin)
        try legacy.setToken("pd_stale", for: origin)
        XCTAssertEqual(try store.token(for: origin), "pd_new")
    }

    func testFailedWriteKeepsTheOldItem() throws {
        struct Refusing: TokenStore {
            func token(for origin: ServerOrigin) throws -> String? { nil }
            func setToken(_ token: String, for origin: ServerOrigin) throws { throw TokenStoreError.keychain(status: -34018) }
            func removeToken(for origin: ServerOrigin) throws {}
        }
        let legacy = InMemoryTokenStore()
        try legacy.setToken("pd_old", for: origin)
        let store = MigratingTokenStore(primary: Refusing(), legacy: legacy)
        XCTAssertEqual(try store.token(for: origin), "pd_old", "still signed in")
        XCTAssertEqual(try legacy.token(for: origin), "pd_old", "nothing lost")
    }

    func testSetAndRemoveClearTheLegacyCopy() throws {
        let primary = InMemoryTokenStore()
        let legacy = InMemoryTokenStore()
        let store = MigratingTokenStore(primary: primary, legacy: legacy)
        try legacy.setToken("pd_old", for: origin)
        try store.setToken("pd_new", for: origin)
        XCTAssertNil(try legacy.token(for: origin))
        try legacy.setToken("pd_old", for: origin)
        try store.removeToken(for: origin)
        XCTAssertNil(try legacy.token(for: origin))
        XCTAssertNil(try primary.token(for: origin))
        XCTAssertNil(try store.token(for: origin), "sign-out leaves nothing to migrate back")
    }

    func testAFailingNewKeychainReadFallsBackToTheLegacyItem() throws {
        struct Throwing: TokenStore {
            func token(for origin: ServerOrigin) throws -> String? { throw TokenStoreError.keychain(status: -25308) }
            func setToken(_ token: String, for origin: ServerOrigin) throws {}
            func removeToken(for origin: ServerOrigin) throws {}
        }
        let legacy = InMemoryTokenStore()
        try legacy.setToken("pd_old", for: origin)
        XCTAssertEqual(try MigratingTokenStore(primary: Throwing(), legacy: legacy).token(for: origin), "pd_old", "not signed out")
        XCTAssertThrowsError(try MigratingTokenStore(primary: Throwing(), legacy: InMemoryTokenStore()).token(for: origin))
    }
}
