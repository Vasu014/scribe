import Foundation
import GRDB

/// Schema migrations. `meta.schema_version` is our explicit version, separate
/// from GRDB's own migration bookkeeping — REQUIRED from day one (SPEC §4.6).
/// After day 2 of the build, every schema change lands here as a new migration.
public enum Migrations {

    /// The highest `meta.schema_version` this build knows how to read.
    ///
    /// Bump it in the same migration that writes the new value, or the guard
    /// in `MeetingStore.init` will reject the store the migration just wrote.
    public static let currentVersion = 2

    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "meta") { t in
                t.column("schema_version", .integer).notNull()
            }
            try db.execute(sql: "INSERT INTO meta (schema_version) VALUES (1)")

            try db.create(table: "sessions") { t in
                t.primaryKey("id", .blob)
                t.column("startedAt", .datetime).notNull()
                t.column("endedAt", .datetime)
                t.column("state", .text).notNull()
                t.column("recovered", .boolean).notNull().defaults(to: false)
                t.column("title", .text)
                t.column("deviceEvents", .text).notNull().defaults(to: "[]")
            }

            try db.create(table: "segments") { t in
                // UUID stable across hypothesis revisions — UPSERT on id (SPEC §4.2)
                t.primaryKey("id", .blob)
                t.column("sessionId", .blob).notNull().indexed()
                t.column("channel", .text).notNull()
                t.column("text", .text).notNull()
                t.column("startOffset", .double).notNull()
                t.column("endOffset", .double).notNull()
                t.column("isFinal", .boolean).notNull().defaults(to: false)
                t.column("inferredAt", .datetime).notNull()
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "fragments") { t in
                t.primaryKey("id", .blob)
                t.column("sessionId", .blob).notNull().indexed()
                t.column("text", .text).notNull()
                t.column("anchorOffset", .double).notNull()
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "notes") { t in
                t.primaryKey("id", .blob)
                t.column("sessionId", .blob).notNull().indexed()
                t.column("markdown", .text).notNull()
                t.column("model", .text).notNull()
                t.column("promptVersion", .text).notNull()
                t.column("isCanonical", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
            }
        }

        // v2, v3, ... append below. Never edit a shipped migration.

        /// Fusion failure reason on the session row (SPEC §4.5 failure/retry
        /// semantics). `processing` on its own is ambiguous — it covers both
        /// "still fusing" and "failed, Retry available" — and the reason used
        /// to live only in the History window's memory, so a relaunch turned a
        /// permanently failed session into an eternal spinner. Both columns
        /// are nullable and default to NULL, so existing rows migrate as "no
        /// failure recorded", which is exactly what they mean.
        migrator.registerMigration("v2") { db in
            try db.alter(table: "sessions") { t in
                t.add(column: "fusionErrorMessage", .text)
                t.add(column: "fusionFailedAt", .datetime)
            }
            try db.execute(sql: "UPDATE meta SET schema_version = 2")
        }

        return migrator
    }
}
