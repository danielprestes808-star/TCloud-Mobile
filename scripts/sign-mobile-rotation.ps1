param(
  [string]$ApkPath = "",
  [string]$OutputPath = ""
)

$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent

if ([string]::IsNullOrWhiteSpace($ApkPath)) {
  $ApkPath = Join-Path $root "build\app\outputs\flutter-apk\app-release.apk"
}
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
  $OutputPath = Join-Path $root "build\app\outputs\flutter-apk\app-release-compatible.apk"
}
if (-not (Test-Path -LiteralPath $ApkPath -PathType Leaf)) {
  throw "APK nao encontrado: $ApkPath"
}

$local = @{}
Get-Content (Join-Path $root "android\local.properties") | ForEach-Object {
  $line = $_.Trim()
  if ($line -and -not $line.StartsWith("#") -and $line.Contains("=")) {
    $parts = $line.Split("=", 2)
    $local[$parts[0].Trim()] = $parts[1].Trim()
  }
}

$keystore = @{}
Get-Content (Join-Path $root "android\key.properties") | ForEach-Object {
  $line = $_.Trim()
  if ($line -and -not $line.StartsWith("#") -and $line.Contains("=")) {
    $parts = $line.Split("=", 2)
    $keystore[$parts[0].Trim()] = $parts[1].Trim()
  }
}

$sdk = ([string]$local["sdk.dir"]).Replace("\\", "\")
$buildTools = Get-ChildItem (Join-Path $sdk "build-tools") -Directory |
  Sort-Object { [version]$_.Name } -Descending |
  Select-Object -First 1
$apksigner = Join-Path $buildTools.FullName "apksigner.bat"

$releaseStore = [string]$keystore["storeFile"]
if (-not [IO.Path]::IsPathRooted($releaseStore)) {
  $releaseStore = [IO.Path]::GetFullPath(
    (Join-Path (Join-Path $root "android\app") $releaseStore)
  )
}

$debugStore = Join-Path $env:USERPROFILE ".android\debug.keystore"
$lineage = Join-Path $root "release\tcloud-mobile-signing-lineage.bin"

$env:TCLOUD_RELEASE_STORE_PASS = [string]$keystore["storePassword"]
$env:TCLOUD_RELEASE_KEY_PASS = [string]$keystore["keyPassword"]
$env:TCLOUD_DEBUG_STORE_PASS = "android"
$env:TCLOUD_DEBUG_KEY_PASS = "android"

try {
  if (-not (Test-Path -LiteralPath $lineage -PathType Leaf)) {
    & $apksigner rotate --out $lineage `
      --old-signer --ks $debugStore --ks-key-alias androiddebugkey `
      --ks-pass env:TCLOUD_DEBUG_STORE_PASS `
      --key-pass env:TCLOUD_DEBUG_KEY_PASS `
      --set-installed-data true --set-shared-uid true `
      --set-permission true --set-rollback false --set-auth true `
      --new-signer --ks $releaseStore `
      --ks-key-alias ([string]$keystore["keyAlias"]) `
      --ks-pass env:TCLOUD_RELEASE_STORE_PASS `
      --key-pass env:TCLOUD_RELEASE_KEY_PASS
    if ($LASTEXITCODE -ne 0) { throw "Falha ao criar a linhagem." }
  }

  & $apksigner sign --out $OutputPath --lineage $lineage `
    --rotation-min-sdk-version 28 --v3-signing-enabled true `
    --v4-signing-enabled false `
    --ks $debugStore --ks-key-alias androiddebugkey `
    --ks-pass env:TCLOUD_DEBUG_STORE_PASS `
    --key-pass env:TCLOUD_DEBUG_KEY_PASS `
    --next-signer --ks $releaseStore `
    --ks-key-alias ([string]$keystore["keyAlias"]) `
    --ks-pass env:TCLOUD_RELEASE_STORE_PASS `
    --key-pass env:TCLOUD_RELEASE_KEY_PASS $ApkPath
  if ($LASTEXITCODE -ne 0) { throw "Falha ao assinar o APK compativel." }

  & $apksigner verify --verbose $OutputPath
  if ($LASTEXITCODE -ne 0) { throw "A verificacao da assinatura falhou." }
  Write-Host "APK compativel pronto: $OutputPath" -ForegroundColor Green
} finally {
  $env:TCLOUD_RELEASE_STORE_PASS = $null
  $env:TCLOUD_RELEASE_KEY_PASS = $null
  $env:TCLOUD_DEBUG_STORE_PASS = $null
  $env:TCLOUD_DEBUG_KEY_PASS = $null
}
