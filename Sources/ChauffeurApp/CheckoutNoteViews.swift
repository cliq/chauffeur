import SwiftUI
import ChauffeurCore

/// Edits the note on a checkout, such as where to resume a parked worktree.
/// Saving empty text removes the note.
struct CheckoutNoteEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let projectID: UUID
    let row: CheckoutRow
    @State private var text = ""
    /// The stored note the edit began from, so an agent's concurrent write is not overwritten.
    @State private var version: String?
    @State private var saving = false
    @State private var failure: String?
    /// Fixed-width text with whole lines, for notes laid out like code.
    @AppStorage("checkoutNote.codeStyle") private var codeStyle = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Note on \(row.title)").font(.title3).fontWeight(.semibold)
                Text("Where to resume, what is left, anything to remember next time. Agents with Chauffeur messaging can read and update it.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Group {
                if codeStyle {
                    ArgumentEditor(text: $text, accessibilityLabel: "Note", wrapsLines: false)
                } else {
                    TextEditor(text: $text).font(.body)
                }
            }
            .frame(minHeight: 200)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
            .accessibilityIdentifier("checkoutNote.text")
            HStack {
                if let note = row.note { CheckoutNoteAttribution(note: note) }
                Spacer()
                Toggle("Code style", isOn: $codeStyle)
                    .toggleStyle(.checkbox)
                    .help("Fixed-width font without wrapping lines")
                    .accessibilityIdentifier("checkoutNote.codeStyle")
            }
            if let failure { Text(failure).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if row.note != nil {
                    Button("Delete Note", role: .destructive) { save("") }.disabled(saving || !model.online)
                }
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                // Return inserts a line in the editor, so saving takes Command-Return.
                Button("Save") { save(text) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(saving || !model.online || text == (row.note?.text ?? ""))
                    .help("Save (⌘↩)")
                    .accessibilityIdentifier("checkoutNote.save")
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { text = row.note?.text ?? ""; version = model.checkoutNoteVersion(row.note?.id) }
        .interactiveDismissDisabled(saving)
    }

    private func save(_ value: String) {
        saving = true; failure = nil
        Task {
            defer { saving = false }
            do {
                try await model.saveCheckoutNote(projectID: projectID, folderID: row.folderID, path: row.path, text: value, version: version)
                dismiss()
            } catch { failure = error.localizedDescription }
        }
    }
}

/// When and by whom a note was last written.
struct CheckoutNoteAttribution: View {
    let note: CheckoutNote
    var body: some View {
        Text("Edited \(note.updatedAt.formatted(.relative(presentation: .named)))" + (note.authorTitle.map { " by “\($0)”" } ?? ""))
            .font(.caption).foregroundStyle(.secondary)
    }
}

/// The note shown where a checkout's work resumes: its empty state and the launch sheet.
struct CheckoutNoteCallout: View {
    let text: String
    var note: CheckoutNote? = nil
    var edit: (() -> Void)? = nil
    /// Beyond this height the text scrolls inside the card instead of growing it.
    var maxTextHeight: CGFloat? = nil
    /// Shows only this many lines until the reader asks for the whole note.
    var collapsedLineLimit: Int? = nil
    @State private var expanded = false
    @State private var truncated = false
    /// The editor's code style; a collapsed preview keeps wrapping so its line limit holds.
    @AppStorage("checkoutNote.codeStyle") private var codeStyle = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Note on this checkout", systemImage: "note.text").fontWeight(.medium)
                Spacer()
                if let edit { Button("Edit…", action: edit).controlSize(.small).accessibilityIdentifier("checkoutNote.edit") }
            }
            if codeStyle, collapsedLineLimit == nil {
                // Whole lines scroll sideways; a tall note also scrolls down, up to the limit.
                ViewThatFits(in: .vertical) {
                    ScrollView(.horizontal) { codeText }
                    ScrollView([.horizontal, .vertical]) { codeText }
                }.frame(maxHeight: maxTextHeight)
            } else if let maxTextHeight {
                // A short note keeps its own height; a long one scrolls within
                // whatever height is left, up to the limit.
                ViewThatFits(in: .vertical) {
                    noteText
                    ScrollView { noteText }
                }.frame(maxHeight: maxTextHeight)
            } else if let collapsedLineLimit, !expanded {
                noteText.lineLimit(collapsedLineLimit)
                    .background(GeometryReader { limited in
                        // The full text, laid out off screen, tells whether the limit cut anything.
                        noteText.hidden().background(GeometryReader { full in
                            Color.clear.onAppear { truncated = full.size.height > limited.size.height + 1 }
                                .onChange(of: full.size.height) { _, height in truncated = height > limited.size.height + 1 }
                        })
                        .frame(width: limited.size.width).fixedSize(horizontal: false, vertical: true)
                    }.hidden())
            } else {
                noteText
            }
            if collapsedLineLimit != nil, truncated || expanded {
                Button(expanded ? "Show Less" : "Read Full Note") { expanded.toggle() }
                    .buttonStyle(.link).controlSize(.small)
                    .accessibilityIdentifier("checkoutNote.expand")
            }
            if let note { CheckoutNoteAttribution(note: note) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("checkoutNote.callout")
    }
    private var codeText: some View {
        Text(text).font(.body.monospaced()).textSelection(.enabled).fixedSize()
    }
    private var noteText: some View {
        Text(text).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
    }
}
