# Dónde meter cada credencial

> Las claves NUNCA van en código del repo. Aquí explico dónde va cada una.

## Resumen rápido

| Credencial | Dónde meterla |
|---|---|
| `SUPABASE_URL` | `.env` local + GitHub Secret `SUPABASE_URL` |
| `SUPABASE_ANON_KEY` | `.env` local + GitHub Secret `SUPABASE_ANON_KEY` + Info.plist de iOS (build) |
| `SUPABASE_SERVICE_ROLE_KEY` | Solo GitHub Secret `SUPABASE_SERVICE_ROLE_KEY` (NUNCA en cliente) |
| `GEMINI_API_KEY` | Solo GitHub Secret `GEMINI_API_KEY` (NUNCA en cliente) |
| Certificado y perfiles Apple | Codemagic Code signing identities |
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
| `GEMINI_API_KEY` | `AIza...` (sensible) |
| `SUPABASE_ACCESS_TOKEN` | (para `supabase` CLI desde Actions) |
| `SUPABASE_PROJECT_REF` | (el `ref` de tu proyecto) |
| `USDA_FDC_API_KEY` | (gratis en fdc.nal.usda.gov) |

## 3. Variables de iOS (Info.plist via XcodeGen)

La app y la extensión reciben `SUPABASE_URL` y `SUPABASE_ANON_KEY` como build settings. GitHub Actions ya los pasa desde GitHub Secrets:

```yaml
- name: Inject config
  env:
    SUPABASE_URL: ${{ secrets.SUPABASE_URL }}
    SUPABASE_ANON_KEY: ${{ secrets.SUPABASE_ANON_KEY }}
  run: xcodebuild ... SUPABASE_URL="$SUPABASE_URL" SUPABASE_ANON_KEY="$SUPABASE_ANON_KEY" build
```

Codemagic usa las mismas variables desde el grupo `Supabase`. `ios/project.yml` las expande en los dos `Info.plist` durante la compilación.

## 4. Variables de Supabase (para Edge Functions)

Las Edge Functions leen variables de entorno con `Deno.env.get()`. Se configuran en:

- **Local**: con `supabase functions serve` o pasándolas en el shell
- **Remoto**: con `supabase secrets set` o desde el dashboard de Supabase

```bash
# Local
supabase functions serve chat-proxy --env-file .env.local

# Remoto
supabase secrets set GEMINI_API_KEY=AIza... --project-ref YOUR_REF
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
