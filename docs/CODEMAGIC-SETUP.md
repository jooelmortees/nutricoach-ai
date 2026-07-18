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

### Group: `Supabase`

| Variable | Value | Secret |
|---|---|---|
| `SUPABASE_URL` | URL del proyecto | ❌ No |
| `SUPABASE_ANON_KEY` | Clave pública `anon` | ✅ Sí |

## Paso 4 — Configurar Code Signing

1. En tu app de Codemagic, ve a **Code signing identities**
2. Conecta **Apple Developer Portal** con una App Store Connect API key.
3. En **iOS certificates**, genera o sube un certificado **Apple Development** que incluya su clave privada.
4. En **iOS provisioning profiles**, sube los perfiles de la app y de la extensión descritos abajo.

La API key `.p8` permite consultar el portal, pero no sustituye al certificado de firma con clave privada.

### Capacidades y perfil del widget

El widget necesita una extensión firmada aparte y dos capacidades compartidas:

1. En Apple Developer crea el App Group `group.com.joelmortees.nutricoach`.
2. En el App ID `com.joelmortees.nutricoach`, activa **App Groups**, **HealthKit**, **Sign in with Apple** y **Push Notifications**. Keychain Sharing se declara en los entitlements del target, no como un identificador descargable del portal.
3. Crea el App ID explícito `com.joelmortees.nutricoach.widgets` y asígnale el mismo **App Group**.
4. Regenera el provisioning profile de la app y crea otro para la extensión.
5. Sube ambos perfiles a **Code signing identities > iOS provisioning profiles** en Codemagic.

Codemagic obtiene el perfil principal y los perfiles `com.joelmortees.nutricoach.*` al usar el bundle ID base. Si falta el perfil de la extensión, el código compilará sin firma pero el IPA firmado no se podrá generar.

⚠️ Si ya borraste el .p8, tendrás que:
- Volver a https://appstoreconnect.apple.com/access/api
- **Revocar** la key anterior (porque solo se puede descargar una vez)
- Crear una nueva key con el mismo nombre
- Volver a codificarla con `.\configure-apple.ps1`

## Paso 5 — Disparar el primer build

1. Ve a tu app → click **Start new build**
2. Selecciona workflow **`ios-debug`** (compilación Debug con firma de desarrollo)
3. Click **Start build**
4. Espera 3-5 minutos (vs 2+ horas de GitHub Actions)

Cuando termine:
- Click en el artifact **`NutriCoach-Debug.ipa`**
- Descárgalo a tu PC
- Instálalo con FleckStore usando el certificado propio de NutriCoach

## Workflows definidos

| Workflow | Cuándo se ejecuta | Qué hace | Output |
|---|---|---|---|
| `ios-debug` | Push a main, feat/* o test/* | Compila Debug, firma la app y verifica que la extensión esté embebida | `NutriCoach-Debug.ipa` |
| `ios-signed` | Push a main o manual | Compila y firma con tu Apple Developer | `NutriCoach-Release.ipa` (para instalar mediante FleckStore) |

Para uso diario, **`ios-signed`** es el que necesitas.

La instalación en el iPhone de desarrollo se hace mediante **FleckStore con el certificado propio de NutriCoach**. FleckStore debe conservar la firma separada de la app y `NutriCoachWidgets.appex`, además de los entitlements de Sign in with Apple, App Groups y Keychain Sharing. Si vuelve a firmar el IPA sin ellos, Apple Sign In y la comunicación con el widget fallarán aunque el build de Codemagic sea correcto.

## Renovar la app cada 7 días

Un perfil Development del Apple Developer Program mantiene la validez indicada por el propio perfil. El plazo de 7 días solo aplica si Sideloadly o AltStore vuelve a firmar el IPA con un Apple ID gratuito; esa re-firma también puede limitar capabilities como App Groups, HealthKit o Keychain Sharing.

Opciones para una re-firma gratuita:

1. **AltStore** (gratis, recomendado) → re-firma automático
2. **Reinstalar manualmente** cada semana con sideloadly
3. **Workflow manual** → generas de nuevo el IPA y dejas que Sideloadly lo vuelva a firmar

## Troubleshooting

Si un build falla:
- Click en el build fallido
- Revisa los logs (especialmente `Build (Debug, signed)`)
- Si es error de compilación Swift, me lo pasas y lo arreglo
- Si es error de code signing, revisa el certificado con clave privada y los dos provisioning profiles en Code signing identities
