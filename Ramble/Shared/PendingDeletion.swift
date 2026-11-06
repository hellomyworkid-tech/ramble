import SwiftData
import SwiftUI

/// A record deleted from a list waits 8 seconds for 撤销 before it goes. Until then it is only
/// hidden from the lists and nothing about it changes, so undoing brings everything back: photos,
/// links, reminders. It is deleted for good when the time is up, when something else is deleted,
/// or when the app moves to the background.
@Observable
final class PendingDeletion {
    static let shared = PendingDeletion()

    /// What the bar says, and the records it hides.
    struct Item: Equatable {
        let id = UUID()
        let message: String
        let ids: Set<PersistentIdentifier>

        static func == (lhs: Item, rhs: Item) -> Bool { lhs.id == rhs.id }
    }

    private(set) var current: Item?
    private var models: [any PersistentModel] = []
    private var context: ModelContext?
    private var afterDeleting: (() -> Void)?
    private var timer: Task<Void, Never>?

    /// Whether `model` is waiting to be deleted, and so left out of the lists.
    func hides(_ model: some PersistentModel) -> Bool {
        current?.ids.contains(model.persistentModelID) ?? false
    }

    /// Hides `models` now and deletes them in a few seconds unless 撤销 is tapped. `afterDeleting`
    /// runs only once they are really gone (a note's 「更新于」, say).
    func delete(_ models: [any PersistentModel], message: String, in context: ModelContext,
                then afterDeleting: (() -> Void)? = nil) {
        commit()
        self.models = models
        self.context = context
        self.afterDeleting = afterDeleting
        current = Item(message: message, ids: Set(models.map(\.persistentModelID)))
        timer = Task {
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled { commit() }
        }
    }

    /// Brings the records back as they were.
    func undo() {
        timer?.cancel()
        reset()
    }

    /// Deletes whatever is waiting, now.
    func commit() {
        guard current != nil else { return }
        timer?.cancel()
        if let context {
            for model in models { context.delete(model) }
            afterDeleting?()
            try? context.save()
        }
        reset()
    }

    private func reset() {
        current = nil
        models = []
        context = nil
        afterDeleting = nil
        timer = nil
    }
}

/// A capsule at the bottom saying what just happened, with 撤销.
struct UndoBar: View {
    let text: String
    var systemImage = "checkmark.circle.fill"
    let undo: () -> Void

    var body: some View {
        HStack {
            Label(text, systemImage: systemImage)
                .font(.subheadline)
                .lineLimit(1)
            Spacer()
            Button("撤销", action: undo)
                .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: .capsule)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

extension View {
    /// 「已删除「…」 撤销」 at the bottom while a deleted record waits (`PendingDeletion`).
    func deletionUndoBar() -> some View {
        modifier(DeletionUndoBar())
    }
}

private struct DeletionUndoBar: ViewModifier {
    func body(content: Content) -> some View {
        let pending = PendingDeletion.shared
        content
            // Over the list rather than beside it: making room moved the page when it came and went.
            .overlay(alignment: .bottom) {
                if let item = pending.current {
                    UndoBar(text: item.message, systemImage: "trash") {
                        withAnimation { pending.undo() }
                    }
                    .task(id: item.id) { AccessibilityNotification.Announcement(item.message).post() }
                }
            }
            .animation(.default, value: pending.current)
    }
}
