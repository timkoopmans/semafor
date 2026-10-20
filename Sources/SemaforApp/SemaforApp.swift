import SwiftUI

import SemaforCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

/// Owns the live object graph and republishes scheduler/prober state for
/// SwiftUI: sections + status title rebuild on every scheduler or prober
/// update and on a 30 s tick so countdown text stays fresh.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var sections: [ProviderSectionModel] = []
    @Published private(set) var status = StatusItemModel.title(
        for: [:], pollInterval: 300, now: Date())
    @Published private(set) var paused = false
    @Published private(set) var divergenceText: String?

    let settings: AppSettings
    let store: SampleStore
    private let scheduler: PollScheduler
    private let prober: PassiveProber
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

        let tailer = SessionLogTailer(
            stateURL: directory.appendingPathComponent("tailer-state.json"))
        self.prober = PassiveProber(
            providers: providers,
            tailer: tailer,
            extractors: [
                .claude: ClaudeLogExtractor(),
                .codex: CodexLogExtractor(),
            ],
            control: ControlProbe(http: http),
            writer: store,
            settings: settings)

        let updates = scheduler.updates()
        Task { [weak self] in
            for await snapshots in updates {
                await self?.apply(snapshots)
            }
        }
        let probeUpdates = prober.updates()
        Task { [weak self] in
            for await _ in probeUpdates {
                await self?.applyLatest()
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
        let seconds = max(0, Int(Date().timeIntervalSince(latest)))
        if seconds < 600 { return "poll \(seconds) s ago" }
        return "poll \(seconds / 60)m ago"
    }

    func startPolling() {
        guard !started else { return }
        started = true
        Task { await scheduler.start() }
        Task { await prober.start() }  // backfills, then scans the CLI logs
    }

    func refreshAll() {
        Task {
            await scheduler.refresh(.claude)
            await scheduler.refresh(.codex)
            await prober.scanNow()
            await applyLatest()
        }
    }

    func togglePaused() {
        paused.toggle()
        let value = paused
        Task { await scheduler.setPaused(value) }
        Task { await prober.setPaused(value) }
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
        let probeSince = now.addingTimeInterval(-30 * 24 * 3600)  // store window for verdicts/sparklines
        let thresholds = settings.thresholds
        let baseline = BaselineEngine(thresholds: thresholds)

        var verdicts: [ProviderID: Verdict] = [:]
        var probesByProvider: [ProviderID: (probes: [ProbeSample], controls: [ControlSample])] = [:]
        let allControls = await store.controlSamples(since: probeSince)  // one read for all providers
        for id in [ProviderID.claude, .codex] {
            guard let snapshot = latestSnapshots[id] else { continue }
            let probes = await store.probeSamples(provider: id, since: probeSince)
            probesByProvider[id] = (probes, allControls)

            var paceStatuses: [WindowName: BurnRateEstimator.PaceStatus] = [:]
            for window in snapshot.windows {
                paceStatuses[window.name] = BurnRateEstimator.pace(
                    usedPercent: window.usedPercent,
                    windowSeconds: window.windowSeconds,
                    resetsAt: window.resetsAt,
                    now: now,
                    threshold: settings.paceDeltaPoints)
            }
            verdicts[id] = VerdictEngine.verdict(
                for: id,
                input: VerdictInput(
                    snapshot: snapshot, probes: probes, controls: allControls,
                    paceStatuses: paceStatuses),
                baseline: baseline, thresholds: thresholds, now: now)
        }

        let statuses = latestSnapshots.compactMapValues(\.officialStatus)
        let allProbes = probesByProvider.values.flatMap { $0.probes }
        divergenceText = VerdictEngine.divergence(
            verdicts: verdicts, statuses: statuses, latestProbes: allProbes)
        let troubled = Set(verdicts.values.filter {
            [.degraded, .crawling, .limited].contains($0.state)
        }.map(\.provider))

        var built: [ProviderSectionModel] = []
        for id in [ProviderID.claude, .codex] {
            guard let snapshot = latestSnapshots[id] else { continue }
            var projections: [WindowName: BurnRateEstimator.Projection] = [:]
            // One store read per provider per rebuild, not per window.
            let recent = await store.limits(provider: id, since: since)
            for name in Set(snapshot.windows.map(\.name)) {
                let samples = recent
                    .filter { $0.name == name }
                    .compactMap { window -> (at: Date, usedPercent: Double)? in
                        guard let percent = window.usedPercent else { return nil }
                        return (at: window.fetchedAt, usedPercent: percent)
                    }
                if let projection = BurnRateEstimator.project(samples: samples, now: now) {
                    projections[name] = projection
                }
            }
            let bundle = probesByProvider[id] ?? ([], [])
            let latestProbe = bundle.probes
                .filter { $0.outcome == .ok }
                .max { $0.timestamp < $1.timestamp }
            built.append(ProviderSectionModel(
                snapshot: snapshot, projections: projections, now: now,
                settings: settings, pollInterval: pollInterval,
                verdict: verdicts[id],
                latestProbe: latestProbe,
                recentSamples: bundle.probes,
                divergenceText: troubled.contains(id) ? divergenceText : nil,
                measuredToday: await prober.measuredCountToday(provider: id)))
        }
        sections = built
        status = StatusItemModel.title(
            for: latestSnapshots, pollInterval: pollInterval, now: now, verdicts: verdicts)
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
        .defaultSize(width: 420, height: 460)
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
