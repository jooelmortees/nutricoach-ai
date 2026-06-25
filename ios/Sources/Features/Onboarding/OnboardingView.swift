// ============================================================
// OnboardingView - configuracion inicial al primer login
// ============================================================

import SwiftUI
import HealthKit

struct OnboardingView: View {
    @EnvironmentObject var auth: AuthManager
    @StateObject private var viewModel = OnboardingViewModel()
    @State private var step: Step = .welcome

    enum Step: Int, CaseIterable {
        case welcome
        case profile
        case health
        case goal
        case done
    }

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                // Indicador de progreso
                ProgressView(value: Double(step.rawValue + 1), total: Double(Step.allCases.count))
                    .tint(.green)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)

                // Contenido del paso actual
                Group {
                    switch step {
                    case .welcome: welcomeStep
                    case .profile: profileStep
                    case .health: healthStep
                    case .goal: goalStep
                    case .done: doneStep
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 24)

                // Botones de navegacion
                HStack {
                    if step != .welcome && step != .done {
                        Button("Atrás") {
                            withAnimation { goBack() }
                        }
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if step != .done {
                        Button {
                            withAnimation { goNext() }
                        } label: {
                            HStack {
                                Text(buttonText)
                                Image(systemName: "arrow.right")
                            }
                            .font(.headline)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(.green.gradient, in: Capsule())
                        }
                        .disabled(!canProceed)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
    }

    // MARK: - Pasos

    private var welcomeStep: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "leaf.fill")
                .font(.system(size: 100))
                .foregroundStyle(.green.gradient)
            Text("Bienvenido a NutriCoach")
                .font(.largeTitle).bold()
                .multilineTextAlignment(.center)
            Text("Tu dietista personal con IA potenciado por M3. Vamos a conocerte en 4 pasos rápidos.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
    }

    private var profileStep: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("Cuéntame sobre ti")
                    .font(.title).bold()
                    .padding(.top, 16)
                Text("Esto me ayuda a calcular tu metabolismo basal y darte recomendaciones precisas.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 8)

                FormField(label: "Nombre", text: $viewModel.fullName, placeholder: "Tu nombre")
                FormField(label: "Edad", text: $viewModel.ageString, placeholder: "30", keyboard: .numberPad)
                Picker("Sexo", selection: $viewModel.sex) {
                    Text("Masculino").tag("male")
                    Text("Femenino").tag("female")
                    Text("Otro").tag("other")
                }
                .pickerStyle(.segmented)

                FormField(label: "Altura (cm)", text: $viewModel.heightString, placeholder: "175", keyboard: .numberPad)
                FormField(label: "Peso actual (kg)", text: $viewModel.weightString, placeholder: "70", keyboard: .numberPad)
            }
        }
    }

    private var healthStep: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "heart.text.square.fill")
                .font(.system(size: 80))
                .foregroundStyle(.red.gradient)
            Text("Conecta Apple Health")
                .font(.title).bold()
                .multilineTextAlignment(.center)
            Text("Conecto automaticamente con Apple Health para leer tus pasos, frecuencia cardiaca, sueno y entrenamientos. Es opcional pero muy util para personalizar tus recomendaciones.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
            Button {
                Task { await viewModel.requestHealthKit() }
            } label: {
                HStack {
                    if viewModel.isConnectingHealthKit {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: viewModel.healthKitGranted ? "checkmark.circle.fill" : "heart.fill")
                        Text(viewModel.healthKitGranted ? "Conectado" : "Conectar Apple Health")
                    }
                }
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(viewModel.healthKitGranted ? Color.gray : Color.red, in: Capsule())
            }
            .disabled(viewModel.healthKitGranted || viewModel.isConnectingHealthKit)

            if viewModel.healthKitGranted {
                if HealthKitManager.shared.isSyncing {
                    Text("Leyendo datos de Apple Health...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let msg = viewModel.errorMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .onAppear {
            viewModel.refreshHealthKitStatus()
        }
    }

    private var goalStep: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("¿Cuál es tu objetivo?")
                    .font(.title).bold()
                    .padding(.top, 16)

                VStack(spacing: 12) {
                    GoalCard(
                        icon: "arrow.down.circle.fill",
                        title: "Perder peso",
                        description: "Déficit calórico moderado (~500 kcal/día)",
                        color: .red,
                        isSelected: viewModel.goal == "lose"
                    ) {
                        viewModel.goal = "lose"
                    }
                    GoalCard(
                        icon: "equal.circle.fill",
                        title: "Mantener peso",
                        description: "Aporte calórico = gasto diario",
                        color: .green,
                        isSelected: viewModel.goal == "maintain"
                    ) {
                        viewModel.goal = "maintain"
                    }
                    GoalCard(
                        icon: "arrow.up.circle.fill",
                        title: "Ganar peso/músculo",
                        description: "Superávit calórico (~300 kcal/día)",
                        color: .blue,
                        isSelected: viewModel.goal == "gain"
                    ) {
                        viewModel.goal = "gain"
                    }
                }
                .padding(.horizontal, 8)
            }
        }
    }

    private var doneStep: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 100))
                .foregroundStyle(.green.gradient)
            Text("¡Todo listo!")
                .font(.largeTitle).bold()
            Text("He calculado tu metabolismo basal. Mi objetivo diario recomendado es de \(viewModel.calculatedKcal) kcal.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            Button {
                Task { await viewModel.finish(auth: auth) }
            } label: {
                HStack {
                    if viewModel.isSaving {
                        ProgressView().tint(.white)
                    } else {
                        Text("Empezar").font(.headline)
                        Image(systemName: "arrow.right")
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 32)
                .padding(.vertical, 14)
                .background(.green.gradient, in: Capsule())
            }
            .disabled(viewModel.isSaving)
        }
    }

    // MARK: - Navigation helpers

    private var buttonText: String {
        switch step {
        case .welcome: return "Empezar"
        case .profile: return "Continuar"
        case .health: return "Continuar"
        case .goal: return "Calcular mi objetivo"
        case .done: return ""
        }
    }

    private var canProceed: Bool {
        switch step {
        case .welcome: return true
        case .profile:
            return !viewModel.fullName.isEmpty &&
                   !viewModel.ageString.isEmpty &&
                   !viewModel.heightString.isEmpty &&
                   !viewModel.weightString.isEmpty
        case .health: return true
        case .goal: return !viewModel.goal.isEmpty
        case .done: return true
        }
    }

    private func goNext() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        step = next
    }

    private func goBack() {
        guard let prev = Step(rawValue: step.rawValue - 1) else { return }
        step = prev
    }
}

