import Contacts
import Foundation

/// Loads all macOS contacts once via CNContactStore, normalizes their numbers to
/// E.164, and caches them in memory. Handles permission-denied cleanly.
///
/// Main-actor isolated because the cache is loaded once at startup and consumed
/// from the UI, both on the main actor. Swift 6 strict concurrency is satisfied
/// by actor isolation rather than a lock (NSLock is not async-safe).
@MainActor
public final class ContactIndex {

    public enum LoadError: Error, CustomStringConvertible {
        case permissionDenied
        case restricted
        case enumerationFailed(String)

        public var description: String {
            switch self {
            case .permissionDenied:
                return "Contacts access was denied. Enable it in System Settings > Privacy & Security > Contacts."
            case .restricted:
                return "Contacts access is restricted on this Mac (parental controls / MDM)."
            case .enumerationFailed(let reason):
                return "Failed to read contacts: \(reason)"
            }
        }
    }

    private var _contacts: [Contact] = []
    private let store: CNContactStore

    public init(store: CNContactStore = CNContactStore()) {
        self.store = store
    }

    /// The in-memory cache. Empty until `load()` succeeds.
    public var contacts: [Contact] { _contacts }

    /// Requests access if needed, then enumerates all contacts and replaces the
    /// cache. Throws `LoadError.permissionDenied` if the user says no.
    public func load() async throws {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized:
            break
        case .denied:
            throw LoadError.permissionDenied
        case .notDetermined:
            let granted = try await store.requestAccess(for: .contacts)
            guard granted else { throw LoadError.permissionDenied }
        case .restricted:
            throw LoadError.restricted
        @unknown default:
            throw LoadError.enumerationFailed("unknown authorization state")
        }

        let keys: [CNKeyDescriptor] = [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        var loaded: [Contact] = []
        do {
            try store.enumerateContacts(with: request) { cn, _ in
                if let contact = Self.map(cn) { loaded.append(contact) }
            }
        } catch {
            throw LoadError.enumerationFailed(error.localizedDescription)
        }
        _contacts = loaded
    }

    private static func map(_ cn: CNContact) -> Contact? {
        let phones = cn.phoneNumbers.compactMap { pn -> ContactPhone? in
            guard let e164 = PhoneNormalizer.normalize(pn.value.stringValue) else { return nil }
            let label = CNLabeledValue<CNPhoneNumber>.localizedString(forLabel: pn.label ?? "")
            return ContactPhone(label: label, e164: e164)
        }
        // A contact with no usable phone number is KEPT, deliberately.
        //
        // Dropping it here meant the person did not exist as far as Voicy was
        // concerned, so saying their name produced "no contact matched, say the
        // contact's full name and try again". That reads as "I misheard you" when
        // the truth is "I heard you perfectly, that person has no phone number",
        // and it sent the user off to re-pronounce a name that was never the
        // problem. It also made `PipelineFailure.recipientHasNoPhoneNumber`
        // unreachable in the live app: every contact in the index was guaranteed
        // to have a number, so the guard that produces that message could never
        // fire.
        //
        // Keeping them means the resolver can match the name and the send path can
        // refuse for the real reason. `Contact.preferredE164` is already nil for
        // these, and every send path guards on it, so no phone-less contact can
        // reach an actual send.
        //
        // An entry with no name at all is still dropped: it cannot be matched by
        // a spoken name, so keeping it would only add noise to the match scores.
        let hasName = ![cn.givenName, cn.familyName, cn.nickname, cn.organizationName]
            .allSatisfy(\.isEmpty)
        guard hasName else { return nil }
        return Contact(identifier: cn.identifier,
                       givenName: cn.givenName,
                       familyName: cn.familyName,
                       nickname: cn.nickname,
                       organizationName: cn.organizationName,
                       phones: phones)
    }
}