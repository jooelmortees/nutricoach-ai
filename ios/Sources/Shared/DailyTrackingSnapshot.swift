import Foundation
import OSLog

struct DailyMacroTotals: Codable, Equatable {
    var kcal: Double = 0
    var protein: Double = 0
    var carbs: Double = 0
    var fat: Double = 0
}

struct DailyTrackingSnapshot: Codable, Equatable {
    var userId: UUID?
    var date: Date
    var updatedAt: Date
    var timeZoneIdentifier: String?
    var totals: DailyMacroTotals
    var kcalTarget: Int?
    var proteinTarget: Int?
    var carbsTarget: Int?
    var fatTarget: Int?
    var waterMl: Int
    var waterTargetMl: Int

    static var empty: DailyTrackingSnapshot {
        DailyTrackingSnapshot(
            userId: nil,
            date: Date(),
            updatedAt: Date(),
            timeZoneIdentifier: TimeZone.current.identifier,
            totals: DailyMacroTotals(),
            kcalTarget: nil,
            proteinTarget: nil,
            carbsTarget: nil,
            fatTarget: nil,
            waterMl: 0,
            waterTargetMl: 2000
        )
    }

    var calendar: Calendar {
        var calendar = Calendar.current
        if let timeZoneIdentifier,
           let timeZone = TimeZone(identifier: timeZoneIdentifier) {
            calendar.timeZone = timeZone
        }
        return calendar
    }

    var isForToday: Bool {
        calendar.isDate(date, inSameDayAs: Date())
    }
}

enum WidgetSnapshotStore {
    private static let legacySnapshotKey = "widget.dailyTrackingSnapshot"
    private static let snapshotFileName = "daily-tracking-snapshot.json"
    private static let logger = Logger(
        subsystem: "com.joelmortees.nutricoach",
        category: "WidgetSnapshot"
    )

    static func load() -> DailyTrackingSnapshot? {
        guard let url = snapshotURL else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return loadLegacySnapshot()
        }

        var snapshot: DailyTrackingSnapshot?
        var coordinationError: NSError?
        var operationError: Error?
        NSFileCoordinator().coordinate(
            readingItemAt: url,
            options: [],
            error: &coordinationError
        ) { coordinatedURL in
            do {
                snapshot = try decodeSnapshot(at: coordinatedURL)
            } catch {
                operationError = error
            }
        }
        if let coordinationError {
            log(coordinationError)
        } else {
            log(operationError)
        }
        return snapshot
    }

    static func save(_ snapshot: DailyTrackingSnapshot) throws -> Bool {
        guard let url = snapshotURL else {
            throw WidgetSnapshotError.appGroupUnavailable
        }
        let data = try JSONEncoder().encode(snapshot)
        var didSave = false
        var coordinationError: NSError?
        var operationError: Error?
        NSFileCoordinator().coordinate(
            writingItemAt: url,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedURL in
            do {
                if FileManager.default.fileExists(atPath: coordinatedURL.path),
                   let currentSnapshot = try? decodeSnapshot(at: coordinatedURL),
                   currentSnapshot.updatedAt > snapshot.updatedAt {
                    return
                }
                try data.write(to: coordinatedURL, options: .atomic)
                didSave = true
            } catch {
                operationError = error
            }
        }
        if let coordinationError {
            throw coordinationError
        }
        if let operationError {
            throw operationError
        }
        if didSave {
            UserDefaults(suiteName: SharedConfiguration.appGroupIdentifier)?
                .removeObject(forKey: legacySnapshotKey)
        }
        return didSave
    }

    static func clear() {
        guard let url = snapshotURL else {
            clearLegacySnapshot()
            return
        }
        var coordinationError: NSError?
        var operationError: Error?
        NSFileCoordinator().coordinate(
            writingItemAt: url,
            options: .forDeleting,
            error: &coordinationError
        ) { coordinatedURL in
            guard FileManager.default.fileExists(atPath: coordinatedURL.path) else {
                return
            }
            do {
                try FileManager.default.removeItem(at: coordinatedURL)
            } catch {
                operationError = error
            }
        }
        if let coordinationError {
            log(coordinationError)
        } else {
            log(operationError)
        }
        clearLegacySnapshot()
    }

    private static var snapshotURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedConfiguration.appGroupIdentifier
        )?.appendingPathComponent(snapshotFileName)
    }

    private static func decodeSnapshot(at url: URL) throws -> DailyTrackingSnapshot {
        try JSONDecoder().decode(
            DailyTrackingSnapshot.self,
            from: Data(contentsOf: url)
        )
    }

    private static func loadLegacySnapshot() -> DailyTrackingSnapshot? {
        guard let data = UserDefaults(
            suiteName: SharedConfiguration.appGroupIdentifier
        )?.data(forKey: legacySnapshotKey) else {
            return nil
        }
        do {
            return try JSONDecoder().decode(DailyTrackingSnapshot.self, from: data)
        } catch {
            log(error)
            return nil
        }
    }

    private static func clearLegacySnapshot() {
        UserDefaults(suiteName: SharedConfiguration.appGroupIdentifier)?
            .removeObject(forKey: legacySnapshotKey)
    }

    private static func log(_ error: Error?) {
        guard let error else { return }
        logger.error("Error de snapshot: \(error.localizedDescription, privacy: .public)")
    }
}

enum WidgetSnapshotError: LocalizedError {
    case appGroupUnavailable

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            return "El App Group de NutriCoach no esta disponible"
        }
    }
}
