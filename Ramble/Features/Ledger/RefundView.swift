import SwiftUI

/// 「退款」: how much of this expense came back. It takes the spending down where it happened and
/// goes back into the account, and doesn't count as income.
struct RefundView: View {
    @Environment(\.dismiss) private var dismiss

    let entry: LedgerEntry

    @State private var amountText: String
    @State private var date = Date.now
    @FocusState private var amountFocused: Bool

    init(entry: LedgerEntry) {
        self.entry = entry
        _amountText = State(initialValue: entry.netAmount.inputText)
    }

    var body: some View {
        Form {
            Section {
                AmountField(text: $amountText, currencyCode: entry.currencyCode, focused: $amountFocused)
            } header: {
                Text("退回多少")
            } footer: {
                Text(footer)
            }
            Section {
                DatePicker("退款日期", selection: $date, displayedComponents: .date)
            }
        }
        .navigationTitle(entry.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消", systemImage: "xmark", role: .cancel) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("确认退款", systemImage: "checkmark", role: .confirm) {
                    guard let amount else { return }
                    entry.recordRefund(amount, on: date)
                    dismiss()
                }
                .disabled(amount == nil)
            }
        }
        .onAppear { amountFocused = true }
    }

    private var amount: Decimal? {
        guard let value = Decimal(userInput: amountText), value > 0, value <= entry.netAmount else { return nil }
        return value
    }

    private var footer: String {
        let most = entry.netAmount.money(entry.currencyCode)
        if let account = entry.account {
            return String(localized: "最多 \(most)。从这笔支出里扣掉，不算收入；\(account.name)的余额会加回来。")
        }
        return String(localized: "最多 \(most)。从这笔支出里扣掉，不算收入。")
    }
}
