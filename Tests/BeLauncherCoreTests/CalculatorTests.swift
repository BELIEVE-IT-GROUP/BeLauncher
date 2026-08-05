import Testing
import Foundation
@testable import BeLauncherCore

@Suite("Calculator")
struct CalculatorTests {

    @Test("plain arithmetic")
    func arithmetic() {
        #expect(Calculator.evaluate("2+2")?.display == "4")
        #expect(Calculator.evaluate("10 * 3")?.display == "30")
        #expect(Calculator.evaluate("(4+6)/4")?.display == "2.5")
        #expect(Calculator.evaluate("2^10")?.display == "1024")
        #expect(Calculator.evaluate("=7*6")?.display == "42")
    }

    @Test("percentages")
    func percentages() {
        #expect(Calculator.evaluate("15% of 300")?.display == "45")
        #expect(Calculator.evaluate("15% de 300")?.display == "45")
        #expect(Calculator.evaluate("200+10%")?.display == "220")
        #expect(Calculator.evaluate("200-10%")?.display == "180")
    }

    @Test("unit conversion covers length, mass, temperature, time and data")
    func conversions() {
        #expect(Calculator.evaluate("10 km to mi")?.display == "6.213712")
        #expect(Calculator.evaluate("1 kg in lb")?.display == "2.204623")
        #expect(Calculator.evaluate("100 c to f")?.display == "212")
        #expect(Calculator.evaluate("32 f to c")?.display == "0")
        #expect(Calculator.evaluate("2 h to min")?.display == "120")
        #expect(Calculator.evaluate("1 gb to mb")?.display == "1024")
        #expect(Calculator.evaluate("5 km a millas")?.display == "3.106856")
    }

    @Test("mismatched or unknown units are not a calculation")
    func rejectsNonsense() {
        #expect(Calculator.evaluate("10 km to kg") == nil)
        #expect(Calculator.evaluate("10 foo to bar") == nil)
    }

    @Test("ordinary searches are never swallowed by the calculator")
    func leavesSearchAlone() {
        #expect(Calculator.evaluate("safari") == nil)
        #expect(Calculator.evaluate("") == nil)
        #expect(Calculator.evaluate("gh swift") == nil)
        #expect(Calculator.evaluate("2") == nil)          // a bare number is not a calculation
        #expect(Calculator.evaluate("notes") == nil)
    }

    @Test("function calls are refused — NSExpression is fenced in by the character allow-list")
    func refusesFunctionCalls() {
        #expect(Calculator.evaluate("FUNCTION(1,'description')") == nil)
        #expect(Calculator.evaluate("sum({1,2})") == nil)
    }

    @Test("the copied value is unformatted")
    func rawValue() throws {
        let result = try #require(Calculator.evaluate("1000000/3"))
        #expect(!result.raw.contains(","))
    }
}

@Suite("File search")
struct FileSearchTests {

    @Test("only the explicit prefix triggers a file search")
    func prefix() {
        #expect(FileSearch.query(from: "f budget") == "budget")
        #expect(FileSearch.query(from: "  F Report 2026 ") == "Report 2026")
        #expect(FileSearch.query(from: "finder") == nil)      // a word starting with f is not a prefix
        #expect(FileSearch.query(from: "f") == nil)
        #expect(FileSearch.query(from: "f a") == nil)         // too short to be worth a query
    }

    @Test("results are capped and mapped to name + path")
    func mapping() {
        let search = FileSearch { term, limit in
            (0..<20).prefix(limit).map { FoundFile(name: "\(term)-\($0).txt", path: "/tmp/\(term)-\($0).txt") }
        }
        let found = search.search("notes", limit: 3)
        #expect(found.count == 3)
        #expect(found.first?.name == "notes-0.txt")
    }

    @Test("an unavailable Spotlight degrades to no results instead of failing")
    func degradesGracefully() {
        let search = FileSearch { _, _ in [] }
        #expect(search.search("anything").isEmpty)
    }
}
