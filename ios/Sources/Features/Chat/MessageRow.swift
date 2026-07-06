// ============================================================
// MessageRow - celda individual del chat redisenada
// Estilo opencode: bloques separados y plegables para thinking,
// tools y texto. Cada bloque es visualmente distinto.
// ============================================================

import SwiftUI

struct MessageRow: View {
    let message: ChatMessage
    let onImageTap: (String) -> Void
    let onSaveMeal: (PendingMeal) async -> Bool
    var onRegenerate: (() -> Void)? = nil
    var onRetry: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 8) {
            // Imagenes adjuntas (siempre arriba)
            if let attachments = message.attachments, !attachments.isEmpty {
                AttachmentsGrid(attachments: attachments, onImageTap: onImageTap)
            }

            // Bloque thinking (plegable, solo assistant)
            if let thinking = message.thinking, !thinking.isEmpty {
                ThinkingBlock(text: thinking)
            }

            // Bloque tools (estilo opencode: seccion con bordes)
            if let toolStatus = message.toolStatus, !toolStatus.isEmpty {
                ToolBlock(tools: toolStatus)
            }

            // Burbuja de texto principal
            if !message.content.isEmpty || message.isStreaming {
                TextBubble(
                    text: message.content,
                    role: message.role,
                    isStreaming: message.isStreaming,
                    onSaveMeal: onSaveMeal
                )
            }

            // Acciones debajo del mensaje
            messageActions
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
        .padding(.horizontal, message.role == .user ? 60 : 0)
    }

    @ViewBuilder
    private var messageActions: some View {
        if !message.isStreaming {
            HStack(spacing: 12) {
                if message.role == .assistant, let onRegenerate {
                    Button(action: onRegenerate) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                            Text("Regenerar")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                if message.role == .user, let onRetry {
                    Button(action: onRetry) {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle")
                            Text("Reintentar")
                        }
                        .font(.caption)
                        .foregroundStyle(.red)
                    }
                }
            }
            .padding(.horizontal, 4)
        }
    }
}

// MARK: - Bloque Thinking (plegable, estilo opencode)

struct ThinkingBlock: View {
    let text: String
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain.head.profile")
                        .font(.caption2)
                    Text(isExpanded ? "Ocultar razonamiento" : "Ver razonamiento")
                        .font(.caption2)
                    if !isExpanded {
                        Text(truncatedPreview)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.purple)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)

            if isExpanded {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.purple.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color.purple.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
    }

    private var truncatedPreview: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 50 {
            return trimmed
        }
        return String(trimmed.prefix(50)) + "..."
    }
}

// MARK: - Bloque Tools (estilo opencode: bordes + seccion)

struct ToolBlock: View {
    let tools: [ToolStatus]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(tools) { tool in
                HStack(spacing: 6) {
                    Image(systemName: toolIcon(tool.name))
                        .font(.caption2)
                        .foregroundStyle(.blue)

                    Text(tool.summary.isEmpty ? toolLabel(tool.name) : tool.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer()

                    if tool.isRunning {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 12, height: 12)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
            }
        }
        .background(Color.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.blue.opacity(0.1), lineWidth: 0.5)
        )
    }

    private func toolIcon(_ name: String) -> String {
        switch name {
        case "get_user_profile": return "person.crop.circle"
        case "get_recent_meals": return "fork.knife"
        case "get_health_metrics": return "heart.text.square"
        case "remember_fact": return "brain"
        case "web_search": return "magnifyingglass"
        case "calculate_daily_target": return "target"
        default: return "wrench.and.screwdriver"
        }
    }

    private func toolLabel(_ name: String) -> String {
        switch name {
        case "get_user_profile": return "Consultando tu perfil"
        case "get_recent_meals": return "Revisando comidas recientes"
        case "get_health_metrics": return "Leyendo metricas de salud"
        case "remember_fact": return "Guardando en memoria"
        case "web_search": return "Buscando informacion"
        case "calculate_daily_target": return "Calculando objetivo diario"
        default: return "Procesando"
        }
    }
}

// MARK: - Macros detectadas (PendingMeal + extract)

struct PendingMeal: Codable, Equatable {
    var description: String
    var meal_type: String?
    var kcal: Double?
    var protein_g: Double?
    var carbs_g: Double?
    var fat_g: Double?
    var confidence: Double?
    var ingredients: [PendingIngredient]?

