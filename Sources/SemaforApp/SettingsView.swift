import ServiceManagement
import SwiftUI

import SemaforCore

/// Poll policy + credential-free probe configuration + data reset.
/// Probe model IDs persist now but only feed probes in M3.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var pollIntervalMinutes: Int
    @State private var launchAtLogin: Bool
    @State private var claudeProbeModelID: String
    @State private var codexProbeModelID: String

    init(model: AppModel) {
        self.model = model
        _pollIntervalMinutes = State(initialValue: model.settings.pollIntervalMinutes)
        _launchAtLogin = State(initialValue: model.settings.launchAtLogin)
        _claudeProbeModelID = State(initialValue: model.settings.claudeProbeModelID)
        _codexProbeModelID = State(initialValue: model.settings.codexProbeModelID)
    }

    var body: some View {
        Form {
            Picker("Poll interval", selection: $pollIntervalMinutes) {
                ForEach([2, 5, 15, 30], id: \.self) { minutes in
                    Text("\(minutes) min").tag(minutes)
                }
            }
            .onChange(of: pollIntervalMinutes) { _, value in
                model.settings.pollIntervalMinutes = value
            }

            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    model.settings.launchAtLogin = enabled
                    if enabled {
                        try? SMAppService.mainApp.register()
                    } else {
                        try? SMAppService.mainApp.unregister()
                    }
                }

            Section("Latency probes (used from M3)") {
                TextField("Claude model id", text: $claudeProbeModelID)
                    .onChange(of: claudeProbeModelID) { _, value in
                        model.settings.claudeProbeModelID = value
                    }
                TextField("Codex model id", text: $codexProbeModelID)
                    .onChange(of: codexProbeModelID) { _, value in
                        model.settings.codexProbeModelID = value
                    }
            }

            Section {
                Button("Reset data…", role: .destructive) { model.resetData() }
            } header: {
                Text("Sample store")
            } footer: {
                Text("Deletes all locally recorded limit samples.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .padding(.bottom, 8)
    }
}
