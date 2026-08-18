import XCTest
@testable import ScratchpadKit

final class FragmentComposerTests: XCTestCase {

    func testBurstFreezesAfterThreeSecondPause() {
        var persisted: [(String, TimeInterval)] = []
        var frozen: [(String, TimeInterval)] = []
        let composer = FragmentComposer()
        composer.onPersistPending = { persisted.append(($0, $1)) }
        composer.onFreeze = { frozen.append(($0, $1)) }

        composer.edit("pricing objection", at: 100.0)   // burst start → anchor 100
        composer.heartbeat(at: 100.2)
        composer.heartbeat(at: 101.1)                    // trailing persist (~1 s debounce)
        composer.heartbeat(at: 103.1)                    // ≥3 s since last edit → freeze

        XCTAssertEqual(frozen.count, 1)
        XCTAssertEqual(frozen[0].0, "pricing objection")
        XCTAssertEqual(frozen[0].1, 100.0, "anchor is burst start")
        XCTAssertFalse(persisted.isEmpty, "pending row must have been persisted before freeze")
    }

    func testNewlineFreezesImmediately() {
        var frozen: [(String, TimeInterval)] = []
        let composer = FragmentComposer()
        composer.onFreeze = { frozen.append(($0, $1)) }

        composer.edit("ask legal about DPA", at: 200.0)
        composer.edit("ask legal about DPA now", at: 200.4)
        composer.newline(at: 200.5)

        XCTAssertEqual(frozen.count, 1)
        XCTAssertEqual(frozen[0].0, "ask legal about DPA now")
        XCTAssertEqual(frozen[0].1, 200.0)
    }

    func testDebouncePersistsAtMostOncePerSecond() {
        var persisted: [(String, TimeInterval)] = []
        let composer = FragmentComposer()
        composer.onPersistPending = { persisted.append(($0, $1)) }

        composer.edit("a", at: 300.0)
        composer.edit("ab", at: 300.2)
        composer.edit("abc", at: 300.4)
        composer.edit("abcd", at: 300.6)

        // First edit persists immediately (no prior persist); the rest are
        // within the debounce window and wait for the heartbeat.
        XCTAssertEqual(persisted.count, 1)
        composer.heartbeat(at: 301.7)   // ≥1 s after last edit (300.6)
        XCTAssertEqual(persisted.count, 2)
        XCTAssertEqual(persisted.last?.0, "abcd", "pending row must reflect the latest text")
    }

    func testAnchorResetsBetweenBursts() {
        var frozen: [(String, TimeInterval)] = []
        let composer = FragmentComposer()
        composer.onFreeze = { frozen.append(($0, $1)) }

        composer.edit("first", at: 400.0)
        composer.newline(at: 400.2)
        composer.edit("second", at: 405.0)              // new burst → new anchor
        composer.newline(at: 405.1)

        XCTAssertEqual(frozen.map(\.1), [400.0, 405.0])
    }

    func testEmptyAndWhitespaceTextIgnored() {
        var frozen: [(String, TimeInterval)] = []
        let composer = FragmentComposer()
        composer.onFreeze = { frozen.append(($0, $1)) }

        composer.edit("   ", at: 500.0)
        composer.heartbeat(at: 504.0)

        XCTAssertTrue(frozen.isEmpty, "whitespace-only input must not create a fragment")
    }

    func testFlushFreezesPendingBurstAtSessionStop() {
        var frozen: [(String, TimeInterval)] = []
        let composer = FragmentComposer()
        composer.onFreeze = { frozen.append(($0, $1)) }

        composer.edit("last thought", at: 600.0)
        composer.flush(at: 600.5)

        XCTAssertEqual(frozen.count, 1)
        XCTAssertEqual(frozen[0].0, "last thought")
    }
}
