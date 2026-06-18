// ============================================================
// Hola Mundo mínimo - test empírico de que el entorno compila
// ============================================================

import SwiftUI

@main
struct HolaApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 16) {
                Image(systemName: "leaf.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(.green)
                Text("NutriCoach")
                    .font(.largeTitle)
                    .bold()
                Text("Build OK")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
