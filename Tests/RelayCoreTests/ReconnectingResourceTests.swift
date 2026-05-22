import XCTest
@testable import RelayCore

final class ReconnectingResourceTests: XCTestCase {
    /// Controllable fake "resource opener" used as `R = Int`.
    private actor Fake {
        private(set) var openCount = 0
        private var alive = true
        private var delayNanos: UInt64 = 0

        func setAlive(_ b: Bool) { alive = b }
        func setDelay(_ n: UInt64) { delayNanos = n }

        func open() async -> Int {
            if delayNanos > 0 { try? await Task.sleep(nanoseconds: delayNanos) }
            openCount += 1
            return openCount
        }
        func isAlive(_ value: Int) -> Bool { alive }
    }

    func testCachesWhileAlive() async throws {
        let fake = Fake()
        let res = ReconnectingResource<Int>(
            open: { await fake.open() },
            isAlive: { await fake.isAlive($0) })
        let a = try await res.get()
        let b = try await res.get()
        XCTAssertEqual(a, 1)
        XCTAssertEqual(b, 1)
        let count = await fake.openCount
        XCTAssertEqual(count, 1, "a living cached resource must not be re-opened")
    }

    func testReopensWhenDead() async throws {
        let fake = Fake()
        let res = ReconnectingResource<Int>(
            open: { await fake.open() },
            isAlive: { await fake.isAlive($0) })
        _ = try await res.get()        // opens -> 1
        await fake.setAlive(false)
        let second = try await res.get() // dead -> re-open -> 2
        XCTAssertEqual(second, 2)
        let count = await fake.openCount
        XCTAssertEqual(count, 2)
    }

    func testInvalidateForcesReopen() async throws {
        let fake = Fake()
        let res = ReconnectingResource<Int>(
            open: { await fake.open() },
            isAlive: { await fake.isAlive($0) })
        _ = try await res.get()
        await res.invalidate()
        _ = try await res.get()
        let count = await fake.openCount
        XCTAssertEqual(count, 2)
    }

    func testSingleFlightUnderConcurrentGets() async throws {
        let fake = Fake()
        await fake.setDelay(20_000_000) // 20ms so the three gets overlap
        let res = ReconnectingResource<Int>(
            open: { await fake.open() },
            isAlive: { await fake.isAlive($0) })
        async let g1 = res.get()
        async let g2 = res.get()
        async let g3 = res.get()
        let results = try await [g1, g2, g3]
        XCTAssertEqual(results, [1, 1, 1])
        let count = await fake.openCount
        XCTAssertEqual(count, 1, "concurrent gets must share a single open()")
    }
}
