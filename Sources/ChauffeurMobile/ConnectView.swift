import SwiftUI
import ChauffeurRemoteProtocol
import ChauffeurRemoteClient

/// 01 / Connect to Mac. A saved host reconnects directly; otherwise enter the address and pair.
struct ConnectView: View {
    @Bindable var model: MobileAppModel
    @State private var host = ""
    @State private var portText = String(MobileAppModel.defaultPort)
    @State private var showPairing = false

    private var port: Int {
        Int(portText.trimmingCharacters(in: .whitespaces)) ?? MobileAppModel.defaultPort
    }

    private var canPair: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !model.isPairing
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Connect to your Mac")
                        .font(.title2.weight(.semibold))
                    Text("Use the same local network.")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            if let saved = model.savedHost {
                Section("Saved Mac") {
                    HStack {
                        Image(systemName: "desktopcomputer")
                            .font(.title2)
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading) {
                            Text(saved.name).font(.headline)
                            Text("\(saved.host):\(saved.port)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button("Forget this Mac", role: .destructive) {
                        model.forget()
                    }
                    .accessibilityIdentifier("connect-forget")
                }
            } else {
                Section {
                    TextField("Mac address (e.g. leos-mac.local)", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityIdentifier("connect-host")
                    TextField("Port", text: $portText)
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("connect-port")
                } header: {
                    Text("Mac address")
                } footer: {
                    Text("Enable Remote Access in the Mac's Settings, then pair with the code it shows. Pairing uses port \(String(port + 1)).")
                }
            }

            Section {
                ConnectionStateLabel(state: model.connectionState)
                if let error = model.connectError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if isProtocolMismatch {
                    Text("Protocol mismatch: the Mac and this iPhone run different Chauffeur builds. Install the same version on both (a Debug phone build pairs with a Debug Mac build on port \(String(MobileAppModel.defaultPort))).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Reachability and pairing errors appear here.")
            }

            Section {
                if model.savedHost != nil {
                    Button {
                        Task { await model.connect() }
                    } label: {
                        HStack {
                            if model.isConnecting {
                                ProgressView()
                            }
                            Text(model.isConnecting ? "Connecting…" : "Connect")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isConnecting)
                    .accessibilityIdentifier("connect-button")
                } else {
                    Button {
                        showPairing = true
                    } label: {
                        HStack {
                            if model.isPairing {
                                ProgressView()
                            }
                            Text(model.isPairing ? "Pairing…" : "Pair with a code")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canPair)
                    .accessibilityIdentifier("connect-pair")
                }
            }
            .listRowBackground(Color.clear)
        }
        .navigationTitle("Chauffeur")
        .sheet(isPresented: $showPairing) {
            PairingSheet { code in
                Task { await model.pair(host: host, port: port, code: code) }
            }
        }
    }

    private var isProtocolMismatch: Bool {
        let mismatch = RemoteClientError.protocolMismatch(hostVersion: 0, clientVersion: 0).userMessage
        if model.connectError == mismatch { return true }
        if case .unavailable(let message) = model.connectionState, message == mismatch { return true }
        return false
    }
}

struct ConnectionStateLabel: View {
    let state: HostConnectionState

    var body: some View {
        switch state {
        case .disconnected:
            Label("Not connected", systemImage: "circle")
                .foregroundStyle(.secondary)
        case .connecting:
            HStack {
                ProgressView()
                Text("Connecting…")
            }
        case .connected(let info):
            Label("Connected to \(info.hostName)", systemImage: "circle.fill")
                .foregroundStyle(.green)
        case .unavailable(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }
}

/// Pairing code entry. Ten Crockford base32 characters shown as XXXX-XXXX-XX.
struct PairingSheet: View {
    var onPair: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var display = ""

    private var normalizedCode: String? {
        PairingKeyDerivation.normalize(display)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("XXXX-XXXX-XX", text: $display)
                        .font(.system(.title2, design: .monospaced))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("pairing-code")
                        .onChange(of: display) { _, newValue in
                            let formatted = Self.format(newValue)
                            if formatted != newValue {
                                display = formatted
                            }
                        }
                } header: {
                    Text("Pairing code")
                } footer: {
                    Text("Open Remote Access in the Mac's Settings and enter the code it shows. The code expires after a few minutes.")
                }

                Section {
                    Button {
                        if let code = normalizedCode {
                            onPair(code)
                            dismiss()
                        }
                    } label: {
                        Text("Pair & connect")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(normalizedCode == nil)
                    .accessibilityIdentifier("pairing-submit")
                }
                .listRowBackground(Color.clear)
            }
            .navigationTitle("Pair this device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    static func format(_ text: String) -> String {
        let raw = text.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(PairingKeyDerivation.codeLength)
        var result = ""
        for (index, character) in raw.enumerated() {
            if index == 4 || index == 8 {
                result.append("-")
            }
            result.append(character)
        }
        return result
    }
}

#Preview("Saved host") {
    NavigationStack {
        ConnectView(model: .preview(connected: false))
    }
}

#Preview("Manual entry") {
    NavigationStack {
        ConnectView(model: MobileAppModel(
            credentials: InMemoryCredentialStore(),
            journal: InMemoryOperationJournal(),
            makeTerminalAdapter: MobileAppModel.defaultTerminalAdapterFactory(arguments: ["--fake-terminal"])
        ))
    }
}

#Preview("Pairing sheet") {
    PairingSheet { _ in }
}
