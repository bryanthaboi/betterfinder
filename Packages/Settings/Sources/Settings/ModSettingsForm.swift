import AppKit
import SwiftUI

@MainActor
public final class ModSettingsFormModel: ObservableObject {
    public let store: ModSettingsStore
    @Published public private(set) var values: [String: ModSettingValue]
    @Published public private(set) var errors: [String: String] = [:]
    @Published public private(set) var secretPresence: Set<String> = []
    @Published public var secretDrafts: [String: String] = [:]

    public init(store: ModSettingsStore) {
        self.store = store
        self.values = store.values
        self.secretPresence = Set(store.schema.fields.filter { store.hasSecret($0.key) }.map(\.key))
    }

    public var schema: ModSettingsSchema { store.schema }

    public func value(_ key: String) -> ModSettingValue? { values[key] }

    public var announce: (String) -> Void = { text in
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    func title(for key: String) -> String {
        schema.fields.first { $0.key == key }?.title ?? key
    }

    private func fail(_ key: String, _ error: Error) {
        let message = error.localizedDescription
        let changed = errors[key] != message
        errors[key] = message
        if changed { announce("\(title(for: key)): \(message)") }
    }

    @discardableResult
    public func update(_ key: String, _ value: ModSettingValue) -> Bool {
        do {
            values[key] = try store.set(value, for: key)
            errors[key] = nil
            return true
        } catch {
            fail(key, error)
            return false
        }
    }

    public func reset(_ key: String) {
        store.reset(key)
        values[key] = store.value(for: key)
        errors[key] = nil
    }

    public func resetAll() {
        store.resetAll()
        values = store.values
        errors = [:]
    }

    public func commitSecret(_ key: String) {
        let draft = secretDrafts[key] ?? ""
        guard !draft.isEmpty else { return }
        do {
            try store.setSecret(draft, for: key)
            secretDrafts[key] = nil
            secretPresence.insert(key)
            errors[key] = nil
            announce("\(title(for: key)) saved")
        } catch {
            fail(key, error)
        }
    }

    public func clearSecret(_ key: String) {
        do {
            try store.clearSecret(key)
            secretPresence.remove(key)
            secretDrafts[key] = nil
            errors[key] = nil
            announce("\(title(for: key)) removed")
        } catch {
            fail(key, error)
        }
    }
}

public struct ModSettingsFormView: View {
    @ObservedObject var model: ModSettingsFormModel

    public init(model: ModSettingsFormModel) {
        self.model = model
    }

    public var body: some View {
        Form {
            ForEach(model.schema.fields) { field in
                Section {
                    control(for: field)
                    if let description = field.description {
                        Text(description).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if let error = model.errors[field.key] {
                        Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !model.schema.fields.isEmpty {
                Section {
                    Button("Reset to Defaults") { model.resetAll() }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func control(for field: ModSettingsSchema.Field) -> some View {
        switch field.kind {
        case .boolean:
            Toggle(field.title, isOn: Binding(
                get: { model.value(field.key)?.boolValue ?? false },
                set: { model.update(field.key, .bool($0)) }
            ))
        case .integer(let lo, let hi, let step, _):
            IntegerRow(title: field.title, minimum: lo, maximum: hi, step: step ?? 1,
                       value: Binding(get: { model.value(field.key)?.integerValue ?? 0 }, set: { model.update(field.key, .integer($0)) }))
        case .number(let lo, let hi, let step, _):
            NumberRow(title: field.title, minimum: lo, maximum: hi, step: step,
                      value: Binding(get: { model.value(field.key)?.numberValue ?? 0 }, set: { model.update(field.key, .number($0)) }))
        case .string(_, let placeholder, let multiline, _):
            TextField(field.title, text: Binding(
                get: { model.value(field.key)?.stringValue ?? "" },
                set: { model.update(field.key, .string($0)) }
            ), prompt: placeholder.map { Text($0) }, axis: multiline ? .vertical : .horizontal)
                .lineLimit(multiline ? 3...8 : 1...1)
        case .enumeration(let options, _):
            Picker(field.title, selection: Binding(
                get: { model.value(field.key)?.stringValue ?? options.first?.value ?? "" },
                set: { model.update(field.key, .string($0)) }
            )) {
                ForEach(options, id: \.value) { Text($0.title).tag($0.value) }
            }
        case .secret(let placeholder):
            SecretRow(title: field.title, placeholder: placeholder, isSet: model.secretPresence.contains(field.key),
                      draft: Binding(get: { model.secretDrafts[field.key] ?? "" }, set: { model.secretDrafts[field.key] = $0 }),
                      save: { model.commitSecret(field.key) }, clear: { model.clearSecret(field.key) })
        }
    }
}

private struct IntegerRow: View {
    let title: String
    let minimum: Int?
    let maximum: Int?
    let step: Int
    @Binding var value: Int

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, value: $value, format: .number)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 90)
            Stepper(title, value: $value, in: (minimum ?? Int.min / 2)...(maximum ?? Int.max / 2), step: step)
                .labelsHidden()
                .accessibilityValue("\(value)")
        }
    }
}

private struct NumberRow: View {
    let title: String
    let minimum: Double?
    let maximum: Double?
    let step: Double?
    @Binding var value: Double

    var body: some View {
        HStack {
            Text(title)
            if let minimum, let maximum {
                Group {
                    if let step {
                        Slider(value: $value, in: minimum...maximum, step: step) { Text(title) }
                    } else {
                        Slider(value: $value, in: minimum...maximum) { Text(title) }
                    }
                }
                .labelsHidden()
                .accessibilityValue(value.formatted(.number.precision(.fractionLength(0...3))))
                Text(value, format: .number.precision(.fractionLength(0...3))).monospacedDigit().frame(width: 60, alignment: .trailing)
                    .accessibilityHidden(true)
            } else {
                Spacer()
                TextField(title, value: $value, format: .number)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 110)
            }
        }
    }
}

private struct SecretRow: View {
    let title: String
    let placeholder: String?
    let isSet: Bool
    @Binding var draft: String
    let save: () -> Void
    let clear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Label(isSet ? "Stored in Keychain" : "Not set", systemImage: isSet ? "lock.fill" : "lock.open")
                    .font(.caption)
                    .foregroundStyle(isSet ? .green : .secondary)
                    .accessibilityHidden(true)
            }
            HStack {
                SecureField(title, text: $draft, prompt: Text(isSet ? "Enter a new value to replace" : (placeholder ?? "Enter value")))
                    .labelsHidden()
                    .onSubmit(save)
                    .accessibilityValue(isSet ? "Stored in Keychain" : "Not set")
                    .accessibilityHint(isSet ? "Enter a new value to replace the stored one" : (placeholder ?? "Enter a value"))
                Button("Save", action: save).disabled(draft.isEmpty)
                    .accessibilityLabel("Save \(title)")
                Button("Remove", role: .destructive, action: clear).disabled(!isSet)
                    .accessibilityLabel("Remove \(title)")
            }
        }
    }
}
