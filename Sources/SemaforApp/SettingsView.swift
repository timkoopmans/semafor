import ServiceManagement
import SwiftUI

import SemaforCore

/// Poll policy, passive-measurement policy, and data reset.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var pollIntervalMinutes: Int
    @State private var scanIntervalSeconds: Int
    @State private var backfillDays: Int
    @State private var sampleRecencyMinutes: Int
    @State private var controlProbeEnabled: Bool
    @State private var zWarn: Double
    @State private var zCrawl: Double
    @State private var consecutiveProbeN: Int
    @State private var launchAtLogin: Bool
    @State private var confirmingReset = false

    init(model: AppModel) {
        self.model = model
        _pollIntervalMinutes = State(initialValue: model.settings.pollIntervalMinutes)
        _scanIntervalSeconds = State(initialValue: model.settings.scanIntervalSeconds)
        _backfillDays = State(initialValue: model.settings.backfillDays)
        _sampleRecencyMinutes = State(initialValue: model.settings.sampleRecencyMinutes)
        _controlProbeEnabled = State(initialValue: model.settings.controlProbeEnabled)
        _zWarn = State(initialValue: model.settings.zWarn)
        _zCrawl = State(initialValue: model.settings.zCrawl)
        _consecutiveProbeN = State(initialValue: model.settings.consecutiveProbeN)
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

            Section("Passive measurement") {
                numberField("Scan interval (s)", value: $scanIntervalSeconds, range: 15...3600) {
                    model.settings.scanIntervalSeconds = $0
                }
                numberField("Backfill history (days)", value: $backfillDays, range: 1...30) {
                    model.settings.backfillDays = $0
                }
                numberField("Sample recency (min)", value: $sampleRecencyMinutes, range: 5...180) {
                    model.settings.sampleRecencyMinutes = $0
                }
            }

            Section("Verdict thresholds") {
                numberField("Warn z", value: $zWarn, fractionDigits: 1, clamp: 1...20) {
                    model.settings.zWarn = $0
                }
                numberField("Crawl z", value: $zCrawl, fractionDigits: 1, clamp: 1...50) {
                    model.settings.zCrawl = $0
                }
                numberField("Consecutive slow calls", value: $consecutiveProbeN, range: 2...10) {
                    model.settings.consecutiveProbeN = $0
                }
                Toggle("Control probe", isOn: $controlProbeEnabled)
                    .onChange(of: controlProbeEnabled) { _, enabled in
                        model.settings.controlProbeEnabled = enabled
                    }
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
        .frame(width: 420)
        .padding(.bottom, 8)
    }

    private func numberField(
        _ title: String, value: Binding<Int>, range: ClosedRange<Int>,
        store: @escaping (Int) -> Void
    ) -> some View {
        // LabeledContent keeps the label on one line and trails the field —
        // plain TextField(title) let the label column collapse and hyphenate.
        LabeledContent(title) {
            TextField("", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
                .onChange(of: value.wrappedValue) { _, clamped in
                    store(min(max(clamped, range.lowerBound), range.upperBound))
                }
        }
    }

    private func numberField(
        _ title: String, value: Binding<Double>, fractionDigits: Int,
        clamp: ClosedRange<Double>, store: @escaping (Double) -> Void
    ) -> some View {
        LabeledContent(title) {
            TextField("", value: value, format: .number.precision(.fractionLength(0...fractionDigits)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
                .onChange(of: value.wrappedValue) { _, clamped in
                    store(min(max(clamped, clamp.lowerBound), clamp.upperBound))
                }
        }
    }
}
