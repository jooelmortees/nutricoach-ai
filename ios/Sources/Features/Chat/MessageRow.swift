// ============================================================
// MessageRow - celda individual del chat (rediseno completo)
// Patrones: avatar + esquinas asimetricas (scarf/AICat),
// tools colapsables con color por tipo (Sidekick/scarf),
// thinking colapsable con preview (hanlin-ai)
// ============================================================

import SwiftUI

struct MessageRow: View {
    let message: ChatMessage
    let isLastAssistant: Bool
    let onImageTap: (String) -> Void
    let onSaveMeal: (PendingMeal) async -> Bool
    var onRegenerate: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.role == .assistant {
                // Avatar del asistente (estilo scarf)
                AssistantAvatar()
                    .padding(.top, 2)
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                contentStack
                messageActions
            }

            if message.role == .user {
                Spacer(minLength: 40)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var contentStack: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
            // Thinking colapsable (estilo hanlin-ai)
            if let thinking = message.thinking, !thinking.isEmpty, message.role == .assistant {
                ThinkingSection(text: thinking, isStreaming: message.isStreaming)
            }

            // Imagenes adjuntas
            if let attachments = message.attachments, !attachments.isEmpty {
                AttachmentsGrid(attachments: attachments, onImageTap: onImageTap)
            }

            // Tools en ejecucion (estilo Sidekick/scarf)
            if let toolStatus = message.toolStatus, !toolStatus.isEmpty {
                ToolStepsSection(tools: toolStatus)
            }

            // Burbuja de texto con markdown + deteccion de macros
            if !message.content.isEmpty || !message.isStreaming {
                TextBubble(
                    text: message.content,
                    role: message.role,
                    isStreaming: message.isStreaming,
                    onSaveMeal: onSaveMeal
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }

    @ViewBuilder
    private var messageActions: some View {
        if !message.isStreaming && message.role == .assistant && isLastAssistant {
            if let onRegenerate {
                Button(action: onRegenerate) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                        Text("Regenerar")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.leading, 4)
                .padding(.top, 2)
            }
        }
    }
}

// MARK: - Assistant avatar

private struct AssistantAvatar: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.green.opacity(0.15))
            .frame(width: 28, height: 28)
            .overlay(
                Image(systemName: "leaf.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.green)
            )
    }
}

// MARK: - Thinking section (estilo hanlin-ai: colapsable + preview)

private struct ThinkingSection: View {
    let text: String
    let isStreaming: Bool
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isStreaming ? "brain.head.profile" : (isExpanded ? "chevron.down" : "brain.head.profile"))
                        .font(.caption2)
                    if isStreaming {
                        Text("Pensando...")
                            .font(.caption2)
                    } else {
                        Text(isExpanded ? "Ocultar razonamiento" : "Razonamiento")
                            .font(.caption2)
                    }
                    if !isExpanded && !isStreaming {
                        Text("- \(preview)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(.purple)
            }
            .buttonStyle(.plain)

            if isExpanded {
                ScrollView(.vertical, showsIndicators: true) {
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 150)
                .padding(8)
                .background(Color.purple.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var preview: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count <= 50 ? trimmed : String(trimmed.prefix(50)) + "..."
    }
}

// MARK: - Tool steps section (estilo Sidekick/scarf: pills con color por tipo)

private struct ToolStepsSection: View {
    let tools: [ToolStatus]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(tools) { tool in
                ToolPill(tool: tool)
            }
        }
    }
}

private struct ToolPill: View {
    let tool: ToolStatus
    @State private var showDetails = false

    private var kindColor: Color {
        switch tool.name {
        case "web_search": return Color.blue
        case "remember_fact": return Color.purple
        case "calculate_daily_target": return Color.orange
        case "get_user_profile", "get_recent_meals", "get_health_metrics": return Color.green
        case "generate_meal_plan": return Color.teal
        default: return Color.gray
        }
    }

