import Foundation
import Security

// Creates only a unique, nonsensitive fixture item and immediately deletes it.
// Never reads existing credentials or changes Keychain defaults/search lists.
var keychain: SecKeychain?
let lookup = SecKeychainCopyDefault(&keychain)
var added: OSStatus = errSecNotAvailable
var deleted: OSStatus = errSecNotAvailable
if lookup == errSecSuccess, let keychain {
    let service = "app.aitvaras.synthetic-keychain-check.\(UUID().uuidString)"
    let account = "synthetic-account"
    let password = "synthetic-nonsecret-value"
    var item: SecKeychainItem?
    added = service.withCString { servicePointer in
        account.withCString { accountPointer in
            password.withCString { passwordPointer in
                SecKeychainAddGenericPassword(keychain, UInt32(service.utf8.count), servicePointer,
                    UInt32(account.utf8.count), accountPointer, UInt32(password.utf8.count), passwordPointer, &item)
            }
        }
    }
    if let item { deleted = SecKeychainItemDelete(item) }
}
print("{\"lookup\":\(lookup),\"added\":\(added),\"deleted\":\(deleted)}")
exit(lookup == errSecSuccess && added == errSecSuccess && deleted == errSecSuccess ? 0 : 1)
