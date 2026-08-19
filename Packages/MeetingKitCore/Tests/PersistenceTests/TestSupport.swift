import Foundation
import GRDB
import XCTest
@testable import Persistence

// MARK: - Deterministic time

/// Fixed clocks and explicit time zones for every date-sensitive test.
///
/// NOTHING in these suites may read `Date()` or `Calendar.current`. The store
/// persists UTC and the UI renders local time, so a test that borrows the
/// machine's zone passes in India (UTC+5:30) and fails in CI (UTC) — or, worse,
/// the other way round, which is how the "rows look hours old" confusion got
/// all the way to a user in the first place.
enum FixedTime {
    static let ist = TimeZone(identifier: "Asia/Kolkata")!        // UTC+5:30, no DST
    static let newYork = TimeZone(identifier: "America/New_York")! // DST twice a year
    static let utc = TimeZone(identifier: "UTC")!

    /// Gregorian calendar pinned to `zone` with a fixed (POSIX) locale, so
    /// week rules and day boundaries never depend on the host.
    static func calendar(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    /// An instant named by its LOCAL wall-clock reading in `zone`.
    static func date(
        _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int, _ minute: Int, _ second: Int = 0,
        nanosecond: Int = 0,
        in zone: TimeZone
    ) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        components.nanosecond = nanosecond
        guard let date = calendar(zone).date(from: components) else {
            fatalError("unrepresentable test date \(components) in \(zone.identifier)")
        }
        return date
    }

    /// `h:mm a` in a fixed zone — the History window's rendering, made
    /// host-independent so "9:00 AM" means the same thing everywhere.
    static func wallClock(_ date: Date, in zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd h:mm a"
        return formatter.string(from: date)
    }

    /// Local calendar day of an instant, as `(year, month, day)` in `zone`.
    static func localDay(_ date: Date, in zone: TimeZone) -> DateComponents {
        calendar(zone).dateComponents([.year, .month, .day], from: date)
    }
}

// MARK: - Store fixtures

/// A temporary directory that removes itself with the test case.
final class TempStoreDirectory {
    let url: URL

    init(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("scribe-\(label)-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            XCTFail("could not create temp dir: \(error)", file: file, line: line)
        }
    }

    var storePath: String { url.appendingPathComponent("store.sqlite").path }

    func path(_ name: String) -> String { url.appendingPathComponent(name).path }

    deinit { try? FileManager.default.removeItem(at: url) }
}

/// Reads raw column text straight out of the SQLite file, bypassing
/// `MeetingStore` and GRDB's record decoding.
///
/// Round-tripping a `Date` through the same encoder that wrote it cannot
/// detect a zone bug — a store that wrote local time and read it back as local
/// time round-trips perfectly and is still wrong the moment anything else
/// (sqlite3, an export, a second process) reads the file. These helpers assert
/// what is actually ON DISK.
enum RawStore {
    static func query(_ path: String, _ sql: String, _ arguments: StatementArguments = StatementArguments()) throws -> [Row] {
        let queue = try DatabaseQueue(path: path)
        return try queue.read { db in try Row.fetchAll(db, sql: sql, arguments: arguments) }
    }

    static func text(_ path: String, _ sql: String, _ arguments: StatementArguments = StatementArguments()) throws -> String? {
        let queue = try DatabaseQueue(path: path)
        return try queue.read { db in try String.fetchOne(db, sql: sql, arguments: arguments) }
    }

    static func count(_ path: String, _ table: String) throws -> Int {
        let queue = try DatabaseQueue(path: path)
        return try queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? -1 }
    }

    /// Column names of a table, as SQLite sees them.
    static func columns(_ path: String, _ table: String) throws -> Set<String> {
        let queue = try DatabaseQueue(path: path)
        return try queue.read { db in
            Set(try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))").compactMap { $0["name"] as String? })
        }
    }

    /// Applied GRDB migration identifiers, in application order.
    static func appliedMigrations(_ path: String) throws -> [String] {
        let queue = try DatabaseQueue(path: path)
        return try queue.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
        }
    }
}
