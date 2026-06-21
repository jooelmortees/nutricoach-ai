// ============================================================
// MessageRow - celda individual del chat
// ============================================================

import SwiftUI

struct MessageRow: View {
    let message: ChatMessage
    let onImageTap: (String) -> Void
    let onSaveMeal: (PendingMeal) -> Void

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .user {
                Spacer(minLength: 60)
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
                // Thinking oculto en pantalla (plegable tras "Ver razonamiento")
                if let thinking = message.thinking, !thinking.isEmpty {
                    ThinkingBubble(text: thinking)
                }
                // Imagenes adjuntas
                if let attachments = message.attachments, !attachments.isEmpty {
                    AttachmentsGrid(attachments: attachments, onImageTap: onImageTap)
                }
                // Burbuja de texto con markdown + deteccion de macros
                TextBubble(
                    text: message.content,
                    role: message.role,
                    isStreaming: message.isStreaming,
                    onSaveMeal: onSaveMeal
                )
            }

            if message.role == .assistant {
                Spacer(minLength: 60)
            }
        }
    }
}

// MARK: - Macros detectadas

struct PendingMeal: Codable, Equatable {
    let description: String
    let meal_type: String?
    let kcal: Double?
    let protein_g: Double?
    let carbs_g: Double?
    let fat_g: Double?
    let confidence: Double?

    /// Busca un JSON de macros en el texto y lo extrae.
    /// Formato esperado: `{"description": "...", "kcal": N, "protein_g": N, ...}`
    static func extract(from text: String) -> (cleaned: String, macros: PendingMeal?)? {
        guard let jsonStart = text.firstIndex(of: "{") else { return nil }
        // Buscar el final del JSON (matching braces basico)
        var depth = 0
        var inString = false
        var escape = false
        var jsonEnd: String.Index? = nil
        for i in text.indices[text.index(jsonStart, offsetBy: 0)...] {
            let c = text[i]
            if escape { escape = false; continue }
            if c == "\\" && inString { escape = true; continue }
            if c == "\"" { inString.toggle(); continue }
            if inString { continue }
            if c == "{" { depth += 1 }
            if c == "}" { depth -= 1; if depth == 0 { jsonEnd = i; break } }
        }
        guard let jsonEnd else { return nil }
        let jsonStr = String(text[jsonStart...jsonEnd])
        // El texto a quitar incluye el JSON + espacios/newlines alrededor
        let before = text[text.startIndex..<jsonStart]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let after = text[text.index(after: jsonEnd)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = [before, after].filter { !$0.isEmpty }.joined(separator: "\n\n")

        // Parsear JSON
        guard let data = jsonStr.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let meal = PendingMeal(
            description: (parsed["description"] as? String) ?? "Comida",
            meal_type: parsed["meal_type"] as? String,
            kcal: (parsed["kcal"] as? NSNumber)?.doubleValue,
            protein_g: (parsed["protein_g"] as? NSNumber)?.doubleValue,
            carbs_g: (parsed["carbs_g"] as? NSNumber)?.doubleValue,
            fat_g: (parsed["fat_g"] as? NSNumber)?.doubleValue,
            confidence: (parsed["confidence"] as? NSNumber)?.doubleValue
        )
        return (cleaned, meal)
    }
}

// MARK: - Grid de imagenes adjuntas

struct AttachmentsGrid: View {
    let attachments: [MessageAttachment]
    let onImageTap: (String) -> Void

    private let thumbSize: CGFloat = 70
    private let cornerRadius: CGFloat = 8

    var body: some View {
        let images = attachments.filter { $0.type == "image" }
        if images.isEmpty {
            EmptyView()
        } else if images.count == 1 {
            singleImage(images[0])
        } else {
            multipleImages(images)
        }
    }

    @ViewBuilder
    private func singleImage(_ att: MessageAttachment) -> some View {
        AsyncImage(url: URL(string: att.url)) { phase in
            switch phase {
            case .empty:
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color(.tertiarySystemBackground))
                    .frame(width: thumbSize * 1.8, height: thumbSize * 1.8)
                    .overlay(ProgressView())
            case .success(let image):
                image.resizable().scaledToFill()
                    .frame(width: thumbSize * 1.8, height: thumbSize * 1.8)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                    .onTapGesture { onImageTap(att.url) }
            case .failure:
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color(.tertiarySystemBackground))
                    .frame(width: thumbSize * 1.8, height: thumbSize * 1.8)
                    .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
            @unknown default:
                EmptyView()
            }
        }
    }

    private func multipleImages(_ images: [MessageAttachment]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHGrid(rows: [GridItem(.fixed(thumbSize))], spacing: 4) {
                ForEach(images, id: \.url) { att in
                    AsyncImage(url: URL(string: att.url)) { phase in
                        switch phase {
                        case .empty:
                            RoundedRectangle(cornerRadius: cornerRadius)
                                .fill(Color(.tertiarySystemBackground))
                                .frame(width: thumbSize, height: thumbSize)
                                .overlay(ProgressView().scaleEffect(0.7))
                        case .success(let image):
                            image.resizable().scaledToFill()
                                .frame(width: thumbSize, height: thumbSize)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                                .onTapGesture { onImageTap(att.url) }
                        case .failure:
                            RoundedRectangle(cornerRadius: cornerRadius)
                                .fill(Color(.tertiarySystemBackground))
                                .frame(width: thumbSize, height: thumbSize)
                                .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                        @unknown default:
                            EmptyView()
                        }
                    }
                }
            }
        }
        .frame(height: thumbSize)
    }
}

