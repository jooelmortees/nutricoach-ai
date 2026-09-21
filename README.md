# NutriCoach AI

App iOS nativa con un agente IA dietista-nutricionista potenciado por **Gemini 3.5 Flash**, conectado a Apple HealthKit, con memoria persistente, visión nativa para análisis de comida, y MCPs especializados en nutrición, fitness y salud.

## Arquitectura en 30 segundos

```
iPhone (FleckStore con certificado propio)
   ↓ Supabase Swift SDK
Supabase (Postgres + pgvector + Auth + Storage + Edge Functions)
   ↓ HTTPS (proxy seguro)
Gemini 3.5 Flash (cerebro IA con visión, tool use, thinking)
   ↓ MCP
8 MCPs (web_search oficial + 7 custom: nutrition, fitness, wearable, memory, recipes, fasting, user-data)
```

Más detalle en [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Estructura del repo

```
nutricoach-ai/
├── ios/                  # Proyecto Xcode (generable con XcodeGen)
├── supabase/             # Edge Functions + migraciones SQL (estructura estándar de Supabase CLI)
├── docs/                 # Arquitectura, system prompt del agente, onboarding
├── .github/workflows/    # Build iOS en macos-15-arm64
├── .env.example          # Plantilla de variables de entorno
└── README.md
```

## Setup inicial (1 vez)

### 1. Clonar e instalar dependencias
```bash
git clone https://github.com/your-user/nutricoach-ai.git
cd nutricoach-ai
cp .env.example .env
# Rellena .env con tus claves reales (ver docs/SETUP-CREDENTIALS.md)
```

### 2. Configurar Supabase
```bash
# Instalar Supabase CLI
npm install -g supabase

# Linkear con tu proyecto
supabase login
supabase link --project-ref YOUR_PROJECT_REF

# Aplicar migraciones
supabase db push

# Desplegar Edge Functions
supabase functions deploy chat-proxy
supabase functions deploy hk-sync
supabase functions deploy mcp-router
```

### 3. Configurar Apple Developer
1. Crea un **App ID** en https://developer.apple.com/account con bundle ID `com.joelmortees.nutricoach`
2. Configura también el App ID `com.joelmortees.nutricoach.widgets` y el App Group compartido
3. Habilita los entitlements y crea los perfiles indicados en [`docs/CODEMAGIC-SETUP.md`](docs/CODEMAGIC-SETUP.md)
4. Configura el certificado y los perfiles en Codemagic

### 4. Configurar GitHub Secrets
Ve a Settings > Secrets and variables > Actions del repo y crea:
- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`
- `SUPABASE_SERVICE_ROLE_KEY`
- `GEMINI_API_KEY`

Detalle completo en [`docs/SETUP-CREDENTIALS.md`](docs/SETUP-CREDENTIALS.md).

### 5. Generar el proyecto Xcode
```bash
brew install xcodegen   # Si tuvieras Mac, pero no es necesario
```

El proyecto Xcode se genera automáticamente en CI. GitHub Actions produce un IPA sin firma para validar la compilación; Codemagic produce el IPA firmado con los perfiles de la app y el widget.

### 6. Instalar la app en tu iPhone
1. Ejecuta el workflow `ios-signed` en Codemagic
2. Descarga `NutriCoach-Release.ipa`
3. Instálalo en un dispositivo incluido en el provisioning profile
4. Usa el IPA de GitHub solo como artefacto de compilación; una re-firma genérica puede perder las capabilities compartidas

## Documentación

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — Decisiones técnicas detalladas
- [`docs/AGENT-SYSTEM-PROMPT.md`](docs/AGENT-SYSTEM-PROMPT.md) — El system prompt del dietista
- [`docs/TOOLS.md`](docs/TOOLS.md) — Las 34+ tools que el agente puede llamar
- [`docs/ONBOARDING-USER.md`](docs/ONBOARDING-USER.md) — Cómo configurar tu iPhone (HealthKit, Health Sync, etc.)
- [`docs/SETUP-CREDENTIALS.md`](docs/SETUP-CREDENTIALS.md) — Dónde meter cada clave y secreto

## Stack

| Capa | Tecnología |
|---|---|
| iOS | Swift 5.9, SwiftUI, HealthKit, AVFoundation |
| Backend DB | Supabase Postgres + pgvector |
| Auth | Supabase Auth (email + Google OAuth con PKCE) |
| Storage | Supabase Storage |
| Realtime | Supabase Realtime v2 |
| Lógica | Supabase Edge Functions (Deno) |
| IA | Gemini 3.5 Flash (OpenAI-compatible endpoint) |
| MCP | `web_search` (Google Search via Gemini) + 7 custom |
| Build | GitHub Actions `macos-15-arm64` |
| Distribución | FleckStore con certificado propio (Apple Developer Program) |

## Licencia

MIT. Ver [`LICENSE`](LICENSE).
