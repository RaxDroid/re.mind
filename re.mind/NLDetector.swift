//
//  NLDetector.swift
//  re.mind
//
//  Created by Raul Sanchez on 9/3/26.
//

import Foundation

struct ParsedEvent {
    let title: String
    let date: Date?
    let description: String?
    let recurrence: RecurrenceRule?
}

enum RecurrenceRule: Equatable, CustomStringConvertible {
    case daily
    case weekly
    case monthly
    case yearly
    case everyMonth(day: Int?)
    case custom(String)

    var description: String {
        switch self {
        case .daily: return "daily"
        case .weekly: return "weekly"
        case .monthly: return "monthly"
        case .yearly: return "yearly"
        case .everyMonth(let day):
            if let day { return "every month on day \(day)" }
            return "every month"
        case .custom(let value):
            return value
        }
    }
}

struct NaturalLanguageEventParser {

    private let calendar: Calendar
    private let locale: Locale
    private let timeZone: TimeZone

    init(
        calendar: Calendar = .current,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) {
        var cal = calendar
        cal.locale = locale
        cal.timeZone = timeZone

        self.calendar = cal
        self.locale = locale
        self.timeZone = timeZone
    }

    func parse(_ input: String) -> ParsedEvent {
        let original = input.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !original.isEmpty else {
            return ParsedEvent(title: "Untitled", date: nil, description: nil, recurrence: nil)
        }

        let normalized = normalizeInput(original)

        let recurrenceMatch = detectRecurrence(in: normalized)
        let recurrence = recurrenceMatch?.rule

        let dateMatch = detectDate(in: normalized) ?? fallbackNumericDate(in: normalized)

        let cleanedText: String
        let parsedDate: Date?

        if let dateMatch {
            parsedDate = dateMatch.date

            var text = normalized
            text = remove(range: dateMatch.range, from: text)

            if let recurrenceMatch {
                text = remove(range: recurrenceMatch.range, from: text)
            }

            cleanedText = cleanupSpacing(text)
        } else {
            parsedDate = nil

            var text = normalized
            if let recurrenceMatch {
                text = remove(range: recurrenceMatch.range, from: text)
            }

            cleanedText = cleanupSpacing(text)
        }

        let split = splitTitleAndDescription(from: cleanedText)

        return ParsedEvent(
            title: split.title.isEmpty ? original : split.title,
            date: parsedDate,
            description: split.description,
            recurrence: recurrence
        )
    }
}

// MARK: - Core Helpers

private extension NaturalLanguageEventParser {

    struct DateMatch {
        let date: Date
        let range: Range<String.Index>
    }

    struct RecurrenceMatch {
        let rule: RecurrenceRule
        let range: Range<String.Index>
    }

