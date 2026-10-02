import XCTest
@testable import LiveWire

final class QueueTests: XCTestCase {
    private func tx(_ id: Int, audio: Bool = true) -> Transmission {
        Transmission(id: id, incidentId: nil, agency: .fire, incidentType: nil, occurredAt: Double(id), heardAt: Double(id),
                     transcript: "t\(id)", summary: nil, address: nil, lat: nil, lon: nil,
                     audioFile: audio ? "\(id).wav" : nil, duration: 1, units: [])
    }

    func testFIFOOrder() {
        var q = ClipQueue()
        for i in 1...3 { q.enqueue(tx(i)) }
        XCTAssertEqual(q.count, 3)
        XCTAssertEqual(q.dequeue()?.id, 1)
        XCTAssertEqual(q.dequeue()?.id, 2)
        XCTAssertEqual(q.dequeue()?.id, 3)
        XCTAssertNil(q.dequeue())
        XCTAssertTrue(q.isEmpty)
    }

    func testCapacityDropsOldestAndCountsSkipped() {
        var q = ClipQueue()
        for i in 1...10 { XCTAssertEqual(q.enqueue(tx(i)), 0) }
        XCTAssertEqual(q.enqueue(tx(11)), 1)        // 1 dropped
        XCTAssertEqual(q.enqueue(tx(12)), 1)        // 2 dropped
        XCTAssertEqual(q.count, 10)
        XCTAssertEqual(q.items.first?.id, 3)
        XCTAssertEqual(q.items.last?.id, 12)
        XCTAssertEqual(q.takeSkipped(), 2)
        XCTAssertEqual(q.takeSkipped(), 0)
    }

    func testDuplicatesIgnoredAndFilterRemoval() {
        var q = ClipQueue()
        q.enqueue(tx(1))
        q.enqueue(tx(1))
        XCTAssertEqual(q.count, 1)
        q.enqueue(tx(2))
        q.removeAll(where: { $0.id == 1 })
        XCTAssertEqual(q.items.map(\.id), [2])
        q.removeAll()
        XCTAssertTrue(q.isEmpty)
    }

    @MainActor
    func testEngineQueuesOnlyWhileLive() {
        let defaults = UserDefaults(suiteName: "livewire.queue-tests")!
        defaults.removePersistentDomain(forName: "livewire.queue-tests")
        let engine = AudioEngine(settings: Settings(defaults: defaults))
        engine.enqueue(tx(1))
        XCTAssertEqual(engine.lastTransmission?.id, 1, "pill shows the last transcript while paused")
        XCTAssertTrue(engine.queue.isEmpty, "nothing is queued while paused")
        XCTAssertFalse(engine.isLive)
    }
}
