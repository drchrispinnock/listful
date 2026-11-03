import Foundation
import Testing
@testable import ListfulCore

private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/London")!
    calendar.firstWeekday = 2
    return calendar
}()

private let locale = Locale(identifier: "en_GB")

private func day(_ text: String) -> Date {
    let parts = text.split(separator: "-").map { Int($0)! }
    return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 15))!
}

private func key(_ schedule: RepeatSchedule, on text: String) -> String {
    schedule.periodKey(for: schedule.occurrence(onOrBefore: day(text), calendar: calendar), calendar: calendar)
}

@Suite struct RepeatScheduleTests {
    @Test func dailyPeriodIsTheDay() {
        #expect(key(RepeatSchedule(frequency: .daily), on: "2026-11-03") == "2026-11-03")
    }

    @Test func weekdaysSkipTheWeekend() {
        let schedule = RepeatSchedule(frequency: .weekdays)
        #expect(key(schedule, on: "2026-11-06") == "2026-11-06") // Friday
        #expect(key(schedule, on: "2026-11-08") == "2026-11-06") // Sunday
        #expect(key(schedule, on: "2026-11-09") == "2026-11-09") // Monday
    }

    @Test func weeklyPeriodStartsOnTheChosenDays() {
        let schedule = RepeatSchedule(frequency: .weekly, weekdays: [2, 4]) // Mon, Wed
        #expect(key(schedule, on: "2026-11-02") == "2026-11-02")
        #expect(key(schedule, on: "2026-11-03") == "2026-11-02")
        #expect(key(schedule, on: "2026-11-04") == "2026-11-04")
        #expect(key(schedule, on: "2026-11-08") == "2026-11-04")
    }

    @Test func monthlyDayIsClampedToShortMonths() {
        let schedule = RepeatSchedule(frequency: .monthly, dayOfMonth: 31)
        #expect(schedule.occurrence(onOrBefore: day("2026-02-28"), calendar: calendar) == calendar.startOfDay(for: day("2026-02-28")))
        #expect(key(schedule, on: "2026-03-30") == "2026-02")
        #expect(key(schedule, on: "2026-03-31") == "2026-03")
    }

    @Test func monthlyBeforeTheDayIsLastMonth() {
        let schedule = RepeatSchedule(frequency: .monthly, dayOfMonth: 15)
        #expect(key(schedule, on: "2026-01-14") == "2025-12")
        #expect(key(schedule, on: "2026-01-15") == "2026-01")
    }

    @Test func lastDayOfMonth() {
        let schedule = RepeatSchedule(frequency: .monthly, dayOfMonth: 0)
        let occurrence = schedule.occurrence(onOrBefore: day("2028-02-29"), calendar: calendar)
        #expect(occurrence == calendar.startOfDay(for: day("2028-02-29")))
        #expect(key(schedule, on: "2028-02-28") == "2028-01")
    }

    @Test func quartersAndYears() {
        #expect(key(RepeatSchedule(frequency: .quarterly), on: "2026-11-03") == "2026-Q4")
        #expect(key(RepeatSchedule(frequency: .quarterly), on: "2026-01-01") == "2026-Q1")
        let yearly = RepeatSchedule(frequency: .yearly, month: 4, day: 6)
        #expect(key(yearly, on: "2026-04-05") == "2025")
        #expect(key(yearly, on: "2026-04-06") == "2026")
    }

    @Test func labels() {
        let occurrence = calendar.startOfDay(for: day("2026-11-03"))
        #expect(RepeatSchedule(frequency: .daily).periodLabel(for: occurrence, calendar: calendar, locale: locale) == "Tue 3 Nov")
        #expect(RepeatSchedule(frequency: .monthly).periodLabel(for: occurrence, calendar: calendar, locale: locale) == "November 2026")
        #expect(RepeatSchedule(frequency: .quarterly).periodLabel(for: occurrence, calendar: calendar, locale: locale) == "Q4 2026")
    }

