param([string]$Device = '', [string]$ApiBaseUrl = 'http://127.0.0.1:8787', [switch]$LocalOnly)
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)
$arguments = @('run')
if ($Device) { $arguments += @('-d',$Device) }
if ($LocalOnly) { $arguments += '--dart-define=API_BASE_URL=' }
if (-not $LocalOnly) {
  $adb = if ($env:ANDROID_HOME) { Join-Path $env:ANDROID_HOME 'platform-tools/adb.exe' } else { 'adb' }
  if ($ApiBaseUrl -match '^http://(127\.0\.0\.1|localhost):8787/?$') {
    if ($Device) { & $adb -s $Device reverse tcp:8787 tcp:8787 } else { & $adb reverse tcp:8787 tcp:8787 }
    if ($Device) { & $adb -s $Device reverse tcp:8790 tcp:8790 } else { & $adb reverse tcp:8790 tcp:8790 }
    if ($LASTEXITCODE -ne 0) { throw 'ADB reverse failed; select one device with -Device, or set an accessible -ApiBaseUrl.' }
  }
  $arguments += "--dart-define=API_BASE_URL=$ApiBaseUrl"
}
& flutter @arguments
exit $LASTEXITCODE
