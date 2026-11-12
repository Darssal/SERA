param([switch]$SkipModel, [switch]$SkipSigning)
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)
& flutter pub get
if ($LASTEXITCODE -ne 0) { throw 'Flutter dependencies failed' }
$seraPython = Join-Path (Get-Location) 'backend/.venv/Scripts/python.exe'
if (-not (Test-Path -LiteralPath $seraPython)) { & python -m venv backend/.venv }
& $seraPython -m pip install --index-url https://pypi.org/simple -r backend/requirements.txt -c backend/requirements.lock.txt
if ($LASTEXITCODE -ne 0) { throw 'Backend dependencies failed' }
if (-not $SkipModel) {
  & $seraPython backend/download_asr_model.py
  if ($LASTEXITCODE -ne 0) { throw 'Streaming model setup failed' }
}
if (-not $SkipSigning) {
  & $seraPython scripts/generate-signing.py
  if ($LASTEXITCODE -ne 0) { throw 'Signing setup failed' }
}
Write-Host 'Setup complete. Run scripts/start-fullstack.ps1, then scripts/run-android.ps1 -Device 127.0.0.1:16416.'
