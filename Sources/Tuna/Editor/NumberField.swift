import SwiftUI

struct NumberField: View {
    let label: String
    let value: Float
    let range: ClosedRange<Float>
    let digits: Int
    var live = true
    let apply: (Float) -> Void

    @FocusState private var focused: Bool
    @State private var draft: String?

    var body: some View {
        TextField(label, text: Binding(
            get: { draft ?? value.formatted(.number.grouping(.never).precision(.fractionLength(digits))) },
            set: { text in
                draft = text
                if live, let number = parse(text), range.contains(number), number != value {
                    apply(number)
                }
            }
        ))
        .labelsHidden()
        .accessibilityLabel(label)
        .monospacedDigit()
        .focused($focused)
        .onChange(of: focused) { _, isFocused in
            if !isFocused { finish() }
        }
        .onSubmit { finish() }
    }

    private func parse(_ text: String) -> Float? {
        let normalized = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: Locale.current.decimalSeparator ?? ".", with: ".")
            .replacingOccurrences(of: ",", with: ".")
        guard let number = Float(normalized), number.isFinite else { return nil }
        return number
    }

    private func finish() {
        if let draft, let number = parse(draft) {
            let bounded = min(range.upperBound, max(range.lowerBound, number))
            if bounded != value { apply(bounded) }
        }
        draft = nil
    }
}
