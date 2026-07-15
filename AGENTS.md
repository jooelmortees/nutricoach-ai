# AGENTS.md - NutriCoach AI

Reglas específicas de este proyecto. Complementa (no sustituye) el AGENTS.md global de `~/.config/opencode/AGENTS.md`.

## Reglas críticas del proyecto

### Compilación iOS

- **Plataforma de build**: macOS-only (Xcode 26 en Mac mini M2 de Codemagic).
- **NO se puede compilar iOS en Windows**. Xcode no existe para Windows. Swift for Windows solo compila binarios Windows, no iOS. No prometas al usuario que puede compilar iOS localmente.
- **Si un build falla con `failed to produce diagnostic` del compilador de Swift**, NO revertir a regresiones. El error oculta otro. Investigar con `context7` y `gh_grep`, leer TODO el código relacionado (viewmodel, sub-vistas, modelos), pedir log completo al usuario si el grep no basta. Fix debe mantener TODA la funcionalidad.
- **Entitlements (HealthKit, Apple Sign In)**: el build se hace con `CODE_SIGNING_ALLOWED=NO` y por tanto `xcodebuild` NO inyecta los entitlements en el binario. iOS los rechaza en runtime con "Missing entitlement". Solución: paso post-build `Re-sign with entitlements` en `codemagic.yaml` que ejecuta `codesign --force --sign - --entitlements ...` (firma ad-hoc). **CRÍTICO para HealthKit**: además, en `developer.apple.com` el App ID `com.joelmortees.nutricoach` debe tener la capability **HealthKit** habilitada, y el cert que use Sideloadly/AltStore debe estar vinculado a un provisioning profile de ese App ID. Sin eso, iOS rechaza el entitlement incluso con codesign ad-hoc.

### Tabla `meals` (referencia rápida para inserts)

- Columnas reales: `id, user_id, logged_at, meal_type, name, notes, photo_urls, video_url, source, total_kcal, total_protein_g, total_carbs_g, total_fat_g, total_fiber_g, ai_analysis, location, created_at`.
- **NO tiene `description`**: usar `name`. **NO tiene `kcal`/`protein_g`/etc.**: usar `total_kcal`/`total_protein_g`/etc. La app Swift tiene `PendingMeal` (JSON parseado) con `description`/`kcal`/`protein_g` — mapear a los nombres reales antes de insertar.
- `source` es enum (`manual` por defecto). Para comidas del chat usar `text` o `ai`. Ver check constraint en migración 0001.
- `ai_analysis` es jsonb. Para metadata simple usar `notes` text en su lugar.

### Planes (`meal_plans` + `PlanMeal`)

- **Tabla `meal_plans`**: `id, user_id, week_start, plan (jsonb), generated_by, status, notes, created_at, updated_at`. El campo `plan` se decodifica a `PlanContent` (ver `ios/Sources/Models/Plans.swift`).
- **Estructura del jsonb `plan`** (generada por Edge Function `generate-plan`):
  - `type` ("weekly"|"daily"), `title`, `summary`, `target_kcal`, `target_protein_g`, `target_carbs_g`, `target_fat_g`
  - `days[]` con `day` (string) y `meals[]`
  - Cada `meal`: `type` (breakfast|lunch|dinner|snack), `name`, `kcal`, `protein_g`, `carbs_g`, `fat_g`, `fiber_g`, `notes`, **`ingredients[]`** (name, quantity, unit), **`preparation_steps[]`** (4-8 pasos detallados), `prep_time_min`, `cook_time_min`, `servings`, `difficulty` (facil|media|alta), `tips`, `allergens[]`.
- **CRÍTICO - ingredientes y preparación obligatorios**: el generador compartido crea y valida cada día por separado. Gemini debe devolver SIEMPRE `ingredients` y `preparation_steps` en cada comida; un plan incompleto no se guarda. `PlanMeal` mantiene `preparation` opcional solo para decodificar planes antiguos.
- **UI**: al pulsar una comida del plan se abre `PlanMealDetailView` (sheet) con ingredientes, preparación, macros, tiempos, dificultad, tips, alérgenos y botón "Registrar como comida de hoy" (inserta en `meals` con `source='ai_suggestion'`).
- **`PlanMealDifficulty`**: enum con `init(from:)` custom que normaliza tildes y mayúsculas. Si Gemini devuelve "Fácil" o "MEDIA", se mapea correctamente.
- **`source` al registrar desde plan**: usar siempre `'ai_suggestion'` (valor válido del enum `meal_source_t`). NUNCA inventar valores de enum.

### Secrets y configuración

- **`.env`**: NUNCA commitear. Permisos `icacls` owner-only (`DESKTOP-8C0IARF\Joel FullControl`).
- **`.env.example`**: plantilla con placeholders, sí se commitea.
- **Codemagic Environment Variables**: se inyectan al `.app/Info.plist` post-build con `PlistBuddy Add` (no `Set`). Grupo declarado en el workflow con `groups: [NombreGrupo]`.
- **GitHub Secrets**: para CI alternativa si Codemagic falla.

### Supabase

- **Project ref**: `oqkctjzaojyevdxvavaj`
- **Tablas importantes**: `profiles`, `memories`, `user_facts`, `messages`, `conversations`, `meals`, `health_metrics`.
- **RLS activo** en TODAS las tablas. Para tests con `service_role` key.
- **MCP `supabase` disponible** en este opencode. Usar `supabase_execute_sql` con `project_id=oqkctjzaojyevdxvavaj` para queries.

### Estructura del proyecto

- `ios/Sources/App/`: entry point, RootView, AppState
- `ios/Sources/Features/Auth|Dashboard|Chat|Macros|Settings|Camera|Plans/`: features
- `ios/Sources/Services/`: SupabaseClient, AuthManager, HealthKitManager, AgentService, StorageService, Config
- `ios/Sources/Models/`: Models.swift con structs Codable (Profile, Conversation, Message, Meal)
- `ios/Sources/Resources/`: Info.plist, Assets.xcassets, NutriCoach.entitlements
- `supabase/functions/`: Edge Functions (chat-proxy, hk-sync, mcp-router + MCPs)
- `supabase/migrations/`: 4 migraciones SQL (init, rls, functions, storage)

### Convenciones

- **Idioma del código**: comentarios en español de España, nombres de variables en inglés (excepto cuando el dominio lo requiera).
- **Tests**: NO hay (decidido por Joel, app personal). No añadir tests por postureo.
- **Style**: SwiftUI nativo, `@MainActor` en view models, structs Codable para modelos de Supabase.
- **NO emojis** en código (solo en UI si el usuario los pide).
- **NO silenciar errores** con `try?` salvo que sea seguro ignorar.

### Decisiones de fase

- **Fase 1 (MVP)**: Auth + Chat + Macros + Camera placeholder. Hecho.
- **Fase 2**: pendiente por decisión del usuario.
- **Apple Sign In**: capability añadida, implementado pero no testeado en device.
- **Persistencia de sesión**: activada por defecto en SDK Supabase Swift.