    func normalizeInput(_ input: String) -> String {
        var text = input

        // Normalize punctuation spacing
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

        // Normalize some date wording
        text = text.replacingOccurrences(
            of: #"(\d{1,2})\s+of\s+([A-Za-z]+)"#,
            with: "$1 $2",
            options: .regularExpression
        )

        // Normalize ordinal suffixes: 1st -> 1, 2nd -> 2, etc.
        text = text.replacingOccurrences(
            of: #"\b(\d{1,2})(st|nd|rd|th)\b"#,
            with: "$1",
            options: .regularExpression
        )

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func detectRecurrence(in text: String) -> RecurrenceMatch? {
        let patterns: [(String, RecurrenceRule)] = [
            (#"\bevery day\b"#, .daily),
            (#"\bdaily\b"#, .daily),
            (#"\bevery week\b"#, .weekly),
            (#"\bweekly\b"#, .weekly),
            (#"\bevery month\b"#, .monthly),
            (#"\bmonthly\b"#, .monthly),
            (#"\bevery year\b"#, .yearly),
            (#"\byearly\b"#, .yearly),
            (#"\bannually\b"#, .yearly)
        ]

        for (pattern, rule) in patterns {
            if let range = firstRegexRange(pattern, in: text) {
                return RecurrenceMatch(rule: rule, range: range)
            }
        }

        // "every month on 15"
        if let range = firstRegexRange(#"\bevery month on \d{1,2}\b"#, in: text) {
            let phrase = String(text[range])
            let day = extractFirstInt(from: phrase)
            return RecurrenceMatch(rule: .everyMonth(day: day), range: range)
        }

        return nil
    }

    func detectDate(in text: String) -> DateMatch? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return nil
        }

        let range = NSRange(text.startIndex..., in: text)
        let matches = detector.matches(in: text, options: [], range: range)

        // Prefer the first valid date match with the shortest reasonable span
        for match in matches {
            guard let date = match.date,
                  let swiftRange = Range(match.range, in: text) else {
                continue
            }

            let matchedText = text[swiftRange].trimmingCharacters(in: .whitespacesAndNewlines)
            if matchedText.isEmpty { continue }

            return DateMatch(date: date, range: swiftRange)
        }

        return nil
    }

    func fallbackNumericDate(in text: String) -> DateMatch? {
        // Handles:
        // "10 03"
        // "10/03"
        // "10-03"
        // "10.03"
        // Assumes day-month
        let pattern = #"\b(\d{1,2})[\/\-\.\s](\d{1,2})\b"#

        guard let range = firstRegexRange(pattern, in: text) else { return nil }

        let matched = String(text[range])
        let numbers = matched
            .components(separatedBy: CharacterSet.decimalDigits.inverted)
            .compactMap { Int($0) }

        guard numbers.count >= 2 else { return nil }

        let day = numbers[0]
        let month = numbers[1]

        guard (1...31).contains(day), (1...12).contains(month) else {
            return nil
        }

        let now = Date()
        let currentYear = calendar.component(.year, from: now)

        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = timeZone
        components.year = currentYear
        components.month = month
        components.day = day

        guard var date = calendar.date(from: components) else {
            return nil
        }

        // If already passed this year, roll to next year for reminder/task-like behavior
        if date < startOfToday() {
            components.year = currentYear + 1
            if let nextYearDate = calendar.date(from: components) {
                date = nextYearDate
            }
        }

        return DateMatch(date: date, range: range)
    }

    func splitTitleAndDescription(from text: String) -> (title: String, description: String?) {
        let cleaned = cleanupSpacing(text)

        guard !cleaned.isEmpty else {
            return ("Untitled", nil)
        }

        // Priority 1: split by comma
        if let commaIndex = cleaned.firstIndex(of: ",") {
            let title = cleaned[..<commaIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            let after = cleaned[cleaned.index(after: commaIndex)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)

            return (
                title.isEmpty ? "Untitled" : String(title),
                after.isEmpty ? nil : String(after)
            )
        }

        // Priority 2: split by connector words often starting descriptions
        let connectors = [
            " with ", " for ", " about ", " re ", " regarding ",
            " note ", " notes ", " desc ", " details ", " location "
        ]

        for connector in connectors {
            if let range = cleaned.range(of: connector, options: .caseInsensitive) {
                let title = cleaned[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                let description = cleaned[range.lowerBound...].trimmingCharacters(in: .whitespacesAndNewlines)

                if !title.isEmpty {
                    return (
                        String(title),
                        description.isEmpty ? nil : String(description)
                    )
                }
            }
        }

        // Priority 3: heuristic split
        // First 2-4 words become title, rest description, only if enough words exist
        let words = cleaned.split(separator: " ").map(String.init)
        if words.count >= 5 {
            let titleWordCount = min(3, max(2, words.count / 3))
            let title = words.prefix(titleWordCount).joined(separator: " ")
            let description = words.dropFirst(titleWordCount).joined(separator: " ")
            return (title, description.isEmpty ? nil : description)
        }

        return (cleaned, nil)
    }

    func cleanupSpacing(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " ,", with: ",")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
    }

    func remove(range: Range<String.Index>, from text: String) -> String {
        var copy = text
        copy.removeSubrange(range)
        return copy
    }

    func firstRegexRange(_ pattern: String, in text: String) -> Range<String.Index>? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let nsRange = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange),
              let range = Range(match.range, in: text) else {
            return nil
        }

        return range
    }

    func extractFirstInt(from text: String) -> Int? {
        text.components(separatedBy: CharacterSet.decimalDigits.inverted)
            .compactMap { Int($0) }
            .first
    }

    func startOfToday() -> Date {
        calendar.startOfDay(for: Date())
    }
}
