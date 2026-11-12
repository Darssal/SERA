param([string]$Device = '127.0.0.1:16416', [int]$Port = 8787, [switch]$SkipDevice)
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)
$seraMissing = @()
foreach ($name in @('flutter','python','java','adb','node')) {
  if (Get-Command $name -ErrorAction SilentlyContinue) { Write-Host "OK $name" }
  elseif ($name -ne 'adb' -or -not $SkipDevice) { $seraMissing += $name; Write-Host "MISSING $name" }
}
if (Get-Command flutter -ErrorAction SilentlyContinue) { & flutter doctor -v }
$seraPython = Join-Path (Get-Location) 'backend/.venv/Scripts/python.exe'
if (Test-Path -LiteralPath $seraPython) {
  & $seraPython -c "import fastapi,uvicorn,sherpa_onnx,pywebpush; print('Backend dependencies available')"
  if ($LASTEXITCODE -ne 0) { $seraMissing += 'backend dependencies' }
} else { $seraMissing += 'backend venv (run scripts/setup.ps1)' }
$seraFfprobe = if ($env:FFPROBE_PATH) { $env:FFPROBE_PATH } elseif (Get-Command ffprobe -ErrorAction SilentlyContinue) { (Get-Command ffprobe).Source } else { 'D:/development/ffmpeg/ffmpeg-9.0.2-essentials_build/bin/ffprobe.exe' }
if (Test-Path -LiteralPath $seraFfprobe) { & $seraFfprobe -version | Select-Object -First 1 }
else { Write-Host 'Optional cloud file-ASR is unavailable: install FFmpeg/ffprobe and set FFPROBE_PATH. Local streaming ASR does not require it.' }
if (-not $SkipDevice -and (Get-Command adb -ErrorAction SilentlyContinue)) {
  & adb devices -l
  & adb -s $Device get-state
  if ($LASTEXITCODE -ne 0) { $seraMissing += "device $Device" }
}
try {
  $seraHealth = Invoke-RestMethod "http://127.0.0.1:$Port/health/ready" -TimeoutSec 5
  $seraHealth | ConvertTo-Json -Depth 5
} catch { Write-Host "API not ready on $Port. Start scripts/start-fullstack.ps1." }
if ($seraMissing.Count) { throw ('Missing: ' + ($seraMissing -join ', ')) }
Write-Host 'Environment inspection complete. Read component health above before testing.'
