import Foundation
import PDFKit
import BeLauncherCore

struct BELPDFActionInput: Codable, Sendable {
    let path: String
}

/// Reads PDF text locally through PDFKit. It returns the extracted text as the action result and
/// never copies the document into the Brain; callers can decide whether to save a memory.
struct PDFActionHandler: BELActionHandler {
    let actionID = "files.extract_pdf_text"

    init?(definition: BELActionDefinition) {
        guard definition.id == actionID, definition.adapter == .publicAPI else { return nil }
    }

    func perform(input: Data) async throws -> BELActionResult {
        let value = try JSONDecoder().decode(BELPDFActionInput.self, from: input)
        let url = URL(fileURLWithPath: value.path).standardizedFileURL
        guard url.pathExtension.caseInsensitiveCompare("pdf") == .orderedSame else {
            throw PDFActionError.notPDF(value.path)
        }
        guard let document = PDFDocument(url: url) else {
            throw PDFActionError.couldNotRead(value.path)
        }
        let text = (0..<document.pageCount)
            .compactMap { document.page(at: $0)?.string }
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw PDFActionError.empty(value.path) }
        return BELActionResult(text: text, changed: [url.path], receipt: "pdf:extract_text")
    }
}

enum PDFActionError: Error, Equatable {
    case notPDF(String)
    case couldNotRead(String)
    case empty(String)
}
