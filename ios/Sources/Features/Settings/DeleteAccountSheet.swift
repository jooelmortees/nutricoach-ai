// ============================================================
// DeleteAccountSheet - doble confirmacion para eliminar cuenta
// El usuario debe escribir ELIMINAR para poder confirmar.
// ============================================================

import SwiftUI

struct DeleteAccountSheet: View {
    @Binding var isPresented: Bool
    @Binding var isDeleting: Bool
    @Binding var errorMessage: String?
    let onConfirm: () -> Void

    @State private var confirmationText: String = ""
    @FocusState private var isFocused: Bool

    private let requiredText = "ELIMINAR"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Icono de advertencia
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.red)
                        .padding(.top, 20)

                    Text("Eliminar cuenta permanentemente")
                        .font(.title3.bold())
                        .multilineTextAlignment(.center)

                    // Lista de lo que se borrara
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Se borrará TODO lo siguiente:")
                            .font(.subheadline.weight(.semibold))

                        DeleteItemRow(icon: "person.crop.circle.badge.minus", text: "Tu cuenta de usuario")
                        DeleteItemRow(icon: "fork.knife", text: "Todas tus comidas registradas")
                        DeleteItemRow(icon: "bubble.left.and.bubble.right", text: "Todas tus conversaciones y mensajes")
                        DeleteItemRow(icon: "heart.text.square", text: "Tus métricas de salud sincronizadas")
                        DeleteItemRow(icon: "brain", text: "Tus preferencias y datos guardados")
                        DeleteItemRow(icon: "photo.on.rectangle", text: "Tus fotos de comidas en Storage")
                        DeleteItemRow(icon: "list.clipboard", text: "Tus planes de comida y recetas")
                    }
                    .padding()
                    .background(Color.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.red.opacity(0.2), lineWidth: 1)
                    )
                    .padding(.horizontal)

                    Text("Esta acción es **irreversible**. No podrás recuperar tus datos.")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    // Campo de confirmacion: escribir ELIMINAR
                    VStack(spacing: 8) {
                        Text("Para confirmar, escribe **\(requiredText)**:")
                            .font(.subheadline)
                        TextField(requiredText, text: $confirmationText)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.characters)
                            .focused($isFocused)
                            .multilineTextAlignment(.center)
                            .font(.body.weight(.semibold))
                            .padding(.horizontal, 40)
                    }
                    .padding(.horizontal)

                    if let err = errorMessage {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal)
                    }

                    // Boton de confirmacion (solo habilitado si escribe ELIMINAR)
                    Button(role: .destructive) {
                        onConfirm()
                    } label: {
                        HStack {
                            if isDeleting {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: "trash.fill")
                            }
                            Text(isDeleting ? "Eliminando..." : "Eliminar mi cuenta")
                        }
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            confirmationText == requiredText
                                ? Color.red
                                : Color.red.opacity(0.3)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(confirmationText != requiredText || isDeleting)
                    .padding(.horizontal)

                    Button("Cancelar") {
                        isPresented = false
                    }
                    .font(.subheadline)
                    .padding(.bottom, 20)
                }
            }
            .navigationTitle("Eliminar cuenta")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") {
                        isPresented = false
                    }
                }
            }
        }
        .interactiveDismissDisabled(isDeleting)
    }
}

private struct DeleteItemRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundStyle(.red)
            Text(text)
                .font(.subheadline)
            Spacer()
            Image(systemName: "checkmark")
                .font(.caption2)
                .foregroundStyle(.red.opacity(0.6))
        }
    }
}