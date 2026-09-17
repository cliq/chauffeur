import SwiftUI

/// 01 / Connect to Mac. A saved host reconnects directly; otherwise manual entry or pairing.
struct ConnectView: View {
    @Bindable var model: MobileAppModel
    @State private var host = ""
    @State private var portText = String(MobileAppModel.defaultPort)
    @State private var showPairing = false

    private var port: Int {
        Int(portText.trimmingCharacters(in: .whitespaces)) ?? MobileAppModel.defaultPort
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
                    Button("Use a different Mac", role: .destructive) {
                        model.forgetSavedHost()
                    }
                }
            } else {
                Section {
                    TextField("Mac address (e.g. leos-mac.local)", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Port", text: $portText)
                        .keyboardType(.numberPad)
                    Button("Pair with a code") {
                        showPairing = true
                    }
                } header: {
                    Text("Mac address")
                } footer: {
                    Text("First connection: enable remote access on the Mac and pair this device.")
                }
            }

            Section {
                ConnectionStateLabel(state: model.connectionState)
            } footer: {
                Text("Reachability and pairing errors appear here.")
            }

            Section {
                Button {
                    if let saved = model.savedHost {
                        model.connect(host: saved.host, port: saved.port)
                    } else {
                        model.connect(host: host, port: port)
                    }
                } label: {
                    Text(model.savedHost == nil ? "Pair & connect" : "Connect")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.connectionState == .connecting)
            }
            .listRowBackground(Color.clear)
        }
        .navigationTitle("Chauffeur")
        .sheet(isPresented: $showPairing) {
            PairingSheet { code in
                model.pair(code: code)
            }
        }
    }
}

struct ConnectionStateLabel: View {
    let state: ConnectionState

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
        case .connected(let hostName):
            Label("Connected to \(hostName)", systemImage: "circle.fill")
                .foregroundStyle(.green)
        case .unavailable(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }
}

/// Pairing / host verification. Ten alphanumeric characters shown as XXXX-XXXX-XX.
struct PairingSheet: View {
    var onPair: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var display = ""

    private var rawCode: String {
        display.filter { $0.isLetter || $0.isNumber }
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
                        .onChange(of: display) { _, newValue in
                            let formatted = Self.format(newValue)
                            if formatted != newValue {
                                display = formatted
                            }
                        }
                } header: {
                    Text("Pairing code")
                } footer: {
                    Text("Open Remote Access on your Mac and enter the code it shows. The code expires after a few minutes.")
                }

                Section {
                    Button {
                        onPair(rawCode)
                        dismiss()
                    } label: {
                        Text("Pair & connect")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(rawCode.count != 10)
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
        let raw = text.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(10)
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
        ConnectView(model: MobileAppModel(makeTerminalAdapter: MobileAppModel.defaultTerminalAdapterFactory(arguments: ["--fake-terminal"])))
    }
}

#Preview("Pairing sheet") {
    PairingSheet { _ in }
}
