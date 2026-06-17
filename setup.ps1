# ============================================================
# setup.ps1 - Script de setup para Windows
# Ejecutar UNA VEZ después de clonar el repo.
# Automatiza la mayor parte de la configuración local.
# ============================================================

param(
    [switch]$SkipSupabase = $false,
    [switch]$SkipFunctions = $false,
    [switch]$Help = $false
)

$ErrorActionPreference = "Stop"
$ProjectRoot = $PSScriptRoot

if ($Help) {
    Write-Host @"
Uso: .\setup.ps1 [-SkipSupabase] [-SkipFunctions]

Este script automatiza:
  1. Verifica .env
  2. (Opcional) Linkea y aplica migraciones a Supabase
  3. (Opcional) Despliega Edge Functions
  4. Verifica que los secrets críticos estén en .env
  5. Crea .gitignore seguro
"@
    exit 0
}

Write-Host "=== NutriCoach AI - Setup ===" -ForegroundColor Green
Write-Host ""

# 1. Verificar Node
Write-Host "[1/5] Verificando Node..." -NoNewline
$nodeVersion = node --version
if ($LASTEXITCODE -ne 0) {
    Write-Host " FAIL" -ForegroundColor Red
    Write-Host "Node no instalado. Instálalo desde https://nodejs.org" -ForegroundColor Red
    exit 1
}
Write-Host " OK ($nodeVersion)" -ForegroundColor Green

# 2. Verificar .env
Write-Host "[2/5] Verificando .env..." -NoNewline
if (-not (Test-Path "$ProjectRoot\.env")) {
    Write-Host " MISSING" -ForegroundColor Yellow
    if (Test-Path "$ProjectRoot\.env.example") {
        Copy-Item "$ProjectRoot\.env.example" "$ProjectRoot\.env"
        Write-Host " (copiado de .env.example)" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "⚠️  IMPORTANTE: rellena las claves en .env antes de continuar" -ForegroundColor Yellow
        Write-Host "   - SUPABASE_SERVICE_ROLE_KEY (dashboard Supabase)" -ForegroundColor Yellow
        Write-Host "   - MINIMAX_API_KEY (platform.minimax.io)" -ForegroundColor Yellow
        Write-Host "   - APPLE_* (developer.apple.com)" -ForegroundColor Yellow
        Write-Host ""
        $continue = Read-Host "Pulsa Enter para continuar o Ctrl+C para salir"
    } else {
        Write-Host " FAIL" -ForegroundColor Red
        Write-Host "No existe .env ni .env.example" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host " OK" -ForegroundColor Green
}

# 3. Validar que los secrets críticos no estén vacíos
Write-Host "[3/5] Validando secrets críticos..." -NoNewline
$envContent = Get-Content "$ProjectRoot\.env" -Raw
$missing = @()
if ($envContent -match "SUPABASE_SERVICE_ROLE_KEY=\s*$|<") { $missing += "SUPABASE_SERVICE_ROLE_KEY" }
if ($envContent -match "MINIMAX_API_KEY=\s*$|<") { $missing += "MINIMAX_API_KEY" }
if ($envContent -match "APPLE_TEAM_ID=\s*$|<") { $missing += "APPLE_TEAM_ID" }
if ($missing.Count -gt 0) {
    Write-Host " INCOMPLETO" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Faltan en .env:" -ForegroundColor Yellow
    $missing | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    Write-Host ""
    $continue = Read-Host "Pulsa Enter para continuar o Ctrl+C para salir"
} else {
    Write-Host " OK" -ForegroundColor Green
}

# 4. Permisos estrictos en .env
Write-Host "[4/5] Asegurando permisos owner-only en .env..." -NoNewline
$u = $env:USERNAME
& icacls "$ProjectRoot\.env" /inheritance:r /grant "${u}:F" 2>$null | Out-Null
Write-Host " OK" -ForegroundColor Green

# 5. Supabase (opcional)
if (-not $SkipSupabase) {
    $doSupabase = Read-Host "[5/5] ¿Quieres aplicar migraciones y desplegar Edge Functions ahora? (s/n)"
    if ($doSupabase -eq "s") {
        Write-Host ""
        Write-Host "Verificando Supabase CLI..." -NoNewline
        $supabaseCmd = Get-Command supabase -ErrorAction SilentlyContinue
        if (-not $supabaseCmd) {
            Write-Host " INSTALAR" -ForegroundColor Yellow
            Write-Host "Instalando Supabase CLI..." -ForegroundColor Cyan
            npm install -g supabase
        } else {
            Write-Host " OK" -ForegroundColor Green
        }

        Write-Host ""
        Write-Host "Login en Supabase..." -ForegroundColor Cyan
        supabase login

        $projectRef = Read-Host "Project ref de NutriCoach-DB (ej: oqkctjzaojyevdxvavaj)"
        Write-Host ""
        Write-Host "Linkeando proyecto..." -ForegroundColor Cyan
        supabase link --project-ref $projectRef

        Write-Host ""
        Write-Host "Aplicando migraciones..." -ForegroundColor Cyan
        supabase db push

        if (-not $SkipFunctions) {
            Write-Host ""
            Write-Host "Desplegando Edge Functions..." -ForegroundColor Cyan
            supabase functions deploy chat-proxy
            supabase functions deploy hk-sync
            supabase functions deploy mcp-router

            Write-Host ""
            Write-Host "Configurando secrets de Edge Functions..." -ForegroundColor Cyan
            $minimaxKey = (Get-Content "$ProjectRoot\.env" | Select-String "MINIMAX_API_KEY=(.+)" | ForEach-Object { $_.Matches[0].Groups[1].Value })
            $usdaKey = (Get-Content "$ProjectRoot\.env" | Select-String "USDA_FDC_API_KEY=(.+)" | ForEach-Object { $_.Matches[0].Groups[1].Value })
            if ($minimaxKey -and $minimaxKey -notmatch "^<") {
                supabase secrets set MINIMAX_API_KEY=$minimaxKey --project-ref $projectRef
            }
            if ($usdaKey -and $usdaKey -ne "<copiar>") {
                supabase secrets set USDA_FDC_API_KEY=$usdaKey --project-ref $projectRef
            }
        }
    }
}

Write-Host ""
Write-Host "=== Setup completado ===" -ForegroundColor Green
Write-Host ""
Write-Host "Próximos pasos:" -ForegroundColor Cyan
Write-Host "  1. Configura los GitHub Secrets restantes (ver docs/SETUP-CREDENTIALS.md)"
Write-Host "  2. Ve a https://github.com/jooelmortees/nutricoach-ai/actions/workflows/build-ios.yml"
Write-Host "  3. Lanza 'Build iOS' manualmente"
Write-Host "  4. Descarga el .ipa y instala con sideloadly/AltStore"
Write-Host ""
