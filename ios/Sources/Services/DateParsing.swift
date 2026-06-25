// ============================================================
// DateParsing - utilidades para parsear fechas ISO8601 de Supabase
// ============================================================
//
// PostgREST devuelve timestamps como "2026-06-24T22:00:00+00:00" (sin
// fracciones de segundo). ISO8601DateFormatter con .withFractionalSeconds
// SOLO parsea strings que tienen fracciones; si no las tiene, devuelve nil.
// Esto causaba que todas las metricas cayeran a `now` y se asignaran a "hoy".
//
// Este helper prueba varios formatos en orden:
//   1. ISO8601 con fracciones de segundo
//   2. ISO8601 sin fracciones (lo que devuelve PostgREST)
//   3. Fallback con zona Z y espacio como separador (formatos legacy)

import Foundation

enum DateParsing {
    /// Formatter para ISO8601 CON fracciones de segundo
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Formatter para ISO8601 SIN fracciones de segundo (lo que devuelve PostgREST)
    private static let standardFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Parsea un string ISO8601 intentando varios formatos.
    /// Devuelve nil si ninguno funciona.
    static func parse(_ string: String) -> Date? {
        // 1. Probar con fracciones de segundo
        if let date = fractionalFormatter.date(from: string) {
            return date
        }
        // 2. Probar sin fracciones (formato de PostgREST)
        if let date = standardFormatter.date(from: string) {
            return date
        }
        // 3. Fallback: reemplazar espacio por 'T' y aniadir Z si no tiene zona
        //    Formatos como "2026-06-24 22:00:00+00:00" o "2026-06-24 22:00:00"
        let trimmed = String(string.prefix(19)).replacingOccurrences(of: " ", with: "T")
        // Probar con zona Z (UTC)
        if let date = standardFormatter.date(from: trimmed + "Z") {
            return date
        }
        // Probar tal cual con T
        if let date = standardFormatter.date(from: trimmed) {
            return date
        }
        return nil
    }
}