// MARK: - Helper views

private struct FormField: View {
    let label: String
    @Binding var text: String
    var placeholder: String = ""
    var keyboard: UIKeyboardType = .default

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .keyboardType(keyboard)
                .padding(12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

private struct GoalCard: View {
    let icon: String
    let title: String
    let description: String
    let color: Color
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title)
                    .foregroundStyle(color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? color : .secondary)
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.secondarySystemBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(isSelected ? color : .clear, lineWidth: 2)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

@MainActor
final class OnboardingViewModel: ObservableObject {
    @Published var fullName: String = ""
    @Published var ageString: String = ""
    @Published var sex: String = "male"
    @Published var heightString: String = ""
    @Published var weightString: String = ""
    @Published var goal: String = ""
    @Published var healthKitGranted: Bool = false
    @Published var isConnectingHealthKit: Bool = false
    @Published var isSaving: Bool = false
    @Published var errorMessage: String?

    init() {
        // Reflejar estado real al entrar al view model
        // NOTA: la comprobacion real de permisos de lectura es async
        // (statusForAuthorizationRequest), pero init no puede ser async.
        // Asumimos no autorizado hasta que refreshHealthKitStatusAsync corra.
        // Se invoca en onAppear de la vista.
    }

    /// Comprueba el estado REAL de autorizacion de HealthKit.
    /// Apple no expone si el usuario concedio/denegio read (privacidad):
    /// solo podemos saber si ya se mostro el sheet de permisos.
    /// Devuelve true si el sheet ya se mostro (statusForAuthorizationRequest == .unnecessary).
    func refreshHealthKitStatus() {
        Task {
            let granted = await HealthKitManager.shared.refreshAuthorizationStatusAsync()
            await MainActor.run { self.healthKitGranted = granted }
        }
    }

    /// Mifflin-St Jeor para calcular TMB (Tasa Metabolica Basal)
    /// Hombres: 10*peso + 6.25*altura - 5*edad + 5
    /// Mujeres: 10*peso + 6.25*altura - 5*edad - 161
    var calculatedKcal: Int {
        guard let weight = Double(weightString),
              let height = Double(heightString),
              let age = Double(ageString) else { return 2000 }
        let bmr: Double
        if sex == "male" {
            bmr = 10 * weight + 6.25 * height - 5 * age + 5
        } else {
            bmr = 10 * weight + 6.25 * height - 5 * age - 161
        }
        // Multiplicador de actividad (moderate = 1.55)
        let tdee = bmr * 1.55
        // Ajuste por objetivo
        switch goal {
        case "lose": return Int(tdee - 500)
        case "gain": return Int(tdee + 300)
        default: return Int(tdee)
        }
    }

    func requestHealthKit() async {
        errorMessage = nil
        isConnectingHealthKit = true
        defer { isConnectingHealthKit = false }
        do {
            try await HealthKitManager.shared.requestAuthorization()
            // Tras pedir, refrescar estado real (ahora async)
            let granted = await HealthKitManager.shared.refreshAuthorizationStatusAsync()
            healthKitGranted = granted
            if granted {
                // Sync inicial inmediato: 7 dias hacia atras.
                // force=true para saltarse el throttling de lastSyncAt
                // (es la primera vez que conectamos).
                await HealthKitManager.shared.syncToBackend(days: 7, force: true)
            } else {
                errorMessage = "No se ha concedido acceso a Apple Health. Puedes activarlo mas tarde en Ajustes de iOS > Salud > Datos y acceso > Apps."
            }
        } catch {
            // Si falla, no es bloqueante - el user puede continuar sin HealthKit
            healthKitGranted = false
            errorMessage = "No se pudo conectar HealthKit: \(error.localizedDescription)"
        }
    }

    func finish(auth: AuthManager) async {
        isSaving = true
        defer { isSaving = false }
        do {
            // Calcular año de nacimiento
            var birthDate: String? = nil
            if let age = Int(ageString), age > 0 {
                let year = Calendar.current.component(.year, from: Date()) - age
                birthDate = "\(year)-01-01"
            }

            struct UpdatePayload: Encodable {
                let full_name: String?
                let birth_date: String?
                let sex: String?
                let height_cm: Double?
                let weight_kg: Double?
                let activity_level: String
                let goal: String?
                let daily_kcal_target: Int
                let daily_protein_g: Int
                let daily_carbs_g: Int
                let daily_fat_g: Int
                let onboarded_at: String
            }

            // Macronutrientes: 30% prot, 40% carbs, 30% fat
            let kcal = calculatedKcal
            let protein = Int(Double(kcal) * 0.30 / 4.0)
            let carbs = Int(Double(kcal) * 0.40 / 4.0)
            let fat = Int(Double(kcal) * 0.30 / 9.0)

            let payload = UpdatePayload(
                full_name: fullName.isEmpty ? nil : fullName,
                birth_date: birthDate,
                sex: sex,
                height_cm: Double(heightString),
                weight_kg: Double(weightString),
                activity_level: "moderate",
                goal: goal,
                daily_kcal_target: kcal,
                daily_protein_g: protein,
                daily_carbs_g: carbs,
                daily_fat_g: fat,
                onboarded_at: ISO8601DateFormatter().string(from: Date())
            )

            let userId = try await SupabaseService.shared.client.auth.session.user.id.uuidString
            try await SupabaseService.shared.client
                .from("profiles")
                .update(payload)
                .eq("id", value: userId)
                .execute()

            // Recargar perfil en auth
            await auth.restoreSession()
        } catch {
            errorMessage = "Error guardando perfil: \(error.localizedDescription)"
        }
    }
}