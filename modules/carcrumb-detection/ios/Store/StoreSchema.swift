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

    migrator.registerMigration("v2_trip_points") { db in
      // Trip route (RouteSampling.swift). Raw coordinates: never logged; deleted with the
      // trip (CASCADE) and by "Geçmişi sil" (explicit DELETE + VACUUM + WAL TRUNCATE).
      // Plain rowid (no AUTOINCREMENT): nothing outside this table refers to a point id.
      // `seq` is the route order, assigned by the store per trip (MAX + 1), never by the
      // clock: fix timestamps can jump with the device clock, insertion order cannot.
      // Thinning leaves gaps in `seq`; only its order matters.
      try db.execute(sql: """
        CREATE TABLE trip_points (
          id INTEGER PRIMARY KEY,
          tripId INTEGER NOT NULL REFERENCES trips(id) ON DELETE CASCADE,
          seq INTEGER NOT NULL CHECK (seq >= 0),
          timestamp DATETIME NOT NULL,
          latitude DOUBLE NOT NULL CHECK (latitude BETWEEN -90 AND 90),
          longitude DOUBLE NOT NULL CHECK (longitude BETWEEN -180 AND 180),
          accuracy DOUBLE NOT NULL CHECK (accuracy >= 0)
        );
        -- Serves the route read (WHERE tripId = ? ORDER BY seq), MAX(seq) / COUNT per trip,
        -- and the ON DELETE CASCADE lookup (leading column tripId), and makes the order unique.
        CREATE UNIQUE INDEX trip_points_on_tripId_seq ON trip_points(tripId, seq);
        """)
    }

    return migrator
  }
}
