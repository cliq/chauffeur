import Foundation
import ChauffeurCore
import ChauffeurRemoteProtocol

/// The remote device selects a session, never a filesystem path.
enum RemoteProgressReader {
    static func summary(session: Session) -> SessionProgressSummary? {
        guard let registration = session.progress else { return nil }
        do { return summary(try ProgressFiles.read(jsonPath: registration.jsonPath)) }
        catch { return SessionProgressSummary(title: "Progress unavailable", now: "", error: "Cannot read the registered progress JSON on the Mac.") }
    }

    private static func summary(_ progress: ImplementationProgress) -> SessionProgressSummary {
        SessionProgressSummary(title: String(progress.title.prefix(200)), now: String(progress.now.prefix(500)),
                               percentComplete: progress.percentComplete, updatedAt: progress.updated)
    }

    static func panel(session: Session) throws -> SessionProgressPanel {
        guard let registration = session.progress else { throw ChauffeurError("progress_unavailable", "This session has no registered progress panel.") }
        let data = try ProgressFiles.readData(path: registration.jsonPath)
        let progress = try ImplementationProgress.decode(data)
        var panel = SessionProgressPanel(sessionID: session.id, summary: summary(progress), json: String(decoding: data, as: UTF8.self))
        if let path = registration.htmlPath {
            do {
                _ = try ProgressFiles.htmlURL(path)
                let html = try ProgressFiles.readData(path: path)
                guard let text = String(data: html, encoding: .utf8) else { throw ChauffeurError("progress_invalid", "The progress HTML is not UTF-8") }
                panel.html = text
            } catch { panel.htmlError = "Cannot read the registered HTML panel on the Mac." }
        } else { panel.htmlError = "This session has registered JSON progress, but no HTML panel." }
        // JSON escaping can expand file contents. Leave room for the response envelope.
        guard try RemoteJSON.encode(panel).count < Int(RemoteFraming.maxPayloadBytes) - 4096 else {
            throw ChauffeurError("progress_invalid", "The progress panel is too large to send to this device.")
        }
        return panel
    }
}
