import SwiftUI

// "Mark as Bought…" on a part's page. It opens the popover of the "3c Mark as bought" artboard.
struct MarkAsBoughtButton: View {
    let part: PartRecord
    @State private var isPresented = false

    var body: some View {
        Button(MarkAsBoughtWording.buttonTitle, action: present)
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .fontWeight(.semibold)
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                MarkAsBoughtPopover(part: part, close: dismiss)
            }
            .accessibilityIdentifier("markAsBought")
    }

    private func present() { isPresented = true }
    private func dismiss() { isPresented = false }
}

// The popover's content. It makes its form when it opens, from the part's options and your
// rates, and Mark as Bought saves what you picked or typed, with Undo. Cancel and Esc close it
// and change nothing.
struct MarkAsBoughtPopover: View {
    @Environment(PartState.self) private var parts
    @Environment(MoneyState.self) private var money
    @Environment(\.undoManager) private var undoManager
    let part: PartRecord
    let close: () -> Void
    @State private var form: MarkAsBoughtForm?
    @State private var isSaving = false
    @State private var failure: String?
    @State private var unsavedOption = false

    var body: some View {
        Group {
            if let form {
                MarkAsBoughtContent(
                    form: form, isSaving: isSaving, failure: failure, cancel: close,
                    confirm: confirm)
            } else if unsavedOption {
                MarkAsBoughtUnsavedOption(close: close)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: MarkAsBoughtLayout.width, height: 80)
            }
        }
        // Once Mark as Bought is saving, the popover stays until it has saved.
        .interactiveDismissDisabled(isSaving)
        .task(makeFormEffect)
    }

    // The form starts from the options as they are saved, once any price still being typed
    // has saved. An option whose typing did not save stops it, so it never offers an old
    // price.
    private func makeFormEffect() async {
        guard form == nil else { return }
        guard let options = await parts.savedOptions(of: part.id) else {
            unsavedOption = true
            return
        }
        form = MarkAsBoughtForm(options: options, rates: money.rates)
    }

    // The popover stays open until what was bought has saved, so nothing typed is lost when
    // the save fails.
    private func confirm() {
        guard !isSaving, let purchase = form?.purchase() else { return }
        isSaving = true
        failure = nil
        Task { await save(purchase) }
    }

    private func save(_ purchase: PartPurchase) async {
        let saved = await parts.markBought(purchase, of: part.id, undoManager: undoManager)
        isSaving = false
        guard saved else {
            failure = parts.saveError ?? "What you bought did not save. Try again."
            return
        }
        close()
    }
}

// The form as on "3c": the options with "Somewhere else", the supplier, the price and the
// shipping when they are needed, "Charged to you" when you pay in another currency, and Cancel
// and Mark as Bought. Return confirms.
struct MarkAsBoughtContent: View {
    let form: MarkAsBoughtForm
    var isSaving = false
    var failure: String?
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MarkAsBoughtLayout.spacing) {
            Text("Mark as Bought")
                .font(.system(size: PageLayout.detailSize, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            if !form.options.isEmpty {
                MarkAsBoughtChoices(form: form)
            }
            if form.asksPrice {
                MarkAsBoughtPriceFields(form: form, submit: confirm)
            }
            if form.asksCharged {
                Divider()
                MarkAsBoughtChargedField(form: form, submit: confirm)
            }
            if let failure {
                MarkAsBoughtProblem(message: failure)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                    .buttonBorderShape(.capsule)
                    .accessibilityIdentifier("cancelMarkAsBought")
                Button("Mark as Bought", action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving)
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("confirmMarkAsBought")
            }
            .padding(.top, 4)
        }
        .padding(MarkAsBoughtLayout.padding)
        .frame(width: MarkAsBoughtLayout.width, alignment: .leading)
    }
}

// What the popover says when an option's price or shipping did not save.
private struct MarkAsBoughtUnsavedOption: View {
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MarkAsBoughtLayout.spacing) {
            Text("Mark as Bought")
                .font(.system(size: PageLayout.detailSize, weight: .semibold))
            MarkAsBoughtProblem(
                message:
                    "An option’s price or shipping did not save. Correct it on the part’s page, then mark the part bought."
            )
            HStack {
                Spacer()
                Button("Close", action: close)
                    .keyboardShortcut(.cancelAction)
                    .buttonBorderShape(.capsule)
            }
        }
        .padding(MarkAsBoughtLayout.padding)
        .frame(width: MarkAsBoughtLayout.width, alignment: .leading)
    }
}

