import Foundation
@preconcurrency import Contacts
import BeLauncherCore

@MainActor
final class ContactAccess {
    private let store = CNContactStore()
    private(set) var contacts: [ContactItem] = []
    private(set) var lastError: String?
    private var hasAsked = false
    var isAuthorised: Bool { CNContactStore.authorizationStatus(for: .contacts) == .authorized }

    func requestAccessIfNeeded() async {
        guard !isAuthorised, !hasAsked else { return }
        hasAsked = true
        _ = try? await store.requestAccess(for: .contacts)
        await refresh()
    }

    func refresh() async {
        guard isAuthorised else { return }
        lastError = nil
        let keys: [CNKeyDescriptor] = [CNContactIdentifierKey as NSString, CNContactFormatter.descriptorForRequiredKeys(for: .fullName), CNContactEmailAddressesKey as NSString, CNContactPhoneNumbersKey as NSString]
        var found: [ContactItem] = []
        let request = CNContactFetchRequest(keysToFetch: keys)
        do {
            try store.enumerateContacts(with: request) { contact, _ in
                let name = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
                guard !name.isEmpty else { return }
                found.append(ContactItem(id: contact.identifier, name: name,
                                         email: contact.emailAddresses.first?.value as String? ?? "",
                                         phone: contact.phoneNumbers.first?.value.stringValue ?? ""))
            }
        } catch {
            lastError = error.localizedDescription
            return
        }
        contacts = found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
