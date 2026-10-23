import SwiftUI

/// Form row that opens the repeat-rule editor.
struct RecurrenceField: View {
    @Binding var recurrence: Recurrence?
    let anchor: Date
    var allowsLastDayOfMonth = true

    var body: some View {
        NavigationLink {
            RecurrenceEditor(recurrence: $recurrence, anchor: anchor, allowsLastDayOfMonth: allowsLastDayOfMonth)
        } label: {
            LabeledContent("重复", value: recurrence?.summary(anchor: anchor) ?? String(localized: "不重复"))
        }
    }
}

struct RecurrenceEditor: View {
    @Binding var recurrence: Recurrence?
    let anchor: Date
    let allowsLastDayOfMonth: Bool

    private struct Preset: Identifiable {
        let id: String
        let title: LocalizedStringResource
        let value: Recurrence?
    }

    private var presets: [Preset] {
        var list: [Preset] = [
            Preset(id: "none", title: "不重复", value: nil),
            Preset(id: "daily", title: "每天", value: .daily),
            Preset(id: "workdays", title: "工作日", value: .workdaysOnly),
            Preset(id: "weekly", title: "每周", value: .weekly),
            Preset(id: "biweekly", title: "每两周", value: .biweekly),
            Preset(id: "monthly", title: "每月", value: Recurrence.monthly().normalized(anchor: anchor)),
        ]
        if allowsLastDayOfMonth {
            list.append(Preset(id: "lastDay", title: "每月最后一天", value: .monthly(day: Recurrence.lastDayOfMonth)))
        }
        list.append(Preset(id: "yearly", title: "每年", value: .yearly))
        return list
    }

