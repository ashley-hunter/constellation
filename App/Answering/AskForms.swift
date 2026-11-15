import ConstellationCore
import SwiftUI

/// The full answer for one ask, in the session view.
struct AskForm: View {
    let ask: Ask
    var codeHeight: CGFloat = 280

    var body: some View {
        switch ask.kind {
        case .permission(let permission):
            VStack(alignment: .leading, spacing: 16) {
                PermissionDetail(permission: permission, codeHeight: codeHeight)
                ChoiceButtons(ask: ask)
            }
        case .question(let question):
            QuestionForm(ask: ask, question: question)
        case .secret(let secret):
            SecretForm(ask: ask, secret: secret)
        }
    }
}

/// A button per quick answer, each with its ⌥ key. A permission's keys reach it from the reply box
/// too (`answersPermission`); a question's ⌥ digits only while no text field has the keys, as ⌥
/// there types (# on a UK keyboard).
struct ChoiceButtons: View {
    @Environment(AppModel.self) private var model
    let ask: Ask
    var height: CGFloat = 32

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(ask.choices) { choice in
                Button {
                    model.answer(ask: ask, with: choice.answer)
                } label: {
                    if model.keyboard.isEditingText, !ask.isPermission {
                        Text(choice.label)
                    } else {
                        KeyedLabel(choice.label, key: "⌥" + choice.key.uppercased())
                    }
                }
                .buttonStyle(ConstellationButtonStyle(weight: choice.weight, height: height))
            }
        }
    }
}

struct KeyedLabel: View {
    let label: String
    let key: String

    init(_ label: String, key: String) {
        self.label = label
        self.key = key
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
            KeyChip(key)
        }
    }
}

/// The command for shell tools, otherwise the edit or input, with line numbers.
struct PermissionDetail: View {
    let permission: PermissionAsk
    var codeHeight: CGFloat = 280

    private var isShell: Bool { ["Bash", "shell"].contains(permission.toolName) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                // The amber dot says it's waiting on you, as on the desktop.
                (Text(Image(systemName: "circle.fill")).font(.system(size: 6)).foregroundStyle(Palette.ask).baselineOffset(2) + Text("  ") + Text(prompt))
                    .font(.ui(14, weight: .medium))
                    .foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                // What the agent said the command is for, when that isn't just the command again.
                if isShell, let why = permission.inputPreview, why != permission.summary {
                    Text(why).font(.ui(12)).foregroundStyle(Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if isShell {
                // A command reads as one, at a prompt, with no line numbers.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("$").foregroundStyle(Palette.textTertiary)
                    Text(permission.summary).foregroundStyle(Palette.text).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.mono(12))
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.surfaceSunken, in: .rect(cornerRadius: 8))
                .copyable(permission.summary, help: "Copy command")
            } else if let code {
                CodeBlock(code, maxHeight: codeHeight)
            }
        }
    }

    private var prompt: String {
        if isShell { return "Run this command?" }
        return "\(permission.toolName): \(permission.summary)"
    }

    private var code: String? { permission.inputPreview }
}

/// Every question, with option buttons and free text. One single-choice question answers on a click.
struct QuestionForm: View {
    @Environment(AppModel.self) private var model
    let ask: Ask
    let question: QuestionAsk
    @State private var selected: [String: Set<String>] = [:]
    @State private var freeText: [String: String] = [:]

