// ============================================================
// HealthKitManager - lectura/escritura de HealthKit
// ============================================================

import Foundation
import HealthKit

@MainActor
final class HealthKitManager: ObservableObject {
    static let shared = HealthKitManager()

    @Published var isAuthorized: Bool = false
    @Published var lastError: String?

    private let store = HKHealthStore()

    /// Tipos que leemos del usuario
    private var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = []
        let quantityTypes: [HKQuantityTypeIdentifier] = [
            .heartRate, .restingHeartRate, .walkingHeartRateAverage,
            .heartRateVariabilitySDNN, .vo2Max,
            .stepCount, .distanceWalkingRunning, .distanceCycling,
            .activeEnergyBurned, .basalEnergyBurned, .flightsClimbed,
            .bodyMass, .bodyFatPercentage, .oxygenSaturation,
            .bodyTemperature, .respiratoryRate,
            .appleExerciseTime, .appleMoveTime, .appleStandTime,
        ]
        for id in quantityTypes {
            if let t = HKQuantityType.quantityType(forIdentifier: id) {
                types.insert(t)
            }
        }
        let categoryTypes: [HKCategoryTypeIdentifier] = [
            .sleepAnalysis, .mindfulSession,
        ]
        for id in categoryTypes {
            if let t = HKCategoryType.categoryType(forIdentifier: id) {
                types.insert(t)
            }
        }
        types.insert(HKObjectType.workoutType())
        return types
    }

    /// Tipos que escribimos (opcional, futuro)
    private var writeTypes: Set<HKSampleType> {
        var types: Set<HKSampleType> = []
        if let dietary = HKQuantityType.quantityType(forIdentifier: .dietaryEnergyConsumed) {
            types.insert(dietary)
        }
        if let protein = HKQuantityType.quantityType(forIdentifier: .dietaryProtein) {
            types.insert(protein)
        }
        if let carbs = HKQuantityType.quantityType(forIdentifier: .dietaryCarbohydrates) {
            types.insert(carbs)
        }
        if let fat = HKQuantityType.quantityType(forIdentifier: .dietaryFatTotal) {
            types.insert(fat)
        }
        if let water = HKQuantityType.quantityType(forIdentifier: .dietaryWater) {
            types.insert(water)
        }
        return types
    }

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthKitError.notAvailable
        }
        try await store.requestAuthorization(toShare: writeTypes, read: readTypes)
        isAuthorized = true
    }

    /// Sincroniza los últimos N días de HealthKit a Supabase vía Edge Function.
    /// Captura errores internamente y los publica en `lastError` para que las
    /// vistas no tengan que propagar `try` por encima.
    func syncToBackend(days: Int = 7) async {
        do {
            let end = Date()
            let start = Calendar.current.date(byAdding: .day, value: -days, to: end) ?? end

            let metrics = try await collectMetrics(from: start, to: end)

            // Enviar al backend
            let url = Config.hkSyncURL
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(try await getAccessToken())", forHTTPHeaderField: "Authorization")
            req.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
            req.httpBody = try JSONEncoder().encode(HealthSyncRequest(metrics: metrics))

            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? "?"
                throw HealthKitError.syncFailed(body)
            }
            AppLogger.info("HealthKit sync OK: \(metrics.count) métricas")
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            AppLogger.warning("HealthKit sync fallo: \(error.localizedDescription)")
        }
    }

    private func getAccessToken() async throws -> String {
        let session = try await SupabaseService.shared.client.auth.session
        return session.accessToken
    }

    private func collectMetrics(from start: Date, to end: Date) async throws -> [HealthMetricPayload] {
        var out: [HealthMetricPayload] = []
        let quantityTypes: [HKQuantityTypeIdentifier] = [
            .heartRate, .restingHeartRate, .vo2Max, .stepCount,
            .activeEnergyBurned, .basalEnergyBurned, .bodyMass,
            .oxygenSaturation, .respiratoryRate,
        ]
        for id in quantityTypes {
            let samples = try await queryQuantity(id: id, from: start, to: end)
            out.append(contentsOf: samples)
        }
        // Sueño
        let sleep = try await querySleep(from: start, to: end)
        out.append(contentsOf: sleep)
        return out
    }

    private func queryQuantity(id: HKQuantityTypeIdentifier, from start: Date, to end: Date) async throws -> [HealthMetricPayload] {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

        let capturedType = type
        let capturedId = id
        let dateFormatter = ISO8601DateFormatter()

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: capturedType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let quantitySamples = samples as? [HKQuantitySample] else {
                    continuation.resume(returning: [])
                    return
                }
                let typeName = capturedId.rawValue.replacingOccurrences(of: "HKQuantityTypeIdentifier", with: "")
                let result: [HealthMetricPayload] = quantitySamples.map { sample in
                    let unit = HKUnit(from: sample.unit)
                    return HealthMetricPayload(
                        type: typeName,
                        value: sample.quantity.doubleValue(for: unit),
                        unit: sample.unit.unitString,
                        recorded_at: dateFormatter.string(from: sample.startDate)
                    )
                }
                continuation.resume(returning: result)
            }
            store.execute(query)
        }
    }

    private func querySleep(from start: Date, to end: Date) async throws -> [HealthMetricPayload] {
        guard let type = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let categorySamples = samples as? [HKCategorySample] else {
                    continuation.resume(returning: [])
                    return
                }
                var total: TimeInterval = 0
                for sample in categorySamples {
                    total += sample.endDate.timeIntervalSince(sample.startDate)
                }
                guard total > 0 else {
                    continuation.resume(returning: [])
                    return
                }
                let recordedAt = ISO8601DateFormatter().string(from: end)
                let payload = HealthMetricPayload(
                    type: "sleep_minutes",
                    value: Double(Int(total / 60)),
                    unit: "minutes",
                    recorded_at: recordedAt
                )
                continuation.resume(returning: [payload])
            }
            store.execute(query)
        }
    }
}

enum HealthKitError: LocalizedError {
    case notAvailable
    case syncFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAvailable: return "HealthKit no disponible en este dispositivo"
        case .syncFailed(let msg): return "Error sincronizando con HealthKit: \(msg)"
        }
    }
}

// MARK: - Payloads Encodable para la Edge Function hk-sync

struct HealthMetricPayload: Encodable {
    let type: String
    let value: Double
    let unit: String
    let recorded_at: String
}

struct HealthSyncRequest: Encodable {
    let metrics: [HealthMetricPayload]
}
