# ============================================================
# configure-apple.ps1
# Automatiza la codificación del .p8 a base64 y rellena el .env
# Ejecutar DESPUÉS de generar el App ID y la API Key en
# developer.apple.com y appstoreconnect.apple.com
# ============================================================

param(
    [string]$P8Path = "",
    [switch]$Help = $false
)

$ErrorActionPreference = "Stop"
$ProjectRoot = $PSScriptRoot
$EnvFile = "$ProjectRoot\.env"

if ($Help) {
    Write-Host @"
Uso: .\configure-apple.ps1 [-P8Path <ruta-al-p8>]

Si no pasas -P8Path, el script te preguntará interactivamente.

Pasos previos que TIENES que haber hecho:
  1. Crear App ID 'com.nutricoach.app' en developer.apple.com
  2. Generar API Key (.p8) en appstoreconnect.apple.com/access/api

Este script:
  - Codifica el .p8 a base64
  - Te pregunta Team ID, Key ID, Issuer ID
  - Actualiza tu .env con los 4 valores
  - NO los imprime en pantalla
"@
    exit 0
}

Write-Host "=== Configurador Apple Developer ===" -ForegroundColor Green
Write-Host ""

# Verificar .env
if (-not (Test-Path $EnvFile)) {
    Write-Host "ERROR: no existe $EnvFile" -ForegroundColor Red
    Write-Host "Crea el .env desde .env.example primero" -ForegroundColor Red
    exit 1
}

# Preguntar ruta del .p8 si no se pasó
if ([string]::IsNullOrWhiteSpace($P8Path)) {
    Write-Host "Arrastra el archivo .p8 a esta ventana o pega su ruta completa." -ForegroundColor Cyan
    Write-Host "Si lo descargaste de Safari/Chrome, suele estar en: $env:USERPROFILE\Downloads\`n" -ForegroundColor Gray
    $P8Path = Read-Host "Ruta al .p8"
    $P8Path = $P8Path.Trim('"').Trim("'")
}

if (-not (Test-Path $P8Path)) {
    Write-Host "ERROR: no existe el archivo: $P8Path" -ForegroundColor Red
    exit 1
}

# Preguntar los 3 IDs
Write-Host ""
Write-Host "Necesito 3 datos que están en tu cuenta de Apple:" -ForegroundColor Cyan
Write-Host "  - Team ID: aparece arriba a la derecha en developer.apple.com (10 caracteres)" -ForegroundColor Gray
Write-Host "  - Key ID: aparece junto al nombre de la API Key que generaste" -ForegroundColor Gray
Write-Host "  - Issuer ID: aparece en App Store Connect > Users > Keys (es un UUID)" -ForegroundColor Gray
Write-Host ""

$teamId = Read-Host "Team ID (ej: 9HXVF6WC32)"
$keyId = Read-Host "Key ID (10 chars alfanuméricos)"
$issuerId = Read-Host "Issuer ID (UUID formato xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)"

# Validaciones básicas
if ($teamId -notmatch "^[A-Z0-9]{10}$") {
    Write-Host "AVISO: Team ID no parece válido (esperaba 10 chars A-Z0-9)" -ForegroundColor Yellow
    $confirm = Read-Host "¿Continuar? (s/n)"
    if ($confirm -ne "s") { exit 1 }
}

if ($keyId -notmatch "^[A-Z0-9]{10}$") {
    Write-Host "AVISO: Key ID no parece válido (esperaba 10 chars A-Z0-9)" -ForegroundColor Yellow
    $confirm = Read-Host "¿Continuar? (s/n)"
    if ($confirm -ne "s") { exit 1 }
}

if ($issuerId -notmatch "^[a-f0-9-]{36}$") {
    Write-Host "AVISO: Issuer ID no parece un UUID válido" -ForegroundColor Yellow
    $confirm = Read-Host "¿Continuar? (s/n)"
    if ($confirm -ne "s") { exit 1 }
}

# Codificar .p8 a base64
Write-Host ""
Write-Host "Codificando .p8 a base64..." -NoNewline
try {
    $bytes = [System.IO.File]::ReadAllBytes($P8Path)
    $base64 = [Convert]::ToBase64String($bytes)
    Write-Host " OK" -ForegroundColor Green
} catch {
    Write-Host " ERROR" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

# Verificar que el base64 empieza con lo esperado (BEGIN PRIVATE KEY)
$decoded = [System.Text.Encoding]::UTF8.GetString($bytes)
if ($decoded -notmatch "BEGIN PRIVATE KEY") {
    Write-Host "AVISO: el .p8 no parece un archivo de clave privada PEM válido" -ForegroundColor Yellow
    $confirm = Read-Host "¿Continuar de todas formas? (s/n)"
    if ($confirm -ne "s") { exit 1 }
}

# Actualizar .env
Write-Host "Actualizando .env..." -NoNewline
$envContent = Get-Content $EnvFile -Raw

# Reemplazar los placeholders
$envContent = $envContent -replace "APPLE_TEAM_ID=<.*>", "APPLE_TEAM_ID=$teamId"
$envContent = $envContent -replace "APPLE_KEY_ID=<.*>", "APPLE_KEY_ID=$keyId"
$envContent = $envContent -replace "APPLE_ISSUER_ID=<.*>", "APPLE_ISSUER_ID=$issuerId"
$envContent = $envContent -replace "APPLE_API_KEY_BASE64=<.*>", "APPLE_API_KEY_BASE64=$base64"

Set-Content -Path $EnvFile -Value $envContent -NoNewline -Encoding UTF8
Write-Host " OK" -ForegroundColor Green

# Aplicar permisos owner-only
Write-Host "Asegurando permisos owner-only en .env..." -NoNewline
$u = $env:USERNAME
& icacls $EnvFile /inheritance:r /grant "${u}:F" 2>$null | Out-Null
Write-Host " OK" -ForegroundColor Green

Write-Host ""
Write-Host "=== Listo ===" -ForegroundColor Green
Write-Host ""
Write-Host "Configurado en .env (no se imprime por seguridad):" -ForegroundColor Cyan
Write-Host "  APPLE_TEAM_ID        = $teamId" -ForegroundColor Gray
Write-Host "  APPLE_KEY_ID         = $keyId" -ForegroundColor Gray
Write-Host "  APPLE_ISSUER_ID      = $issuerId" -ForegroundColor Gray
Write-Host "  APPLE_API_KEY_BASE64 = [$(($base64.Length)) chars]" -ForegroundColor Gray
Write-Host ""
Write-Host "Borra el .p8 de tu carpeta de Descargas después de esto (no lo necesitamos)." -ForegroundColor Yellow
Write-Host "Próximo paso: mete estos 4 valores en GitHub Secrets también." -ForegroundColor Cyan
Write-Host ""
