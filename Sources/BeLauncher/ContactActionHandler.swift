import Foundation
import AppKit
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
    private let presentShare: @MainActor @Sendable (URL) -> Bool
    private let contactsAuthorized: @Sendable () -> Bool
    private let contactForID: @Sendable ([CNKeyDescriptor], String) throws -> CNContact?
    init?(definition: BELActionDefinition) {
        self.init(definition: definition,
                  presentShare: ContactActionHandler.defaultPresentShare,
                  contactsAuthorized: { CNContactStore.authorizationStatus(for: .contacts) == .authorized },
                  contactForID: ContactActionHandler.defaultContactForID)
    }

    init?(definition: BELActionDefinition,
          presentShare: @escaping @MainActor @Sendable (URL) -> Bool,
          contactsAuthorized: @escaping @Sendable () -> Bool = { CNContactStore.authorizationStatus(for: .contacts) == .authorized },
          contactForID: @escaping @Sendable ([CNKeyDescriptor], String) throws -> CNContact? = ContactActionHandler.defaultContactForID) {
        guard ["contacts.find", "contacts.get_details", "contacts.copy_email", "contacts.create", "contacts.update", "contacts.share"].contains(definition.id),
              definition.adapter == .publicAPI else { return nil }
        actionID = definition.id
        self.presentShare = presentShare
        self.contactsAuthorized = contactsAuthorized
        self.contactForID = contactForID
    }
    func perform(input: Data) async throws -> BELActionResult {
        let value = try JSONDecoder().decode(BELContactActionInput.self, from: input)
        guard contactsAuthorized() else { throw ContactActionError.permission }
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
        var keys: [CNKeyDescriptor] = [CNContactIdentifierKey as NSString,
                                       CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
                                       CNContactEmailAddressesKey as NSString,
                                       CNContactPhoneNumbersKey as NSString,
                                       CNContactPostalAddressesKey as NSString,
                                       CNContactOrganizationNameKey as NSString]
        if actionID == "contacts.share" {
            keys.append(CNContactVCardSerialization.descriptorForRequiredKeys())
        }
        if actionID != "contacts.find" {
            guard let id = value.contactID else { throw ContactActionError.noMatches }
            let found = try contactForID(keys, id)
            guard let contact = found else { throw ContactActionError.noMatches }
            if actionID == "contacts.share" {
                return try await share(contact: contact, identifier: id)
            }
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

    private func share(contact: CNContact, identifier: String) async throws -> BELActionResult {
        let data: Data
        do {
            data = try CNContactVCardSerialization.data(with: [contact])
        } catch {
            throw ContactShareActionError.serializationFailed(error.localizedDescription)
        }
        let name = CNContactFormatter.string(from: contact, style: .fullName) ?? L("Contact")
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeLauncher-\(UUID().uuidString)-\(Self.safeShareFileName(name)).vcf")
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw ContactShareActionError.filePreparationFailed(error.localizedDescription)
        }
        let shown = await MainActor.run { presentShare(fileURL) }
        guard shown else { throw ContactShareActionError.sharingUnavailable }
        return BELActionResult(text: L("Share options opened for %@", name),
                               changed: [fileURL.path], receipt: "contacts:share:\(identifier)")
    }

    private static func defaultContactForID(_ keys: [CNKeyDescriptor], _ identifier: String) throws -> CNContact? {
        let request = CNContactFetchRequest(keysToFetch: keys)
        let store = CNContactStore()
        var found: CNContact?
        try store.enumerateContacts(with: request) { contact, stop in
            if contact.identifier == identifier { found = contact; stop.pointee = true }
        }
        return found
    }

    @MainActor
    private static func defaultPresentShare(_ fileURL: URL) -> Bool {
        guard let view = NSApp.keyWindow?.contentView,
              view.window != nil,
              !NSSharingService.sharingServices(forItems: [fileURL]).isEmpty else {
            return false
        }
        let picker = NSSharingServicePicker(items: [fileURL])
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        return true
    }

    private static func safeShareFileName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "contact" : cleaned
    }
}
enum ContactActionError: Error, Equatable { case permission, noMatches, noDetails, invalidInput }

enum ContactShareActionError: Error, Equatable {
    case permission
    case invalidInput
    case noMatches
    case serializationFailed(String)
    case filePreparationFailed(String)
    case sharingUnavailable
}

/// Opens the exact record through Contacts' documented scripting dictionary. A plain
/// `NSWorkspace.open` would only launch an empty Contacts window and falsely claim to open a
/// contact. The script is a fixed template; only the opaque system identifier is escaped.
struct ContactOpenActionHandler: BELActionHandler {
    let actionID = "contacts.open"

    init?(definition: BELActionDefinition) {
        guard definition.id == "contacts.open", definition.adapter == .appleScript else { return nil }
    }

    func perform(input: Data) async throws -> BELActionResult {
        let value = try JSONDecoder().decode(BELContactActionInput.self, from: input)
        guard let id = value.contactID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
            throw ContactOpenActionError.invalidInput
        }
        let escapedID = id.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Contacts"
            activate
            set matches to (every person whose id is "\(escapedID)")
            if (count of matches) is 0 then error number -1728
            set selection to matches
        end tell
        """
        let failure: ContactOpenActionError? = await MainActor.run {
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
            guard let error else { return nil }
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -1728 { return .noMatches }
            if code == -1743 { return .automationPermission }
            return .scriptFailed(error[NSAppleScript.errorMessage] as? String ?? L("The contact could not be opened."))
        }
        if let failure { throw failure }
        return BELActionResult(text: L("Contact opened"), receipt: "contacts:open:\(id)")
    }
}

enum ContactOpenActionError: Error, Equatable {
    case invalidInput
    case noMatches
    case automationPermission
    case scriptFailed(String)
}
