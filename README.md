# NutriCoach AI

A native iOS app with an AI dietitian-nutritionist agent powered by **Gemini 3.5 Flash** — connected to Apple HealthKit, with persistent memory, on-device meal photo analysis, and specialised MCP servers for nutrition, fitness and health.

> 🍎 Currently in active development — App Store release coming soon.

## What it does

NutriCoach AI is a personal nutrition coach that lives on your iPhone:

- **Chat with an AI dietitian** — ask anything about nutrition, log meals in natural language, or send voice notes. The agent understands context and remembers you.
- **Snap your meals** — take a photo and the AI estimates macros and calories with native vision.
- **HealthKit sync** — weight, activity, sleep and more flow in automatically and feed the agent's recommendations.
- **Macro dashboard + iOS widgets** — daily calories, protein, carbs and fat at a glance, on the home screen and lock screen.
- **AI-generated meal plans** — personalised weekly plans built around your goals and preferences.
- **Persistent memory** — the agent remembers your habits, restrictions and progress across sessions.

## Architecture

```
iPhone (SwiftUI)
   ↓ Supabase Swift SDK
Supabase (Postgres + pgvector + Auth + Storage + Edge Functions)
   ↓ HTTPS (secure proxy)
Gemini 3.5 Flash (AI brain: vision, tool use, reasoning)
   ↓ MCP
Specialised MCPs (web search + custom: nutrition, fitness, wearable, memory, recipes, fasting, user data)
```

Full technical detail: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Tech stack

| Layer | Technology |
|---|---|
| iOS | Swift 5.9, SwiftUI, HealthKit, AVFoundation |
| Widgets | WidgetKit (macros + water tracking widgets) |
| Database | Supabase Postgres + pgvector |
| Auth | Supabase Auth (email + Google OAuth with PKCE) |
| Storage | Supabase Storage |
| Realtime | Supabase Realtime v2 |
| Server logic | Supabase Edge Functions (Deno) |
| AI | Gemini 3.5 Flash (OpenAI-compatible endpoint) |
| MCP | Web search + custom MCP servers |
| CI | GitHub Actions (`macos-15-arm64`), signed builds with Codemagic |
| Project generation | XcodeGen |

## Project structure

```
nutricoach-ai/
├── ios/                  # Native iOS app (SwiftUI, generated with XcodeGen)
│   ├── Sources/Features  # Auth, Camera, Chat, Dashboard, Macros, Onboarding, Plans, Settings
│   ├── Sources/Services  # AgentService, HealthKitManager, SupabaseClient, …
│   └── WidgetExtension/  # Home-screen widgets
├── supabase/
│   ├── functions/        # Edge Functions: chat-proxy, hk-sync, mcp-router, generate-plan, …
│   └── migrations/       # Versioned SQL schema
├── docs/                 # Architecture, agent system prompt, setup guides
├── .github/workflows/    # iOS build + functions deploy + DB migrations
└── .env.example          # Environment template
```

## Getting started

> You need a Mac with Xcode for iOS development, a Supabase project and a Gemini API key.

### 1. Clone and configure

```bash
git clone https://github.com/jooelmortees/nutricoach-ai.git
cd nutricoach-ai
cp .env.example .env
# Fill in .env with your keys (see docs/SETUP-CREDENTIALS.md)
```

### 2. Set up Supabase

```bash
npm install -g supabase
supabase login
supabase link --project-ref YOUR_PROJECT_REF
supabase db push                      # apply migrations
supabase functions deploy chat-proxy
supabase functions deploy hk-sync
supabase functions deploy mcp-router
```

### 3. Apple Developer setup

1. Create an **App ID** at [developer.apple.com](https://developer.apple.com/account) with bundle ID `com.joelmortees.nutricoach`
2. Add the widget App ID `com.joelmortees.nutricoach.widgets` and a shared App Group
3. Configure signing as described in [`docs/CODEMAGIC-SETUP.md`](docs/CODEMAGIC-SETUP.md)

### 4. Generate the Xcode project and build

```bash
brew install xcodegen
xcodegen generate --spec ios/project.yml
```

CI builds an unsigned IPA on every push (GitHub Actions); signed release builds run on Codemagic.

## Documentation

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — detailed technical decisions
- [`docs/AGENT-SYSTEM-PROMPT.md`](docs/AGENT-SYSTEM-PROMPT.md) — the dietitian agent's system prompt
- [`docs/TOOLS.md`](docs/TOOLS.md) — every tool the agent can call
- [`docs/SETUP-CREDENTIALS.md`](docs/SETUP-CREDENTIALS.md) — where each key and secret goes

## License

Proprietary, source-available. See [`LICENSE`](LICENSE).
