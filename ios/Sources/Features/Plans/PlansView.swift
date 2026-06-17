// ============================================================
// PlansView - planes de dieta (fase 3, placeholder)
// ============================================================

import SwiftUI

struct PlansView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "list.bullet.rectangle.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(.green.gradient)
                Text("Planes de dieta")
                    .font(.largeTitle)
                    .bold()
                Text("Pídele a tu agente un plan semanal desde el chat. Llegará aquí.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Label("Disponible en fase 3", systemImage: "hammer.fill")
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.orange.opacity(0.2), in: Capsule())
                    .foregroundStyle(.orange)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Planes")
        }
    }
}
