param([int]$Port = 8787, [string]$AiKeyFile = '', [string]$AiModel = '', [switch]$SkipBuild, [string]$DemoDate = '', [string[]]$EnvFile = @())
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)
if (-not $SkipBuild) {
  & flutter pub get
  if ($LASTEXITCODE -ne 0) { throw 'flutter pub get failed' }
  $buildArguments = @('build','web','--release','--no-web-resources-cdn','--dart-define=API_BASE_URL=same-origin')
  if ($DemoDate) { $buildArguments += "--dart-define=DEMO_DATE=$DemoDate" }
  & flutter @buildArguments
  if ($LASTEXITCODE -ne 0) { throw 'Flutter Web build failed' }
}
if (-not (Test-Path -LiteralPath 'build/web/index.html')) { throw 'Web build missing. Run without -SkipBuild first.' }
$seraPython = Join-Path (Get-Location) 'backend/.venv/Scripts/python.exe'
if (-not (Test-Path -LiteralPath $seraPython)) { throw 'Run scripts/setup.ps1 first.' }
& $seraPython web/generate_offline_manifest.py build/web
if ($LASTEXITCODE -ne 0) { throw 'Offline resource manifest generation failed' }
if (-not $AiKeyFile) {
  $candidate = Join-Path (Split-Path (Get-Location).Path -Parent) '硅基流动AI接口api.txt'
  if (Test-Path -LiteralPath $candidate) { $AiKeyFile = $candidate }
}
$serverArguments = @('scripts/serve.py','--host','127.0.0.1','--port',"$Port",'--web-dir','build/web')
if ($AiKeyFile) { $serverArguments += @('--ai-key-file', $AiKeyFile) }
if ($AiModel) { $serverArguments += @('--ai-model', $AiModel) }
foreach ($privateFile in $EnvFile) { $serverArguments += @('--env-file', $privateFile) }
Write-Host "Open http://127.0.0.1:$Port/ in the browser. Stop with Ctrl+C."
& $seraPython @serverArguments
exit $LASTEXITCODE
