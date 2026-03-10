//
//  ContentView.swift
//  re.mind
//
//  Created by Raul Sanchez on 9/3/26.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.isSearching) private var isSearching
    @Query(sort: \Reminder.createdOn, order: .reverse) private var reminders: [Reminder]

    @AppStorage("selectedCalendarIdentifier") private var selectedCalendarIdentifier = ""
    @State private var searchText = ""
    @State private var searchScope: ReminderSearchScope = .all
    @State private var selectedTagFilters = Set<String>()
    @State private var selectedDayFilter: ReminderDayFilter?
    @State private var calendarOptions: [CalendarBindingOption] = []
    @State private var calendarStatusMessage: String?

    init() {}

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ReminderQuickAddSectionView { text in
                        addReminder(from: text)
                    }
                }

                if !selectedTagFilters.isEmpty || selectedDayFilter != nil {
                    Section("Filters") {
                        ReminderActiveFiltersView(
                            selectedTags: $selectedTagFilters,
                            selectedDayFilter: $selectedDayFilter
                        )
                    }
                }

                Section("My Reminders") {
                    if reminders.isEmpty {
                        ContentUnavailableView(
                            "No reminders yet",
                            systemImage: "list.bullet",
                            description: Text("Add one above using natural language.")
                        )
                    } else if filteredReminders.isEmpty {
                        ContentUnavailableView(
                            "No matching reminders",
                            systemImage: "magnifyingglass",
                            description: Text("Try a different search, tag filter, or day filter.")
                        )
                    } else {
                        ForEach(filteredReminders) { reminder in
                            ReminderRowView(reminder: reminder)
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                if let url = reminder.preferredMapURL {
                                    Button("Map", systemImage: "globe") {
                                        MapsLauncher.open(url)
                                    }
                                    .tint(.green)
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button("Delete", systemImage: "trash") {
                                    delete(reminder)
                                }
                                .tint(.red)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Reminders")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        calendarMenuContent
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search reminders")
            .searchScopes($searchScope) {
                Text("All").tag(ReminderSearchScope.all)
                Text("Tags").tag(ReminderSearchScope.tags)
                Text("Days").tag(ReminderSearchScope.days)
            }
            .searchSuggestions {
                if isSearching {
                    ReminderSearchSuggestions(
                        searchScope: searchScope,
                        query: searchText,
                        selectedTags: selectedTagFilters,
                        selectedDayFilter: selectedDayFilter,
                        availableTags: availableTags
                    ) { tag in
                        selectedTagFilters.insert(tag)
                    } onSelectDay: { filter in
                        selectedDayFilter = filter
                    }
                }
            }
            .task {
                await loadCalendarOptions()
            }
            .alert("Calendar Sync", isPresented: calendarStatusAlertIsPresented) {
                Button("OK", role: .cancel) {
                    calendarStatusMessage = nil
                }
            } message: {
                Text(calendarStatusMessage ?? "")
            }
        }
    }

    private var filteredReminders: [Reminder] {
        reminders.filter { reminder in
            matchesSearchText(reminder) &&
            matchesTagFilters(reminder) &&
            matchesDayFilter(reminder)
        }
    }

    private var availableTags: [String] {
        Array(Set(reminders.flatMap(\.tags)))
            .sorted { lhs, rhs in
                lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
            }
    }

    private var selectedCalendarOption: CalendarBindingOption? {
        calendarOptions.first { $0.id == selectedCalendarIdentifier }
    }

    private var calendarStatusAlertIsPresented: Binding<Bool> {
        Binding(
            get: { calendarStatusMessage != nil },
            set: { isPresented in
                if !isPresented {
                    calendarStatusMessage = nil
                }
            }
        )
    }

    private func matchesSearchText(_ reminder: Reminder) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }

        let haystack = [
            reminder.title,
            reminder.notes,
            reminder.place,
            reminder.tags.joined(separator: " ")
        ]
        .compactMap { $0?.lowercased() }
        .joined(separator: " ")

        return haystack.contains(query.lowercased())
    }

    private func matchesTagFilters(_ reminder: Reminder) -> Bool {
        guard !selectedTagFilters.isEmpty else { return true }

        return selectedTagFilters.allSatisfy { tag in
            reminder.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
        }
    }

    private func matchesDayFilter(_ reminder: Reminder) -> Bool {
        guard let selectedDayFilter else { return true }
        return selectedDayFilter.matches(reminder)
    }

    private func addReminder(from text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        withAnimation {
            let reminder = Reminder(interpretationString: trimmed)
            modelContext.insert(reminder)
            persistChanges()

            if !selectedCalendarIdentifier.isEmpty {
                Task {
                    await syncReminderToCalendar(reminder)
                }
            }
        }
    }

    private func delete(_ reminder: Reminder) {
        let reference = CalendarEventReference(
            calendarIdentifier: reminder.calendarIdentifier,
            eventIdentifier: reminder.calendarEventIdentifier,
            calendarItemIdentifier: reminder.calendarItemIdentifier,
            title: reminder.title,
            dueDate: reminder.dueDate
        )

        withAnimation {
            modelContext.delete(reminder)
            persistChanges()
        }

        if reminder.calendarEventIdentifier != nil || reminder.calendarItemIdentifier != nil {
            Task {
                do {
                    try await CalendarSyncService.shared.deleteEvent(reference: reference)
                } catch {
                    calendarStatusMessage = error.localizedDescription
                }
            }
        }
    }

    private func loadCalendarOptions() async {
        do {
            let options = try await CalendarSyncService.shared.availableCalendars()
            calendarOptions = options

            if !selectedCalendarIdentifier.isEmpty,
               options.contains(where: { $0.id == selectedCalendarIdentifier }) == false {
                selectedCalendarIdentifier = ""
            }
        } catch {
            calendarStatusMessage = error.localizedDescription
        }
    }

    private func syncReminderToCalendar(_ reminder: Reminder) async {
        guard !selectedCalendarIdentifier.isEmpty else { return }
        guard reminder.dueDate != nil else {
            calendarStatusMessage = "Calendar sync requires a due date."
            return
        }

        do {
            let result = try await CalendarSyncService.shared.sync(
                reminder: reminder,
                to: selectedCalendarIdentifier
            )

            reminder.calendarIdentifier = selectedCalendarIdentifier
            reminder.calendarEventIdentifier = result.eventIdentifier
            reminder.calendarItemIdentifier = result.calendarItemIdentifier
            persistChanges()
            calendarStatusMessage = nil
        } catch {
            calendarStatusMessage = error.localizedDescription
        }
    }

    @ViewBuilder
    private var calendarMenuContent: some View {
        Section("Calendar Sync") {
            if let selectedCalendarOption {
                Label(selectedCalendarOption.displayName, systemImage: "checkmark.circle.fill")
            } else {
                Text("Store only in app")
            }

            Button("Refresh Calendars", systemImage: "arrow.clockwise") {
                Task {
                    await loadCalendarOptions()
                }
            }

            if !selectedCalendarIdentifier.isEmpty {
                Button("Store Only In App", systemImage: "internaldrive") {
                    selectedCalendarIdentifier = ""
                    calendarStatusMessage = nil
                }
            }
        }

        Section("Choose Calendar") {
            if calendarOptions.isEmpty {
                Text("No calendars loaded")
            } else {
                ForEach(calendarOptions) { option in
                    Button {
                        selectedCalendarIdentifier = option.id
                        calendarStatusMessage = nil
                    } label: {
                        if option.id == selectedCalendarIdentifier {
                            Label(option.displayName, systemImage: "checkmark")
                        } else {
                            Text(option.displayName)
                        }
                    }
                }
            }
        }
    }

    private func persistChanges() {
        do {
            try modelContext.save()
        } catch {
            calendarStatusMessage = error.localizedDescription
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Reminder.self, inMemory: true)
}

