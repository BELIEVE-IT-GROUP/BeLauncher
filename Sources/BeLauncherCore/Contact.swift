import Foundation

public struct ContactItem: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let email: String
    public let phone: String
    public init(id: String, name: String, email: String = "", phone: String = "") {
        self.id = id; self.name = name; self.email = email; self.phone = phone
    }
    public var searchableText: String { "\(name) \(email) \(phone)" }
}