// The options to pick from, each with its price with shipping, then "Somewhere else".
private struct MarkAsBoughtChoices: View {
    @Environment(MoneyState.self) private var money
    let form: MarkAsBoughtForm

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(form.options) { option in
                MarkAsBoughtChoiceRow(
                    title: option.supplier,
                    detail: PartMoneyWording.breakdown(
                        of: option, rates: form.rates, saysShipping: false),
                    amount: PartMoneyWording.headline(of: option, rates: form.rates),
                    isChosen: form.choice == .option(option.id),
                    choose: { form.choose(.option(option.id)) })
            }
            MarkAsBoughtChoiceRow(
                title: MarkAsBoughtWording.elsewhere, detail: nil, amount: nil,
                isChosen: form.choice == .elsewhere, choose: { form.choose(.elsewhere) })
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Bought from")
    }
}

private struct MarkAsBoughtChoiceRow: View {
    let title: String
    let detail: String?
    let amount: String?
    let isChosen: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 10) {
                Image(systemName: isChosen ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(isChosen ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: MarkAsBoughtLayout.textSize))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let detail {
                    Text(detail)
                        .font(.system(size: PartOptionLayout.smallSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let amount {
                    Text(amount)
                        .font(
                            .system(
                                size: MarkAsBoughtLayout.textSize,
                                weight: isChosen ? .semibold : .regular)
                        )
                        .monospacedDigit()
                        .lineLimit(1)
                        .frame(minWidth: MarkAsBoughtLayout.amountWidth, alignment: .trailing)
                }
            }
            .frame(height: MarkAsBoughtLayout.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel([title, detail, amount].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
    }
}

// The supplier, and the price with its currency and the shipping, as on "3c, Just the amount".
private struct MarkAsBoughtPriceFields: View {
    let form: MarkAsBoughtForm
    let submit: () -> Void
    @FocusState private var focus: MarkAsBoughtForm.Field?

    var body: some View {
        VStack(alignment: .leading, spacing: MarkAsBoughtLayout.spacing) {
            MarkAsBoughtField(
                label: "Supplier", prefix: nil, prompt: "Where you bought it",
                text: binding(.supplier), problem: nil, isFocused: focus == .supplier,
                identifier: "boughtSupplier", submit: submit
            )
            .focused($focus, equals: .supplier)
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    MarkAsBoughtLabel(
                        text: "Price", isFocused: focus == .price, problem: problem(.price))
                    HStack(spacing: 6) {
                        MarkAsBoughtBox(
                            prefix: CurrencyRules.symbol(of: form.currency), prompt: "0",
                            text: binding(.price), isFocused: focus == .price,
                            hasProblem: problem(.price) != nil, identifier: "boughtPrice",
                            label: "Price", submit: submit
                        )
                        .focused($focus, equals: .price)
                        Menu {
                            CurrencyMenuItems(first: [form.rates.home, form.currency]) {
                                form.chooseCurrency($0)
                            }
                        } label: {
                            Text(form.currency)
                                .font(.system(size: PageLayout.detailSize, weight: .medium))
                        }
                        .menuStyle(.button)
                        .fixedSize()
                        .frame(height: MarkAsBoughtLayout.fieldHeight)
                        .accessibilityLabel("Currency")
                        .accessibilityValue(CurrencyRules.name(of: form.currency))
                        .accessibilityIdentifier("boughtCurrency")
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    MarkAsBoughtLabel(
                        text: "Shipping", isFocused: focus == .shipping,
                        problem: problem(.shipping))
                    MarkAsBoughtBox(
                        prefix: CurrencyRules.symbol(of: form.currency), prompt: "0",
                        text: binding(.shipping), isFocused: focus == .shipping,
                        hasProblem: problem(.shipping) != nil, identifier: "boughtShipping",
                        label: "Shipping", submit: submit
                    )
                    .focused($focus, equals: .shipping)
                }
                .frame(width: MarkAsBoughtLayout.shippingWidth)
            }
            ForEach([MarkAsBoughtForm.Field.price, .shipping], id: \.self) { field in
                if let message = problem(field) {
                    MarkAsBoughtProblem(message: message)
                }
            }
        }
        .onChange(of: focus, initial: false, leaveField)
        .onAppear(perform: focusPrice)
    }

    private func problem(_ field: MarkAsBoughtForm.Field) -> String? { form.problem(for: field) }

    private func binding(_ field: MarkAsBoughtForm.Field) -> Binding<String> {
        Binding(get: { value(of: field) }, set: { form.change(field, to: $0) })
    }

    private func value(of field: MarkAsBoughtForm.Field) -> String {
        switch field {
        case .supplier: form.supplier
        case .price: form.price
        case .shipping: form.shipping
        case .charged: form.charged
        }
    }

    private func leaveField(_ old: MarkAsBoughtForm.Field?, _ new: MarkAsBoughtForm.Field?) {
        if let old, old != new { form.leave(old) }
    }

    // The price is the one value needed, so the cursor starts there.
    private func focusPrice() { focus = .price }
}

// "Charged to you": the real amount in your home currency, filled in from your rate.
private struct MarkAsBoughtChargedField: View {
    let form: MarkAsBoughtForm
    let submit: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MarkAsBoughtLabel(
                text: "Charged to you", isFocused: isFocused, problem: form.problem(for: .charged))
            HStack(spacing: 10) {
                MarkAsBoughtBox(
                    prefix: CurrencyRules.symbol(of: form.rates.home), prompt: "0",
                    text: Binding(get: chargedText, set: changeCharged), isFocused: isFocused,
                    hasProblem: form.problem(for: .charged) != nil, identifier: "boughtCharged",
                    label: "Charged to you", submit: submit
                )
                .focused($isFocused)
                .frame(width: MarkAsBoughtLayout.chargedWidth)
                Text(form.chargedHint)
                    .font(.system(size: PartOptionLayout.smallSize))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message = form.problem(for: .charged) {
                MarkAsBoughtProblem(message: message)
            }
        }
        .onChange(of: isFocused, initial: false, leaveCharged)
    }

    private func chargedText() -> String { form.charged }
    private func changeCharged(_ text: String) { form.change(.charged, to: text) }

    private func leaveCharged(_ was: Bool, _ now: Bool) {
        if was, !now { form.leave(.charged) }
    }
}

// A labelled field of the popover.
private struct MarkAsBoughtField: View {
    let label: String
    let prefix: String?
    let prompt: String
    let text: Binding<String>
    let problem: String?
    let isFocused: Bool
    let identifier: String
    let submit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MarkAsBoughtLabel(text: label, isFocused: isFocused, problem: problem)
            MarkAsBoughtBox(
                prefix: prefix, prompt: prompt, text: text, isFocused: isFocused,
                hasProblem: problem != nil, identifier: identifier, label: label, submit: submit)
        }
    }
}

