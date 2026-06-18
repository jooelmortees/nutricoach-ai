# Codemagic — Setup paso a paso

Codemagic es un CI/CD especializado en iOS/Android con **runners macOS dedicados** (sin la cola de GitHub Actions free). Plan free: 500 minutos/mes.

## Paso 1 — Crear cuenta y conectar GitHub

1. Abre https://codemagic.io
2. Click **Sign up with GitHub**
3. Autoriza Codemagic a acceder a tus repos
4. (Opcional pero recomendado) Click en tu avatar → **Teams** → crea un team gratuito personal

## Paso 2 — Añadir el repo NutriCoach

1. En el dashboard, click **Add application**
2. Selecciona **GitHub** como provider
3. Busca `nutricoach-ai` y click **Add repository**
4. Codemagic detecta automáticamente el `codemagic.yaml` que ya está en el repo

## Paso 3 — Configurar Environment Variables y Groups

Ve a tu app → **Environment variables** → crea los grupos y variables:

### Group: `bundle_identifiers` (públicas, no son secretas)

| Variable | Value | Secret |
|---|---|---|
| `APPLE_BUNDLE_ID` | `com.joelmortees.nutricoach` | ❌ No |

### Group: `app_store_connect` (secretas, sensibles)

| Variable | Value | Secret |
|---|---|---|
| `APP_STORE_CONNECT_TEAM_ID` | `9HXVF6WC32` | ✅ Sí |
| `APPLE_KEY_ID` | `NW4KQY9NF2` | ✅ Sí |
| `APPLE_ISSUER_ID` | `d9cdd5e6-6af6-4494-8934-b1689e73f524` | ✅ Sí |
| `APPLE_API_KEY_BASE64` | (el base64 largo de tu `.env`) | ✅ Sí |

## Paso 4 — Configurar Code Signing

1. En tu app de Codemagic, ve a **Code signing identities**
2. Click **Apple Developer Portal** → conectar
3. Pega:
   - **Team ID**: `9HXVF6WC32`
   - **Key ID**: `NW4KQY9NF2`
   - **Issuer ID**: `d9cdd5e6-6af6-4494-8934-b1689e73f524`
   - **API Key (.p8)**: sube el archivo `AuthKey_NW4KQY9NF2.p8` desde tu PC
4. Codemagic se conecta a Apple y descarga tus certificados

⚠️ Si ya borraste el .p8, tendrás que:
- Volver a https://appstoreconnect.apple.com/access/api
- **Revocar** la key anterior (porque solo se puede descargar una vez)
- Crear una nueva key con el mismo nombre
- Volver a codificarla con `.\configure-apple.ps1`

## Paso 5 — Disparar el primer build

1. Ve a tu app → click **Start new build**
2. Selecciona workflow **`ios-debug`** (más rápido, solo compila sin firma)
3. Click **Start build**
4. Espera 3-5 minutos (vs 2+ horas de GitHub Actions)

Cuando termine:
- Click en el artifact **`NutriCoach-Debug-unsigned.ipa`**
- Descárgalo a tu PC
- Instálalo con sideloadly/AltStore

## Workflows definidos

| Workflow | Cuándo se ejecuta | Qué hace | Output |
|---|---|---|---|
| `ios-debug` | Push/PR a main o feat/* | Compila sin firmar (valida que el código está OK) | `NutriCoach-Debug-unsigned.ipa` |
| `ios-signed` | Push a main o manual | Compila Y firma con tu Apple Developer | `NutriCoach-Release.ipa` (instalable con sideloadly) |

Para uso diario, **`ios-signed`** es el que necesitas.

## Renovar la app cada 7 días

Como la app está firmada con tu Apple ID personal, caduca a los 7 días. Opciones:

1. **AltStore** (gratis, recomendado) → re-firma automático
2. **Reinstalar manualmente** cada semana con sideloadly
3. **Workflow manual** → disparas `ios-signed` cada semana y re-instalas

## Troubleshooting

Si un build falla:
- Click en el build fallido
- Revisa los logs (especialmente `Build (Debug, no signing)`)
- Si es error de compilación Swift, me lo pasas y lo arreglo
- Si es error de code signing, revisa que el .p8 esté bien subido en Code signing identities
