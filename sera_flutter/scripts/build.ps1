param([ValidateSet('web','apk','aab','all')][string]$Target = 'web', [string]$AndroidApiBaseUrl = 'http://127.0.0.1:8787', [switch]$Debug, [switch]$HideReview)
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)
$common = @()
if ($HideReview) { $common += '--dart-define=ENABLE_REVIEW=false' }
if ($Target -in @('web','all')) {
  & flutter build web --release --no-web-resources-cdn --dart-define=API_BASE_URL=same-origin @common
  if ($LASTEXITCODE -ne 0) { throw 'Web build failed' }
  $seraPython = Join-Path (Get-Location) 'backend/.venv/Scripts/python.exe'
  if (-not (Test-Path -LiteralPath $seraPython)) { throw 'Run scripts/setup.ps1 first.' }
  & $seraPython web/generate_offline_manifest.py build/web
  if ($LASTEXITCODE -ne 0) { throw 'Offline resource manifest generation failed' }
}
if ($Target -in @('apk','aab','all')) {
  if (-not $Debug -and -not (Test-Path -LiteralPath '.local/signing/key.properties') -and -not $env:SERA_SIGNING_PROPERTIES) { throw 'Run scripts/generate-signing.py or supply SERA_SIGNING_PROPERTIES. Release requires its own signing key.' }
  $artifacts = if ($Target -eq 'all') { @('apk','appbundle') } elseif ($Target -eq 'aab') { @('appbundle') } else { @('apk') }
  foreach ($artifact in $artifacts) {
    $arguments = @('build',$artifact)
    $arguments += if ($Debug) { '--debug' } else { '--release' }
    $arguments += $common
    $arguments += "--dart-define=API_BASE_URL=$AndroidApiBaseUrl"
    & flutter @arguments
    if ($LASTEXITCODE -ne 0) { throw "$artifact build failed" }
  }
}
