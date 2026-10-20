import ServiceManagement
import SwiftUI

import SemaforCore

/// Poll policy + data reset. Passive measurement settings land in the M3
/// verdict-settings task.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var pollIntervalMinutes: Int
    @State private var launchAtLogin: Bool
    @State private var confirmingReset = false

    init(model: AppModel) {
        self.model = model
        _pollIntervalMinutes = State(initialValue: model.settings.pollIntervalMinutes)
        _launchAtLogin = State(initialValue: model.settings.launchAtLogin)
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

            Section {
                Button("Reset data…", role: .destructive) { confirmingReset = true }
                    .confirmationDialog(
                        "Delete all locally recorded limit samples?",
                        isPresented: $confirmingReset,
                        titleVisibility: .visible
                    ) {
                        Button("Reset data", role: .destructive) { model.resetData() }
                        Button("Cancel", role: .cancel) {}
                    }
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