    var body: some View {
        Form {
            Section {
                ForEach(presets) { preset in
                    Button {
                        recurrence = preset.value
                    } label: {
                        HStack {
                            Text(preset.title).foregroundStyle(.primary)
                            Spacer()
                            if recurrence == preset.value {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                }
            }

            Section("自定义") {
                Picker("频率", selection: frequencyBinding) {
                    Text("不重复").tag(Recurrence.Frequency?.none)
                    ForEach(Recurrence.Frequency.allCases) { frequency in
                        Text(frequencyTitle(frequency)).tag(Optional(frequency))
                    }
                }
                if let current = recurrence {
                    Stepper(value: intervalBinding, in: 1...99) {
                        Text(current.everyText)
                    }
                    if current.frequency == .weekly, current.interval == 1 {
                        WeekdayPicker(selection: weekdaysBinding)
                    }
                    if current.frequency == .monthly, allowsLastDayOfMonth {
                        Toggle("每月最后一天", isOn: lastDayBinding)
                    }
                }
            }

            if recurrence != nil {
                Section {
                    Toggle("设置结束日期", isOn: hasEndBinding)
                    if let endDate = recurrence?.endDate {
                        DatePicker("结束于", selection: Binding(
                            get: { endDate },
                            set: { recurrence?.endDate = $0 }
                        ), in: anchor..., displayedComponents: .date)
                    }
                }
            }
        }
        .navigationTitle("重复")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func frequencyTitle(_ frequency: Recurrence.Frequency) -> LocalizedStringResource {
        switch frequency {
        case .daily: "按天"
        case .weekly: "按周"
        case .monthly: "按月"
        case .yearly: "按年"
        }
    }

    private var frequencyBinding: Binding<Recurrence.Frequency?> {
        Binding(
            get: { recurrence?.frequency },
            set: { newValue in
                guard let newValue else { recurrence = nil; return }
                var rule = recurrence ?? Recurrence(frequency: newValue)
                rule.frequency = newValue
                recurrence = rule.normalized(anchor: anchor)
            }
        )
    }

    private var intervalBinding: Binding<Int> {
        Binding(
            get: { recurrence?.interval ?? 1 },
            set: { recurrence?.interval = $0 }
        )
    }

    private var weekdaysBinding: Binding<Set<Int>> {
        Binding(
            get: { Set(recurrence?.weekdays ?? []) },
            set: { recurrence?.weekdays = $0.sorted() }
        )
    }

    private var lastDayBinding: Binding<Bool> {
        Binding(
            get: { recurrence?.monthDay == Recurrence.lastDayOfMonth },
            set: { isLast in
                recurrence?.monthDay = isLast ? Recurrence.lastDayOfMonth : Calendar.current.component(.day, from: anchor)
            }
        )
    }

    private var hasEndBinding: Binding<Bool> {
        Binding(
            get: { recurrence?.endDate != nil },
            set: { on in
                recurrence?.endDate = on ? Calendar.current.date(byAdding: .month, value: 6, to: anchor) : nil
            }
        )
    }
}

/// Seven toggle buttons, Monday first.
struct WeekdayPicker: View {
    @Binding var selection: Set<Int>
    private let order = [2, 3, 4, 5, 6, 7, 1]

    var body: some View {
        let symbols = Calendar.current.veryShortStandaloneWeekdaySymbols
        HStack(spacing: 6) {
            ForEach(order, id: \.self) { weekday in
                let isOn = selection.contains(weekday)
                Button {
                    if isOn { selection.remove(weekday) } else { selection.insert(weekday) }
                } label: {
                    Text(symbols[weekday - 1])
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .foregroundStyle(isOn ? Color.white : Color.primary)
                        .background(isOn ? Color.accentColor : Color(.tertiarySystemFill), in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }
}

/// Form row that opens the multi-reminder editor (days before + time).
struct ReminderRulesField: View {
    @Binding var rules: [ReminderRule]

    var body: some View {
        NavigationLink {
            ReminderRulesEditor(rules: $rules)
        } label: {
            LabeledContent("提醒", value: ReminderRule.summary(of: rules))
        }
    }
}

struct ReminderRulesEditor: View {
    @Binding var rules: [ReminderRule]

    private var time: Binding<Date> {
        Binding(
            get: {
                let rule = rules.first ?? ReminderRule(daysBefore: 0)
                return Calendar.current.date(bySettingHour: rule.hour, minute: rule.minute, second: 0, of: .now) ?? .now
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                rules = rules.map { ReminderRule(daysBefore: $0.daysBefore, hour: parts.hour ?? 9, minute: parts.minute ?? 0) }
            }
        )
    }

    var body: some View {
        Form {
            Section {
                ForEach(ReminderRule.presetDays, id: \.self) { days in
                    let isOn = rules.contains { $0.daysBefore == days }
                    Button {
                        toggle(days)
                    } label: {
                        HStack {
                            Text(days == 0 ? String(localized: "当天") : String(localized: "提前 \(days) 天"))
                                .foregroundStyle(.primary)
                            Spacer()
                            if isOn { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                    }
                }
            } footer: {
                Text("可以多选，比如提前 3 天先提醒一次，当天再提醒一次。")
            }
            if !rules.isEmpty {
                Section {
                    DatePicker("提醒时间", selection: time, displayedComponents: .hourAndMinute)
                }
            }
        }
        .navigationTitle("提醒")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func toggle(_ days: Int) {
        if let index = rules.firstIndex(where: { $0.daysBefore == days }) {
            rules.remove(at: index)
        } else {
            let template = rules.first ?? ReminderRule(daysBefore: 0)
            rules.append(ReminderRule(daysBefore: days, hour: template.hour, minute: template.minute))
            rules.sort { $0.daysBefore > $1.daysBefore }
        }
    }
}

struct CurrencyPicker: View {
    let title: LocalizedStringResource
    @Binding var code: String

    var body: some View {
        Picker(selection: $code) {
            ForEach(currencies, id: \.self) { code in
                Text(label(for: code)).tag(code)
            }
        } label: {
            Text(title)
        }
    }

    private var currencies: [String] {
        AppSettings.commonCurrencies.contains(code) ? AppSettings.commonCurrencies : [code] + AppSettings.commonCurrencies
    }

    private func label(for code: String) -> String {
        let name = Locale.current.localizedString(forCurrencyCode: code) ?? code
        return "\(code) · \(name)"
    }
}

/// Large amount entry used by the ledger and bill editors.
struct AmountField: View {
    @Binding var text: String
    let currencyCode: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(currencySymbol)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("0.00", text: $text)
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .monospacedDigit()
                .keyboardType(.decimalPad)
                .focused(focused)
                .accessibilityLabel(Text("金额"))
        }
        .padding(.vertical, 4)
    }

    /// "¥", "US$", "HK$" — whatever the current locale prints for this currency.
    private var currencySymbol: String {
        Decimal(0)
            .money(currencyCode, wholeNumbers: true)
            .filter { !$0.isNumber && !$0.isWhitespace }
    }
}
