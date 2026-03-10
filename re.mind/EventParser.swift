//
//  EventParser.swift
//  re.mind
//
//  Created by Raul Sanchez on 10/3/26.
//

import Foundation;

// MARK: - Parsed Draft

struct ReminderDraft {
    let title: String
    let dueDate: Date?
    let notes: String?
    let recurrence: String?
    let place: String?
    let geolocation: GeoLocation?
    let tags: [String]
}

final class EventParser {

    static let shared = EventParser()

    private let locale = Locale(identifier: "es_DO")
    private let timeZone = TimeZone(identifier: "America/Santo_Domingo") ?? .current
    private var calendar: Calendar

    private init() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = timeZone
        self.calendar = calendar
    }

    // Public entry point
    func parse(_ rawInput: String) -> ReminderDraft {
        let original = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !original.isEmpty else {
            return ReminderDraft(
                title: "Untitled",
                dueDate: nil,
                notes: nil,
                recurrence: .none,
                place: nil,
                geolocation: nil,
                tags: []
            )
        }

        let normalized = normalizeInput(original)

        let tags = extractTags(from: normalized.text)
        var workingText = normalized.textRemovingTags

        let recurrenceMatch = detectRecurrence(in: workingText)
        let recurrence = recurrenceMatch?.value ?? .none
        if let recurrenceMatch {
            workingText = remove(range: recurrenceMatch.range, from: workingText)
        }

        let placeMatch = detectPlace(in: workingText)
        let place = placeMatch?.value
        if let placeMatch {
            workingText = remove(range: placeMatch.range, from: workingText)
        }

        let dateMatch = detectDate(in: workingText)
        let dueDate = dateMatch?.date
        if let dateMatch {
            workingText = remove(range: dateMatch.range, from: workingText)
        }

        let cleaned = cleanupText(workingText)
        let split = splitTitleAndNotes(from: cleaned)

        return ReminderDraft(
            title: split.title,
            dueDate: dueDate,
            notes: split.notes,
            recurrence: recurrence,
            place: place,
            geolocation: nil,
            tags: tags
        )
    }
}

// MARK: - Internal Types

private extension EventParser {
    struct ExtractionResult<T> {
        let value: T
        let range: Range<String.Index>
    }

    struct DateExtraction {
        let date: Date
        let range: Range<String.Index>
    }

    struct NormalizationResult {
        let text: String
        let textRemovingTags: String
    }
}

// MARK: - Parsing Pipeline

private extension EventParser {

    func normalizeInput(_ input: String) -> NormalizationResult {
        var text = input

        text = text.replacingOccurrences(of: "\u{00A0}", with: " ")
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Ordinals in English/Spanish-like variants: 1st, 2nd, 3rd, 4th
        text = text.replacingOccurrences(
            of: #"(?i)\b(\d{1,2})(st|nd|rd|th)\b"#,
            with: "$1",
            options: .regularExpression
        )

        // "10 of march" -> "10 march"
        text = text.replacingOccurrences(
            of: #"(?i)\b(\d{1,2})\s+of\s+([a-záéíóúñ]+)\b"#,
            with: "$1 $2",
            options: .regularExpression
        )

        // "10 de marzo" -> "10 marzo"
        text = text.replacingOccurrences(
            of: #"(?i)\b(\d{1,2})\s+de\s+([a-záéíóúñ]+)\b"#,
            with: "$1 $2",
            options: .regularExpression
        )

        // Normalize punctuation spacing
        text = text.replacingOccurrences(of: "\\s*,\\s*", with: ", ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        let withoutTags = text.replacingOccurrences(
            of: #"(?i)(?<!\S)#[\p{L}\p{N}_-]+"#,
            with: "",
            options: .regularExpression
        )
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)