    @Test func keysAreRecognisedByFrequency() {
        #expect(RepeatSchedule(frequency: .daily).isPeriodKey("2026-11-03"))
        #expect(!RepeatSchedule(frequency: .daily).isPeriodKey("2026-11"))
        #expect(RepeatSchedule(frequency: .quarterly).isPeriodKey("2026-Q4"))
        #expect(!RepeatSchedule(frequency: .yearly).isPeriodKey("notes"))
    }

    @Test func markerRoundTrips() {
        let schedules = [
            RepeatSchedule(frequency: .daily, carriesOver: true),
            RepeatSchedule(frequency: .weekly, weekdays: [2, 4, 6]),
            RepeatSchedule(frequency: .monthly, dayOfMonth: 0, carriesOver: true),
            RepeatSchedule(frequency: .yearly, month: 11, day: 3),
        ]
        for schedule in schedules {
            let outline = Outline(title: "Routine", items: [TaskItem(title: "Stretch")], schedule: schedule)
            let text = MarkdownCodec.encode(outline)
            let decoded = MarkdownCodec.decode(text)
            #expect(decoded.schedule == schedule)
            #expect(decoded.title == "Routine")
            #expect(decoded.items.map(\.title) == ["Stretch"])
            #expect(MarkdownCodec.encode(decoded) == text)
        }
    }