struct ReminderQuickAddSectionView: View {
    let onAdd: (String) -> Void

    @State private var reminderText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick Add")
                .font(.headline)

            TextField(
                "Dinner with Ana tomorrow at 7pm at SBG #personal",
                text: $reminderText,
                axis: .vertical
            )
            .lineLimit(2...4)
            .padding(.vertical, 8)
            .submitLabel(.done)
            .onSubmit(addReminder)

            HStack {
                Text("Examples: \"Pay rent on the 1st\" or \"Doctor Friday at 10am @Cedimat\"")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Add", systemImage: "plus.circle.fill") {
                    addReminder()
                }
                .buttonStyle(.borderedProminent)
                .disabled(reminderText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func addReminder() {
        let trimmed = reminderText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        onAdd(trimmed)
        reminderText = ""
    }
}

struct ReminderRowView: View {
    let reminder: Reminder

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            statusIcon

            VStack(alignment: .leading, spacing: 6) {
                Text(reminder.title)
                    .font(.headline)
                    .strikethrough(reminder.isCompleted, color: .secondary)

                if let dueDate = reminder.dueDate {
                    Label {
                        Text(dueDate, format: .dateTime.day().month().hour().minute())
                    } icon: {
                        Image(systemName: "calendar")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }

                if let place = reminder.place, !place.isEmpty {
                    Label(place, systemImage: "mappin.and.ellipse")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if let notes = reminder.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if !reminder.tags.isEmpty {
                    Text(reminder.tags.map { "#\($0)" }.joined(separator: " "))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 12)
        }
        .padding(.vertical, 4)
    }

    private var statusIcon: some View {
        Image(systemName: hasLocation ? "mappin.circle.fill" : "checklist")
            .font(.title3)
            .foregroundStyle(hasLocation ? .blue : .orange)
            .frame(width: 28, height: 28)
    }

    private var hasLocation: Bool {
        reminder.geolocation != nil || !(reminder.place?.isEmpty ?? true)
    }
}

struct ReminderSearchSuggestions: View {
    let searchScope: ReminderSearchScope
    let query: String
    let selectedTags: Set<String>
    let selectedDayFilter: ReminderDayFilter?
    let availableTags: [String]
    let onSelectTag: (String) -> Void
    let onSelectDay: (ReminderDayFilter) -> Void

