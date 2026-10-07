# Arquitectura

## Resumen en una imagen

```
iPhone (FleckStore con certificado propio)
└─ NutriCoach (Swift 5.9, SwiftUI, HealthKit, AVFoundation)
   ├─ supabase-swift (Auth, DB, Storage, Realtime)
   └─ HTTPS a Edge Functions

        │
        ▼

Supabase (managed)
├─ Postgres 15 + pgvector (memoria semántica)
├─ Auth (email + Google OAuth con PKCE, JWT)
├─ Storage (fotos/vídeos privados con RLS)
├─ Realtime v2 (WebSocket para chat streaming)
└─ Edge Functions (Deno)
   ├─ chat-proxy   → orquesta DeepSeek V4.1 Flash (OpenCode Go) con 25+ tools
   ├─ hk-sync      → recibe HealthKit del iPhone
   └─ mcp-router   → 7 MCPs custom (nutrition, fitness, wearable,
                     memory, recipes, fasting, user-data)

         │ HTTPS (https://opencode.ai/zen/go/v1)
         ▼

OpenCode Go · DeepSeek V4.1 Flash (suscripción en opencode.ai/console)
├─ Visión nativa (fotos de comida vía image_url)
├─ Thinking (delta.reasoning_content)
├─ Tool use / Function calling
├─ Streaming SSE (thinking + text por separado)
└─ Fallback a glm-5.3-flash ante errores transitorios

Notas de voz: Gemini 3.5 Flash (input_audio; verificado 2026-10-07:
ningún modelo de OpenCode Go acepta audio)
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

### Por qué DeepSeek V4.1 Flash (vía OpenCode Go)
- Modelo open source con visión y tool calling verificados (2026-10-07)
- Coste fijo: plan OpenCode Go ($10/mes, ~130k requests/mes estimadas para este modelo)
- Thinking nativo (`reasoning_content`) y streaming compatible con el protocolo SSE existente
- El gateway exige `x-opencode-session` por conversación; el chat ya tiene `conversation_id`
- Notas de voz siguen en Gemini porque DeepSeek no acepta `input_audio`

### Por qué wger + USDA FDC
- Open source, sin coste por API call, sin riesgo de cierre
- Datos verificados por la comunidad
- USDA FDC es CC0 (dominio público)
- Suficiente para MVP; en fase avanzada podemos añadir más

### Por qué no hay TTS/STT/imagen
- Coste/beneficio no compensa para esta app
- El modelo ya ve fotos de comida del usuario (no necesita generar)
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
   - Puede consultar el plan alimentario activo completo o por día mediante `get_active_meal_plan`
   - Construye system prompt (perfil + hechos + instrucciones)
   - Llama a `POST https://opencode.ai/zen/go/v1/chat/completions` con `model=deepseek-v4.1-flash`, tools, `x-opencode-session`, stream=true
   - Reintenta errores transitorios con backoff exponencial y usa `glm-5.3-flash` si el primario sigue sin estar disponible
3. **DeepSeek V4.1 Flash**:
   - Genera thinking (interno, en `delta.reasoning_content`)
   - Decide si llamar a tools
   - Si sí: para, llama a `POST /functions/v1/mcp-router` con `tool` y `arguments`
   - **mcp-router** despacha al MCP correcto (nutrition, fitness, etc.)
   - El MCP lee/escribe en Supabase, devuelve resultado
   - El modelo integra el resultado y sigue razonando
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
- GitHub Actions valida la compilación y empaqueta un IPA sin firma
- Codemagic compila y firma la app y la extensión con sus perfiles de desarrollo
- Para conservar HealthKit, App Groups y Keychain Sharing se usa el IPA firmado de Codemagic

## Por qué NO publicamos en App Store

- Es para uso personal de Joel
- La distribución privada mediante FleckStore evita el proceso de publicación en App Store
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