// MARK: - Burbuja de texto (con markdown + deteccion de macros)

private struct TextBubble: View {
    let text: String
    let role: ChatMessage.Role
    let isStreaming: Bool
    let onSaveMeal: (PendingMeal) -> Void

    @State private var dots: Int = 1
    private let timer = Timer.publish(every: 0.45, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Si esta vacio y esta streaming, mostrar 3 circulos
            if text.isEmpty && isStreaming {
                HStack(spacing: 3) {
                    ForEach(0..<3) { i in
                        Circle()
                            .fill(.secondary)
                            .frame(width: 7, height: 7)
                            .opacity(i < dots ? 1.0 : 0.3)
                    }
                }
                .frame(width: 36, height: 22, alignment: .center)
                .onReceive(timer) { _ in
                    dots = (dots % 3) + 1
                }
            } else if let extracted = PendingMeal.extract(from: text), let macros = extracted.macros {
                // Caso 1: se detectaron macros en el texto
                VStack(alignment: .leading, spacing: 8) {
                    // Texto sin el JSON (markdown renderizado)
                    if !extracted.cleaned.isEmpty {
                        MarkdownText(text: extracted.cleaned)
                    }
                    // Tarjeta de macros
                    MacrosCard(meal: macros, onSave: {
                        onSaveMeal(macros)
                    })
                }
            } else {
                // Caso 2: texto normal (markdown renderizado)
                MarkdownText(text: text)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(bg, in: RoundedRectangle(cornerRadius: 16))
        .foregroundStyle(fg)
        .frame(maxWidth: .infinity, alignment: role == .user ? .trailing : .leading)
    }

    private var bg: Color {
        role == .user ? .green : Color(.secondarySystemBackground)
    }

    private var fg: Color {
        role == .user ? .white : .primary
    }
}

// MARK: - Texto con markdown (AttributedString)

private struct MarkdownText: View {
    let text: String

    var body: some View {
        // Intentar parsear como markdown. Si falla, mostrar el texto plano.
        if let attributed = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                allowsExtendedAttributes: false,
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            Text(attributed)
                .textSelection(.enabled)
        } else {
            Text(text)
                .textSelection(.enabled)
        }
    }
}

// MARK: - Tarjeta de macros (visible cuando se detecta JSON)

private struct MacrosCard: View {
    let meal: PendingMeal
    let onSave: () -> Void
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "fork.knife.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
                Text(meal.description)
                    .font(.headline)
                    .lineLimit(2)
            }

            HStack(spacing: 12) {
                if let kcal = meal.kcal {
                    MacroPill(label: "kcal", value: "\(Int(kcal))", color: .orange)
                }
                if let p = meal.protein_g {
                    MacroPill(label: "P", value: "\(Int(p))g", color: .red)
                }
                if let c = meal.carbs_g {
                    MacroPill(label: "C", value: "\(Int(c))g", color: .blue)
                }
                if let f = meal.fat_g {
                    MacroPill(label: "G", value: "\(Int(f))g", color: .yellow)
                }
            }

            Button(action: onSave) {
                HStack {
                    Image(systemName: saved ? "checkmark.circle.fill" : "plus.circle.fill")
                    Text(saved ? "Guardado en tu día" : "Guardar en mi día")
                }
                .font(.subheadline)
                .fontWeight(.medium)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(saved ? Color.green.opacity(0.2) : Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(.green)
            }
            .disabled(saved)
            .onChange(of: saved) { _, newValue in
                if newValue {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        saved = false
                    }
                }
            }
        }
        .padding(12)
        .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.green.opacity(0.2), lineWidth: 1)
        )
    }
}

private struct MacroPill: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.headline)
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Thinking bubble (plegable, oculto por defecto)

private struct ThinkingBubble: View {
    let text: String
    @State private var isExpanded: Bool = false

    var body: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isExpanded ? "brain.head.profile" : "lightbulb")
                    .font(.caption2)
                Text(isExpanded ? "Ocultar razonamiento" : "Ver razonamiento")
                    .font(.caption2)
            }
            .foregroundStyle(.purple)
        }
        .padding(.vertical, 2)
        .buttonStyle(.plain)
        .popover(isPresented: $isExpanded, attachmentAnchor: .point(.top), arrowEdge: .bottom) {
            ScrollView {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: 320)
            }
            .frame(maxHeight: 300)
            .presentationCompactAdaptation(.popover)
        }
    }
}