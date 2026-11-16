import SwiftData
import SwiftUI

extension LedgerCategory {
    /// One the person names while recording (自定义): the one of this kind already called that, or a
    /// new one at the end of the list with a plain icon and the next color along. Both can be
    /// changed later in 设置 › 分类.
    static func custom(named name: String, kind: CategoryKind, in context: ModelContext) -> LedgerCategory? {
        let wanted = name.trimmed
        guard !wanted.isEmpty else { return nil }
        let raw = kind.rawValue
        let sameKind = (try? context.fetch(FetchDescriptor<LedgerCategory>(predicate: #Predicate { $0.kindRaw == raw }))) ?? []
        let named = sameKind.filter { $0.name.compare(wanted, options: .caseInsensitive) == .orderedSame }
        if let existing = named.first(where: { $0.parent == nil }) ?? named.first { return existing }
        let colors = CategoryEditorView.colors
        let category = LedgerCategory(name: wanted, kind: kind, symbol: "tag.fill", colorHex: colors[sameKind.count % colors.count],
                                      sortOrder: (sameKind.map(\.sortOrder).max() ?? -1) + 1)
        context.insert(category)
        return category
    }
}

extension View {
    /// Asks for a name and hands back the category of `kind` called that, new or not.
    func newCategoryAlert(isPresented: Binding<Bool>, kind: CategoryKind, onCreate: @escaping (LedgerCategory) -> Void) -> some View {
        modifier(NewCategoryAlert(isPresented: isPresented, kind: kind, onCreate: onCreate))
    }
}

private struct NewCategoryAlert: ViewModifier {
    @Binding var isPresented: Bool
    let kind: CategoryKind
    let onCreate: (LedgerCategory) -> Void

    @Environment(\.modelContext) private var context
    @State private var name = ""

    func body(content: Content) -> some View {
        content.alert(kind == .income ? "自定义收入分类" : "自定义支出分类", isPresented: $isPresented) {
            TextField(kind == .income ? "如 兼职、房租收入" : "如 宠物、育儿", text: $name)
            Button("取消", role: .cancel) { name = "" }
            Button("添加") {
                if let category = LedgerCategory.custom(named: name, kind: kind, in: context) { onCreate(category) }
                name = ""
            }
        } message: {
            Text("图标和颜色可以在「设置 › 分类」里改。")
        }
    }
}

/// 「分类」 as a menu that ends with 自定义…, for forms where the category is one line among others.
struct CategoryField: View {
    let title: LocalizedStringResource
    let kind: CategoryKind
    /// Already narrowed to `kind`.
    let categories: [LedgerCategory]
    @Binding var selection: LedgerCategory?
    /// What having none is called here: 未分类, or 不指定 for a bill.
    var noneTitle: LocalizedStringResource = "未分类"

    @State private var isNaming = false

    var body: some View {
        LabeledContent {
            Menu {
                Button(String(localized: noneTitle)) { selection = nil }
                ForEach(categories) { category in
                    Button {
                        selection = category
                    } label: {
                        if category == selection {
                            Label(category.name, systemImage: "checkmark")
                        } else {
                            Text(category.name)
                        }
                    }
                }
                Divider()
                Button("自定义…", systemImage: "plus") { isNaming = true }
            } label: {
                HStack(spacing: 4) {
                    Text(selection?.name ?? String(localized: noneTitle))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(.secondary)
            }
        } label: {
            Text(title)
        }
        .newCategoryAlert(isPresented: $isNaming, kind: kind) { selection = $0 }
    }
}
