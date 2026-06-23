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
    @Published var isSyncing: Bool = false

    private let store = HKHealthStore()

    /// Clave de UserDefaults para evitar sincronizar mas de una vez por ventana
    private static let lastSyncKey = "hk_last_sync_at"

    /// Tipos clave cuya autorizacion comprobamos para considerar "conectado".
    /// Si ninguno esta autorizado, la app no intentara leer HK.
    private static let keyTypes: [HKQuantityTypeIdentifier] = [
        .stepCount, .heartRate, .restingHeartRate, .activeEnergyBurned,
    ]

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
        // NO marcamos isAuthorized=true ciegamente: comprobamos el estado real
        // por tipo. requestAuthorization SIEMPRE resuelve OK aunque el usuario
        // haya denegado todo (es un prompt, no una promesa).
        isAuthorized = Self.checkAuthorizationStatus(store: store)
    }

    /// Comprueba el estado REAL de autorizacion para los tipos clave.
    /// Devuelve true solo si TODOS los tipos clave estan en `.sharingAuthorized`.
    /// Un tipo en `.notDetermined` significa que el usuario aun no ha visto el prompt
    /// o lo ha denegado sin decidir.
    static func checkAuthorizationStatus(store: HKHealthStore) -> Bool {
        for id in keyTypes {
            guard let type = HKQuantityType.quantityType(forIdentifier: id) else { continue }
            let status = store.authorizationStatus(for: type)
            guard status == .sharingAuthorized else { return false }
        }
        return true
    }

    /// Convenience: usa el store interno del singleton.
    func refreshAuthorizationStatus() -> Bool {
        let real = Self.checkAuthorizationStatus(store: store)
        isAuthorized = real
        return real
    }

    /// Asegura que el usuario haya sido preguntado por los permisos de HealthKit.
    /// Si el status es .notDetermined, muestra el dialogo de iOS.
    /// Esto es necesario porque `authorizationStatus(for:)` no refleja cambios
    /// hechos en Ajustes hasta que la app llame explicitamente a
    /// `requestAuthorization(toShare:read:)`.
    func ensureAuthorizationPrompted() async {
        let store = HKHealthStore()
        var needsPrompt = false
        for id in HealthKitManager.keyTypes {
            guard let type = HKQuantityType.quantityType(forIdentifier: id) else { continue }
            if store.authorizationStatus(for: type) == .notDetermined {
                needsPrompt = true
                break
            }
        }
        if needsPrompt {
            do {
                try await store.requestAuthorization(toShare: writeTypes, read: readTypes)
            } catch {
                AppLogger.warning("ensureAuthorizationPrompted fallo: \(error.localizedDescription)")
            }
        }
        isAuthorized = Self.checkAuthorizationStatus(store: store)
    }

    /// Sincroniza los últimos N días de HealthKit a Supabase vía Edge Function.
    /// Captura errores internamente y los publica en `lastError` para que las
    /// vistas no tengan que propagar `try` por encima.
    ///
    /// - Parameters:
    ///   - days: ventana hacia atras a sincronizar.
    ///   - force: si true, ignora `lastSyncAt` y sincroniza siempre. Usar en
    ///     onboarding (primera conexion) y en el boton manual de Settings.
    func syncToBackend(days: Int = 7, force: Bool = false) async {
        // Si ya hay una sincronizacion en curso, no lanzar otra en paralelo
        if isSyncing { return }

        // Si no hay autorizacion real, no intentamos leer HK
        guard isAuthorized else {
            AppLogger.warning("HealthKit sync omitido: sin autorizacion")
            return
        }

        // Throttling: si la ultima sync fue hace <1h y no es forzada, saltar
        if !force, let last = UserDefaults.standard.object(forKey: Self.lastSyncKey) as? Date {
            let elapsed = Date().timeIntervalSince(last)
            if elapsed < 3600 {
                AppLogger.info("HealthKit sync omitido: ultima sync hace \(Int(elapsed))s")
                return
            }
        }

        isSyncing = true
        defer { isSyncing = false }

        do {
            let end = Date()
            let start = Calendar.current.date(byAdding: .day, value: -days, to: end) ?? end

            let metrics = try await collectMetrics(from: start, to: end)

            guard !metrics.isEmpty else {
                AppLogger.info("HealthKit sync: 0 muestras en ventana")
                UserDefaults.standard.set(Date(), forKey: Self.lastSyncKey)
                lastError = nil
                return
            }

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
            AppLogger.info("HealthKit sync OK: \(metrics.count) metricas")
            UserDefaults.standard.set(Date(), forKey: Self.lastSyncKey)
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
        let unit = Self.preferredUnit(for: capturedId)

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
                    HealthMetricPayload(
                        type: typeName,
                        value: sample.quantity.doubleValue(for: unit),
                        unit: unit.unitString,
                        recorded_at: dateFormatter.string(from: sample.startDate)
                    )
                }
                continuation.resume(returning: result)
            }
            store.execute(query)
        }
    }

    /// Unit canónica por identificador. HealthKit no expone `sample.unit` en
    /// `HKQuantitySample`: hay que derivarlo del tipo. Mapeamos los más comunes
    /// a units legibles; el resto cae a `.count()`.
    private static func preferredUnit(for id: HKQuantityTypeIdentifier) -> HKUnit {
        switch id {
        case .stepCount, .flightsClimbed, .appleExerciseTime,
             .appleMoveTime, .appleStandTime:
            return .count()
        case .heartRate, .restingHeartRate, .walkingHeartRateAverage,
             .respiratoryRate:
            return HKUnit.count().unitDivided(by: .minute())
        case .heartRateVariabilitySDNN:
            return .secondUnit(with: .milli)
        case .vo2Max:
            return HKUnit.literUnit(with: .milli).unitDivided(by: .gramUnit(with: .kilo).unitMultiplied(by: .minute()))
        case .activeEnergyBurned, .basalEnergyBurned:
            return .kilocalorie()
        case .distanceWalkingRunning, .distanceCycling:
            return .meter()
        case .bodyMass:
            return .gramUnit(with: .kilo)
        case .bodyFatPercentage, .oxygenSaturation:
            return .percent()
        case .bodyTemperature:
            return .degreeCelsius()
        default:
            return .count()
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
