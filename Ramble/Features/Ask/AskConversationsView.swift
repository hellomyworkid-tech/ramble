import SwiftUI

/// The earlier conversations in 问一问, latest first: open one to read it or carry on, swipe to delete.
struct AskConversationsView: View {
    /// The conversation showing behind this page.
    let currentID: UUID
    let open: (AskConversation) -> Void

    private struct Deleted {
        let conversation: AskConversation
        let index: Int
    }

    @State private var conversations = AskHistory.load()
    @State private var deleted: Deleted?
    @State private var confirmDelete: AskConversation?
    @State private var confirmClear = false

    var body: some View {
        List {
            ForEach(conversations) { conversation in
                Button { open(conversation) } label: { row(conversation) }
                    .buttonStyle(.plain)
                    .swipeActions(allowsFullSwipe: false) {
                        SwipeDeleteButton { confirmDelete = conversation }
                    }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color(.systemGroupedBackground))
        .overlay {
            if conversations.isEmpty {
                ContentUnavailableView("还没有历史对话", systemImage: "bubble.left.and.text.bubble.right",
                                       description: Text("问过的问题会按对话留在这里。"))
            }
        }
        .navigationTitle("历史对话")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !conversations.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("清空") { confirmClear = true }
                }
            }
        }
        .deletionAlert(String(localized: "删除这个对话？"), item: $confirmDelete) { conversation in
            Button("删除", role: .destructive) { delete(conversation) }
        } message: { conversation in
            Text("「\(conversation.title)」")
        }
        .alert("清空所有对话？", isPresented: $confirmClear) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) {
                conversations = []
                deleted = nil
                AskHistory.clear()
            }
        } message: {
            Text("只删除问一问里的记录，不会动你的账目、待办和笔记。")
        }
        .safeAreaInset(edge: .bottom) {
            if let deleted {
                UndoBar(text: String(localized: "已删除「\(deleted.conversation.title)」"), systemImage: "trash") { undo(deleted) }
            }
        }
        .animation(.default, value: deleted?.conversation.id)
        .task(id: deleted?.conversation.id) {
            guard deleted != nil else { return }
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled { deleted = nil }
        }
    }

    private func row(_ conversation: AskConversation) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(conversation.title)
                    .lineLimit(1)
                Text(DayText.due(conversation.lastDate, hasTime: true) + " · " + String(localized: "\(conversation.records.count) 个问题"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if conversation.id == currentID {
                Image(systemName: "checkmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tint)
                    .accessibilityLabel("正在看")
            }
        }
        .contentShape(.rect)
    }

    private func delete(_ conversation: AskConversation) {
        guard let index = conversations.firstIndex(of: conversation) else { return }
        conversations.remove(at: index)
        AskHistory.save(conversations)
        deleted = Deleted(conversation: conversation, index: index)
    }

    private func undo(_ deleted: Deleted) {
        conversations.insert(deleted.conversation, at: min(deleted.index, conversations.count))
        AskHistory.save(conversations)
        self.deleted = nil
    }
}
