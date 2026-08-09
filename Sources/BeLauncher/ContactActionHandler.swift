import Foundation
import Contacts
import BeLauncherCore

struct BELContactActionInput: Codable, Sendable {
    let query: String
    let contactID: String?
    let name: String?
    let email: String?
    let phone: String?
    init(query: String = "", contactID: String? = nil) {
        self.query = query
        self.contactID = contactID
        self.name = nil
        self.email = nil
        self.phone = nil
    }
    init(name: String, email: String? = nil, phone: String? = nil) {
        self.query = ""
        self.contactID = nil
        self.name = name
        self.email = email
        self.phone = phone
    }
    init(contactID: String, name: String?, email: String?, phone: String?) {
        self.query = ""
        self.contactID = contactID
        self.name = name
        self.email = email
        self.phone = phone
    }
}

struct ContactActionHandler: BELActionHandler {
    let actionID: String
    init?(definition: BELActionDefinition) {
        guard ["contacts.find", "contacts.get_details", "contacts.copy_email", "contacts.create", "contacts.update"].contains(definition.id),
              definition.adapter == .publicAPI else { return nil }
        actionID = definition.id
    }
    func perform(input: Data) async throws -> BELActionResult {
        let value = try JSONDecoder().decode(BELContactActionInput.self, from: input)
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { throw ContactActionError.permission }
        let store = CNContactStore()
        if actionID == "contacts.create" {
            let name = value.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty else { throw ContactActionError.invalidInput }
            let contact = CNMutableContact()
            let parts = name.split(separator: " ", maxSplits: 1).map(String.init)
            contact.givenName = parts.first ?? name
            contact.familyName = parts.count > 1 ? parts[1] : ""
            if let email = value.email, !email.isEmpty {
                contact.emailAddresses = [CNLabeledValue(label: CNLabelWork, value: email as NSString)]
            }
            if let phone = value.phone, !phone.isEmpty {
                contact.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile,
                                                        value: CNPhoneNumber(stringValue: phone))]
            }
            let request = CNSaveRequest()
            request.add(contact, toContainerWithIdentifier: nil)
            try store.execute(request)
            return BELActionResult(text: L("Contact created: %@", name),
                                   changed: [contact.identifier],
                                   receipt: "contacts:create:\(contact.identifier)")
        }
        let keys: [CNKeyDescriptor] = [CNContactIdentifierKey as NSString,
                                       CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
                                       CNContactEmailAddressesKey as NSString,
                                       CNContactPhoneNumbersKey as NSString,
                                       CNContactPostalAddressesKey as NSString,
                                       CNContactOrganizationNameKey as NSString]
        if actionID != "contacts.find" {
            guard let id = value.contactID else { throw ContactActionError.noMatches }
            var found: CNContact?
            let request = CNContactFetchRequest(keysToFetch: keys)
            try store.enumerateContacts(with: request) { contact, stop in
                if contact.identifier == id { found = contact; stop.pointee = true }
            }
            guard let contact = found else { throw ContactActionError.noMatches }
            if actionID == "contacts.update" {
                let edited = contact.mutableCopy() as! CNMutableContact
                if let name = value.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                    let parts = name.split(separator: " ", maxSplits: 1).map(String.init)
                    edited.givenName = parts.first ?? name
                    edited.familyName = parts.count > 1 ? parts[1] : ""
                }
                if let email = value.email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty {
                    edited.emailAddresses = [CNLabeledValue(label: CNLabelWork, value: email as NSString)]
                }
                if let phone = value.phone?.trimmingCharacters(in: .whitespacesAndNewlines), !phone.isEmpty {
                    edited.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile,
                                                          value: CNPhoneNumber(stringValue: phone))]
                }
                guard value.name != nil || value.email != nil || value.phone != nil else {
                    throw ContactActionError.invalidInput
                }
                let request = CNSaveRequest()
                request.update(edited)
                try store.execute(request)
                let updatedName = CNContactFormatter.string(from: edited, style: .fullName) ?? L("Untitled")
                return BELActionResult(text: L("Contact updated: %@", updatedName),
                                       changed: [id], receipt: "contacts:update:\(id)")
            }
            let name = CNContactFormatter.string(from: contact, style: .fullName) ?? L("Untitled")
            let email = contact.emailAddresses.first?.value as String? ?? ""
            let phone = contact.phoneNumbers.first?.value.stringValue ?? ""
            if actionID == "contacts.copy_email" {
                let value = email.isEmpty ? phone : email
                guard !value.isEmpty else { throw ContactActionError.noDetails }
                return BELActionResult(text: value, receipt: "contacts:copy:\(id)")
            }
            let organization = contact.organizationName
            let lines = [
                name,
                organization.isEmpty ? nil : organization,
                email.isEmpty ? nil : email,
                phone.isEmpty ? nil : phone
            ].compactMap { $0 }
            return BELActionResult(text: lines.joined(separator: "\n"), receipt: "contacts:details:\(id)")
        }
        let query = value.query
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
enum ContactActionError: Error, Equatable { case permission, noMatches, noDetails, invalidInput }