    @Test func templateFileFormat() {
        let outline = Outline(
            title: "Routine", items: [TaskItem(title: "Stretch")],
            schedule: RepeatSchedule(frequency: .weekly, weekdays: [4, 2], carriesOver: true))
        #expect(MarkdownCodec.encode(outline) == """
            # Routine
            <!-- listful: repeat=weekly:mon,wed carry-over -->

            - [ ] Stretch

            """)
        #expect(MarkdownCodec.title(in: "<!-- listful: repeat=daily -->\n# Routine\n") == "Routine")
    }
}

@Suite struct CarryOverTests {
    private func outline(_ text: String) -> Outline { MarkdownCodec.decode(text) }

    private func copy(_ template: String, previous: String? = nil) -> (copy: String, previous: String?) {
        let made = RepeatingChecklists.makeCopy(
            of: outline(template), name: "Routine", label: "Tue 3 Nov",
            carryingOverFrom: previous.map(outline))
        return (MarkdownCodec.encode(made.copy), made.previous.map(MarkdownCodec.encode))
    }

    @Test func copyResetsTasksAndDropsTheSchedule() {
        let made = copy("""
            # Routine
            <!-- listful: repeat=daily -->
            - [x] Stretch
            - [ ] Plan
            """)
        #expect(made.copy == "# Routine — Tue 3 Nov\n\n- [ ] Stretch\n- [ ] Plan\n")
        #expect(made.previous == nil)
    }

    @Test func blankTasksAreNeitherCopiedNorCarried() {
        let made = copy("- [ ] Rise\n  - [ ] \n- [ ] \n", previous: "- [ ] Call Bob\n- [ ] \n")
        #expect(made.copy == "# Routine — Tue 3 Nov\n\n- [ ] Call Bob\n- [ ] Rise\n")
        #expect(made.previous == "- [ ] \n")
    }

    @Test func unfinishedTasksMoveToTheTop() {
        let made = copy("- [ ] Stretch\n", previous: """
            # Routine — Mon 2 Nov
            - [x] Stretch
            - [ ] Call Bob
              - [x] Find number
            - [ ] Email Ann
            """)
        #expect(made.copy == """
            # Routine — Tue 3 Nov

            - [ ] Call Bob
              - [x] Find number
            - [ ] Email Ann
            - [ ] Stretch

            """)
        #expect(made.previous == "# Routine — Mon 2 Nov\n\n- [x] Stretch\n")
    }

    @Test func openSubtasksOfDoneTasksMoveOnTheirOwn() {
        let made = copy("- [ ] Stretch\n", previous: """
            - [x] Project
              - [x] Draft
              - [ ] Review
            """)
        #expect(made.copy.contains("- [ ] Review\n- [ ] Stretch"))
        #expect(made.previous == "- [x] Project\n  - [x] Draft\n")
    }

    @Test func templateTasksAreNotDuplicated() {
        let made = copy("- [ ] Stretch\n- [ ] Plan\n", previous: """
            - [ ] Stretch
              - [ ] Hamstrings
            - [x] Plan
            """)
        #expect(made.copy == "# Routine — Tue 3 Nov\n\n- [ ] Stretch\n  - [ ] Hamstrings\n- [ ] Plan\n")
        #expect(made.previous == "- [x] Plan\n")
    }

    @Test func tasksKeepTheirHeadings() {
        let made = copy("""
            ## Morning

            - [ ] Stretch

            ## Evening

            - [ ] Read
            """, previous: """
            ## Evening

            - [ ] Tidy desk

            ## Errands

            - [ ] Post office
            """)
        #expect(made.copy == """
            # Routine — Tue 3 Nov

            ## Morning

            - [ ] Stretch

            ## Evening

            - [ ] Tidy desk
            - [ ] Read

            ## Errands

            - [ ] Post office

            """)
        #expect(made.previous == "## Evening\n\n## Errands\n")
    }
}

@Suite struct MakeDueCopiesTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "RepeatingTests-\(UUID().uuidString)")
    var lists: TaskLibrary { TaskLibrary(folderURL: folder) }
    var templates: TaskLibrary { TaskLibrary(folderURL: lists.templatesFolderURL) }

    func cleanUp() { try? FileManager.default.removeItem(at: folder) }

    private func run(on text: String) -> [RepeatingChecklists.Result] {
        RepeatingChecklists.makeDueCopies(templates: templates, lists: lists, date: day(text), calendar: calendar, locale: locale)
    }

    private func read(_ name: String) throws -> String? {
        try MarkdownFileStore(fileURL: lists.url(forName: name)).readText()
    }

    @Test func makesEachPeriodsCopyOnceAndCarriesOver() throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: templates.folderURL, withIntermediateDirectories: true)
        try templates.createList(named: "Routine", contents: Outline(
            title: "Routine", items: [TaskItem(title: "Stretch")],
            schedule: RepeatSchedule(frequency: .daily, carriesOver: true)))

        #expect(run(on: "2026-11-02").compactMap(\.copy) == [lists.url(forName: "Routine 2026-11-02")])
        #expect(run(on: "2026-11-02").isEmpty)

        let monday = lists.url(forName: "Routine 2026-11-02")
        try "# Routine — Mon 2 Nov\n\n- [x] Stretch\n- [ ] Call Bob\n".write(to: monday, atomically: true, encoding: .utf8)

        // Wednesday after a day off: one copy, carrying over from Monday's.
        let results = run(on: "2026-11-04")
        #expect(results.map(\.previous) == [monday])
        #expect(try read("Routine 2026-11-04") == "# Routine — Wed 4 Nov\n\n- [ ] Call Bob\n- [ ] Stretch\n")
        #expect(try read("Routine 2026-11-02") == "# Routine — Mon 2 Nov\n\n- [x] Stretch\n")
        #expect(try read("Routine 2026-11-03") == nil)
    }

    @Test func emptyTemplatesAreSkipped() throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: templates.folderURL, withIntermediateDirectories: true)
        try templates.createList(named: "New", contents: Outline(
            title: "New", items: [TaskItem(title: "")], schedule: RepeatSchedule()))
        try templates.createList(named: "Plain", contents: Outline(items: [TaskItem(title: "No schedule")]))
        #expect(run(on: "2026-11-02").isEmpty)
        #expect(try lists.lists().isEmpty)
    }
}