private struct MarkAsBoughtLabel: View {
    let text: String
    let isFocused: Bool
    let problem: String?

    var body: some View {
        Text(text)
            .font(.system(size: InPlaceLayout.labelSize, weight: .medium))
            .foregroundStyle(colour)
            .accessibilityHidden(true)
    }

    private var colour: Color {
        if problem != nil { return .red }
        return isFocused ? .accentColor : .secondary
    }
}

// The box of a field: a 32 pt rounded box with a thin outline, the currency's symbol before an
// amount, and an accent ring while you type in it. It turns red when it needs something.
private struct MarkAsBoughtBox: View {
    let prefix: String?
    let prompt: String
    let text: Binding<String>
    let isFocused: Bool
    let hasProblem: Bool
    let identifier: String
    let label: String
    let submit: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: MarkAsBoughtLayout.fieldRadius)
        HStack(spacing: 4) {
            if let prefix {
                Text(prefix).foregroundStyle(.secondary).accessibilityHidden(true)
            }
            TextField(label, text: text, prompt: Text(prompt))
                .textFieldStyle(.plain)
                .labelsHidden()
                .onSubmit(submit)
                .accessibilityLabel(label)
                .accessibilityIdentifier(identifier)
        }
        .font(.system(size: MarkAsBoughtLayout.textSize))
        .padding(.horizontal, 10)
        .frame(height: MarkAsBoughtLayout.fieldHeight)
        .background(Color(nsColor: .textBackgroundColor), in: shape)
        .overlay(shape.strokeBorder(outline, lineWidth: 1))
        .background {
            if isFocused {
                RoundedRectangle(cornerRadius: MarkAsBoughtLayout.fieldRadius + 3)
                    .fill(Color.accentColor.opacity(0.18))
                    .padding(-3)
            }
        }
    }

    private var outline: Color {
        if hasProblem { return .red }
        if isFocused { return .accentColor }
        return Color.primary.opacity(0.16)
    }
}

private struct MarkAsBoughtProblem: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.circle.fill")
            .font(.system(size: PartOptionLayout.smallSize))
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }
}

enum MarkAsBoughtWording {
    static let buttonTitle = "Mark as Bought…"
    static let elsewhere = "Somewhere else"
}

// Values from the "3c Mark as bought" artboard on the Paper page "Rework · Simple".
enum MarkAsBoughtLayout {
    static let width: CGFloat = 420
    static let padding: CGFloat = 18
    static let spacing: CGFloat = 14
    static let rowHeight: CGFloat = 36
    static let textSize: CGFloat = 15
    static let amountWidth: CGFloat = 72
    static let fieldHeight: CGFloat = 32
    static let fieldRadius: CGFloat = 8
    static let shippingWidth: CGFloat = 110
    static let chargedWidth: CGFloat = 140
}
