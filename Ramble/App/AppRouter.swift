import Foundation
import Observation
import SwiftData

/// App-wide navigation that something outside a view (a notification tap) can drive.
@Observable
final class AppRouter {
    static let shared = AppRouter()

    enum Focus: Equatable {
        case task(PersistentIdentifier)
        case bill(PersistentIdentifier, pay: Bool)
        case expiry(PersistentIdentifier)
        case note(PersistentIdentifier)
        case newNote
    }

    var tab: AppTab = .today
    /// The record a tab should open; the tab clears it once handled.
    var focus: Focus?
    /// Set while a screen with its own composer (a note) is showing.
    var hidesCaptureBar = false
    /// A capture Siri, Shortcuts or a widget asked for; the root view opens it.
    var pendingCapture: CaptureStart?
    /// 问一问, optionally with a question to ask straight away.
    var pendingAsk: AskRequest?
    /// The weekly or monthly report to open.
    var pendingReport: PeriodReport.Kind?

    struct AskRequest: Identifiable, Equatable {
        let id = UUID()
        var question: String?
    }

    func ask(_ question: String? = nil) {
        pendingAsk = AskRequest(question: question)
    }

    func openReport(_ kind: PeriodReport.Kind) {
        pendingReport = kind
    }

    func startCapture(_ start: CaptureStart) {
        pendingCapture = start
    }

    /// Links from widgets and Shortcuts: ramble://capture (listening), ramble://capture?text=…,
    /// ramble://ask?q=…, ramble://report?kind=week|month, ramble://today | tasks | notes | ledger | reminders.
    @discardableResult
    func open(_ url: URL) -> Bool {
        guard url.scheme == "ramble" else { return false }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        switch url.host() {
        case "capture":
            let text = components?.queryItems?.first { $0.name == "text" }?.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            startCapture(text.isEmpty ? .voice : .text(text))
        case "ask":
            let question = components?.queryItems?.first { $0.name == "q" }?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
            ask(question?.isEmpty == false ? question : nil)
        case "report":
            openReport(components?.queryItems?.first { $0.name == "kind" }?.value == "month" ? .month : .week)
        case "today": tab = .today
        case "tasks": tab = .tasks
        case "notes": tab = .notes
        case "ledger": tab = .ledger
        case "reminders": tab = .reminders
        default: return false
        }
        return true
    }

    func open(_ note: Note) {
        tab = .notes
        focus = .note(note.persistentModelID)
    }

    func openNewNote() {
        tab = .notes
        focus = .newNote
    }

    func open(_ target: PlannedReminder.Target?, id: String, pay: Bool = false) {
        guard let target else { return }
        if target == .openApp {
            tab = .today
            return
        }
        if target == .report {
            openReport(id == "month" ? .month : .week)
            return
        }
        guard let identifier = ModelRef.decode(id) else { return }
        switch target {
        case .task:
            tab = .tasks
            focus = .task(identifier)
        case .bill:
            tab = .reminders
            focus = .bill(identifier, pay: pay)
        case .expiry:
            tab = .reminders
            focus = .expiry(identifier)
        case .openApp, .report:
            break
        }
    }
}