    private var iconName: String {
        switch tool.name {
        case "get_user_profile": return "person.crop.circle"
        case "get_recent_meals": return "fork.knife"
        case "get_health_metrics": return "heart.text.square"
        case "remember_fact": return "brain"
        case "web_search": return "magnifyingglass"
        case "calculate_daily_target": return "target"
        case "generate_meal_plan": return "calendar"
        default: return "wrench.and.screwdriver"
        }
    }

    private var label: String {
        switch tool.name {
        case "get_user_profile": return "Consultando tu perfil"
        case "get_recent_meals": return "Revisando tus comidas recientes"
        case "get_health_metrics": return "Leyendo tus metricas de salud"
        case "remember_fact": return "Guardando en memoria"
        case "web_search": return "Buscando informacion"
        case "calculate_daily_target": return "Calculando tu objetivo diario"
        case "generate_meal_plan": return "Generando plan de comidas"
        default: return "Procesando"
        }
    }

    var body: some View {
        Button {
            if !tool.summary.isEmpty {
                withAnimation(.easeInOut(duration: 0.15)) {
                    showDetails.toggle()
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: iconName)
                    .font(.caption2)
                    .foregroundStyle(kindColor)

                Text(tool.summary.isEmpty ? label : tool.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(showDetails ? nil : 1)

                if tool.isRunning {
                    ThinkingIndicator()
                        .scaleEffect(0.5)
                        .padding(.leading, 2)
                } else if !tool.summary.isEmpty {
                    Image(systemName: showDetails ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }

                if !tool.isRunning && tool.summary.isEmpty {
                    Image(systemName: "checkmark")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(kindColor.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(kindColor.opacity(0.2), lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(tool.summary.isEmpty)
    }
}

// MARK: - ToolStatus

struct ToolStatus: Identifiable, Equatable {
    let id = UUID()
    let name: String
    var summary: String
    var isRunning: Bool

    static func == (lhs: ToolStatus, rhs: ToolStatus) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Macros detection (PendingMeal)

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
        let before = text[text.startIndex..<jsonStart].trimmingCharacters(in: .whitespacesAndNewlines)
        let after = text[text.index(after: jsonEnd)...].trimmingCharacters(in: .whitespacesAndNewlines)
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

// MARK: - Attachments grid

struct AttachmentsGrid: View {
    let attachments: [MessageAttachment]
    let onImageTap: (String) -> Void

    private let thumbSize: CGFloat = 70
    private let cornerRadius: CGFloat = 10

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

// MARK: - Text bubble (esquinas asimetricas estilo scarf/AICat)

private struct TextBubble: View {
    let text: String
    let role: ChatMessage.Role
    let isStreaming: Bool
    let onSaveMeal: (PendingMeal) async -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let extracted = PendingMeal.extract(from: text), let macros = extracted.macros {
                if !extracted.cleaned.isEmpty {
                    MarkdownView(text: extracted.cleaned)
                }
                MacrosCard(meal: macros, onSave: { editedMeal in
                    await onSaveMeal(editedMeal)
                })
            } else {
                MarkdownView(text: text)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(bg, in: bubbleShape)
        .foregroundStyle(fg)
        .contextMenu {
            Button {
                UIPasteboard.general.string = text
            } label: {
                Label("Copiar", systemImage: "doc.on.doc")
            }
        }
    }

    private var bubbleShape: UnevenRoundedRectangle {
        if role == .user {
            return UnevenRoundedRectangle(
                topLeadingRadius: 16,
                bottomLeadingRadius: 16,
                bottomTrailingRadius: 4,
                topTrailingRadius: 16
            )
        } else {
            return UnevenRoundedRectangle(
                topLeadingRadius: 4,
                bottomLeadingRadius: 16,
                bottomTrailingRadius: 16,
                topTrailingRadius: 16
            )
        }
    }

    private var bg: Color {
        role == .user ? Color.green.opacity(0.9) : Color(.secondarySystemBackground)
    }

    private var fg: Color {
        role == .user ? .white : .primary
    }
}

// MARK: - Macros card

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

            HStack(spacing: 10) {
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