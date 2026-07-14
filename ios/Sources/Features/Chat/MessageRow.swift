// ============================================================
// MessageRow - celda individual del chat (estilo Claude)
// Assistant: Markdown pegado a la izquierda, sin bocadillo
// User: caja con fondo pegada a la derecha
// Sin avatares, sin logo
// ============================================================

import SwiftUI

struct MessageRow: View, Equatable {
    let message: ChatMessage
    let audioPlayback: AudioPlaybackController
    let onImageTap: (String) -> Void
    let onSaveMeal: (PendingMeal) async -> Bool

    static func == (lhs: MessageRow, rhs: MessageRow) -> Bool {
        lhs.message == rhs.message && lhs.audioPlayback === rhs.audioPlayback
    }

    @ViewBuilder
    var body: some View {
        if message.role == .user {
            contentStack
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.vertical, 10)
        } else {
            contentStack
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private var contentStack: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
            // Thinking colapsable
            if let thinking = message.thinking, !thinking.isEmpty, message.role == .assistant {
                ThinkingSection(text: thinking, isStreaming: message.isStreaming)
            }

            // Imagenes adjuntas
            if let attachments = message.attachments, !attachments.isEmpty {
                AttachmentsGrid(
                    attachments: attachments,
                    audioPlayback: audioPlayback,
                    onImageTap: onImageTap
                )
            }

            // Tools en ejecucion
            if let toolStatus = message.toolStatus, !toolStatus.isEmpty {
                ToolStepsSection(tools: toolStatus)
            }

            // Contenido del mensaje
            if !message.content.isEmpty ||
               (message.role == .assistant && message.isStreaming) {
                messageContent
            }
        }
    }

    @ViewBuilder
    private var messageContent: some View {
        if message.role == .user {
            // USER: caja con fondo, pegada a la derecha
            VStack(alignment: .leading, spacing: 6) {
                if let extracted = PendingMeal.extract(from: message.content), let macros = extracted.macros {
                    if !extracted.cleaned.isEmpty {
                        ChatMarkdownView(text: extracted.cleaned)
                    }
                    MacrosCard(meal: macros, onSave: { editedMeal in
                        await onSaveMeal(editedMeal)
                    })
                } else {
                    ChatMarkdownView(text: message.content)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
            .foregroundStyle(.primary)
            .frame(maxWidth: 280, alignment: .trailing)
            .contextMenu {
                Button {
                    UIPasteboard.general.string = message.content
                } label: {
                    Label("Copiar", systemImage: "doc.on.doc")
                }
            }
        } else {
            // ASSISTANT: Markdown sin bocadillo, pegado a la izquierda
            StreamingAssistantContent(
                text: message.content,
                isStreaming: message.isStreaming,
                onSaveMeal: onSaveMeal
            )
            .contextMenu {
                Button {
                    UIPasteboard.general.string = message.content
                } label: {
                    Label("Copiar", systemImage: "doc.on.doc")
                }
            }
        }
    }
}

private struct StreamingAssistantContent: View {
    let text: String
    let isStreaming: Bool
    let onSaveMeal: (PendingMeal) async -> Bool

    @State private var usesStreamingRenderer: Bool

    init(
        text: String,
        isStreaming: Bool,
        onSaveMeal: @escaping (PendingMeal) async -> Bool
    ) {
        self.text = text
        self.isStreaming = isStreaming
        self.onSaveMeal = onSaveMeal
        _usesStreamingRenderer = State(initialValue: isStreaming)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !isStreaming,
               let extracted = PendingMeal.extract(from: text),
               let macros = extracted.macros {
                if !extracted.cleaned.isEmpty {
                    ChatMarkdownView(text: extracted.cleaned)
                }
                MacrosCard(meal: macros, onSave: { editedMeal in
                    await onSaveMeal(editedMeal)
                })
            } else if usesStreamingRenderer {
                StreamingChatMarkdownView(text: text, isStreaming: isStreaming)
            } else {
                ChatMarkdownView(text: text)
            }

            if isStreaming {
                StreamingDotsIndicator()
                    .padding(.top, 2)
            }
        }
    }
}

private struct StreamingDotsIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                dots(at: 0)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 12.0)) { timeline in
                    dots(at: timeline.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        .frame(width: 28, height: 10, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Generando respuesta")
    }

    private func dots(at time: TimeInterval) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                let pulse = reduceMotion
                    ? 0.65
                    : (sin(time * 4 - Double(index) * 0.75) + 1) / 2

                Circle()
                    .fill(Color(.secondaryLabel))
                    .opacity(0.35 + pulse * 0.5)
                    .frame(width: 5, height: 5)
                    .scaleEffect(0.8 + CGFloat(pulse) * 0.2)
            }
        }
    }
}

// MARK: - Thinking section

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

// MARK: - Tool steps section

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
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
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
        lhs.id == rhs.id &&
        lhs.name == rhs.name &&
        lhs.summary == rhs.summary &&
        lhs.isRunning == rhs.isRunning
    }
}

// MARK: - Macros detection

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
    let audioPlayback: AudioPlaybackController
    let onImageTap: (String) -> Void

    private let thumbSize: CGFloat = 70
    private let cornerRadius: CGFloat = 10

    var body: some View {
        let images = attachments.filter { $0.type == "image" }
        let audios = attachments.filter { $0.type == "audio" }
        VStack(alignment: .trailing, spacing: 6) {
            if images.count == 1 {
                singleImage(images[0])
            } else if images.count > 1 {
                multipleImages(images)
            }
            ForEach(audios) { audio in
                AudioAttachmentCard(
                    id: audio.id,
                    title: audio.name ?? "Grabación de voz",
                    duration: audio.durationSeconds ?? 0,
                    sizeBytes: audio.sizeBytes ?? legacyAudioSize(audio.legacyData),
                    remoteURL: audio.url,
                    legacyBase64: audio.legacyData,
                    playback: audioPlayback
                )
                .frame(maxWidth: 280)
            }
        }
    }

    @ViewBuilder
    private func singleImage(_ att: MessageAttachment) -> some View {
        AsyncImage(url: att.url.flatMap(URL.init(string:))) { phase in
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
                    .onTapGesture {
                        if let url = att.url { onImageTap(url) }
                    }
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
                ForEach(images) { att in
                    AsyncImage(url: att.url.flatMap(URL.init(string:))) { phase in
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
                                .onTapGesture {
                                    if let url = att.url { onImageTap(url) }
                                }
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

    private func legacyAudioSize(_ base64: String?) -> Int {
        guard let base64 else { return 0 }
        return base64.count * 3 / 4
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
