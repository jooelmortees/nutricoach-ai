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
    var waterSyncErrorAt: Date? = nil
    var waterEventIds: [String]? = nil

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
            waterTargetMl: 2000,
            waterSyncErrorAt: nil,
            waterEventIds: []
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

    mutating func resetDailyValues(for date: Date) {
        self.date = date
        updatedAt = Date()
        totals = DailyMacroTotals()
        waterMl = 0
        waterSyncErrorAt = nil
        waterEventIds = []
    }
}

enum WidgetSnapshotStore {
    private static let activeUserKey = "widget.activeUserId"
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

    static var activeUserId: UUID? {
        guard let value = UserDefaults(
            suiteName: SharedConfiguration.appGroupIdentifier
        )?.string(forKey: activeUserKey) else {
            return nil
        }
        return UUID(uuidString: value)
    }

    static func setActiveUser(_ userId: UUID) {
        UserDefaults(suiteName: SharedConfiguration.appGroupIdentifier)?
            .set(userId.uuidString, forKey: activeUserKey)
    }

    static func save(_ snapshot: DailyTrackingSnapshot) throws -> Bool {
        guard let url = snapshotURL else {
            throw WidgetSnapshotError.appGroupUnavailable
        }
        var didSave = false
        var coordinationError: NSError?
        var operationError: Error?
        NSFileCoordinator().coordinate(
            writingItemAt: url,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedURL in
            do {
                guard let snapshotUserId = snapshot.userId,
                      activeUserId == snapshotUserId else {
                    return
                }
                var snapshotToSave = snapshot
                if FileManager.default.fileExists(atPath: coordinatedURL.path),
                   let currentSnapshot = try? decodeSnapshot(at: coordinatedURL),
                   currentSnapshot.userId == snapshot.userId {
                    guard currentSnapshot.updatedAt <= snapshot.updatedAt else {
                        return
                    }
                    if let errorAt = currentSnapshot.waterSyncErrorAt,
                       errorAt > snapshot.updatedAt {
                        snapshotToSave.waterSyncErrorAt = errorAt
                    }
                }
                let data = try JSONEncoder().encode(snapshotToSave)
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

    static func addWater(
        amountMl: Int,
        clientEventId: String,
        userId: UUID,
        loggedAt: Date
    ) throws -> Bool {
        try update(userId: userId) { snapshot in
            let calendar = snapshot.calendar
            guard calendar.isDate(loggedAt, inSameDayAs: Date()) else {
                return false
            }
            if !calendar.isDate(snapshot.date, inSameDayAs: loggedAt) {
                snapshot.resetDailyValues(for: loggedAt)
            }
            if snapshot.waterEventIds?.contains(clientEventId) == true {
                snapshot.waterSyncErrorAt = nil
                return true
            }
            let (waterMl, overflow) = snapshot.waterMl.addingReportingOverflow(amountMl)
            guard !overflow else { return false }
            snapshot.waterMl = waterMl
            snapshot.updatedAt = Date()
            snapshot.waterSyncErrorAt = nil
            var eventIds = snapshot.waterEventIds ?? []
            eventIds.append(clientEventId)
            snapshot.waterEventIds = eventIds
            return true
        }
    }

    static func markWaterSyncFailed(userId: UUID) throws -> Bool {
        try update(userId: userId) { snapshot in
            if !snapshot.isForToday {
                snapshot.resetDailyValues(for: Date())
            }
            snapshot.waterSyncErrorAt = Date()
            return true
        }
    }

    static func clear() {
        UserDefaults(suiteName: SharedConfiguration.appGroupIdentifier)?
            .removeObject(forKey: activeUserKey)
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

    private static func update(
        userId: UUID,
        mutation: (inout DailyTrackingSnapshot) -> Bool
    ) throws -> Bool {
        guard let url = snapshotURL else {
            throw WidgetSnapshotError.appGroupUnavailable
        }
        var didSave = false
        var coordinationError: NSError?
        var operationError: Error?
        NSFileCoordinator().coordinate(
            writingItemAt: url,
            options: [],
            error: &coordinationError
        ) { coordinatedURL in
            do {
                guard FileManager.default.fileExists(atPath: coordinatedURL.path) else {
                    return
                }
                var snapshot = try decodeSnapshot(at: coordinatedURL)
                guard activeUserId == userId,
                      snapshot.userId == userId,
                      mutation(&snapshot) else {
                    return
                }
                let data = try JSONEncoder().encode(snapshot)
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
        return didSave
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
