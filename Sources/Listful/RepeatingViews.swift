import SwiftUI
import ListfulCore

/// The controls for a repeating checklist's schedule: how often, on which
/// days, and whether unfinished tasks carry over.
struct ScheduleForm: View {
    @Binding var schedule: RepeatSchedule

    private let calendar = Calendar.current

    var body: some View {
        Picker("Repeats", selection: $schedule.frequency) {
            ForEach(RepeatSchedule.Frequency.allCases, id: \.self) { frequency in
                Text(Self.title(of: frequency)).tag(frequency)
            }
        }
        switch schedule.frequency {
        case .weekly:
            LabeledContent("On") {
                HStack(spacing: 4) {
                    ForEach(weekdayOrder, id: \.self) { weekday in
                        Toggle(calendar.veryShortWeekdaySymbols[weekday - 1], isOn: weekdayBinding(weekday))
                            .toggleStyle(.button)
                            .help(calendar.weekdaySymbols[weekday - 1])
                    }
                }
            }
        case .monthly:
            Picker("On", selection: $schedule.dayOfMonth) { dayChoices }
        case .yearly:
            Picker("Month", selection: $schedule.month) {
                ForEach(1...12, id: \.self) { Text(calendar.monthSymbols[$0 - 1]).tag($0) }
            }
            Picker("Day", selection: $schedule.day) { dayChoices }
        case .daily, .weekdays, .quarterly:
            EmptyView()
        }
        Toggle(isOn: $schedule.carriesOver) {
            Text("Carry over unfinished tasks")
            Text("Each new copy starts with the previous copy's open tasks, which are moved out of it.")
        }
    }

    @ViewBuilder private var dayChoices: some View {
        ForEach(1...31, id: \.self) { Text(ordinal($0)).tag($0) }
        Text("Last day").tag(0)
    }

    private var weekdayOrder: [Int] {
        (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
    }

    /// Toggles one weekday, keeping at least one chosen.
    private func weekdayBinding(_ weekday: Int) -> Binding<Bool> {
        Binding(
            get: { schedule.weekdays.contains(weekday) },
            set: { on in
                if on {
                    schedule.weekdays.insert(weekday)
                } else if schedule.weekdays.count > 1 {
                    schedule.weekdays.remove(weekday)
                }
            })
    }

    private func ordinal(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        return formatter.string(from: n as NSNumber) ?? "\(n)"
    }

    static func title(of frequency: RepeatSchedule.Frequency) -> String {
        switch frequency {
        case .daily: "Every day"
        case .weekdays: "Every weekday"
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        case .quarterly: "Quarterly"
        case .yearly: "Yearly"
        }
    }
}

/// File ▸ New Repeating Checklist…: names the template and sets its schedule.
struct NewRepeatingSheet: View {
    @Bindable var library: LibraryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField("Name", text: $library.nameDraft)
                ScheduleForm(schedule: $library.scheduleDraft)
            }
            .formStyle(.grouped)
            Text("You'll fill in the checklist next. Listful makes a fresh copy of it, named with the date, each time it's due.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { library.isCreatingRepeating = false }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { library.commitNewRepeating() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 420)
    }
}

/// Changes an open template's schedule.
struct EditScheduleSheet: View {
    @Bindable var document: TaskDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                ScheduleForm(schedule: $document.scheduleDraft)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { document.isEditingSchedule = false }
                    .keyboardShortcut(.cancelAction)
                Button("Done") { document.commitSchedule() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 420)
    }
}

/// Shown above a template's tasks: what it is, and how often it repeats.
struct ScheduleBar: View {
    let schedule: RepeatSchedule
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "repeat")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(schedule.summary(calendar: .current, locale: .current))
                Text(schedule.carriesOver
                     ? "Template. Each copy takes over the last one's unfinished tasks."
                     : "Template. Each copy starts fresh.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Edit…", action: onEdit)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}
