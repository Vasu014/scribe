import Foundation
import GRDB
import XCTest
@testable import Persistence

/// Silent failure is this app's defining defect (SPEC §4.4; both independent
/// audits named it). The store is where it hurt most: an unopenable database
/// used to be swallowed and replaced with `MeetingStore.inMemory()`, so a whole
/// meeting recorded, displayed, ticked "Saved", fused — and evaporated at quit.
///
/// The composition root now refuses to run without persistence, but that
/// refusal is only possible because the STORE throws. These tests pin the
/// lower half of that contract: every way the store can fail to be usable
/// produces a typed, distinguishable error, and no path anywhere in
/// `Persistence` invents a working-looking substitute.
final class StoreFailureSurfacingTests: XCTestCase {

    /// Opening a file that is not a database must throw — never fall back.
    ///
    /// This is the exact failure the in-memory fallback used to hide: the
    /// common cause of a lost store is a corrupt or half-written file, not a
    /// missing one.
    func testACorruptDatabaseFileThrowsInsteadOfOpening() throws {
        let dir = TempStoreDirectory("fail-corrupt")
        let path = dir.path("store.sqlite")
        try Data("this file is a text file wearing a .sqlite extension".utf8)
            .write(to: URL(fileURLWithPath: path))

        XCTAssertThrowsError(try MeetingStore(path: path)) { error in
            let dbError = error as? DatabaseError
            XCTAssertNotNil(dbError, "callers switch on the error; it must stay typed: \(error)")
            XCTAssertEqual(dbError?.resultCode, .SQLITE_NOTADB,
                           "a corrupt file must be distinguishable from an inaccessible one")
            XCTAssertFalse(error.localizedDescription.isEmpty,
                           "the store-failure alert shows this text to the user")
        }
    }

    /// A store whose header was overwritten — a real half-written file, not a
    /// synthetic one — fails the same way.
    func testATruncatedDatabaseHeaderThrows() throws {
        let dir = TempStoreDirectory("fail-truncated")
        let path = dir.path("store.sqlite")
        _ = try MeetingStore(path: path)                       // a real, valid store…
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data(repeating: 0x41, count: 64))   // …with its header smashed
        try handle.close()

