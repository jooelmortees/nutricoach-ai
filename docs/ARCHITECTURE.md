# Arquitectura

## Resumen en una imagen

```
iPhone (sideloadly + AltStore)
└─ NutriCoach (Swift 5.9, SwiftUI, HealthKit, AVFoundation)
   ├─ supabase-swift (Auth, DB, Storage, Realtime)
   └─ HTTPS a Edge Functions

        │
        ▼

Supabase (managed)
├─ Postgres 15 + pgvector (memoria semántica)
├─ Auth (email + Apple ID, JWT)
├─ Storage (fotos/vídeos privados con RLS)
├─ Realtime v2 (WebSocket para chat streaming)
└─ Edge Functions (Deno)
   ├─ chat-proxy   → orquesta Gemini 3.5 Flash con 25+ tools
   ├─ hk-sync      → recibe HealthKit del iPhone
   └─ mcp-router   → 7 MCPs custom (nutrition, fitness, wearable,
                     memory, recipes, fasting, user-data)

         │ HTTPS (https://generativelanguage.googleapis.com/v1beta/openai)
         ▼

Gemini 3.5 Flash (tu API key de Google AI Studio)
├─ Visión nativa (JPEG, PNG, GIF, WEBP ≤ 10MB)
├─ Vídeo nativo (MP4, AVI, MOV, MKV ≤ 50MB; 512MB vía Files API)
├─ Thinking (reasoning_effort: minimal/low/medium/high)
├─ Tool use / Function calling
├─ Streaming con thinking + text por separado
└─ Context window: 1.000.000 tokens
```

## Decisiones técnicas clave

### Por qué SwiftUI
- Declarativo, menos boilerplate
- Soporte oficial Apple
- HealthKit, AVFoundation, AuthServices con SwiftUI bindings

### Por qué Supabase
- BaaS maduro con Postgres+pgvector (no me obliga a otra DB)
- Edge Functions nativas (Deno) sin servidor extra
- Auth + RLS + Storage + Realtime en un solo panel
- Free tier generoso para empezar

### Por qué Gemini 3.5 Flash
- Cerebro agentic con visión + vídeo nativos (no necesito CLIP, no necesito GPT-4V)
- Thinking con reasoning_effort configurable (minimal/low/medium/high)
- Compatible con endpoint OpenAI (fácil integración, formato estándar)
- 1M tokens de context (cargo historial completo)
- API key gratis en Google AI Studio (free tier generoso)

### Por qué wger + USDA FDC
- Open source, sin coste por API call, sin riesgo de cierre
- Datos verificados por la comunidad
- USDA FDC es CC0 (dominio público)
- Suficiente para MVP; en fase avanzada podemos añadir más

### Por qué no hay TTS/STT/imagen
- Coste/beneficio no compensa para esta app
- Gemini ya ve fotos y vídeos del usuario (no necesita generar)
- Texto es lo más útil + más rápido + más barato

## Diagrama de datos

```
profiles ──┬── meals ── meal_items
           │     │
           │     └─ (ai_analysis jsonb)
           │
           ├── user_facts (memoria estructurada)
           │
           ├── memory_embeddings (RAG, vector(1024))
           │
           ├── health_metrics (sincronizado de HealthKit)
           │     │
           │     └─ type ∈ {heart_rate, sleep_minutes, workout, ...}
           │
           ├── recipes
           │
           ├── meal_plans
           │
           ├── conversations ── messages
           │
           ├── user_preferences (key/value ultra-config)
           │
           └── scheduled_nudges
```

Todas las tablas tienen RLS: cada usuario solo ve/edita sus datos.

## Flujo del agente (cuando un usuario envía un mensaje)

1. **iOS** → `POST /functions/v1/chat-proxy` con `conversation_id` y `message`
2. **chat-proxy** (Edge Function):
   - Valida JWT del usuario
   - Carga perfil + hechos activos + últimos 20 mensajes
   - Construye system prompt (perfil + hechos + instrucciones)
   - Llama a `POST /v1beta/openai/chat/completions` con `model=gemini-3.5-flash`, tools, reasoning_effort=medium, stream=true
   - Reintenta errores transitorios con backoff exponencial y usa `gemini-3.1-flash-lite` si 3.5 sigue sin estar disponible
3. **Gemini**:
   - Genera thinking (interno, envuelto en tags `<thought>` en delta.content)
   - Decide si llamar a tools
   - Si sí: para, llama a `POST /functions/v1/mcp-router` con `tool` y `arguments`
   - **mcp-router** despacha al MCP correcto (nutrition, fitness, etc.)
   - El MCP lee/escribe en Supabase, devuelve resultado
   - Gemini integra resultado y sigue razonando
   - Cuando termina, emite `text` final
4. **chat-proxy** streamea `thinking_delta` y `text_delta` al iOS vía Server-Sent Events
5. **iOS** renderiza en tiempo real
6. Al final, **chat-proxy** guarda mensaje en `messages` y `conversations.last_message_at`

## Capas de memoria

| Capa | Dónde | Cuándo se carga | Coste |
|---|---|---|---|
| **Core** | System prompt | Cada request | Medio (implicit caching desde 4096 tokens de prefijo) |
| **Recall** | Últimos 20 mensajes en `messages` | Cada request | Bajo |
| **Archival (RAG)** | `memory_embeddings` (pgvector) | Cuando el agente lo pide | Bajo (HNSW index) |
| **Structured facts** | `user_facts` (texto plano) | Cuando el agente lo pide | Bajo |

## Por qué NO compilamos en local

- Joel no tiene Mac
- GitHub Actions runners `macos-15-arm64` incluyen Xcode 16 con iOS 18 SDK preinstalados
- Compilamos el .xcarchive, exportamos a IPA con nuestro Apple Developer cert
- Joel descarga el IPA y lo instala con sideloadly o AltStore

## Por qué NO publicamos en App Store

- Es para uso personal de Joel
- Sideloadly permite saltarse el review de Apple
- Mantiene total libertad técnica
- Si en el futuro quiere publicar, ajustamos entitlements y submitimos

## Roadmap resumido

| Fase | Estado |
|---|---|
| 0. Setup y andamiaje | ✅ Completa (este commit) |
| 1. Agente dietista mínimo | Pendiente (chat + 3 tools) |
| 2. Health + comida por foto | Pendiente |
| 3. Nutrición completa | Pendiente |
| 4. Fitness + memoria RAG | Pendiente |
| 5. Pulido + extras | Pendiente |
