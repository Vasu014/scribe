import Foundation
import GRDB

/// Schema migrations. `meta.schema_version` is our explicit version, separate
/// from GRDB's own migration bookkeeping — REQUIRED from day one (SPEC §4.6).
/// After day 2 of the build, every schema change lands here as a new migration.
public enum Migrations {

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

        return migrator
    }
}