    private var answersOnClick: Bool { !ask.choices.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(Array(question.questions.enumerated()), id: \.element.id) { index, item in
                VStack(alignment: .leading, spacing: 10) {
                    if !item.header.isEmpty {
                        Text(item.header.uppercased())
                            .font(.ui(11))
                            .foregroundStyle(Palette.textTertiary)
                    }
                    Text(item.prompt)
                        .font(.ui(15))
                        .foregroundStyle(Palette.text)
                        .fixedSize(horizontal: false, vertical: true)
                    options(for: item, index: index)
                    TextField("Something else", text: binding(for: item.id))
                        .textFieldStyle(.plain)
                        .font(.ui(13))
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(Palette.surfaceSunken, in: .rect(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.text.opacity(0.14)))
                        .onSubmit(submit)
                }
            }
            HStack {
                Spacer()
                Button("Answer", action: submit)
                    .buttonStyle(ConstellationButtonStyle(weight: .primary, height: 32))
                    .disabled(!isComplete)
            }
        }
    }

    @ViewBuilder private func options(for item: QuestionAsk.Question, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(item.options.enumerated()), id: \.offset) { number, option in
                let isOn = selected[item.id, default: []].contains(option.label)
                Button {
                    toggle(option.label, in: item)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        if answersOnClick, !model.keyboard.isEditingText {
                            KeyChip("⌥\(number + 1)")
                        } else {
                            Image(systemName: item.multiSelect ? (isOn ? "checkmark.square.fill" : "square") : (isOn ? "largecircle.fill.circle" : "circle"))
                                .font(.system(size: 12))
                                .foregroundStyle(isOn ? Palette.ask : Palette.textTertiary)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.label).font(.ui(13, weight: .medium)).foregroundStyle(Palette.text)
                            if let description = option.description, !description.isEmpty {
                                Text(description)
                                    .font(.ui(12))
                                    .foregroundStyle(Palette.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(isOn ? Palette.rowSelected : Palette.rowHover, in: .rect(cornerRadius: 8))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func binding(for id: String) -> Binding<String> {
        Binding { freeText[id, default: ""] } set: { freeText[id] = $0 }
    }

    private func toggle(_ label: String, in item: QuestionAsk.Question) {
        if answersOnClick {
            model.answer(ask: ask, with: .questions([item.id: [label]]))
            return
        }
        if item.multiSelect {
            selected[item.id, default: []].formSymmetricDifference([label])
        } else {
            selected[item.id] = [label]
        }
    }

    private var answers: [String: [String]] {
        var answers: [String: [String]] = [:]
        for item in question.questions {
            let text = freeText[item.id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
            let picked = item.options.map(\.label).filter { selected[item.id, default: []].contains($0) }
            let values = picked + (text.isEmpty ? [] : [text])
            if !values.isEmpty { answers[item.id] = values }
        }
        return answers
    }

    private var isComplete: Bool {
        answers.count == question.questions.count
    }

    private func submit() {
        guard isComplete else { return }
        model.answer(ask: ask, with: .questions(answers))
    }
}

/// A masked field and "save for this project".
struct SecretForm: View {
    @Environment(AppModel.self) private var model
    let ask: Ask
    let secret: SecretAsk
    @State private var value = ""
    @State private var saveForProject = true
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Needs \(secret.name)")
                .font(.ui(15))
                .foregroundStyle(Palette.text)
            if !secret.reason.isEmpty {
                Text(secret.reason)
                    .font(.ui(13))
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SecureField(secret.name, text: $value)
                .textFieldStyle(.plain)
                .font(.ui(13))
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(Palette.surfaceSunken, in: .rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.text.opacity(0.14)))
                .focused($isFocused)
                .onSubmit(provide)
            Toggle("Save for this project", isOn: $saveForProject)
                .toggleStyle(.checkbox)
                .font(.ui(13))
                .foregroundStyle(Palette.textSecondary)
            HStack(spacing: 8) {
                Button(action: provide) { KeyedLabel("Provide", key: "↵") }
                    .buttonStyle(ConstellationButtonStyle(weight: .primary, height: 32))
                    .disabled(value.isEmpty)
                Button("Decline") { model.answer(ask: ask, with: .secretDeclined) }
                    .buttonStyle(ConstellationButtonStyle(weight: .quiet, height: 32))
            }
        }
        .onAppear { isFocused = true }
    }

    private func provide() {
        guard !value.isEmpty else { return }
        model.answer(ask: ask, with: .secret(value: value, saveForProject: saveForProject))
        value = ""
    }
}

/// Lays children out left to right, wrapping onto new rows.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !row.indices.isEmpty, row.width + spacing + size.width > width {
                rows.append(row)
                row = Row()
            }
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
