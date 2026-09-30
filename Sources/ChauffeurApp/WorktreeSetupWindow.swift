import SwiftUI
import ChauffeurCore

/// Follows one setup script run. It closes itself shortly after the script
/// succeeds and stays open after a failure until it is dismissed.
struct WorktreeSetupWindow: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let runID: UUID
    @State private var output = ""
    private var run: WorktreeSetupRun? { model.snapshot.worktreeSetups?.first { $0.id == runID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    Text(output.isEmpty ? " " : output)
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(Color(white: 0.9))
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        .padding(8)
                    Color.clear.frame(height: 1).id("end")
                }
                .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 6))
                .onChange(of: output) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }
            if run?.status == .failed {
                HStack(alignment: .top) {
                    Text(summary).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Dismiss") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(14).frame(width: 560, height: 300)
        .task(id: runID) { await follow() }
    }
    private var header: some View {
        HStack(spacing: 8) {
            switch run?.status {
            case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            default: ProgressView().controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                if let run { Text(run.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            }
        }
    }
    private var title: String {
        switch run?.status {
        case .succeeded: "Setup script finished"
        case .failed: "Setup script failed"
        default: "Running setup script…"
        }
    }
    /// The first sentence of the runtime's message; the output is already shown above.
    private var summary: String { run?.message?.split(separator: "\n").first.map(String.init) ?? "The setup script failed." }
    private func follow() async {
        while !Task.isCancelled, run?.status ?? .running == .running {
            await readLog()
            try? await Task.sleep(for: .milliseconds(300))
        }
        await readLog()
        guard run?.status == .succeeded else { return }
        try? await Task.sleep(for: .seconds(1.5))
        if !Task.isCancelled { dismiss() }
    }
    /// Reads the end of the log; long installs keep only their most recent output.
    private func readLog() async {
        guard let path = run?.logPath else { return }
        let text = await Task.detached { () -> String? in
            guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: size > 65_536 ? size - 65_536 : 0)
            guard let data = try? handle.readToEnd() else { return "" }
            return String(decoding: data, as: UTF8.self)
        }.value
        if let text, text != output { output = text }
    }
}
