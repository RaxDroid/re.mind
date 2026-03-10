//
//  CalendarSync.swift
//  re.mind
//

import Foundation
import EventKit

struct CalendarBindingOption: Identifiable, Hashable {
    let id: String
    let title: String
    let sourceTitle: String

    var displayName: String {
        sourceTitle.isEmpty ? title : "\(title) (\(sourceTitle))"
    }
}

struct CalendarEventReference {
    let calendarIdentifier: String?
    let eventIdentifier: String?
    let calendarItemIdentifier: String?
    let title: String
    let dueDate: Date?
}

struct CalendarSyncResult {
    let eventIdentifier: String
    let calendarItemIdentifier: String
}

enum CalendarSyncError: LocalizedError {
    case accessDenied
    case calendarNotFound
    case missingDueDate

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Calendar access was denied."
        case .calendarNotFound:
            return "The selected calendar could not be found."
        case .missingDueDate:
            return "A due date is required to sync this reminder to calendar."
        }
    }
}

@MainActor
final class CalendarSyncService {
    static let shared = CalendarSyncService()

    private let store = EKEventStore()

    private init() {}

    func availableCalendars() async throws -> [CalendarBindingOption] {
        try await ensureAccess()

        return store.calendars(for: .event)
            .filter(\.allowsContentModifications)
            .map {
                CalendarBindingOption(
                    id: $0.calendarIdentifier,
                    title: $0.title,
                    sourceTitle: $0.source.title
                )
            }
            .sorted { lhs, rhs in
                if lhs.sourceTitle == rhs.sourceTitle {
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }

                return lhs.sourceTitle.localizedCaseInsensitiveCompare(rhs.sourceTitle) == .orderedAscending
            }
    }

    func sync(reminder: Reminder, to calendarIdentifier: String) async throws -> CalendarSyncResult {
        try await ensureAccess()

        guard let dueDate = reminder.dueDate else {
            throw CalendarSyncError.missingDueDate
        }

        guard let calendar = store.calendar(withIdentifier: calendarIdentifier) else {
            throw CalendarSyncError.calendarNotFound
        }

        let event: EKEvent
        if let existingEvent = resolveEvent(
            calendarIdentifier: calendarIdentifier,
            eventIdentifier: reminder.calendarEventIdentifier,
            calendarItemIdentifier: reminder.calendarItemIdentifier,
            title: reminder.title,
            dueDate: reminder.dueDate
        ) {
            event = existingEvent
        } else {
            event = EKEvent(eventStore: store)
        }

        event.calendar = calendar
        event.title = reminder.title
        event.startDate = dueDate
        event.endDate = Calendar.current.date(byAdding: .hour, value: 1, to: dueDate) ?? dueDate.addingTimeInterval(3600)
        event.location = reminder.place
        event.notes = buildNotes(for: reminder)
        event.recurrenceRules = recurrenceRules(for: reminder.recurrence)

        try store.save(event, span: .thisEvent, commit: true)
        return CalendarSyncResult(
            eventIdentifier: event.eventIdentifier,
            calendarItemIdentifier: event.calendarItemIdentifier
        )
    }

    func deleteEvent(reference: CalendarEventReference) async throws {
        try await ensureAccess()

        guard let event = resolveEvent(
            calendarIdentifier: reference.calendarIdentifier,
            eventIdentifier: reference.eventIdentifier,
            calendarItemIdentifier: reference.calendarItemIdentifier,
            title: reference.title,
            dueDate: reference.dueDate
        ) else {
            return
        }

        let span: EKSpan = event.recurrenceRules?.isEmpty == false ? .futureEvents : .thisEvent
        try store.remove(event, span: span, commit: true)
    }

    private func ensureAccess() async throws {
        if hasAccess {
            return
        }

        let granted: Bool
        if #available(iOS 17.0, *) {
            granted = try await store.requestFullAccessToEvents()
        } else {
            granted = try await withCheckedThrowingContinuation { continuation in
                store.requestAccess(to: .event) { accessGranted, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: accessGranted)
                    }
                }
            }
        }

        guard granted, hasAccess else {
            throw CalendarSyncError.accessDenied
        }
    }

    private var hasAccess: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)

        if #available(iOS 17.0, *) {
            return status == .fullAccess || status == .writeOnly
        } else {
            return status == .authorized
        }
    }

    private func buildNotes(for reminder: Reminder) -> String? {
        var parts: [String] = []

        if let notes = reminder.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            parts.append(notes)
        }

        if !reminder.tags.isEmpty {
            parts.append(reminder.tags.map { "#\($0)" }.joined(separator: " "))
        }

        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    private func recurrenceRules(for value: String?) -> [EKRecurrenceRule]? {
        guard let value else { return nil }

        let frequency: EKRecurrenceFrequency
        switch value {
        case "daily":
            frequency = .daily
        case "weekly":
            frequency = .weekly
        case "monthly":
            frequency = .monthly
        case "yearly":
            frequency = .yearly
        default:
            return nil
        }

        return [EKRecurrenceRule(recurrenceWith: frequency, interval: 1, end: nil)]
    }

    private func resolveEvent(
        calendarIdentifier: String?,
        eventIdentifier _: String?,
        calendarItemIdentifier: String?,
        title: String,
        dueDate: Date?
    ) -> EKEvent? {
        if let calendarItemIdentifier,
           let item = store.calendarItem(withIdentifier: calendarItemIdentifier) as? EKEvent {
            return item
        }

        guard let dueDate else { return nil }

        let start = Calendar.current.date(byAdding: .day, value: -2, to: dueDate) ?? dueDate
        let end = Calendar.current.date(byAdding: .day, value: 30, to: dueDate) ?? dueDate

        let calendars: [EKCalendar]?
        if let calendarIdentifier,
           let calendar = store.calendar(withIdentifier: calendarIdentifier) {
            calendars = [calendar]
        } else {
            calendars = nil
        }

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        return store.events(matching: predicate).first { event in
            event.title == title && Calendar.current.isDate(event.startDate, inSameDayAs: dueDate)
        }
    }
}
