import Foundation
import GRDB

/// SQLite schema of `carcrumb.sqlite`, versioned with GRDB's `DatabaseMigrator`.
///
/// Rules for future changes: never edit a registered migration, append a new one. No
/// `eraseDatabaseOnSchemaChange` (it would silently wipe user history).
///
/// Raw SQL on purpose: the schema is exactly what is written here, independent of GRDB's
/// table-builder defaults, and readable in review.
///
/// Dates are stored the GRDB way (text "YYYY-MM-DD HH:MM:SS.SSS", UTC), which sorts correctly
/// as text, so `ORDER BY parkedAt` / `MAX(parkedAt)` are chronological.
enum StoreSchema {
  static var migrator: DatabaseMigrator {
    var migrator = DatabaseMigrator()

    migrator.registerMigration("v1_trips_parkings") { db in
      // AUTOINCREMENT: ids are never reused, not even after deleting all rows, so a trip id
      // persisted in state.json (or held by an in-flight Core Motion refinement) can never
      // point to a different, newer trip.
      try db.execute(sql: """
        CREATE TABLE trips (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          startedAt DATETIME NOT NULL,
          detectedAt DATETIME NOT NULL,
          endedAt DATETIME,
          status TEXT CHECK (status IN ('confirmed', 'uncertain', 'recovered')),
          distanceMeters DOUBLE CHECK (distanceMeters IS NULL OR distanceMeters >= 0)
        );
        CREATE INDEX trips_on_startedAt ON trips(startedAt);

        CREATE TABLE parkings (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          tripId INTEGER REFERENCES trips(id) ON DELETE SET NULL,
          latitude DOUBLE NOT NULL CHECK (latitude BETWEEN -90 AND 90),
          longitude DOUBLE NOT NULL CHECK (longitude BETWEEN -180 AND 180),
          accuracy DOUBLE NOT NULL,
          confidence TEXT NOT NULL CHECK (confidence IN ('low', 'high')),
          parkedAt DATETIME NOT NULL,
          fixAt DATETIME NOT NULL
        );
        -- One park per trip (ParkingPolicy rule 2).
        CREATE UNIQUE INDEX parkings_on_tripId ON parkings(tripId) WHERE tripId IS NOT NULL;
        CREATE INDEX parkings_on_parkedAt ON parkings(parkedAt);

        -- Defence in depth for "belirsiz yolculuk park yazmaz": even a code path that
        -- bypasses ParkingPolicy cannot attach a park to an uncertain trip.
        CREATE TRIGGER parkings_reject_uncertain_insert BEFORE INSERT ON parkings
        WHEN NEW.tripId IS NOT NULL AND (SELECT status FROM trips WHERE id = NEW.tripId) = 'uncertain'
        BEGIN SELECT RAISE(ABORT, 'parking for uncertain trip'); END;

        CREATE TRIGGER parkings_reject_uncertain_update BEFORE UPDATE OF tripId ON parkings
        WHEN NEW.tripId IS NOT NULL AND (SELECT status FROM trips WHERE id = NEW.tripId) = 'uncertain'
        BEGIN SELECT RAISE(ABORT, 'parking for uncertain trip'); END;
        """)
    }

    return migrator
  }
}
