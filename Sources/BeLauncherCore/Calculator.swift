import Foundation

public struct CalculationResult: Sendable, Equatable {
    public let display: String
    /// What lands on the clipboard when the user hits ↩ — never a formatted string.
    public let raw: String
    public let detail: String
}

/// Arithmetic, percentages and unit conversion, evaluated locally with no network.
public enum Calculator {

    // MARK: - Entry point

    /// Returns nil when the query is not a calculation, so ordinary search is unaffected.
    public static func evaluate(_ query: String) -> CalculationResult? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return convert(trimmed) ?? arithmetic(trimmed)
    }

    // MARK: - Arithmetic

    private static let allowed = CharacterSet(charactersIn: "0123456789.,+-*/×÷^()%  eE")

    private static func arithmetic(_ input: String) -> CalculationResult? {
        var expression = input.hasPrefix("=") ? String(input.dropFirst()) : input
        expression = expression.trimmingCharacters(in: .whitespaces)
        guard expression.count > 1 else { return nil }

        // "15% of 300" / "15% de 300"
        if let percentage = percentageOf(expression) { return percentage }

        expression = expression
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: " ", with: "")
        guard !expression.isEmpty,
              expression.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              expression.rangeOfCharacter(from: CharacterSet(charactersIn: "0123456789")) != nil,
              expression.rangeOfCharacter(from: CharacterSet(charactersIn: "+-*/^%")) != nil else {
            return nil
        }

        // "200+10%" reads as "add 10 percent of 200", the way every calculator behaves.
        expression = expandTrailingPercent(expression)

        // NSExpression would happily evaluate function calls; the character allow-list above
        // is what keeps this to arithmetic.
        guard let value = evaluateArithmetic(expression) else { return nil }
        return result(value, detail: "Calculation")
    }

    private static func evaluateArithmetic(_ expression: String) -> Double? {
        var normalised = expression.replacingOccurrences(of: "^", with: "**")
        // NSExpression does integer division on integer literals: "(4+6)/4" would be 2.
        // Making every literal a decimal keeps arithmetic behaving like a calculator.
        normalised = normalised.replacingOccurrences(
            of: #"(?<![\d.])(\d+)(?![\d.])"#,
            with: "$1.0",
            options: .regularExpression
        )
        guard let parsed = try? NSExpression(format: normalised) else { return nil }
        guard let number = parsed.expressionValue(with: nil, context: nil) as? NSNumber else { return nil }
        let value = number.doubleValue
        return value.isFinite ? value : nil
    }

    private static func expandTrailingPercent(_ expression: String) -> String {
        guard let range = expression.range(of: #"([+\-])([0-9.]+)%$"#, options: .regularExpression) else {
            return expression.replacingOccurrences(of: "%", with: "/100")
        }
        let base = String(expression[expression.startIndex..<range.lowerBound])
        let operatorSign = String(expression[range.lowerBound])
        let amount = expression[expression.index(after: range.lowerBound)..<range.upperBound].dropLast()
        return "(\(base))\(operatorSign)((\(base))*\(amount)/100)"
    }

    private static func percentageOf(_ input: String) -> CalculationResult? {
        let pattern = #"^([0-9.,]+)\s*%\s*(?:of|de)\s+([0-9.,]+)$"#
        guard let match = input.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let parts = String(input[match])
            .replacingOccurrences(of: "%", with: " ")
            .components(separatedBy: CharacterSet.decimalDigits.inverted.subtracting(CharacterSet(charactersIn: ".")))
            .filter { !$0.isEmpty }
        guard parts.count >= 2, let percent = Double(parts[0]), let total = Double(parts[1]) else { return nil }
        return result(percent / 100 * total, detail: "\(format(percent))% of \(format(total))")
    }

    // MARK: - Unit conversion

    /// `10 km to mi`, `20 C in F`, `5 kg a lb`
    private static func convert(_ input: String) -> CalculationResult? {
        let pattern = #"^\s*(-?[0-9]+(?:[.,][0-9]+)?)\s*([a-zA-Z°]+)\s+(?:to|in|a|en|as)\s+([a-zA-Z°]+)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
              let amountRange = Range(match.range(at: 1), in: input),
              let fromRange = Range(match.range(at: 2), in: input),
              let toRange = Range(match.range(at: 3), in: input),
              let amount = Double(input[amountRange].replacingOccurrences(of: ",", with: ".")) else {
            return nil
        }
        let fromKey = String(input[fromRange]).lowercased()
        let toKey = String(input[toRange]).lowercased()

        guard let from = units[fromKey], let to = units[toKey], from.kind == to.kind else { return nil }
        let value = (amount * from.factor + from.offset - to.offset) / to.factor
        return result(value, detail: "\(format(amount)) \(from.symbol) = \(format(value)) \(to.symbol)")
    }

    private struct Unit {
        let kind: String
        let symbol: String
        /// Everything is expressed against a base unit: metres, grams, seconds, kelvin, bytes.
        let factor: Double
        var offset: Double = 0
    }

    private static let units: [String: Unit] = {
        var table: [String: Unit] = [:]
        func add(_ keys: [String], _ unit: Unit) { for key in keys { table[key] = unit } }

        add(["mm"], Unit(kind: "length", symbol: "mm", factor: 0.001))
        add(["cm"], Unit(kind: "length", symbol: "cm", factor: 0.01))
        add(["m", "meter", "meters", "metro", "metros"], Unit(kind: "length", symbol: "m", factor: 1))
        add(["km"], Unit(kind: "length", symbol: "km", factor: 1000))
        add(["in", "inch", "inches", "pulgada", "pulgadas"], Unit(kind: "length", symbol: "in", factor: 0.0254))
        add(["ft", "feet", "foot", "pie", "pies"], Unit(kind: "length", symbol: "ft", factor: 0.3048))
        add(["yd", "yard", "yards"], Unit(kind: "length", symbol: "yd", factor: 0.9144))
        add(["mi", "mile", "miles", "milla", "millas"], Unit(kind: "length", symbol: "mi", factor: 1609.344))

        add(["mg"], Unit(kind: "mass", symbol: "mg", factor: 0.001))
        add(["g", "gram", "grams", "gramo", "gramos"], Unit(kind: "mass", symbol: "g", factor: 1))
        add(["kg", "kilo", "kilos"], Unit(kind: "mass", symbol: "kg", factor: 1000))
        add(["lb", "lbs", "pound", "pounds", "libra", "libras"], Unit(kind: "mass", symbol: "lb", factor: 453.59237))
        add(["oz", "ounce", "ounces", "onza", "onzas"], Unit(kind: "mass", symbol: "oz", factor: 28.349523125))

        add(["c", "°c", "celsius"], Unit(kind: "temperature", symbol: "°C", factor: 1, offset: 273.15))
        add(["f", "°f", "fahrenheit"], Unit(kind: "temperature", symbol: "°F", factor: 5.0 / 9.0, offset: 255.372222222222))
        add(["k", "kelvin"], Unit(kind: "temperature", symbol: "K", factor: 1))

        add(["ms"], Unit(kind: "time", symbol: "ms", factor: 0.001))
        add(["s", "sec", "second", "seconds", "seg", "segundo", "segundos"], Unit(kind: "time", symbol: "s", factor: 1))
        add(["min", "minute", "minutes", "minuto", "minutos"], Unit(kind: "time", symbol: "min", factor: 60))
        add(["h", "hr", "hour", "hours", "hora", "horas"], Unit(kind: "time", symbol: "h", factor: 3600))
        add(["d", "day", "days", "dia", "dias"], Unit(kind: "time", symbol: "d", factor: 86400))

        add(["b", "byte", "bytes"], Unit(kind: "data", symbol: "B", factor: 1))
        add(["kb"], Unit(kind: "data", symbol: "KB", factor: 1024))
        add(["mb"], Unit(kind: "data", symbol: "MB", factor: 1024 * 1024))
        add(["gb"], Unit(kind: "data", symbol: "GB", factor: 1024 * 1024 * 1024))
        add(["tb"], Unit(kind: "data", symbol: "TB", factor: 1024 * 1024 * 1024 * 1024))
        return table
    }()

    // MARK: - Formatting

    private static func result(_ value: Double, detail: String) -> CalculationResult {
        let raw = format(value)
        return CalculationResult(display: raw, raw: raw, detail: detail)
    }

    static func format(_ input: Double) -> String {
        // Round first: unit offsets are irrational in binary, so 32°F → °C lands on
        // -0.000000000000014 and would print as "-0".
        let value = abs(input) < 1e15 ? (input * 1e6).rounded() / 1e6 : input
        if value == 0 { return "0" }
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.maximumFractionDigits = 6
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