        XCTAssertThrowsError(try MeetingStore(path: path)) { error in
            XCTAssertEqual((error as? DatabaseError)?.resultCode, .SQLITE_NOTADB)
        }
    }

    /// An inaccessible location (the Application Support folder missing or
    /// unwritable) is a DIFFERENT problem from a corrupt file, and the alert
    /// offers a different recovery for each — so the errors must not collapse
    /// into one another.
    func testAnUnreachableStorePathThrowsADistinguishableError() throws {
        let dir = TempStoreDirectory("fail-unreachable")
        let missingParent = dir.path("no-such-folder/store.sqlite")

        XCTAssertThrowsError(try MeetingStore(path: missingParent)) { error in
            XCTAssertEqual((error as? DatabaseError)?.resultCode, .SQLITE_CANTOPEN)
        }

        // …and a directory where the file should be.
        let asDirectory = dir.path("store.sqlite")
        try FileManager.default.createDirectory(atPath: asDirectory, withIntermediateDirectories: true)
        XCTAssertThrowsError(try MeetingStore(path: asDirectory)) { error in
            XCTAssertEqual((error as? DatabaseError)?.resultCode, .SQLITE_CANTOPEN)
        }
    }

    /// A store that opens but cannot be written to must fail LOUDLY on the
    /// write. A silent no-op here is the in-memory fallback all over again:
    /// the session record would never exist and every later save would attach
    /// to a session id that is not in the file.
    func testAReadOnlyStoreFailsOnWriteRatherThanSilentlyDroppingRows() throws {
        let dir = TempStoreDirectory("fail-readonly")
        let path = dir.path("store.sqlite")
        _ = try MeetingStore(path: path)
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: path + suffix) {
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: path + suffix)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.url.path) }

        let store = try MeetingStore(path: path)
        XCTAssertThrowsError(try store.createSession()) { error in
            XCTAssertEqual((error as? DatabaseError)?.resultCode, .SQLITE_READONLY,
                           "a failed insert must reach the caller, not a log line: \(error)")
        }
        XCTAssertEqual(try store.allSessions().count, 0, "and nothing was pretended into existence")
    }

    /// A database written by a NEWER Scribe must be refused.
    ///
    /// `DatabaseMigrator` silently SKIPS migration identifiers it does not
    /// know, so before the guard in `MeetingStore.init` this store opened
    /// clean and reported `schemaVersion == 3` to nobody: an older build
    /// (a Sparkle rollback, a second machine, a downgrade) would list the
    /// meetings, record new ones and write through a schema it only half
    /// understands. `meta.schema_version` exists to prevent exactly this
    /// (SPEC §4.6) and nothing outside tests read it.
    func testAStoreFromANewerSchemaIsRefusedWithATypedError() throws {
        let dir = TempStoreDirectory("fail-future")
        let path = dir.path("store.sqlite")
        do {
            let store = try MeetingStore(path: path)
            _ = try store.createSession(startedAt: FixedTime.date(2026, 8, 20, 9, 0, in: FixedTime.ist))
        }
        // What a future v3 build would leave behind.
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v3')")
            try db.execute(sql: "ALTER TABLE sessions ADD COLUMN summaryModel TEXT")
            try db.execute(sql: "UPDATE meta SET schema_version = 3")
        }

        XCTAssertThrowsError(try MeetingStore(path: path)) { error in
            XCTAssertEqual(error as? MeetingStoreError, .schemaTooNew(found: 3, supported: 2))
            let text = error.localizedDescription
            XCTAssertTrue(text.contains("newer version of Scribe"), "the alert must say why: \(text)")
            XCTAssertFalse(text.contains("MeetingStoreError"), "not an enum dump: \(text)")
        }

        // Nothing was destroyed on the way out — the newer store's rows are
        // still there for the updated build to read.
        XCTAssertEqual(try RawStore.count(path, "sessions"), 1)
    }

    /// The guard must not fire on the schema this build writes, on a fresh
    /// store or on one just migrated up from v1.
    func testCurrentAndOlderSchemasStillOpen() throws {
        let fresh = TempStoreDirectory("fail-fresh")
        XCTAssertEqual(try MeetingStore(path: fresh.storePath).schemaVersion, Migrations.currentVersion)

        let old = TempStoreDirectory("fail-old")
        let queue = try DatabaseQueue(path: old.storePath)
        try Migrations.migrator.migrate(queue, upTo: "v1")
        XCTAssertEqual(try MeetingStore(path: old.storePath).schemaVersion, 2, "v1 stores migrate up, not away")
    }

    /// `Migrations.currentVersion` must track what the migrations actually
    /// write, or the guard rejects the store the app itself just created.
    func testDeclaredCurrentVersionMatchesWhatTheMigrationsWrite() throws {
        let dir = TempStoreDirectory("fail-version-sync")
        XCTAssertEqual(try MeetingStore(path: dir.storePath).schemaVersion, Migrations.currentVersion)
    }

    /// `inMemory()` still exists for tests, and must stay a deliberate,
    /// explicitly-named choice — never something a failure path can reach by
    /// accident. Nothing in `MeetingStore` may hand one back from a
    /// path-based open.
    func testPathBasedOpensNeverYieldTheInMemoryStore() throws {
        let dir = TempStoreDirectory("fail-nofallback")
        let path = dir.path("store.sqlite")
        let store = try MeetingStore(path: path)
        _ = try store.createSession(startedAt: FixedTime.date(2026, 8, 20, 9, 0, in: FixedTime.ist))

        // The proof an in-memory store cannot give: the rows are in the file,
        // readable by a second connection that never met this instance.
        XCTAssertEqual(try RawStore.count(path, "sessions"), 1)

        // And the in-memory store really is memory-only — writing to it must
        // not touch the default location.
        let memory = try MeetingStore.inMemory()
        _ = try memory.createSession()
        XCTAssertEqual(try memory.allSessions().count, 1)
        XCTAssertEqual(try RawStore.count(path, "sessions"), 1, "the two stores share nothing")
    }
}
