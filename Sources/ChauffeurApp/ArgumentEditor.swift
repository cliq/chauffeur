import AppKit
import SwiftUI
import ChauffeurCore

/// Plain text input for flags: macOS prose substitutions would corrupt argv.
struct ArgumentEditor: NSViewRepresentable {
    @Binding var text: String
    var accessibilityLabel = "Launch arguments"
    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let editor = NSTextView()
        editor.isRichText = false; editor.importsGraphics = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.smartInsertDeleteEnabled = false
        editor.allowsUndo = true
        editor.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        editor.textColor = .labelColor; editor.backgroundColor = .textBackgroundColor
        editor.textContainerInset = NSSize(width: 8, height: 8)
        editor.isHorizontallyResizable = false; editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.minSize = .zero; editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.string = text; editor.delegate = context.coordinator
        editor.setAccessibilityLabel(accessibilityLabel)
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        if let editor = scroll.documentView as? NSTextView, editor.string != text { editor.string = text }
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            text.wrappedValue = editor.string
        }
    }
}

struct PresetLaunchOptionsEditor: View {
    @Binding var rawArguments: String
    let kind: CLIKind

    private var inspection: LaunchArgumentInspection { LaunchOptions.inspect(rawArguments: rawArguments, kind: kind) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            option("Model", field: .model, value: inspection.model, suggestions: LaunchOptions.modelSuggestions(for: kind))
            option("Reasoning", field: .reasoning, value: inspection.reasoning, suggestions: LaunchOptions.reasoningSuggestions(for: kind))
            if !inspection.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(inspection.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                    }
                }.font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func option(_ label: String, field: LaunchOptionField, value: String?, suggestions: [String]) -> some View {
        HStack(spacing: 10) {
            Text(label).frame(width: 76, alignment: .leading)
            TextField(label, text: Binding(
                get: { value ?? "" },
                set: { newValue in
                    guard let updated = try? LaunchOptions.updating(field: field, value: newValue, rawArguments: rawArguments, kind: kind) else { return }
                    rawArguments = updated
                }
            ), prompt: Text("Provider default"))
                .labelsHidden()
                .accessibilityLabel(label)
                .disabled(inspection.arguments == nil)
                .accessibilityIdentifier(field == .model ? "preset.model" : "preset.reasoning")
            Menu {
                Button("Provider default") { update(field, nil) }
                if !suggestions.isEmpty { Divider() }
                ForEach(suggestions, id: \.self) { suggestion in Button(suggestion) { update(field, suggestion) } }
            } label: { Image(systemName: "chevron.down") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Choose \(label.lowercased())")
                .help("Choose a suggestion or type a custom value in the field.")
                .disabled(inspection.arguments == nil)
        }
    }

    private func update(_ field: LaunchOptionField, _ value: String?) {
        guard let updated = try? LaunchOptions.updating(field: field, value: value, rawArguments: rawArguments, kind: kind) else { return }
        rawArguments = updated
    }
}

struct SessionLaunchOptionsEditor: View {
    let kind: CLIKind
    let preset: AgentPreset?
    @Binding var modelOverride: String?
    @Binding var reasoningOverride: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Model and reasoning").font(.headline)
            sessionOption("Model", selection: $modelOverride, presetValue: presetInspection.model, suggestions: LaunchOptions.modelSuggestions(for: kind))
            sessionOption("Reasoning", selection: $reasoningOverride, presetValue: presetInspection.reasoning, suggestions: LaunchOptions.reasoningSuggestions(for: kind))
            Text("Choose a suggestion or type a custom value. Changes apply only to this session.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var presetInspection: LaunchArgumentInspection {
        guard let preset else { return .init(arguments: [], model: nil, reasoning: nil, warnings: []) }
        return LaunchOptions.inspect(rawArguments: LaunchOptions.rawArguments(for: preset), kind: preset.kind)
    }

    private func sessionOption(_ label: String, selection: Binding<String?>, presetValue: String?, suggestions: [String]) -> some View {
        HStack(spacing: 10) {
            Text(label).frame(width: 76, alignment: .leading)
            TextField(label, text: Binding(
                get: { selection.wrappedValue ?? "" },
                set: { selection.wrappedValue = $0 }
            ), prompt: Text(selection.wrappedValue == nil ? (presetValue.map { "Use preset (\($0))" } ?? "Use preset") : "Provider default"))
                .labelsHidden()
                .accessibilityLabel(label)
                .accessibilityIdentifier(label == "Model" ? "session.model" : "session.reasoning")
            Menu {
                Button(presetValue.map { "Use preset (\($0))" } ?? "Use preset") { selection.wrappedValue = nil }
                Button("Provider default") { selection.wrappedValue = "" }
                if !suggestions.isEmpty { Divider() }
                ForEach(suggestions, id: \.self) { suggestion in Button(suggestion) { selection.wrappedValue = suggestion } }
            } label: { Image(systemName: "chevron.down") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Choose \(label.lowercased())")
                .help("Use preset keeps its setting. Provider default removes the preset’s override for this session.")
        }
    }
}
