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

    /// Observer queries activas (para re-sync en tiempo real cuando HK tiene datos nuevos)
    private var observerQueries: [HKObserverQuery] = []
    /// Callback que se invoca cuando HealthKit detecta datos nuevos. Lo usa DashboardView.
    var onDataUpdated: (() -> Void)?

    /// Inicia observer queries para los tipos clave. Cuando HealthKit detecta
    /// datos nuevos (pasos, FC, energia), invoca onDataUpdated para que la
    /// vista recargue. No usa background delivery (solo foreground).
    func startObserving() {
        guard observerQueries.isEmpty else { return }  // ya activo
        let typesToObserve: [HKQuantityTypeIdentifier] = [
            .stepCount, .activeEnergyBurned, .heartRate, .restingHeartRate,
        ]
        for id in typesToObserve {
            guard let type = HKQuantityType.quantityType(forIdentifier: id) else { continue }
            let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completionHandler, _ in
                Task { @MainActor [weak self] in
                    self?.onDataUpdated?()
                }
                completionHandler()
            }
            store.execute(query)
            observerQueries.append(query)
        }
        // Sueño es category type, no quantity
        if let sleepType = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) {
            let query = HKObserverQuery(sampleType: sleepType, predicate: nil) { [weak self] _, completionHandler, _ in
                Task { @MainActor [weak self] in
                    self?.onDataUpdated?()
                }
                completionHandler()
            }
            store.execute(query)
            observerQueries.append(query)
        }
        AppLogger.info("HealthKit observer queries iniciadas: \(observerQueries.count)")
    }

    /// Detiene los observer queries
    func stopObserving() {
        for query in observerQueries {
            store.stop(query)
        }
        observerQueries.removeAll()
        AppLogger.info("HealthKit observer queries detenidas")
    }

    /// Clave de UserDefaults para evitar sincronizar mas de una vez por ventana
    private static let lastSyncKey = "hk_last_sync_at"

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
        // Apple, por privacidad, NO expone el estado real de permisos de lectura
        // en `authorizationStatus(for:)` (siempre devuelve .notDetermined para read).
        // Solo podemos saber si ya se ha mostrado el sheet al usuario. Si es asi,
        // asumimos conectado; los queries reales devolveran 0 muestras si deniego.
        isAuthorized = await Self.checkAuthorizationStatus(store: store, readTypes: readTypes)
    }

    /// Comprueba el estado REAL de autorizacion.
    ///
    /// Para tipos de ESCRITURA usamos `authorizationStatus(for:)` (refleja el estado
    /// real: .sharingAuthorized / .sharingDenied / .notDetermined).
    ///
    /// Para tipos de LECTURA Apple oculta el estado real por privacidad: devuelve
    /// siempre .notDetermined. En su lugar usamos `statusForAuthorizationRequest`,
    /// que devuelve:
    ///   - .shouldRequest: el sheet se mostraria si llamamos a requestAuthorization
    ///     (es decir, el usuario aun no ha sido preguntado o revoco todo).
    ///   - .unnecessary: ya se ha preguntado (no se volvera a mostrar el sheet).
    ///     Asumimos conectado; los queries devolveran 0 si el usuario denego.
    ///   - .unknown: error.
    ///
    /// Devuelve true solo si los tipos de escritura clave estan autorizados y
    /// los tipos de lectura ya han sido preguntados.
    static func checkAuthorizationStatus(store: HKHealthStore, readTypes: Set<HKObjectType>? = nil) async -> Bool {
        // Escritura: estado real reflejado por authorizationStatus(for:).
        // No tenemos tipos clave de escritura obligatorios (todos opcionales),
        // asi que no bloqueamos por write aqui.

        // Lectura: usar statusForAuthorizationRequest (iOS 12+).
        // Si el caller pasa readTypes, los usamos; si no, usamos un conjunto
        // minimo representativo.
        let types = readTypes ?? Self.defaultReadTypes
        guard !types.isEmpty else { return false }

        do {
            let status = try await store.statusForAuthorizationRequest(toShare: [], read: types)
            return status == .unnecessary
        } catch {
            AppLogger.warning("checkAuthorizationStatus: statusForAuthorizationRequest fallo: \(error.localizedDescription)")
            return false
        }
    }

    /// Conjunto minimo de tipos de lectura para comprobar si se ha preguntado.
    /// Si statusForAuthorizationRequest devuelve .unnecessary para estos,
    /// asumimos que el usuario ya ha visto el sheet de permisos.
    private static let defaultReadTypes: Set<HKObjectType> = {
        var types: Set<HKObjectType> = []
        let keyReadTypes: [HKQuantityTypeIdentifier] = [
            .stepCount, .heartRate, .activeEnergyBurned,
        ]
        for id in keyReadTypes {
            if let t = HKQuantityType.quantityType(forIdentifier: id) {
                types.insert(t)
            }
        }
        return types
    }()

    /// Version async (recomendada). Comprueba write + read correctamente.
    func refreshAuthorizationStatusAsync() async -> Bool {
        let real = await Self.checkAuthorizationStatus(store: store, readTypes: readTypes)
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
        // Comprobamos si ya se ha preguntado usando statusForAuthorizationRequest
        // (authorizationStatus(for:) no sirve para read: siempre .notDetermined).
        let types = readTypes
        var needsPrompt = false
        do {
            let status = try await store.statusForAuthorizationRequest(toShare: [], read: types)
            needsPrompt = (status == .shouldRequest)
        } catch {
            AppLogger.warning("ensureAuthorizationPrompted: no se pudo comprobar status: \(error.localizedDescription)")
            needsPrompt = true
        }
        if needsPrompt {
            do {
                try await store.requestAuthorization(toShare: writeTypes, read: readTypes)
            } catch {
                AppLogger.warning("ensureAuthorizationPrompted fallo: \(error.localizedDescription)")
            }
        }
        isAuthorized = await Self.checkAuthorizationStatus(store: store, readTypes: readTypes)
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
        AppLogger.info("syncToBackend: inicio (days=\(days), force=\(force), isSyncing=\(isSyncing), isAuthorized=\(isAuthorized))")

        // Si ya hay una sincronizacion en curso, no lanzar otra en paralelo
        if isSyncing {
            AppLogger.info("syncToBackend: omitido, ya hay sync en curso")
            return
        }

        // Si no hay autorizacion real, re-comprobar y si sigue sin haber, salir
        if !isAuthorized {
            let rechecked = await Self.checkAuthorizationStatus(store: store, readTypes: readTypes)
            isAuthorized = rechecked
            if !rechecked {
                AppLogger.warning("syncToBackend: omitido, sin autorizacion (re-checked: \(rechecked))")
                return
            }
        }

        // Throttling: si la ultima sync fue hace <1h y no es forzada, saltar
        if !force, let last = UserDefaults.standard.object(forKey: Self.lastSyncKey) as? Date {
            let elapsed = Date().timeIntervalSince(last)
            if elapsed < 3600 {
                AppLogger.info("syncToBackend: omitido por throttle, ultima sync hace \(Int(elapsed))s")
                return
            }
        }

        isSyncing = true
        defer { isSyncing = false }

        // Limpiar errores previos al iniciar una sync nueva
        lastError = nil

        do {            let end = Date()
            let start = Calendar.current.date(byAdding: .day, value: -days, to: end) ?? end

            let metrics = try await collectMetrics(from: start, to: end)
            AppLogger.info("syncToBackend: \(metrics.count) metricas recogidas")

            guard !metrics.isEmpty else {
                AppLogger.info("syncToBackend: 0 muestras en ventana")
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
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                AppLogger.warning("syncToBackend: error HTTP \(code): \(body)")
                throw HealthKitError.syncFailed(body)
            }
            AppLogger.info("syncToBackend: OK \(metrics.count) metricas enviadas")
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

    /// Recoge metricas agregadas por dia (un valor por tipo por dia).
    /// Evita enviar miles de muestras raw (heart rate se muestrea cada 5-10s)
    /// que saturan el isolate de Deno (limite 2s CPU / 250MB RAM -> 546).
    ///
    /// Tipos acumulables (suma del dia): steps, active_energy, basal_energy,
    /// distance, flights_climbed, exercise_time, move_time, stand_time.
    /// Tipos instantaneos (ultimo valor del dia): heart_rate, resting_heart_rate,
    /// vo2max, body_weight, body_fat, oxygen_saturation, respiratory_rate.
    private func collectMetrics(from start: Date, to end: Date) async throws -> [HealthMetricPayload] {
        var out: [HealthMetricPayload] = []

        // Tipos acumulables: suma del dia
        let cumulativeTypes: [HKQuantityTypeIdentifier] = [
            .stepCount, .activeEnergyBurned, .basalEnergyBurned,
            .distanceWalkingRunning, .flightsClimbed,
            .appleExerciseTime, .appleMoveTime, .appleStandTime,
        ]
        for id in cumulativeTypes {
            do {
                let samples = try await queryAggregatedByDay(id: id, from: start, to: end, strategy: .sum)
                out.append(contentsOf: samples)
            } catch {
                // No todos los tipos estan disponibles en todos los dispositivos.
                // Si uno falla (ej: appleExerciseTime sin Watch), continuamos con los demas.
                AppLogger.info("collectMetrics: tipo \(id.rawValue) omitido: \(error.localizedDescription)")
            }
        }

        // Tipos instantaneos: ultimo valor del dia
        let instantTypes: [HKQuantityTypeIdentifier] = [
            .heartRate, .restingHeartRate, .vo2Max, .bodyMass,
            .bodyFatPercentage, .oxygenSaturation, .respiratoryRate,
        ]
        for id in instantTypes {
            do {
                let samples = try await queryAggregatedByDay(id: id, from: start, to: end, strategy: .last)
                out.append(contentsOf: samples)
            } catch {
                AppLogger.info("collectMetrics: tipo \(id.rawValue) omitido: \(error.localizedDescription)")
            }
        }

        // Sueño (agrega por dia, igual que los demas)
        do {
            let sleep = try await querySleep(from: start, to: end)
            out.append(contentsOf: sleep)
        } catch {
            AppLogger.info("collectMetrics: sueno omitido: \(error.localizedDescription)")
        }
        return out
    }

    /// Estrategia de agregacion por dia
    private enum AggregationStrategy {
        case sum   // steps, kcal, distancia
        case last  // FC, peso, SpO2 (ultimo valor del dia)
    }

    // MARK: - Lectura en vivo para Dashboard (sin pasar por Supabase)

    /// Pasos de hoy en vivo (HKStatisticsQuery.cumulativeSum).
    /// Evita el lag de red: el Dashboard lee directo de HealthKit en vez de
    /// esperar a la sync periodica al backend.
    func readTodaySteps() async throws -> Double? {
        try await readTodayValue(id: .stepCount, strategy: .sum)
    }

    /// Calorias activas de hoy en vivo.
    func readTodayActiveEnergy() async throws -> Double? {
        try await readTodayValue(id: .activeEnergyBurned, strategy: .sum)
    }

    /// Lee la ultima noche en una ventana estable de mediodia a mediodia.
    /// Esto evita que abrir el Dashboard por la tarde recorte el inicio del sueno.
    func querySleepForLastNight(referenceDate: Date = Date()) async throws -> Double {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: referenceDate)
        guard let todayNoon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: today),
              let previousNoon = calendar.date(byAdding: .day, value: -1, to: todayNoon) else {
            return 0
        }
        let windowEnd = min(referenceDate, todayNoon)
        return Double(try await querySleepMinutes(from: previousNoon, to: windowEnd))
    }

    private func querySleepMinutes(from start: Date, to end: Date) async throws -> Int {
        guard end > start else { return 0 }
        guard let type = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else { return 0 }

        // Sin strictStartDate: HealthKit devuelve tambien las fases que solapan
        // el inicio de la ventana. Despues las recortamos exactamente al rango.
        let dateRangePredicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let asleepPredicate = HKCategoryValueSleepAnalysis.predicateForSamples(equalTo: HKCategoryValueSleepAnalysis.allAsleepValues)
        let compoundPredicate = NSCompoundPredicate(andPredicateWithSubpredicates: [dateRangePredicate, asleepPredicate])

        let samples: [HKCategorySample] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: compoundPredicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error = error {
                    let nsError = error as NSError
                    if nsError.domain == HKError.errorDomain,
                       nsError.code == HKError.Code.errorNoData.rawValue {
                        continuation.resume(returning: [])
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                continuation.resume(returning: (samples as? [HKCategorySample]) ?? [])
            }
            store.execute(query)
        }

        let intervals = samples.compactMap { sample -> DateInterval? in
            let clippedStart = max(sample.startDate, start)
            let clippedEnd = min(sample.endDate, end)
            guard clippedEnd > clippedStart else { return nil }
            return DateInterval(start: clippedStart, end: clippedEnd)
        }
        .sorted { $0.start < $1.start }

        var merged: [DateInterval] = []
        for interval in intervals {
            guard let last = merged.last else {
                merged.append(interval)
                continue
            }
            if interval.start <= last.end {
                merged[merged.count - 1] = DateInterval(
                    start: last.start,
                    end: max(last.end, interval.end)
                )
            } else {
                merged.append(interval)
            }
        }

        let seconds = merged.reduce(0.0) { $0 + $1.duration }
        return Int((seconds / 60).rounded())
    }

    /// Lee pasos Y calorias activas de los ultimos 7 dias directamente de HealthKit.
    /// Devuelve dos arrays de 7 elementos (index 0 = hace 6 dias, index 6 = hoy).
    /// Usa HKStatisticsCollectionQuery para obtener un valor agregado por dia
    /// en una sola query (mas eficiente que 7 queries separadas).
    /// Deduplica fuentes (iPhone + Apple Watch) automaticamente.
    func readWeeklyStepsAndEnergy() async throws -> (steps: [Double], energy: [Double]) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let weekAgo = calendar.date(byAdding: .day, value: -6, to: today) else {
            return (Array(repeating: 0, count: 7), Array(repeating: 0, count: 7))
        }
        let interval = DateComponents(day: 1)

        let steps = try await fetchCollection(
            id: .stepCount,
            unit: .count(),
            from: weekAgo,
            to: today,
            interval: interval,
            options: .cumulativeSum
        )
        let energy = try await fetchCollection(
            id: .activeEnergyBurned,
            unit: .kilocalorie(),
            from: weekAgo,
            to: today,
            interval: interval,
            options: .cumulativeSum
        )

        return (steps, energy)
    }

    /// Helper: ejecuta HKStatisticsCollectionQuery y devuelve un array de 7
    /// valores (index 0 = hace 6 dias, index 6 = hoy).
    private func fetchCollection(
        id: HKQuantityTypeIdentifier,
        unit: HKUnit,
        from start: Date,
        to end: Date,
        interval: DateComponents,
        options: HKStatisticsOptions
    ) async throws -> [Double] {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else {
            return Array(repeating: 0, count: 7)
        }

        let collection: HKStatisticsCollection? = try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: nil,
                options: options,
                anchorDate: start,
                intervalComponents: interval
            )
            query.initialResultsHandler = { _, collection, error in
                if let error = error {
                    let nsError = error as NSError
                    if nsError.domain == HKError.errorDomain,
                       nsError.code == HKError.Code.errorNoData.rawValue {
                        continuation.resume(returning: nil)
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                continuation.resume(returning: collection)
            }
            store.execute(query)
        }

        guard let collection else { return Array(repeating: 0, count: 7) }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var values = Array(repeating: 0.0, count: 7)

        // Iterar los 7 dias. Para cada dia, obtenemos el statistics y su suma.
        for dayOffset in 0..<7 {
            let day = calendar.date(byAdding: .day, value: -(6 - dayOffset), to: today) ?? today
            let stats = collection.statistics(for: day)
            let quantity = stats?.sumQuantity()
            values[dayOffset] = quantity?.doubleValue(for: unit) ?? 0
        }

        return values
    }

    /// FC reposo de hoy (ultimo valor disponible).
    func readTodayRestingHeartRate() async throws -> Double? {
        try await readTodayValue(id: .restingHeartRate, strategy: .last)
    }

    /// Helper privado: lee el valor agregado de hoy directamente de HealthKit.
    /// Reutiliza queryAggregatedByDay con ventana [startOfDay, now].
    private func readTodayValue(
        id: HKQuantityTypeIdentifier,
        strategy: AggregationStrategy
    ) async throws -> Double? {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let end = Date()
        let samples = try await queryAggregatedByDay(id: id, from: start, to: end, strategy: strategy)
        return samples.first?.value
    }

    /// Mapeo de HKQuantityTypeIdentifier a nombres snake_case consistentes
    /// con la migracion 0001_init.sql (heart_rate, resting_heart_rate, steps, etc.).
    private static func metricName(for id: HKQuantityTypeIdentifier) -> String {
        switch id {
        case .stepCount: return "steps"
        case .heartRate: return "heart_rate"
        case .restingHeartRate: return "resting_heart_rate"
        case .walkingHeartRateAverage: return "walking_heart_rate_avg"
        case .heartRateVariabilitySDNN: return "hrv_sdnn"
        case .vo2Max: return "vo2max"
        case .distanceWalkingRunning: return "distance_walking_running"
        case .distanceCycling: return "distance_cycling"
        case .activeEnergyBurned: return "active_energy"
        case .basalEnergyBurned: return "basal_energy"
        case .flightsClimbed: return "flights_climbed"
        case .bodyMass: return "body_weight"
        case .bodyFatPercentage: return "body_fat"
        case .oxygenSaturation: return "oxygen_saturation"
        case .bodyTemperature: return "body_temperature"
        case .respiratoryRate: return "respiratory_rate"
        case .appleExerciseTime: return "exercise_time"
        case .appleMoveTime: return "move_time"
        case .appleStandTime: return "stand_time"
        default: return id.rawValue.replacingOccurrences(of: "HKQuantityTypeIdentifier", with: "").lowercased()
        }
    }

    /// Query por dia usando HKStatisticsQuery para acumulables (deduplica fuentes:
    /// iPhone + Apple Watch registran los mismos pasos; HKStatisticsQuery.cumulativeSum
    /// los suma sin duplicar, a diferencia de HKSampleQuery + suma manual).
    ///
    /// Para instantaneos (FC, peso) usa HKSampleQuery con sort desc + limit 1
    /// (ultimo valor del dia). No hay duplicacion problematica en instantaneos.
    private func queryAggregatedByDay(
        id: HKQuantityTypeIdentifier,
        from start: Date,
        to end: Date,
        strategy: AggregationStrategy
    ) async throws -> [HealthMetricPayload] {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return [] }
        let unit = Self.preferredUnit(for: id)
        let metricName = Self.metricName(for: id)
        let calendar = Calendar.current

        var current = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: end)
        var results: [HealthMetricPayload] = []

        while current <= endDay {
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: current) ?? current
            let predicate = HKQuery.predicateForSamples(withStart: current, end: dayEnd, options: .strictStartDate)

            let value: Double? = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Double?, Error>) in
                switch strategy {
                case .sum:
                    // HKStatisticsQuery.cumulativeSum deduplica fuentes (iPhone+Watch)
                    let query = HKStatisticsQuery(
                        quantityType: type,
                        quantitySamplePredicate: predicate,
                        options: .cumulativeSum
                    ) { _, stats, error in
                        // errorNoData = "No data available for the specified predicate"
                        // No es un error real, significa que no hay datos para ese dia.
                        // Lo tratamos como nil (sin datos) siguiendo el patron canónico
                        // de react-native-healthkit, tryVital, PhoneClaw, flutter_health_fit.
                        if let error = error {
                            let nsError = error as NSError
                            if nsError.domain == HKError.errorDomain,
                               nsError.code == HKError.Code.errorNoData.rawValue {
                                continuation.resume(returning: nil)
                            } else {
                                continuation.resume(throwing: error)
                            }
                            return
                        }
                        continuation.resume(returning: stats?.sumQuantity()?.doubleValue(for: unit))
                    }
                    store.execute(query)
                case .last:
                    // Ultimo valor del dia: HKSampleQuery sort desc + limit 1
                    let query = HKSampleQuery(
                        sampleType: type,
                        predicate: predicate,
                        limit: 1,
                        sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
                    ) { _, samples, error in
                        // Mismo tratamiento para errorNoData
                        if let error = error {
                            let nsError = error as NSError
                            if nsError.domain == HKError.errorDomain,
                               nsError.code == HKError.Code.errorNoData.rawValue {
                                continuation.resume(returning: nil)
                            } else {
                                continuation.resume(throwing: error)
                            }
                            return
                        }
                        let last = (samples as? [HKQuantitySample])?.first
                        continuation.resume(returning: last?.quantity.doubleValue(for: unit))
                    }
                    store.execute(query)
                }
            }

            if let value = value {
                let recordedAt = ISO8601DateFormatter().string(from: current)
                results.append(HealthMetricPayload(
                    type: metricName,
                    value: value,
                    unit: unit.unitString,
                    recorded_at: recordedAt
                ))
            }

            current = dayEnd
        }

        return results
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
        let calendar = Calendar.current
        var current = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: end)
        var results: [HealthMetricPayload] = []

        while current <= endDay {
            guard let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: current),
                  let previousNoon = calendar.date(byAdding: .day, value: -1, to: noon) else {
                break
            }
            let windowEnd = current == endDay ? min(end, noon) : noon
            let minutes = try await querySleepMinutes(from: previousNoon, to: windowEnd)
            if minutes > 0 {
                let recordedAt = ISO8601DateFormatter().string(from: current)
                results.append(HealthMetricPayload(
                    type: "sleep_minutes",
                    value: Double(minutes),
                    unit: "minutes",
                    recorded_at: recordedAt
                ))
            }
            current = calendar.date(byAdding: .day, value: 1, to: current) ?? endDay.addingTimeInterval(1)
        }
        return results
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
