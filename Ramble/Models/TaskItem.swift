import Foundation
import SwiftData

@Model
final class TaskItem {
    var title: String = ""
    var notes: String = ""
    var dueDate: Date?
    var hasDueTime: Bool = false
    var priorityRaw: Int = 0
    var listName: String = ""
    var isCompleted: Bool = false
    var completedAt: Date?
    var createdAt: Date = Date.now
    var recurrenceData: Data?
    /// Minutes before the due time; 0 = at the due time. Date-only tasks fire at 9:00.
    var reminderMinutes: [Int] = [0]

    @Relationship(deleteRule: .cascade, inverse: \Subtask.task)
    var subtasks: [Subtask]? = []
    /// Set when this to-do was created from a sentence in a note entry.
    var sourceEntry: NoteEntry?
    /// The sentence it came from, as it appears in the entry.
    var sourceQuote: String = ""

    init(title: String, dueDate: Date? = nil, hasDueTime: Bool = false, priority: TaskPriority = .none, listName: String = "") {
        self.title = title
        self.dueDate = dueDate
        self.hasDueTime = hasDueTime
        self.priorityRaw = priority.rawValue
        self.listName = listName
        self.createdAt = .now
    }

    var priority: TaskPriority {
        get { TaskPriority(rawValue: priorityRaw) ?? .none }
        set { priorityRaw = newValue.rawValue }
    }

    var recurrence: Recurrence? {
        get { JSONStore.decode(Recurrence.self, from: recurrenceData) }
        set { recurrenceData = JSONStore.encode(newValue) }
    }

    var sortedSubtasks: [Subtask] {
        (subtasks ?? []).sorted { $0.order < $1.order }
    }

    func isOverdue(now: Date = .now, calendar: Calendar = .current) -> Bool {
        guard let dueDate, !isCompleted else { return false }
        return hasDueTime ? dueDate < now : dueDate < calendar.startOfDay(for: now)
    }

    /// Due today or earlier and still open — what the Today screen shows.
    func isDueByEndOfToday(now: Date = .now, calendar: Calendar = .current) -> Bool {
        guard let dueDate, !isCompleted,
              let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        else { return false }
        return dueDate < tomorrow
    }

    /// Completing a repeating task rolls it to the next occurrence instead of closing it.
    func toggleCompletion(now: Date = .now) {
        if isCompleted {
            isCompleted = false
            completedAt = nil
            return
        }
        if let recurrence, let dueDate, let next = recurrence.nextOccurrence(after: dueDate) {
            self.dueDate = next
            for subtask in subtasks ?? [] { subtask.isDone = false }
        } else {
            isCompleted = true
            completedAt = now
        }
    }
}

@Model
final class Subtask {
    var title: String = ""
    var isDone: Bool = false
    var order: Int = 0
    var task: TaskItem?

    init(title: String, order: Int) {
        self.title = title
        self.order = order
    }
}
