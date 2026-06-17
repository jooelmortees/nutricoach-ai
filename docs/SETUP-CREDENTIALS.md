# Dónde meter cada credencial

> Las claves NUNCA van en código del repo. Aquí explico dónde va cada una.

## Resumen rápido

| Credencial | Dónde meterla |
|---|---|
| `SUPABASE_URL` | `.env` local + GitHub Secret `SUPABASE_URL` |
| `SUPABASE_ANON_KEY` | `.env` local + GitHub Secret `SUPABASE_ANON_KEY` + Info.plist de iOS (build) |
| `SUPABASE_SERVICE_ROLE_KEY` | Solo GitHub Secret `SUPABASE_SERVICE_ROLE_KEY` (NUNCA en cliente) |
| `MINIMAX_API_KEY` | Solo GitHub Secret `MINIMAX_API_KEY` (NUNCA en cliente) |
| `APPLE_TEAM_ID` | GitHub Secret + variable |
| `APPLE_KEY_ID` | GitHub Secret |
| `APPLE_ISSUER_ID` | GitHub Secret |
| `APPLE_API_KEY_BASE64` | GitHub Secret (contenido del .p8 en base64) |
| `SUPABASE_ACCESS_TOKEN` | Solo local (para `supabase` CLI) |
| `SUPABASE_PROJECT_REF` | Solo local (para `supabase` CLI) |

## 1. `.env` local (para desarrollo en tu PC)

```bash
# En la raíz del proyecto
cp .env.example .env
# Edita .env con tus valores reales
```

`.env` está en `.gitignore`, NUNCA se commitea.

## 2. GitHub Secrets (para CI/CD)

Ve a https://github.com/your-user/nutricoach-ai/settings/secrets/actions

Pulsa "New repository secret" para cada uno:

| Secret | Ejemplo |
|---|---|
| `SUPABASE_URL` | `https://abcdefgh.supabase.co` |
| `SUPABASE_ANON_KEY` | `eyJ...` |
| `SUPABASE_SERVICE_ROLE_KEY` | `eyJ...` (MUY sensible) |
| `MINIMAX_API_KEY` | `eyJ...` (MUY sensible) |
| `APPLE_TEAM_ID` | `ABCDE12345` (lo ves en developer.apple.com) |
| `APPLE_KEY_ID` | `1234567890` (en App Store Connect > Users > Keys) |
| `APPLE_ISSUER_ID` | `uuid-de-issuer` (en App Store Connect > Users > Keys) |
| `APPLE_API_KEY_BASE64` | `LS0tLS1...` (contenido del .p8 en base64) |
| `SUPABASE_ACCESS_TOKEN` | (para `supabase` CLI desde Actions) |
| `SUPABASE_PROJECT_REF` | (el `ref` de tu proyecto) |
| `USDA_FDC_API_KEY` | (gratis en fdc.nal.usda.gov) |

### Cómo codificar el .p8 en base64 (en Windows PowerShell)

```powershell
[Convert]::ToBase64String([System.IO.File]::ReadAllBytes("C:\ruta\a\AuthKey_XXXXX.p8"))
```

Copia el resultado y pégalo como valor del secret.

## 3. Variables de iOS (Info.plist via XcodeGen)

Para que la app iOS sepa tu `SUPABASE_URL` y `SUPABASE_ANON_KEY` en build time, se inyectan en `ios/Info.plist`. Hay dos opciones:

### Opción A: Hardcoded en `ios/Sources/Resources/Info.plist`
Edita ese archivo y reemplaza los placeholders. Es seguro poner el anon key (es público).

### Opción B: Inyectado en build desde GitHub Secrets (recomendado)

Modifica `.github/workflows/build-ios.yml` para que antes del paso "Generate Xcode project" haga:

```yaml
- name: Inject config
  env:
    SUPABASE_URL: ${{ secrets.SUPABASE_URL }}
    SUPABASE_ANON_KEY: ${{ secrets.SUPABASE_ANON_KEY }}
  run: |
    cd ios
    plutil -replace SUPABASE_URL -string "$SUPABASE_URL" Sources/Resources/Info.plist
    plutil -replace SUPABASE_ANON_KEY -string "$SUPABASE_ANON_KEY" Sources/Resources/Info.plist
```

Y en `project.yml` define esas keys en `info.properties` con valores vacíos por defecto.

Esto es más limpio y no expone nada en el repo. Lo configuramos en la siguiente iteración.

## 4. Variables de Supabase (para Edge Functions)

Las Edge Functions leen variables de entorno con `Deno.env.get()`. Se configuran en:

- **Local**: con `supabase functions serve` o pasándolas en el shell
- **Remoto**: con `supabase secrets set` o desde el dashboard de Supabase

```bash
# Local
supabase functions serve chat-proxy --env-file .env.local

# Remoto
supabase secrets set MINIMAX_API_KEY=eyJ... --project-ref YOUR_REF
```

También las configuramos automáticamente desde GitHub Secrets en el workflow `deploy-functions.yml`.

## Cómo NO exponer claves

✅ **BIEN**:
- Variables de entorno
- GitHub Secrets
- `.env` local (en .gitignore)
- Supabase Secrets

❌ **MAL**:
- Hardcoded en archivos del repo
- En issues de GitHub
- En logs de consola
- En capturas de pantalla
- En chat (como aquí, jeje)

## Auditoría

Antes de cada release importante, ejecutamos:

```bash
# Buscar secrets leaks en el código
git log -p | grep -E "(api[_-]?key|secret|token|password)" -i
```

Y `gitleaks` en CI para prevenir pushes con secrets.
