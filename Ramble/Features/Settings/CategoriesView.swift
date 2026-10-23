import SwiftData
import SwiftUI

struct CategoriesView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \LedgerCategory.sortOrder) private var categories: [LedgerCategory]
    @State private var kind: CategoryKind = .expense
    @State private var editingCategory: LedgerCategory?
    @State private var isCreating = false

    var body: some View {
        List {
            Section {
                Picker("类型", selection: $kind) {
                    ForEach(CategoryKind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
            Section {
                ForEach(visible) { category in
                    HStack(spacing: 12) {
                        IconTile(symbol: category.symbol, color: Color(hex: category.colorHex))
                        Text(category.name)
                        Spacer()
                        Text("\(category.entries?.count ?? 0) 笔")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(.rect)
                    .onTapGesture { editingCategory = category }
                }
                .onMove(perform: move)
                .onDelete(perform: delete)
            } footer: {
                Text("删除分类后，已有的记账会变成「未分类」。")
            }
        }
        .navigationTitle(Text(ScreenName.categories))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
            ToolbarItem(placement: .topBarTrailing) {
                Button("新建分类", systemImage: "plus") { isCreating = true }
            }
        }
        .sheet(isPresented: $isCreating) {
            NavigationStack { CategoryEditorView(category: nil, kind: kind, nextSortOrder: (visible.map(\.sortOrder).max() ?? -1) + 1) }
        }
        .sheet(item: $editingCategory) { category in
            NavigationStack { CategoryEditorView(category: category, kind: category.kind, nextSortOrder: category.sortOrder) }
        }
    }

    private var visible: [LedgerCategory] {
        categories.filter { $0.kind == kind && $0.parent == nil }
    }

    private func move(from source: IndexSet, to destination: Int) {
        var ordered = visible
        ordered.move(fromOffsets: source, toOffset: destination)
        for (index, category) in ordered.enumerated() {
            category.sortOrder = index
        }
    }

    private func delete(at offsets: IndexSet) {
        let list = visible
        for index in offsets {
            context.delete(list[index])
        }
    }
}

struct CategoryEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let category: LedgerCategory?
    let kind: CategoryKind
    let nextSortOrder: Int

    @State private var name: String
    @State private var symbol: String
    @State private var colorHex: String

    static let symbols = [
        "fork.knife", "cup.and.saucer.fill", "cart.fill", "bag.fill", "tram.fill", "car.fill", "fuelpump.fill", "airplane",
        "house.fill", "bolt.fill", "drop.fill", "wifi", "phone.fill", "tv.fill", "gamecontroller.fill", "film.fill",
        "book.fill", "graduationcap.fill", "cross.case.fill", "pills.fill", "dumbbell.fill", "pawprint.fill", "gift.fill", "heart.fill",
        "tshirt.fill", "scissors", "figure.and.child.holdinghands", "briefcase.fill", "star.fill", "chart.line.uptrend.xyaxis", "banknote.fill", "ellipsis.circle.fill",
    ]

    static let colors = ["#D9480F", "#C2570C", "#A16207", "#248A3D", "#0E7C86", "#0A66D8", "#4F46E5", "#8944AB", "#C2185B", "#6E6E73"]

    init(category: LedgerCategory?, kind: CategoryKind, nextSortOrder: Int) {
        self.category = category
        self.kind = kind
        self.nextSortOrder = nextSortOrder
        _name = State(initialValue: category?.name ?? "")
        _symbol = State(initialValue: category?.symbol ?? "tag.fill")
        _colorHex = State(initialValue: category?.colorHex ?? Self.colors[5])
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    IconTile(symbol: symbol, color: Color(hex: colorHex), size: 44)
                    TextField("分类名称", text: $name)
                        .font(.headline)
                }
            }

            Section("颜色") {
                HStack {
                    ForEach(Self.colors, id: \.self) { hex in
                        Button {
                            colorHex = hex
                        } label: {
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 26, height: 26)
                                .overlay {
                                    if hex == colorHex {
                                        Circle().strokeBorder(.white, lineWidth: 3)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("颜色 \(hex)"))
                        .accessibilityAddTraits(hex == colorHex ? .isSelected : [])
                    }
                }
                .padding(.vertical, 4)
            }

            Section("图标") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                    ForEach(Self.symbols, id: \.self) { item in
                        Button {
                            symbol = item
                        } label: {
                            Image(systemName: item)
                                .font(.system(size: 17, weight: .semibold))
                                .frame(width: 44, height: 44)
                                .foregroundStyle(item == symbol ? Color.white : Color.primary)
                                .background(item == symbol ? Color(hex: colorHex) : Color(.tertiarySystemFill), in: .circle)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(item))
                        .accessibilityAddTraits(item == symbol ? .isSelected : [])
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .navigationTitle(category == nil ? "新建分类" : "编辑分类")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消", systemImage: "xmark", role: .cancel) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存", systemImage: "checkmark", role: .confirm, action: save)
                    .disabled(name.trimmed.isEmpty)
            }
        }
    }

    private func save() {
        let target = category ?? LedgerCategory(name: name.trimmed, kind: kind, symbol: symbol, colorHex: colorHex, sortOrder: nextSortOrder)
        if category == nil { context.insert(target) }
        target.name = name.trimmed
        target.symbol = symbol
        target.colorHex = colorHex
        dismiss()
    }
}
