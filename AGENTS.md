# AGENTS.md - NutriCoach AI

Reglas específicas de este proyecto. Complementa (no sustituye) el AGENTS.md global de `~/.config/opencode/AGENTS.md`.

## Reglas críticas del proyecto

### Compilación iOS

- **Plataforma de build**: macOS-only (Xcode 26 en Mac mini M2 de Codemagic).
- **NO se puede compilar iOS en Windows**. Xcode no existe para Windows. Swift for Windows solo compila binarios Windows, no iOS. No prometas al usuario que puede compilar iOS localmente.
- **Si un build falla con `failed to produce diagnostic` del compilador de Swift**, NO revertir a regresiones. El error oculta otro. Investigar con `context7` y `gh_grep`, leer TODO el código relacionado (viewmodel, sub-vistas, modelos), pedir log completo al usuario si el grep no basta. Fix debe mantener TODA la funcionalidad.
- **Entitlements y widgets**: Codemagic firma durante `xcodebuild` mediante `ios_signing` y perfiles separados para `com.joelmortees.nutricoach` y `com.joelmortees.nutricoach.widgets`. No modificar el `.app` después de firmarlo; verificar app y `.appex` con `codesign --verify --deep --strict`. GitHub Actions usa `CODE_SIGNING_ALLOWED=NO` únicamente para validar compilación y genera un IPA sin firma que no garantiza HealthKit, App Groups ni Keychain Sharing. En Apple Developer deben estar habilitadas las capabilities y regenerados ambos perfiles.
- **Instalación en dispositivo**: Joel instala y actualiza siempre mediante FleckStore usando el certificado propio de NutriCoach. Al diagnosticar firma, asumir que FleckStore puede volver a firmar el IPA y comprobar que preserve los entitlements de la app y `NutriCoachWidgets.appex`, especialmente App Groups y Keychain Sharing.

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
- **Codemagic Environment Variables**: se pasan como build settings a `xcodebuild` y XcodeGen las expande en ambos `Info.plist` antes de firmar. Grupo declarado en el workflow con `groups: [NombreGrupo]`.
- **GitHub Secrets**: para la compilación alternativa sin firma y el despliegue de Edge Functions.

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
- **Google OAuth**: sustituye a Apple Sign In y usa PKCE con `nutricoach://login-callback/` a través de Supabase Auth.
- **Persistencia de sesión**: activada por defecto en SDK Supabase Swift.
