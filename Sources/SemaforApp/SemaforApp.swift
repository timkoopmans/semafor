import SwiftUI

import SemaforCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

/// Owns the live object graph and republishes scheduler state for SwiftUI:
/// sections + status title rebuild on every scheduler update and on a 30 s
/// tick so countdown text stays fresh.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var sections: [ProviderSectionModel] = []
    @Published private(set) var status = StatusItemModel.title(
        for: [:], pollInterval: 300, now: Date())
    @Published private(set) var paused = false

    let settings: AppSettings
    let store: SampleStore
    private let scheduler: PollScheduler
    private var latestSnapshots: [ProviderID: ProviderSnapshot] = [:]
    private var started = false

    init() {
        let settings = AppSettings()
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Semafor", isDirectory: true)
        let store = SampleStore(config: .init(directory: directory))
        let http = URLSessionHTTPClient(timeout: 20)
        let providers: [any Provider] = [
            ClaudeProvider(http: http, credentials: ClaudeKeychainReader(), settings: settings),
            CodexProvider(http: http, auth: CodexFileReader(), settings: settings),
        ]
        self.settings = settings
        self.store = store
        self.scheduler = PollScheduler(providers: providers, writer: store, settings: settings)

        let updates = scheduler.updates()
        Task { [weak self] in
            for await snapshots in updates {
                await self?.apply(snapshots)
            }
        }
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await self?.applyLatest()
            }
        }
        // MenuBarExtra content only renders once clicked — the scheduler must
        // run from launch, or nothing polls until the popover is first opened.
        startPolling()
    }

    var lastPollText: String {
        guard let latest = latestSnapshots.values.map(\.fetchedAt).max() else {
            return "no poll yet"
        }
        let minutes = Int(Date().timeIntervalSince(latest) / 60)
        return minutes < 1 ? "last poll just now" : "last poll \(minutes)m ago"
    }

    func startPolling() {
        guard !started else { return }
        started = true
        Task { await scheduler.start() }
    }

    func refreshAll() {
        Task {
            await scheduler.refresh(.claude)
            await scheduler.refresh(.codex)
        }
    }

    func togglePaused() {
        paused.toggle()
        let value = paused
        Task { await scheduler.setPaused(value) }
    }

    func resetData() {
        Task { try? await store.deleteAll() }
    }

    private func apply(_ snapshots: [ProviderID: ProviderSnapshot]) async {
        latestSnapshots = snapshots
        await applyLatest()
    }

    private func applyLatest() async {
        let now = Date()
        let pollInterval = TimeInterval(settings.pollIntervalMinutes * 60)
        let since = now.addingTimeInterval(-24 * 3600)
        var built: [ProviderSectionModel] = []
        for id in [ProviderID.claude, .codex] {
            guard let snapshot = latestSnapshots[id] else { continue }
            var projections: [WindowName: BurnRateEstimator.Projection] = [:]
            for name in Set(snapshot.windows.map(\.name)) {
                let samples = await store.limits(provider: id, since: since)
                    .filter { $0.name == name }
                    .compactMap { window -> (at: Date, usedPercent: Double)? in
                        guard let percent = window.usedPercent else { return nil }
                        return (at: window.fetchedAt, usedPercent: percent)
                    }
                if let projection = BurnRateEstimator.project(samples: samples, now: now) {
                    projections[name] = projection
                }
            }
            built.append(ProviderSectionModel(
                snapshot: snapshot, projections: projections, now: now,
                settings: settings, pollInterval: pollInterval))
        }
        sections = built
        status = StatusItemModel.title(
            for: latestSnapshots, pollInterval: pollInterval, now: now)
    }
}

@main
struct SemaforApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(model: model)
        } label: {
            Text(model.status.title)
                .foregroundStyle(Self.color(for: model.status.color))
        }
        .menuBarExtraStyle(.window)

        Window("Semafor Settings", id: "settings") {
            SettingsView(model: model)
        }
        .defaultSize(width: 380, height: 360)
    }

    static func color(for status: StatusItemModel.StatusColor) -> Color {
        switch status {
        case .green: return .green
        case .amber: return .orange
        case .red: return .red
        case .grey: return .secondary
        }
    }
}