    static func extract(from text: String) -> (cleaned: String, macros: PendingMeal?)? {
        guard let jsonStart = text.firstIndex(of: "{") else { return nil }
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
        let before = text[text.startIndex..<jsonStart]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let after = text[text.index(after: jsonEnd)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = [before, after].filter { !$0.isEmpty }.joined(separator: "\n\n")

        guard let data = jsonStr.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var ingredients: [PendingIngredient] = []
        if let ingredientsArray = parsed["ingredients"] as? [[String: Any]] {
            for ing in ingredientsArray {
                let name = (ing["name"] as? String) ?? ""
                let quantity = (ing["quantity"] as? NSNumber)?.doubleValue
                let unit = (ing["unit"] as? String) ?? ""
                if !name.isEmpty {
                    ingredients.append(PendingIngredient(name: name, quantity: quantity, unit: unit))
                }
            }
        }
        let meal = PendingMeal(
            description: (parsed["description"] as? String) ?? "Comida",
            meal_type: parsed["meal_type"] as? String,
            kcal: (parsed["kcal"] as? NSNumber)?.doubleValue,
            protein_g: (parsed["protein_g"] as? NSNumber)?.doubleValue,
            carbs_g: (parsed["carbs_g"] as? NSNumber)?.doubleValue,
            fat_g: (parsed["fat_g"] as? NSNumber)?.doubleValue,
            confidence: (parsed["confidence"] as? NSNumber)?.doubleValue,
            ingredients: ingredients.isEmpty ? nil : ingredients
        )
        return (cleaned, meal)
    }
}

struct PendingIngredient: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var quantity: Double?
    var unit: String

    enum CodingKeys: String, CodingKey {
        case name, quantity, unit
    }
}

struct ToolStatus: Identifiable, Equatable {
    let id = UUID()
    let name: String
    var summary: String
    var isRunning: Bool

    static func == (lhs: ToolStatus, rhs: ToolStatus) -> Bool {
        lhs.id == rhs.id
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
    let onSaveMeal: (PendingMeal) async -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if text.isEmpty && isStreaming {
                TypingIndicator()
            } else if let extracted = PendingMeal.extract(from: text), let macros = extracted.macros {
                if !extracted.cleaned.isEmpty {
                    MarkdownView(text: extracted.cleaned, isStreaming: isStreaming)
                }
                MacrosCard(meal: macros, onSave: { editedMeal in
                    await onSaveMeal(editedMeal)
                })
            } else {
                MarkdownView(text: text, isStreaming: isStreaming)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(bg, in: RoundedRectangle(cornerRadius: 16))
        .foregroundStyle(fg)
        .frame(maxWidth: .infinity, alignment: role == .user ? .trailing : .leading)
        .contextMenu {
            Button {
                UIPasteboard.general.string = text
            } label: {
                Label("Copiar", systemImage: "doc.on.doc")
            }
        }
    }

    private var bg: Color {
        role == .user ? .green : Color(.secondarySystemBackground)
    }

    private var fg: Color {
        role == .user ? .white : .primary
    }
}

// MARK: - Tarjeta de macros

private struct MacrosCard: View {
    let meal: PendingMeal
    let onSave: (PendingMeal) async -> Bool
    @State private var saved = false
    @State private var showEditor = false
    @State private var editableMeal: PendingMeal

    init(meal: PendingMeal, onSave: @escaping (PendingMeal) async -> Bool) {
        self.meal = meal
        self.onSave = onSave
        self._editableMeal = State(initialValue: meal)
    }

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

            Button(action: { showEditor = true }) {
                HStack {
                    Image(systemName: saved ? "checkmark.circle.fill" : "square.and.pencil")
                    Text(saved ? "Guardado en tu dia" : "Revisar y guardar")
                }
                .font(.subheadline)
                .fontWeight(.medium)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(saved ? Color.green.opacity(0.2) : Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(.green)
            }
            .disabled(saved)
            .sheet(isPresented: $showEditor) {
                MealEditorSheet(
                    meal: $editableMeal,
                    onSave: { editedMeal in
                        let ok = await onSave(editedMeal)
                        if ok {
                            await MainActor.run { saved = true }
                        }
                        return ok
                    }
                )
            }
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