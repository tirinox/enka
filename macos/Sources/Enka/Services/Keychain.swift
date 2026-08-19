import Foundation
import Security

/// The two secrets Enka holds: the access secret the user types once, and the
/// JWT minted from it.
///
/// Both go to the keychain rather than to `UserDefaults`, and the reason is not
/// symmetry. `UserDefaults` is a plist in the user's Library that any process
/// running as them can read, and the access secret is the *whole* of this
/// server's authentication — there are no accounts behind it. The token is kept
/// beside it because it is a bearer credential good for thirty days, which is
/// the same thing with a shorter fuse.
enum Keychain {
    private static let service = "com.enka.app"

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Writes, or deletes when handed nil. Delete-then-add rather than an
    /// update: `SecItemUpdate` fails when there is nothing to update, so the
    /// two-call version would need the same branch anyway, one level deeper.
    static func write(_ value: String?, to account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        // The panel is hovered while the screen is unlocked, always. Nothing
        // here needs to be readable before the user has logged in, and
        // `ThisDeviceOnly` keeps the secret out of a keychain backup that could
        // be restored onto another Mac.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static let secretAccount = "access-secret"
    static let tokenAccount = "access-token"
}
