import AppKit
import SwiftUI
import ChauffeurCore

struct RemoteAccessSettingsSection: View {
    @EnvironmentObject private var model: AppModel
    @State private var portText = ""
    @State private var portFailure: String?
    @State private var revokingDevice: RemoteAccessStatus.Device?
    @State private var confirmingReset = false
    @State private var copiedPairingCode = false
    private var status: RemoteAccessStatus? { model.snapshot.remoteAccess }
    var body: some View {
        Group {
            if let status {
                Section("Remote Access") {
                    Text("Let the Chauffeur iPhone app browse sessions and use terminals on this Mac over the local network.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Allow remote access", isOn: Binding(get: { status.enabled }, set: { setEnabled($0) }))
                        .accessibilityIdentifier("remote-access-toggle")
                    stateRow(status)
                    portRow(status)
                }
                Section("Pair an iPhone") {
                    pairingSection(status)
                }
                Section("Paired Devices") {
                    devicesSection(status)
                    Button("Reset Remote Access…", role: .destructive) { confirmingReset = true }
                        .accessibilityIdentifier("remote-access-reset")
                }
            } else {
                Section("Remote Access") {
                    Text("Remote access is not available from this runtime.")
                }
            }
        }
        .onAppear { if let status { portText = String(status.port) } }
        .onChange(of: status?.pairing?.code) { _, _ in copiedPairingCode = false }
        .onChange(of: status?.port) { _, port in if let port, !(status?.enabled ?? false) { portText = String(port) } }
        .confirmationDialog("Reset remote access?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Reset Remote Access", role: .destructive) { resetAccess() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Generates a new access key and removes every paired device. Every iPhone must pair again.")
        }
        .confirmationDialog("Revoke \(revokingDevice?.name ?? "this device")?", isPresented: Binding(get: { revokingDevice != nil }, set: { if !$0 { revokingDevice = nil } }), titleVisibility: .visible) {
            Button("Revoke", role: .destructive) { revoke(revokingDevice) }
            Button("Cancel", role: .cancel) { revokingDevice = nil }
        } message: {
            Text("This device will need to pair again to reconnect.")
        }
    }
    @ViewBuilder private func stateRow(_ status: RemoteAccessStatus) -> some View {
        if status.listening, !status.addresses.isEmpty {
            ForEach(status.addresses, id: \.self) { address in
                Text("Listening on \(address):\(status.port)")
            }
        } else if status.listening {
            Text("Listening on port \(status.port)")
        } else if let error = status.error {
            Text(error).foregroundStyle(.red)
        } else {
            Text("Not listening")
        }
        Text("Key fingerprint \(status.keyFingerprint)").font(.caption).foregroundStyle(.secondary)
    }
    @ViewBuilder private func portRow(_ status: RemoteAccessStatus) -> some View {
        HStack {
            TextField("Port", text: $portText).disabled(status.enabled).frame(width: 80)
            Button("Apply") { applyPort() }.disabled(status.enabled)
        }
        if let portFailure { Text(portFailure).foregroundStyle(.red).font(.caption) }
        Text("Turn off remote access to change the port.").font(.caption).foregroundStyle(.secondary)
    }
    @ViewBuilder private func pairingSection(_ status: RemoteAccessStatus) -> some View {
        if let pairing = status.pairing {
            HStack(spacing: 12) {
                Text(pairing.code)
                    .font(.system(.largeTitle, design: .monospaced))
                    .textSelection(.enabled)
                    .accessibilityIdentifier("remote-access-code")
                Button {
                    NSPasteboard.general.clearContents()
                    copiedPairingCode = NSPasteboard.general.setString(pairing.code, forType: .string)
                } label: {
                    Label(copiedPairingCode ? "Copied" : "Copy", systemImage: copiedPairingCode ? "checkmark" : "doc.on.doc")
                }
                .help("Copy pairing code")
                .accessibilityLabel(copiedPairingCode ? "Pairing code copied" : "Copy pairing code")
                .accessibilityIdentifier("remote-access-copy-code")
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("Enter this code in the iPhone app together with one of the addresses above. It expires in \(countdown(pairing.expiresAt, now: context.date)).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Cancel Pairing") { cancelPairing() }
        } else {
            Button("Pair iPhone…") { beginPairing() }
                .disabled(!(status.enabled && status.listening))
                .accessibilityIdentifier("remote-access-pair")
        }
    }
    @ViewBuilder private func devicesSection(_ status: RemoteAccessStatus) -> some View {
        if status.devices.isEmpty {
            Text("No paired devices").font(.caption).foregroundStyle(.secondary)
        } else {
            ForEach(status.devices) { device in
                HStack {
                    Text(device.name)
                    if device.connected {
                        Text("Connected").font(.caption).foregroundStyle(.green)
                    } else if let lastSeenAt = device.lastSeenAt {
                        Text("Last seen \(lastSeenAt, format: .relative(presentation: .named))").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Paired \(device.pairedAt, format: .relative(presentation: .named))").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Revoke", role: .destructive) { revokingDevice = device }
                }
            }
        }
    }
    private func countdown(_ expiresAt: Date, now: Date) -> String {
        let remaining = max(0, Int(expiresAt.timeIntervalSince(now)))
        return String(format: "%d:%02d", remaining / 60, remaining % 60)
    }
    private func setEnabled(_ enabled: Bool) {
        model.perform { _ = try await model.call("setRemoteAccess", .object(["enabled": .bool(enabled)])) }
    }
    private func applyPort() {
        portFailure = nil
        guard let port = Int(portText), (1024...65535).contains(port) else {
            portFailure = "Enter a port between 1024 and 65535."
            return
        }
        model.perform { _ = try await model.call("setRemoteAccess", .object(["enabled": .bool(false), "port": .number(Double(port))])) }
    }
    private func beginPairing() {
        model.perform { _ = try await model.call("beginPairing") }
    }
    private func cancelPairing() {
        model.perform { _ = try await model.call("cancelPairing") }
    }
    private func revoke(_ device: RemoteAccessStatus.Device?) {
        guard let device else { return }
        revokingDevice = nil
        model.perform { _ = try await model.call("revokeRemoteDevice", .object(["deviceID": .string(device.id.uuidString)])) }
    }
    private func resetAccess() {
        model.perform { _ = try await model.call("resetRemoteAccess") }
    }
}
