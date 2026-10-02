import Foundation

/// Reads GET /api/stream (server-sent events) and falls back to polling
/// /api/transmissions + /api/incidents every 5 s while the stream is down.
final class StreamClient: @unchecked Sendable {
    enum Mode: Equatable { case live, polling }

    enum Event {
        case connected(Mode)
        case transmission(Transmission)
        case incident(Incident)
        case ping
        case dropped(String)
    }

    private let api: APIClient
    private let sinceId: @Sendable () -> Int?
    private var task: Task<Void, Never>?

    /// `sinceId` is asked for on every (re)connect so no transmission is missed.
    init(api: APIClient, sinceId: @escaping @Sendable () -> Int?) {
        self.api = api
        self.sinceId = sinceId
    }

    func events() -> AsyncStream<Event> {
        AsyncStream { continuation in
            let t = Task { [api, sinceId] in
                await Self.run(api: api, sinceId: sinceId, continuation: continuation)
                continuation.finish()
            }
            self.task = t
            continuation.onTermination = { _ in t.cancel() }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    // MARK: - Loop

    private static func run(api: APIClient, sinceId: @escaping @Sendable () -> Int?,
                            continuation: AsyncStream<Event>.Continuation) async {
        var failures = 0
        while !Task.isCancelled {
            do {
                try await readStream(api: api, sinceId: sinceId(), continuation: continuation)
                failures = 0
            } catch is CancellationError {
                return
            } catch {
                failures += 1
                continuation.yield(.dropped(error.localizedDescription))
            }
            if Task.isCancelled { return }
            // Stream dropped: poll for a while (longer after repeated failures), then retry SSE.
            let rounds = min(2 + failures * 2, 12)
            await poll(api: api, sinceId: sinceId, rounds: rounds, continuation: continuation)
        }
    }

    private static func readStream(api: APIClient, sinceId: Int?,
                                   continuation: AsyncStream<Event>.Continuation) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(for: api.streamRequest(sinceId: sinceId))
        guard let http = response as? HTTPURLResponse else { throw APIError.network("no response") }
        if http.statusCode == 401 { throw APIError.unauthorized }
        guard http.statusCode == 200 else { throw APIError.server(http.statusCode, "stream") }
        continuation.yield(.connected(.live))

        var eventName = "message"
        for try await line in bytes.lines {
            try Task.checkCancellation()
            if line.hasPrefix(":") { continue }                       // comment / keep-alive
            if line.hasPrefix("event:") {
                eventName = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                let payload = Data(line.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8)
                dispatch(eventName, payload, continuation)
                eventName = "message"
            }
        }
        throw APIError.network("stream ended")
    }

    private static func dispatch(_ name: String, _ data: Data, _ c: AsyncStream<Event>.Continuation) {
        switch name {
        case "transmission":
            if let t = try? APIClient.decoder.decode(Transmission.self, from: data) { c.yield(.transmission(t)) }
        case "incident":
            if let i = try? APIClient.decoder.decode(Incident.self, from: data) { c.yield(.incident(i)) }
        case "ping":
            c.yield(.ping)
        default:
            break
        }
    }

    private static func poll(api: APIClient, sinceId: @escaping @Sendable () -> Int?, rounds: Int,
                             continuation: AsyncStream<Event>.Continuation) async {
        continuation.yield(.connected(.polling))
        for _ in 0..<rounds {
            if Task.isCancelled { return }
            do {
                let tx = try await api.transmissions(sinceId: sinceId() ?? 0, limit: 200)
                for t in tx.transmissions { continuation.yield(.transmission(t)) }
                let incs = try await api.incidents(hours: 2)
                for i in incs { continuation.yield(.incident(i)) }
                continuation.yield(.ping)
            } catch {
                continuation.yield(.dropped(error.localizedDescription))
            }
            try? await Task.sleep(for: .seconds(5))
        }
    }
}
