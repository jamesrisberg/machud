import Foundation
import HUDKit

/// What the settings window draws for one app: its schema's fields, grouped, with the
/// values the app reported. Keys the app reports that the schema does not describe (or
/// every key, for an app without a schema) show as plain text rows under "Other", so the
/// window works for any HUDKit app. Pure, so it is unit tested.
struct SettingsForm: Equatable {
    enum Control: Equatable {
        case toggle
        case text
        /// `int` and `number` fields: a text field plus a stepper.
        case number(NumberSpec)
        case path
        case choice([HUDSettingsSchema.Option])
        /// A value the window cannot edit (a list, an object): shown, not sent back.
        case readOnly
    }

    struct Row: Equatable, Identifiable {
        var key: String
        var title: String
        var control: Control
        /// What the app reported, else the schema default.
        var value: HUDSettingValue?
        var help: String?
        /// The app did not report this key (the value shown is the default).
        var isDefault: Bool

        var id: String { key }

        /// The value as the control shows it (numbers formatted by their spec: `0.75`, `10`).
        var text: String {
            if case .number(let spec) = control, let d = value?.doubleValue { return spec.format(d) }
            return value?.wireString ?? ""
        }
        var isOn: Bool { value?.boolValue ?? false }
    }

    struct Section: Equatable, Identifiable {
        var title: String?
        var rows: [Row]
        var id: String { title ?? "" }
    }

    var sections: [Section]

    var rows: [Row] { sections.flatMap(\.rows) }
    func row(_ key: String) -> Row? { rows.first { $0.key == key } }

    static let otherTitle = "Other"

    static func build(schema: HUDSettingsSchema?, values: [String: Any]) -> SettingsForm {
        var sections: [Section] = []
        if let schema {
            for group in schema.groups {
                let rows = schema.settings.filter { $0.group == group }.map { field -> Row in
                    let reported = values[field.key].flatMap(value(from:))
                    return Row(key: field.key, title: field.title, control: control(for: field),
                               value: reported ?? field.default, help: field.help, isDefault: reported == nil)
                }
                sections.append(Section(title: group, rows: rows))
            }
        }
        let described = Set(schema?.settings.map(\.key) ?? [])
        let extra = values.keys.filter { !described.contains($0) }.sorted().map { key -> Row in
            let raw = values[key]!
            if let v = value(from: raw) {
                let control: Control
                switch v {
                case .bool: control = .toggle
                case .int: control = .number(.integer)
                case .double: control = .number(.decimal)
                case .string: control = .text
                }
                return Row(key: key, title: key, control: control, value: v, help: nil, isDefault: false)
            }
            return Row(key: key, title: key, control: .readOnly, value: .string(display(raw)), help: nil, isDefault: false)
        }
        if !extra.isEmpty { sections.append(Section(title: schema == nil ? nil : otherTitle, rows: extra)) }
        return SettingsForm(sections: sections)
    }

    /// The string `settings set` takes for `input` on `row`, or nil when the row cannot be
    /// sent (read-only) or `input` is not valid for it.
    static func wireValue(_ input: HUDSettingValue, for row: Row) -> String? {
        switch row.control {
        case .readOnly: return nil
        case .toggle: return input.boolValue.map { $0 ? "true" : "false" }
        case .number(let spec):
            return spec.parse(input.wireString).map(spec.format)
        case .choice(let options):
            return options.contains { $0.value == input.wireString } ? input.wireString : nil
        case .text, .path: return input.wireString
        }
    }

    private static func control(for field: HUDSettingsSchema.Field) -> Control {
        switch field.type {
        case .bool: return .toggle
        case .int: return .number(NumberSpec(field: field))
        case .number: return .number(NumberSpec(field: field))
        case .path: return .path
        case .string: return .text
        case .enum: return field.options.isEmpty ? .text : .choice(field.options)
        }
    }

    private static func value(from raw: Any) -> HUDSettingValue? {
        if raw is [Any] || raw is [String: Any] { return nil }
        return HUDSettingValue(any: raw)
    }

    private static func display(_ raw: Any) -> String {
        if let list = raw as? [Any] { return list.map { "\($0)" }.joined(separator: ", ") }
        if JSONSerialization.isValidJSONObject(raw), let data = try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]) {
            return String(decoding: data, as: UTF8.self)
        }
        return "\(raw)"
    }

    /// Compact form for `settings-window state`.
    var json: [[String: Any]] {
        sections.map { section in
            var d: [String: Any] = ["rows": section.rows.map { row -> [String: Any] in
                var r: [String: Any] = ["key": row.key, "title": row.title, "control": row.control.name]
                if let v = row.value { r["value"] = v.jsonValue }
                if row.isDefault { r["default"] = true }
                return r
            }]
            if let title = section.title { d["group"] = title }
            return d
        }
    }
}

extension SettingsForm.Control {
    var name: String {
        switch self {
        case .toggle: return "toggle"
        case .text: return "text"
        case .number: return "number"
        case .path: return "path"
        case .choice: return "choice"
        case .readOnly: return "readOnly"
        }
    }
}

/// How a numeric row parses, clamps, steps and formats its value. Pure, so it is unit tested.
struct NumberSpec: Equatable {
    /// `int` fields: whole numbers only.
    var isInteger: Bool
    var min: Double?
    var max: Double?
    /// The stepper's increment (> 0).
    var step: Double

    static let integer = NumberSpec(isInteger: true, min: nil, max: nil, step: 1)
    static let decimal = NumberSpec(isInteger: false, min: nil, max: nil, step: 0.1)

    init(isInteger: Bool, min: Double? = nil, max: Double? = nil, step: Double? = nil) {
        self.isInteger = isInteger
        self.min = min
        self.max = max
        let fallback: Double = isInteger ? 1 : 0.1
        let s = step.flatMap { $0 > 0 && $0.isFinite ? $0 : nil } ?? fallback
        self.step = isInteger ? Swift.max(1, s.rounded()) : s
    }

    /// From a schema field: `step` defaults to 1 for `int` and 0.1 for `number`.
    init(field: HUDSettingsSchema.Field) {
        self.init(isInteger: field.type == .int, min: field.min, max: field.max, step: field.step)
    }

    /// The value typed in `text`, clamped to the bounds; nil when it is not a number (or, for
    /// an integer row, not a whole number).
    func parse(_ text: String) -> Double? {
        guard let d = Double(text.trimmingCharacters(in: .whitespaces)), d.isFinite else { return nil }
        if isInteger && d != d.rounded() { return nil }
        return clamp(d)
    }

    func clamp(_ value: Double) -> Double {
        var v = value
        if let min, v < min { v = min }
        if let max, v > max { v = max }
        return v
    }

    /// One stepper click from `value` (up for `direction` > 0), snapped to the step grid and
    /// clamped. With no value it starts from `min`, else 0.
    func stepped(_ value: Double?, by direction: Int) -> Double {
        let base = value ?? min ?? 0
        let next = base + Double(direction.signum()) * step
        let snapped = (next / step).rounded() * step
        return clamp(isInteger ? snapped.rounded() : snapped)
    }

    /// The wire and display form: `10` rather than `10.0`, `0.3` rather than `0.30000000000000004`.
    func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int(value)) }
        if isInteger { return String(Int(value.rounded())) }
        return String(format: "%.10g", value)
    }
}
