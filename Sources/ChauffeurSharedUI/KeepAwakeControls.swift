import SwiftUI
import ChauffeurRemoteProtocol

enum KeepAwakeAvailability: Equatable {
    case available
    case disconnected
    case unsupported
}

struct KeepAwakeControls: View {
    let status: KeepAwakeStatus?
    let availability: KeepAwakeAvailability
    let pending: Bool
    let mutationError: String?
    let setSettings: (KeepAwakeSettings) async -> Bool
    let setTimer: (Date?) async -> Bool

    @State private var automatic = false
    @State private var waitingMinutes = 30
    @State private var customHours = 1.0
    @State private var settingsDirty = false

    private var controlsAvailable: Bool { availability == .available && status != nil }
    private var validWaitingMinutes: Bool { (1...1_440).contains(waitingMinutes) }
    private var validCustomHours: Bool { customHours.isFinite && (0.25...24).contains(customHours) }

    var body: some View {
        Section("Keep Awake") {
            availabilityMessage

            Toggle("Keep awake while agents work", isOn: Binding(
                get: { automatic },
                set: { automatic = $0; settingsDirty = true }
            ))
            .disabled(!controlsAvailable || pending)
            .accessibilityIdentifier("keep-awake.automatic")

            VStack(alignment: .leading, spacing: 6) {
                Text("Stop counting waiting agents after")
                HStack {
                    TextField("Minutes", value: Binding(
                        get: { waitingMinutes },
                        set: { waitingMinutes = $0; settingsDirty = true }
                    ), format: .number)
                    .frame(width: 64)
                    .multilineTextAlignment(.trailing)
                    Text("minutes").foregroundStyle(.secondary)
                    Stepper("Waiting limit", value: Binding(
                        get: { min(max(waitingMinutes, 1), 1_440) },
                        set: { waitingMinutes = $0; settingsDirty = true }
                    ), in: 1...1_440)
                    .labelsHidden()
                }
            }
            .disabled(!controlsAvailable || pending)
            .accessibilityIdentifier("keep-awake.waiting-minutes")

            Button(pending ? "Saving…" : "Save Automatic Settings") {
                let submitted = KeepAwakeSettings(automatic: automatic, waitingMinutes: waitingMinutes)
                Task {
                    if await setSettings(submitted) { settingsDirty = false }
                }
            }
            .disabled(!controlsAvailable || pending || !settingsDirty || !validWaitingMinutes)

            statusView

            Text("The display may still sleep. Automatic protection counts active agents and stops counting agents that have waited longer than this limit.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Keep Awake Timer") {
            HStack {
                ForEach([1, 2, 4, 8], id: \.self) { hours in
                    Button("\(hours)h") { startTimer(hours: Double(hours)) }
                        .frame(maxWidth: .infinity)
                        .buttonStyle(.bordered)
                }
            }
            .disabled(!controlsAvailable || pending)

            HStack {
                TextField("Custom hours", value: $customHours, format: .number.precision(.fractionLength(0...2)))
                    .accessibilityIdentifier("keep-awake.custom-hours")
                Stepper("", value: $customHours, in: 0.25...24, step: 0.25)
                    .labelsHidden()
                Button("Start") { startTimer(hours: customHours) }
                    .buttonStyle(.bordered)
                    .disabled(!validCustomHours)
            }
            .disabled(!controlsAvailable || pending)

            if let until = status?.manualUntil, until > Date() {
                LabeledContent("Timer ends") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(until, format: .dateTime.weekday(.abbreviated).hour().minute())
                        Text(timerInterval: min(Date(), until)...until, countsDown: true)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Button("Cancel Timer", role: .destructive) {
                    Task { _ = await setTimer(nil) }
                }
                .disabled(!controlsAvailable || pending)
                .accessibilityIdentifier("keep-awake.cancel-timer")
            } else {
                Text("No timer is running.").foregroundStyle(.secondary)
            }
        }
        .task { synchronizeDraftIfPossible() }
        .onChange(of: status) { _, _ in synchronizeDraftIfPossible() }
        .onChange(of: pending) { _, _ in synchronizeDraftIfPossible() }
    }

    @ViewBuilder private var availabilityMessage: some View {
        switch availability {
        case .available:
            EmptyView()
        case .disconnected:
            Label("Unavailable while disconnected. The status below may be stale.", systemImage: "wifi.slash")
                .foregroundStyle(.secondary)
        case .unsupported:
            Label("Update Chauffeur on the Mac to manage keep-awake settings.", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var statusView: some View {
        if availability != .available {
            LabeledContent("Current protection", value: "Unavailable")
        } else if let status {
            if status.assertionHeld {
                Label(protectionReason(status), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if status.error != nil {
                Label("Protection could not be enabled", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            } else {
                Label("The Mac can sleep normally", systemImage: "moon")
                    .foregroundStyle(.secondary)
            }
            if let error = status.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        } else {
            LabeledContent("Current protection", value: "Loading…")
        }
        if let mutationError {
            Text(mutationError).font(.caption).foregroundStyle(.red)
                .accessibilityIdentifier("keep-awake.mutation-error")
        }
    }

    private func protectionReason(_ status: KeepAwakeStatus) -> String {
        let timerActive = status.manualUntil.map { $0 > Date() } ?? false
        if timerActive, status.qualifyingAgents > 0 {
            return "Protected by the timer and \(agentCount(status.qualifyingAgents))"
        }
        if timerActive { return "Protected by the timer" }
        if status.qualifyingAgents > 0 { return "Protected for \(agentCount(status.qualifyingAgents))" }
        return "Mac sleep is prevented"
    }

    private func agentCount(_ count: Int) -> String {
        "\(count) qualifying agent\(count == 1 ? "" : "s")"
    }

    private func startTimer(hours: Double) {
        guard hours.isFinite, (0.25...24).contains(hours) else { return }
        let until = Date().addingTimeInterval(hours * 60 * 60)
        Task { _ = await setTimer(until) }
    }

    private func synchronizeDraftIfPossible() {
        guard !pending, !settingsDirty, let settings = status?.settings else { return }
        automatic = settings.automatic
        waitingMinutes = settings.waitingMinutes
    }
}