        return NormalizationResult(text: text, textRemovingTags: withoutTags)
    }

    func extractTags(from text: String) -> [String] {
        let pattern = #"(?i)(?<!\S)#([\p{L}\p{N}_-]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let nsRange = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: nsRange)

        var seen = Set<String>()
        var result: [String] = []

        for match in matches {
            guard match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: text) else {
                continue
            }

            let tag = String(text[range]).lowercased()
            if !seen.contains(tag) {
                seen.insert(tag)
                result.append(tag)
            }
        }

        return result
    }

    func detectRecurrence(in text: String) -> ExtractionResult<String>? {
        let patterns: [(String, String)] = [
            (#"(?i)\b(cada día|cada dia|diario|daily|every day)\b"#, "daily"),
            (#"(?i)\b(cada semana|semanal|weekly|every week)\b"#, "weekly"),
            (#"(?i)\b(cada mes|mensual|monthly|every month)\b"#, "monthly"),
            (#"(?i)\b(cada año|cada ano|anual|yearly|every year|annually)\b"#, "yearly")
        ]

        for (pattern, recurrence) in patterns {
            if let range = firstRegexRange(pattern, in: text) {
                return ExtractionResult(value: recurrence, range: range)
            }
        }

        return nil
    }

    func detectPlace(in text: String) -> ExtractionResult<String>? {
        let patterns = [
            #"(?i)\s@([^\.,;]+)"#,
            #"(?i)\b(?:at|en)\s+([^\.,;]+)"#,
            #"(?i)\b(?:location|ubicación|ubicacion|lugar)\s*:\s*([^\.,;]+)"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let nsRange = NSRange(text.startIndex..., in: text)
            guard let match = regex.firstMatch(in: text, range: nsRange),
                  match.numberOfRanges > 1,
                  let fullRange = Range(match.range(at: 0), in: text),
                  let valueRange = Range(match.range(at: 1), in: text) else {
                continue
            }

            let value = String(text[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }

            return ExtractionResult(value: value, range: fullRange)
        }

        return nil
    }

    func detectDate(in text: String) -> DateExtraction? {
        // 1) Relative expressions first so NSDataDetector doesn't swallow the title
        // in phrases like "Dinner tomorrow".
        if let relativeMatch = detectRelativeDate(in: text) {
            return relativeMatch
        }

        // 2) Explicit numeric forms interpreted as day/month
        if let numericMatch = detectNumericDate(in: text) {
            return numericMatch
        }

        // 3) Month-name forms in Spanish/English
        if let monthNameMatch = detectMonthNameDate(in: text) {
            return monthNameMatch
        }

        // 4) Natural language via NSDataDetector
        if let detectorMatch = detectDateWithNSDataDetector(in: text) {
            return detectorMatch
        }

        return nil
    }

    func detectDateWithNSDataDetector(in text: String) -> DateExtraction? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return nil
        }

        let nsRange = NSRange(text.startIndex..., in: text)
        let matches = detector.matches(in: text, options: [], range: nsRange)

        let now = Date()
        let startToday = calendar.startOfDay(for: now)

        for match in matches {
            guard let date = match.date,
                  let range = Range(match.range, in: text) else {
                continue
            }

            let raw = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty || !isLikelyStandaloneDatePhrase(raw) { continue }

            let normalizedDate = adjustYearIfNeeded(
                candidate: date,
                rawDateText: raw,
                now: now,
                startToday: startToday
            )

            return DateExtraction(date: normalizedDate, range: range)
        }

        return nil
    }

    func detectNumericDate(in text: String) -> DateExtraction? {
        // Supports:
        // 10/03
        // 10-03
        // 10.03
        // 10 03
        // 10/03/2026
        // Always interpreted as day/month[/year]
        let pattern = #"(?i)\b(\d{1,2})[\/\-\.\s](\d{1,2})(?:[\/\-\.\s](\d{2,4}))?\b"#

        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: nsRange),
              let fullRange = Range(match.range(at: 0), in: text),
              let dayRange = Range(match.range(at: 1), in: text),
              let monthRange = Range(match.range(at: 2), in: text) else {
            return nil
        }

        guard let day = Int(text[dayRange]),
              let month = Int(text[monthRange]),
              (1...31).contains(day),
              (1...12).contains(month) else {
            return nil
        }

        let year: Int
        if let yearGroup = Range(match.range(at: 3), in: text),
           let parsedYear = Int(text[yearGroup]) {
            year = parsedYear < 100 ? 2000 + parsedYear : parsedYear
        } else {
            year = inferredYear(forDay: day, month: month)
        }

        guard let date = makeDate(day: day, month: month, year: year) else {
            return nil
        }

        return DateExtraction(date: date, range: fullRange)
    }

    func detectMonthNameDate(in text: String) -> DateExtraction? {
        let monthMap = monthDictionary()

        // "10 marzo [2026]"
        let dayFirstPattern = #"(?i)\b(\d{1,2})\s+([a-záéíóúñ]+)(?:\s+(\d{4}))?\b"#
        if let match = matchMonthNamedDate(
            in: text,
            pattern: dayFirstPattern,
            dayGroup: 1,
            monthGroup: 2,
            yearGroup: 3,
            monthMap: monthMap
        ) {
            return match
        }

        // "marzo 10 [2026]" / "march 10 [2026]"
        let monthFirstPattern = #"(?i)\b([a-záéíóúñ]+)\s+(\d{1,2})(?:\s*,?\s*(\d{4}))?\b"#
        if let match = matchMonthNamedDate(
            in: text,
            pattern: monthFirstPattern,
            dayGroup: 2,
            monthGroup: 1,
            yearGroup: 3,
            monthMap: monthMap
        ) {
            return match
        }

        return nil
    }

    func matchMonthNamedDate(
        in text: String,
        pattern: String,
        dayGroup: Int,
        monthGroup: Int,
        yearGroup: Int,
        monthMap: [String: Int]
    ) -> DateExtraction? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(text.startIndex..., in: text)

        for match in regex.matches(in: text, range: nsRange) {
            guard let fullRange = Range(match.range(at: 0), in: text),
                  let dayRange = Range(match.range(at: dayGroup), in: text),
                  let monthRange = Range(match.range(at: monthGroup), in: text),
                  let day = Int(text[dayRange]) else {
                continue
            }

            let monthKey = normalizeMonthToken(String(text[monthRange]))
            guard let month = monthMap[monthKey] else { continue }

            let year: Int
            if let yearSwiftRange = Range(match.range(at: yearGroup), in: text),
               let parsedYear = Int(text[yearSwiftRange]) {
                year = parsedYear
            } else {
                year = inferredYear(forDay: day, month: month)
            }

            guard let date = makeDate(day: day, month: month, year: year) else { continue }

            return DateExtraction(date: date, range: fullRange)
        }

        return nil
    }

    func detectRelativeDate(in text: String) -> DateExtraction? {
        let lower = text.lowercased()
        let now = Date()

        let simplePatterns: [(String, Int)] = [
            (#"\bayer\b|\byesterday\b"#, -1),
            (#"\bhoy\b|\btoday\b"#, 0),
            (#"\bmañana\b|\bmanana\b|\btomorrow\b"#, 1),
            (#"\bpasado mañana\b|\bpasado manana\b"#, 2)
        ]

        for (pattern, offset) in simplePatterns {
            if let range = firstRegexRange(pattern, in: lower) {
                let base = calendar.startOfDay(for: now)
                let date = calendar.date(byAdding: .day, value: offset, to: base) ?? base
                let dateWithPossibleTime = applyTimeIfPresent(in: text, to: date)
                return DateExtraction(date: dateWithPossibleTime, range: range)
            }
        }

        // in X days / en X días
        let inDaysPattern = #"(?i)\b(?:in|en)\s+(\d{1,3})\s+(?:days|day|días|dias|día|dia)\b"#
        if let regex = try? NSRegularExpression(pattern: inDaysPattern) {
            let nsRange = NSRange(text.startIndex..., in: text)
            if let match = regex.firstMatch(in: text, range: nsRange),
               let fullRange = Range(match.range(at: 0), in: text),
               let countRange = Range(match.range(at: 1), in: text),
               let days = Int(text[countRange]) {
                let base = calendar.startOfDay(for: now)
                let date = calendar.date(byAdding: .day, value: days, to: base) ?? base
                let dateWithPossibleTime = applyTimeIfPresent(in: text, to: date)
                return DateExtraction(date: dateWithPossibleTime, range: fullRange)
            }
        }

        // next week / próxima semana
        if let range = firstRegexRange(#"(?i)\b(next week|próxima semana|proxima semana)\b"#, in: text) {
            let base = calendar.startOfDay(for: now)
            let date = calendar.date(byAdding: .day, value: 7, to: base) ?? base
            let dateWithPossibleTime = applyTimeIfPresent(in: text, to: date)
            return DateExtraction(date: dateWithPossibleTime, range: range)
        }

        // next weekday / próximo weekday
        let weekdayPattern = #"(?i)\b(?:next|próximo|proximo)\s+(lunes|martes|miércoles|miercoles|jueves|viernes|sábado|sabado|domingo|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b"#
        if let regex = try? NSRegularExpression(pattern: weekdayPattern) {
            let nsRange = NSRange(text.startIndex..., in: text)
            if let match = regex.firstMatch(in: text, range: nsRange),
               let fullRange = Range(match.range(at: 0), in: text),
                  let weekdayRange = Range(match.range(at: 1), in: text) {
                let token = String(text[weekdayRange]).lowercased()
                if let targetWeekday = weekdayIndex(for: token),
                   let date = nextWeekdayDate(
                    from: now,
                    weekday: targetWeekday,
                    originalText: text,
                    preferFollowingWeek: true
                   ) {
                    return DateExtraction(date: date, range: fullRange)
                }
            }
        }

        // bare weekday / day name only
        let bareWeekdayPattern = #"(?i)\b(lunes|martes|miércoles|miercoles|jueves|viernes|sábado|sabado|domingo|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b"#
        if let regex = try? NSRegularExpression(pattern: bareWeekdayPattern) {
            let nsRange = NSRange(text.startIndex..., in: text)
            if let match = regex.firstMatch(in: text, range: nsRange),
               let fullRange = Range(match.range(at: 0), in: text),
               let weekdayRange = Range(match.range(at: 1), in: text) {
                let token = String(text[weekdayRange]).lowercased()
                if let targetWeekday = weekdayIndex(for: token),
                   let date = nextWeekdayDate(
                    from: now,
                    weekday: targetWeekday,
                    originalText: text,
                    preferFollowingWeek: false
                   ) {
                    return DateExtraction(date: date, range: fullRange)
                }
            }
        }

        return nil
    }
}

// MARK: - Date Helpers

private extension EventParser {

    func adjustYearIfNeeded(candidate: Date, rawDateText: String, now: Date, startToday: Date) -> Date {
        let raw = rawDateText.lowercased()

        let hasExplicitYear = raw.range(of: #"\b\d{4}\b"#, options: .regularExpression) != nil
        if hasExplicitYear {
            return candidate
        }

        // If only month/day were provided and the result is already in the past,
        // move it to next year.
        let containsMonthWord = monthDictionary().keys.contains { raw.contains($0) }
        let containsNumericDayMonth = raw.range(of: #"\b\d{1,2}[\/\-\.\s]\d{1,2}\b"#, options: .regularExpression) != nil

        if (containsMonthWord || containsNumericDayMonth), candidate < startToday {
            let year = calendar.component(.year, from: candidate) + 1
            let month = calendar.component(.month, from: candidate)
            let day = calendar.component(.day, from: candidate)
            let hour = calendar.component(.hour, from: candidate)
            let minute = calendar.component(.minute, from: candidate)

            var components = DateComponents()
            components.year = year
            components.month = month
            components.day = day
            components.hour = hour
            components.minute = minute
            components.second = 0
            components.timeZone = timeZone

            return calendar.date(from: components) ?? candidate
        }

        return candidate
    }

    func inferredYear(forDay day: Int, month: Int) -> Int {
        let now = Date()
        let currentYear = calendar.component(.year, from: now)

        guard let thisYearDate = makeDate(day: day, month: month, year: currentYear) else {
            return currentYear
        }

        return thisYearDate < calendar.startOfDay(for: now) ? (currentYear + 1) : currentYear
    }

    func makeDate(day: Int, month: Int, year: Int) -> Date? {
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = timeZone
        components.year = year
        components.month = month
        components.day = day
        components.hour = 9
        components.minute = 0
        components.second = 0
        return calendar.date(from: components)
    }

    func applyTimeIfPresent(in text: String, to date: Date) -> Date {
        // 8pm, 8 pm, 8:30pm, 20:30, 8:30 pm
        let patterns = [
            #"(?i)\b(\d{1,2})(?::(\d{2}))?\s?(am|pm)\b"#,
            #"(?i)\b(\d{1,2}):(\d{2})\b"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let nsRange = NSRange(text.startIndex..., in: text)

            guard let match = regex.firstMatch(in: text, range: nsRange),
                  let hourRange = Range(match.range(at: 1), in: text),
                  let rawHour = Int(text[hourRange]) else {
                continue
            }

            let minute: Int = {
                if let minuteRange = Range(match.range(at: 2), in: text),
                   let value = Int(text[minuteRange]) {
                    return value
                }
                return 0
            }()

            var hour = rawHour

            if let meridiemRange = Range(match.range(at: 3), in: text) {
                let meridiem = String(text[meridiemRange]).lowercased()
                if meridiem == "pm", hour < 12 { hour += 12 }
                if meridiem == "am", hour == 12 { hour = 0 }
            }

            if !(0...23).contains(hour) || !(0...59).contains(minute) {
                return date
            }

            var comps = calendar.dateComponents([.year, .month, .day], from: date)
            comps.hour = hour
            comps.minute = minute
            comps.second = 0
            comps.timeZone = timeZone

            return calendar.date(from: comps) ?? date
        }

        return date
    }

    func weekdayIndex(for token: String) -> Int? {
        switch token {
        case "domingo", "sunday": return 1
        case "lunes", "monday": return 2
        case "martes", "tuesday": return 3
        case "miércoles", "miercoles", "wednesday": return 4
        case "jueves", "thursday": return 5
        case "viernes", "friday": return 6
        case "sábado", "sabado", "saturday": return 7
        default: return nil
        }
    }

    func nextWeekdayDate(
        from base: Date,
        weekday: Int,
        originalText: String,
        preferFollowingWeek: Bool
    ) -> Date? {
        let startOfToday = calendar.startOfDay(for: base)
        let currentWeekday = calendar.component(.weekday, from: startOfToday)

        var offset = weekday - currentWeekday
        if offset < 0 {
            offset += 7
        }

        if preferFollowingWeek && offset == 0 {
            offset = 7
        }

        guard let dayCandidate = calendar.date(byAdding: .day, value: offset, to: startOfToday) else {
            return nil
        }

        var candidate = applyTimeIfPresent(in: originalText, to: dayCandidate)
        if candidate < base {
            candidate = calendar.date(byAdding: .day, value: 7, to: candidate) ?? candidate
        }

        return candidate
    }
}

// MARK: - Text Helpers

private extension EventParser {

    func splitTitleAndNotes(from text: String) -> (title: String, notes: String?) {
        let cleaned = cleanupText(text)

        guard !cleaned.isEmpty else {
            return ("Untitled", nil)
        }

        // Preferred: comma separation
        if let commaIndex = cleaned.firstIndex(of: ",") {
            let title = cleaned[..<commaIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            let notesStart = cleaned.index(after: commaIndex)
            let notes = cleaned[notesStart...].trimmingCharacters(in: .whitespacesAndNewlines)
            return (
                title.isEmpty ? "Untitled" : String(title),
                notes.isEmpty ? nil : String(notes)
            )
        }

        // Heuristic connectors
        let connectors = [
            " with ", " con ", " for ", " para ", " about ", " sobre ",
            " note ", " notes ", " nota ", " notas ", " details ", " detalles ",
            " because ", " por ", " regarding ", " respecto "
        ]

        for connector in connectors {
            if let range = cleaned.range(of: connector, options: .caseInsensitive) {
                let title = cleaned[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                let notes = cleaned[range.lowerBound...].trimmingCharacters(in: .whitespacesAndNewlines)

                if !title.isEmpty {
                    return (String(title), notes.isEmpty ? nil : String(notes))
                }
            }
        }

        // Final fallback:
        // keep the whole remaining string as title to honor "title cannot be null"
        return (cleaned, nil)
    }

    func cleanupText(_ text: String) -> String {
        var value = text
        value = value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: "\\s+,", with: ",", options: .regularExpression)
        value = value.replacingOccurrences(of: ",\\s*,+", with: ", ", options: .regularExpression)
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: ",;.- "))
        value = value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return value
    }

    func remove(range: Range<String.Index>, from text: String) -> String {
        var copy = text
        copy.removeSubrange(range)
        return cleanupText(copy)
    }

    func firstRegexRange(_ pattern: String, in text: String) -> Range<String.Index>? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: nsRange),
              let range = Range(match.range(at: 0), in: text) else {
            return nil
        }
        return range
    }

    func isLikelyStandaloneDatePhrase(_ text: String) -> Bool {
        let normalized = normalizeForDateValidation(text)
        guard !normalized.isEmpty else { return false }

        let allowedWords = Set([
            "today", "tomorrow", "yesterday",
            "hoy", "manana", "mañana", "ayer",
            "next", "proximo", "próximo",
            "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
            "lunes", "martes", "miercoles", "miércoles", "jueves", "viernes", "sabado", "sábado", "domingo",
            "january", "february", "march", "april", "may", "june", "july", "august",
            "september", "october", "november", "december",
            "enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto",
            "septiembre", "setiembre", "octubre", "noviembre", "diciembre",
            "am", "pm", "at", "a", "de", "del", "of", "on"
        ])

        let tokens = normalized.split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return false }

        var recognizedCount = 0

        for token in tokens {
            if allowedWords.contains(token) || token.range(of: #"^\d{1,4}([:\/\.-]\d{1,4})?(am|pm)?$"#, options: .regularExpression) != nil {
                recognizedCount += 1
                continue
            }

            return false
        }

        return recognizedCount > 0
    }

    func normalizeForDateValidation(_ text: String) -> String {
        text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: locale)
            .lowercased()
            .replacingOccurrences(of: "[,]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func normalizeMonthToken(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: locale)
            .lowercased()
    }

    func monthDictionary() -> [String: Int] {
        [
            "enero": 1, "january": 1, "jan": 1,
            "febrero": 2, "february": 2, "feb": 2,
            "marzo": 3, "march": 3, "mar": 3,
            "abril": 4, "april": 4, "abr": 4, "apr": 4,
            "mayo": 5, "may": 5,
            "junio": 6, "june": 6, "jun": 6,
            "julio": 7, "july": 7, "jul": 7,
            "agosto": 8, "august": 8, "ago": 8, "aug": 8,
            "septiembre": 9, "setiembre": 9, "september": 9, "sep": 9, "sept": 9,
            "octubre": 10, "october": 10, "oct": 10,
            "noviembre": 11, "november": 11, "nov": 11,
            "diciembre": 12, "december": 12, "dic": 12, "dec": 12
        ]
    }
}
