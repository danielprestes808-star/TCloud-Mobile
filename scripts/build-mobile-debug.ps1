$ErrorActionPreference = "Stop"

$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

$propsPath = Join-Path $root "android\local.properties"

if (-not (Test-Path $propsPath)) {
    throw "android\local.properties nao encontrado."
}

$props = @{}

Get-Content $propsPath | ForEach-Object {

    $line = $_.Trim()

    if (
        $line.Length -gt 0 -and
        -not $line.StartsWith("#") -and
        $line.Contains("=")
    ) {
        $parts = $line.Split("=", 2)
        $props[$parts[0].Trim()] = $parts[1].Trim()
    }
}

$apiId = $props["tcloud.telegram.api_id"]
$apiHash = $props["tcloud.telegram.api_hash"]

if ([string]::IsNullOrWhiteSpace($apiId)) {
    throw "Telegram API ID nao configurado."
}

if ([string]::IsNullOrWhiteSpace($apiHash)) {
    throw "Telegram API Hash nao configurado."
}

Write-Host "==============================================" -ForegroundColor Cyan
Write-Host " TCLOUD MOBILE - BUILD COM TELEGRAM" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan

Write-Host "[OK] API ID carregado." -ForegroundColor Green
Write-Host "[OK] API Hash carregado (valor oculto)." -ForegroundColor Green

flutter build apk --debug `
    "--dart-define=TCLOUD_TELEGRAM_API_ID=$apiId" `
    "--dart-define=TCLOUD_TELEGRAM_API_HASH=$apiHash"

if ($LASTEXITCODE -ne 0) {
    throw "Build falhou."
}

$apk = Join-Path `
    $root `
    "build\app\outputs\flutter-apk\app-debug.apk"

if (-not (Test-Path $apk)) {
    throw "APK nao encontrado."
}

Write-Host ""
Write-Host "[OK] APK pronto:" -ForegroundColor Green
Write-Host $apk