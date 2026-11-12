param([string]$ApiBaseUrl = 'http://127.0.0.1:8787', [switch]$LocalOnly, [string]$DemoDate = '')
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)
$arguments = @('run', '-d', 'chrome', '--web-port=4181')
if ($LocalOnly) { $arguments += '--dart-define=API_BASE_URL=' }
if (-not $LocalOnly) { $arguments += "--dart-define=API_BASE_URL=$ApiBaseUrl" }
if ($DemoDate) { $arguments += "--dart-define=DEMO_DATE=$DemoDate" }
& flutter @arguments
exit $LASTEXITCODE
