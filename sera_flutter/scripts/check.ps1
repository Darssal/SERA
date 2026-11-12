$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)
& flutter analyze lib test integration_test
if ($LASTEXITCODE -ne 0) { throw 'Static analysis failed' }
& flutter test
if ($LASTEXITCODE -ne 0) { throw 'Flutter tests failed' }
$seraPython = Join-Path (Get-Location) 'backend/.venv/Scripts/python.exe'
if (-not (Test-Path -LiteralPath $seraPython)) { throw 'Run scripts/setup.ps1 first.' }
& $seraPython -m unittest discover -s backend -p 'test_*.py' -v
if ($LASTEXITCODE -ne 0) { throw 'Backend tests failed' }
& $seraPython -m unittest discover -s test -p 'admin_backend_test.py' -v
if ($LASTEXITCODE -ne 0) { throw 'Admin API integration tests failed' }
& $seraPython -m unittest discover -s test -p 'admin_analytics_backend_test.py' -v
if ($LASTEXITCODE -ne 0) { throw 'Admin analytics tests failed' }
& $seraPython -m unittest discover -s scripts -p 'test_*.py' -v
if ($LASTEXITCODE -ne 0) { throw 'Configuration and delivery tests failed' }

& node --test test/platform_worker_test.mjs test/platform_bridge_test.mjs
if ($LASTEXITCODE -ne 0) { throw 'Service Worker and PCM tests failed' }
& $seraPython -m unittest discover -s test -p 'platform_offline_manifest_test.py' -v
if ($LASTEXITCODE -ne 0) { throw 'Offline manifest tests failed' }