    var body: some View {
        if showsTagSuggestions {
            ForEach(filteredTags, id: \.self) { tag in
                Button {
                    onSelectTag(tag)
                } label: {
                    Label("#\(tag)", systemImage: "tag")
                }
            }
        }

        if showsDaySuggestions {
            ForEach(filteredDays, id: \.self) { day in
                Button {
                    onSelectDay(day)
                } label: {
                    Label(day.title, systemImage: day.systemImage)
                }
            }
        }
    }

    private var showsTagSuggestions: Bool {
        searchScope == .all || searchScope == .tags
    }

    private var showsDaySuggestions: Bool {
        searchScope == .all || searchScope == .days
    }

    private var filteredTags: [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        return availableTags
            .filter { tag in
                trimmed.isEmpty || tag.localizedCaseInsensitiveContains(trimmed)
            }
            .filter { !selectedTags.contains($0) }
            .prefix(6)
            .map { $0 }
    }

    private var filteredDays: [ReminderDayFilter] {
        ReminderDayFilter.allCases
            .filter { $0 != selectedDayFilter }
    }
}

struct ReminderActiveFiltersView: View {
    @Binding var selectedTags: Set<String>
    @Binding var selectedDayFilter: ReminderDayFilter?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(selectedTags).sorted(), id: \.self) { tag in
                        filterChip("#\(tag)") {
                            selectedTags.remove(tag)
                        }
                    }

                    if let selectedDayFilter {
                        filterChip(selectedDayFilter.title) {
                            self.selectedDayFilter = nil
                        }
                    }
                }
            }

            Button("Clear All Filters") {
                selectedTags.removeAll()
                selectedDayFilter = nil
            }
            .font(.footnote)
        }
    }

    private func filterChip(_ title: String, onRemove: @escaping () -> Void) -> some View {
        Button(action: onRemove) {
            HStack(spacing: 6) {
                Text(title)
                Image(systemName: "xmark.circle.fill")
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

enum ReminderSearchScope: String, CaseIterable, Hashable {
    case all
    case tags
    case days
}

enum ReminderDayFilter: String, CaseIterable, Hashable {
    case today
    case tomorrow
    case upcoming
    case overdue
    case noDate

    var title: String {
        switch self {
        case .today:
            return "Today"
        case .tomorrow:
            return "Tomorrow"
        case .upcoming:
            return "Upcoming"
        case .overdue:
            return "Overdue"
        case .noDate:
            return "No Date"
        }
    }

    var systemImage: String {
        switch self {
        case .today:
            return "sun.max"
        case .tomorrow:
            return "sunrise"
        case .upcoming:
            return "calendar"
        case .overdue:
            return "exclamationmark.triangle"
        case .noDate:
            return "calendar.badge.minus"
        }
    }

    func matches(_ reminder: Reminder) -> Bool {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())

        switch self {
        case .today:
            guard let dueDate = reminder.dueDate else { return false }
            return calendar.isDate(dueDate, inSameDayAs: startOfToday)

        case .tomorrow:
            guard let dueDate = reminder.dueDate,
                  let tomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) else {
                return false
            }
            return calendar.isDate(dueDate, inSameDayAs: tomorrow)

        case .upcoming:
            guard let dueDate = reminder.dueDate else { return false }
            return dueDate >= startOfToday

        case .overdue:
            guard let dueDate = reminder.dueDate else { return false }
            return dueDate < startOfToday

        case .noDate:
            return reminder.dueDate == nil
        }
    }
}
