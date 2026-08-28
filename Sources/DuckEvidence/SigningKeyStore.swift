import Foundation
import Crypto

/// Keychain accessibility, modeled as a cross-platform enum so the invariant
/// "the signing key is device-local, unlock-gated, and never syncs off this
/// device" is assertable in `swift test` on Linux — where `Security` and its
/// `kSecAttrAccessible*` constants do not exist.
///
/// The Apple `KeychainSigningKeyStore` maps each case to the real `Security`
/// CFString inside `#if canImport(Security)`.
public enum KeychainAccessibility: String, Equatable, Sendable {
    /// Maps to `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`: readable only
    /// while the device is unlocked, and never included in backups or synced to
    /// other devices. This is the required posture for the RCAN signing key
    /// (Ed25519 cannot live in the Secure Enclave, so we do not over-claim it).
    case whenUnlockedThisDeviceOnly

    /// The exact `Security` constant NAME this maps to. Kept as a plain string so
    /// the mapping can be asserted on Linux, where the CFString symbol is absent.
    public var secAttrConstantName: String {
        switch self {
        case .whenUnlockedThisDeviceOnly:
            return "kSecAttrAccessibleWhenUnlockedThisDeviceOnly"
        }
    }
}

/// Defaults shared by every signing-key store so the accessibility posture has a
/// single source of truth that both the Apple and in-memory stores are
/// configured with (and that tests assert on Linux).
public enum SigningKeyStoreDefaults {
    /// The accessibility every device-local signing-key store is created with.
    public static let accessibility: KeychainAccessibility = .whenUnlockedThisDeviceOnly
}

/// Abstraction over where the app's Ed25519 signing identity lives. The Apple
/// implementation is Keychain-backed; the in-memory implementation exists so the
/// domain logic (and its tests) run on Linux.
public protocol SigningKeyStore: AnyObject {
    /// The accessibility posture this store is configured with.
    var accessibility: KeychainAccessibility { get }

    /// Return the persisted signing identity, creating and persisting a fresh one
    /// on first use.
    func loadOrCreateIdentity() throws -> Curve25519.Signing.PrivateKey

    /// Remove any persisted identity (used by tests / reset flows).
    func deleteIdentity() throws
}

/// A non-persistent signing-key store for tests and Linux CI. It holds the key
/// in memory only; it carries the SAME accessibility value the Keychain store is
/// configured with, so the posture is assertable without `Security`.
public final class InMemorySigningKeyStore: SigningKeyStore {
    public let accessibility: KeychainAccessibility
    private var key: Curve25519.Signing.PrivateKey?

    public init(accessibility: KeychainAccessibility = SigningKeyStoreDefaults.accessibility) {
        self.accessibility = accessibility
    }

    public func loadOrCreateIdentity() throws -> Curve25519.Signing.PrivateKey {
        if let key { return key }
        let fresh = Curve25519.Signing.PrivateKey()
        key = fresh
        return fresh
    }

    public func deleteIdentity() throws {
        key = nil
    }
}

#if canImport(Security)
import Security

/// The Keychain-backed signing-key store used on Apple platforms.
///
/// The raw 32-byte Ed25519 seed is stored as a generic password item with
/// `kSecAttrAccessible = kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, so the
/// key is unlock-gated and never leaves this device. This whole type is compiled
/// out on Linux (`Security` is unavailable), which is why the accessibility
/// posture is expressed via the cross-platform `KeychainAccessibility` enum that
/// tests can check on the Pi.
public final class KeychainSigningKeyStore: SigningKeyStore {

    public enum KeychainError: Error {
        case unexpectedStatus(OSStatus)
        case malformedKeyData
    }

    public let accessibility: KeychainAccessibility
    private let service: String
    private let account: String

    public init(
        service: String = "com.opencastor.ios.signing",
        account: String = "rcan-ed25519-identity",
        accessibility: KeychainAccessibility = SigningKeyStoreDefaults.accessibility
    ) {
        self.service = service
        self.account = account
        self.accessibility = accessibility
    }

    /// The real `Security` accessibility constant for the configured posture.
    private var secAccessibleValue: CFString {
        switch accessibility {
        case .whenUnlockedThisDeviceOnly:
            return kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
    }

    public func loadOrCreateIdentity() throws -> Curve25519.Signing.PrivateKey {
        if let existing = try loadIdentity() { return existing }
        let key = Curve25519.Signing.PrivateKey()
        try store(key)
        return key
    }

    private func loadIdentity() throws -> Curve25519.Signing.PrivateKey? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = item as? Data else { throw KeychainError.malformedKeyData }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
    }

    private func store(_ key: Curve25519.Signing.PrivateKey) throws {
        // Delete-then-add, like every other store in the app: SecItemAdd alone
        // fails as errSecDuplicateItem the moment an item exists, which turns
        // "replace the identity" into a silent no-op.
        try? deleteIdentity()
        var attributes = baseQuery()
        attributes[kSecValueData as String] = key.rawRepresentation
        // The load-bearing posture: unlock-gated, this-device-only, no backup/sync.
        attributes[kSecAttrAccessible as String] = secAccessibleValue
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    public func deleteIdentity() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
#endif
