# NutriCoach AI

App iOS nativa con un agente IA dietista-nutricionista potenciado por **MiniMax-M3**, conectado a Apple HealthKit, con memoria persistente, visión nativa para análisis de comida, y MCPs especializados en nutrición, fitness y salud.

> Estado: **Fase 1 — Configurando Supabase**. DB lista, falta Edge Functions + secrets.

## Estado actual (Jun 2026)

- ✅ **Repo GitHub**: [jooelmortees/nutricoach-ai](https://github.com/jooelmortees/nutricoach-ai) (privado)
- ✅ **Supabase DB**: proyecto `NutriCoach-DB` (ref `oqkctjzaojyevdxvavaj`, region eu-west-1)
  - 13 tablas creadas con RLS estricto
  - 3 storage buckets (meal-photos, meal-videos privados + avatars público)
  - pgvector habilitado (memoria semántica)
  - Realtime en 4 tablas (messages, meals, health_metrics, scheduled_nudges)
- ✅ **Edge Functions**: código escrito (chat-proxy, hk-sync, mcp-router + 7 MCPs)
- ⏳ **Pendiente**: desplegar Edge Functions, configurar secrets, primer build iOS
- ⏳ **Pendiente de ti**: API key MiniMax, Apple Developer certs, service_role key

## Arquitectura en 30 segundos

```
iPhone (sideloadly)
   ↓ Supabase Swift SDK
Supabase (Postgres + pgvector + Auth + Storage + Edge Functions)
   ↓ HTTPS (proxy seguro)
MiniMax-M3 (cerebro IA con visión, tool use, thinking)
   ↓ MCP
8 MCPs (web_search oficial + 7 custom: nutrition, fitness, wearable, memory, recipes, fasting, user-data)
```

Más detalle en [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Estructura del repo

```
nutricoach-ai/
├── ios/                  # Proyecto Xcode (generable con XcodeGen)
├── backend/              # Edge Functions + migraciones SQL
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
1. Crea un **App ID** en https://developer.apple.com/account con bundle ID `com.nutricoach.app`
2. Habilita los entitlements: HealthKit, Camera, Background Modes
3. Genera un **App Store Connect API Key** (.p8) en https://appstoreconnect.apple.com
4. Mete los valores en GitHub Secrets (ver paso 4)

### 4. Configurar GitHub Secrets
Ve a Settings > Secrets and variables > Actions del repo y crea:
- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`
- `SUPABASE_SERVICE_ROLE_KEY`
- `MINIMAX_API_KEY`
- `APPLE_TEAM_ID`
- `APPLE_KEY_ID`
- `APPLE_ISSUER_ID`
- `APPLE_API_KEY_BASE64` (contenido del .p8 en base64)

Detalle completo en [`docs/SETUP-CREDENTIALS.md`](docs/SETUP-CREDENTIALS.md).

### 5. Generar el proyecto Xcode
```bash
brew install xcodegen   # Si tuvieras Mac, pero no es necesario
```

El proyecto Xcode se genera automáticamente en GitHub Actions. Tú solo descargas el IPA del Actions y lo instalas con sideloadly.

### 6. Instalar la app en tu iPhone
1. Ve a la pestaña **Actions** del repo en GitHub
2. Ejecuta el workflow "Build iOS" manualmente
3. Descarga el artefacto `nutricoach-ipa`
4. Conecta tu iPhone, abre sideloadly, arrastra el IPA + mete tu Apple ID
5. Confía en el certificado en Ajustes > General > VPN y gestión de dispositivos

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
| Auth | Supabase Auth (email + Apple ID) |
| Storage | Supabase Storage |
| Realtime | Supabase Realtime v2 |
| Lógica | Supabase Edge Functions (Deno) |
| IA | MiniMax-M3 (Anthropic SDK compatible) |
| MCP | `minimax-coding-plan-mcp` (oficial) + 7 custom |
| Build | GitHub Actions `macos-15-arm64` |
| Distribución | sideloadly (Apple Developer Program) |

## Licencia

MIT. Ver [`LICENSE`](LICENSE).
