import Foundation
import Contacts
import BeLauncherCore

struct BELContactActionInput: Codable, Sendable { let query: String }

struct ContactActionHandler: BELActionHandler {
    let actionID = "contacts.find"
    init?(definition: BELActionDefinition) {
        guard definition.id == actionID, definition.adapter == .publicAPI else { return nil }
    }
    func perform(input: Data) async throws -> BELActionResult {
        let query = try JSONDecoder().decode(BELContactActionInput.self, from: input).query
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { throw ContactActionError.permission }
        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [CNContactFormatter.descriptorForRequiredKeys(for: .fullName), CNContactEmailAddressesKey as NSString, CNContactPhoneNumbersKey as NSString]
        var lines: [String] = []
        let request = CNContactFetchRequest(keysToFetch: keys)
        try store.enumerateContacts(with: request) { contact, stop in
            let name = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
            let email = contact.emailAddresses.first?.value as String? ?? ""
            let phone = contact.phoneNumbers.first?.value.stringValue ?? ""
            if query.isEmpty || name.localizedCaseInsensitiveContains(query) || email.localizedCaseInsensitiveContains(query) || phone.localizedCaseInsensitiveContains(query) {
                lines.append("\(name) — \(email.isEmpty ? phone : email)")
            }
            if lines.count == 30 { stop.pointee = true }
        }
        guard !lines.isEmpty else { throw ContactActionError.noMatches }
        return BELActionResult(text: lines.joined(separator: "\n"), receipt: "contacts:find")
    }
}
enum ContactActionError: Error, Equatable { case permission, noMatches }
