import Foundation
import Testing
@testable import SemaforCore

/// Control probe: robots.txt GETs separating "my network" from "their
/// service" (spec §6.3). Latency comes from the injected clock.
struct ControlProbeTests {
    private func response(_ code: Int, for url: URL) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
    }

    private func probe(
        behavior: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse),
        clock: @escaping @Sendable () -> Date = Date.init
    ) -> ControlProbe {
        ControlProbe(
            http: StubHTTPClient(behavior: behavior),
            dateNow: clock)
    }

    private func steppedClock(_ offsets: [TimeInterval]) -> @Sendable () -> Date {
        let base = Date(timeIntervalSince1970: 1_760_000_000)
        let box = ManagedBox(offsets)
        return {
            let index = box.next()
            return base.addingTimeInterval(offsets[min(index, offsets.count - 1)])
        }
    }

    private final class ManagedBox: @unchecked Sendable {
        private var index = -1
        private let lock = NSLock()
        init(_ values: [TimeInterval]) { self.values = values }
        let values: [TimeInterval]
        func next() -> Int {
            lock.lock(); defer { lock.unlock() }
            index += 1
            return index
        }
    }

    @Test func latencyIsWallTimeBetweenClockReads() async {
        // Reads: timestamp, start, end.
        let probe = probe(
            behavior: { req in (Data(), response(200, for: req.url!)) },
            clock: steppedClock([0, 0, 0.4]))
        let sample = await probe.measure(.claude)
        #expect(sample.provider == .claude)
        #expect(sample.latency! > 0.399 && sample.latency! < 0.401)
        #expect(sample.timestamp == Date(timeIntervalSince1970: 1_760_000_000))
    }

    @Test func targetsRobotsTxtWithTimeout() async throws {
        let requestBox = RequestCaptureBox()
        let probe = ControlProbe(http: StubHTTPClient { req in
            requestBox.capture(req)
            return (Data(), response(200, for: req.url!))
        })
        _ = await probe.measure(.claude)
        _ = await probe.measure(.codex)
        let requests = requestBox.requests
        #expect(requests.count == 2)
        #expect(requests[0].url == URL(string: "https://claude.ai/robots.txt"))
        #expect(requests[1].url == URL(string: "https://chatgpt.com/robots.txt"))
        #expect(requests.allSatisfy { $0.httpMethod == "GET" })
        #expect(requests.allSatisfy { $0.timeoutInterval == 10 })
    }

    @Test func serverErrorAndNetworkFailureReadAsNil() async {
        let failing500 = probe(behavior: { req in (Data(), response(500, for: req.url!)) })
        #expect(await failing500.measure(.claude).latency == nil)

        let failing404 = probe(behavior: { req in (Data(), response(404, for: req.url!)) })
        #expect(await failing404.measure(.codex).latency == nil)

        let throwing = probe(behavior: { _ in throw ProviderError.network })
        #expect(await throwing.measure(.claude).latency == nil)
    }

    @Test func isBadMatrix() {
        let at = Date(timeIntervalSince1970: 1_760_000_000)
        #expect(ControlSample(provider: .claude, latency: nil, timestamp: at)
            .isBad(threshold: 5))
        #expect(ControlSample(provider: .claude, latency: 6, timestamp: at)
            .isBad(threshold: 5))
        #expect(!ControlSample(provider: .claude, latency: 2, timestamp: at)
            .isBad(threshold: 5))
        #expect(!ControlSample(provider: .claude, latency: 5, timestamp: at)
            .isBad(threshold: 5))  // strictly greater
    }
}

private final class RequestCaptureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [URLRequest] = []
    func capture(_ request: URLRequest) {
        lock.lock(); defer { lock.unlock() }
        captured.append(request)
    }
    var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return captured
    }
}
