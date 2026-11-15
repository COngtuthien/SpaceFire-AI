# SpaceFire AI - start the backend API (FastAPI) and the website (Next.js) on Windows.
#
# Usage, from the repository root:
#   launch.cmd                                  (same as: powershell -ExecutionPolicy Bypass -File scripts\start.ps1)
# Options:
#   -Dev            use the Next.js development server (no production build needed)
#   -Rebuild        force a fresh production build of the website
#   -BackendPort N  preferred API port (default 8000); the next free port is used if it is busy
#   -FrontendPort N preferred website port (default 3000); the next free port is used if it is busy
#   -NoBrowser      do not open the browser
#   -Stop           stop servers started by an earlier launch.cmd that is still running
#   -BuildOnly      only build the website (used by setup.cmd)
#
# Configuration is read by the backend from the repository-root .env. Secrets are never printed.
# Press Ctrl+C in this window to stop both servers.
param([switch]$Dev, [switch]$Rebuild, [int]$BackendPort = 8000, [int]$FrontendPort = 3000, [switch]$NoBrowser,
      [switch]$Stop, [switch]$BuildOnly)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$frontend = Join-Path $root "frontend"
$stateDir = Join-Path $root ".spacefire"
$runFile = Join-Path $stateDir "run.json"
$venvPy = Join-Path $root "backend\.venv\Scripts\python.exe"
$nextBin = Join-Path $frontend "node_modules\next\dist\bin\next"

function Ok([string]$msg) { Write-Host "   OK    $msg" -ForegroundColor Green }
function Note([string]$msg) { Write-Host "   NOTE  $msg" -ForegroundColor Yellow }
function Fail([string]$msg, [string]$hint) {
  Write-Host ""
  Write-Host "START FAILED: $msg" -ForegroundColor Red
  if ($hint) { Write-Host "  What to do: $hint" -ForegroundColor Yellow }
  exit 1
}
function Get-Json([string]$url, [int]$timeout = 3) {
  try { return Invoke-RestMethod -Uri $url -TimeoutSec $timeout -UseBasicParsing } catch { return $null }
}
function Test-PortFree([int]$port) {
  $busy = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
  if ($busy) { return $false }
  $l = $null
  try { $l = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $port); $l.Start(); return $true }
  catch { return $false }
  finally { if ($l) { $l.Stop() } }
}
function Find-FreePort([int]$preferred) {
  for ($p = $preferred; $p -lt $preferred + 20; $p++) { if (Test-PortFree $p) { return $p } }
  Fail "No free port between $preferred and $($preferred + 19)." "Close other local servers or pass -BackendPort / -FrontendPort."
}
function Stop-Tree([int]$procId) {
  if ($procId -and (Get-Process -Id $procId -ErrorAction SilentlyContinue)) { & taskkill.exe /PID $procId /T /F *> $null }
}
function Read-RunState {
  if (-not (Test-Path $runFile)) { return $null }
  try { return Get-Content $runFile -Raw | ConvertFrom-Json } catch { return $null }
}
function Show-LogTail([string]$path) {
  if (Test-Path $path) { Write-Host "--- last lines of $path ---"; Get-Content $path -Tail 25 | ForEach-Object { Write-Host "  $_" } }
}

# --- Stop, or reuse a running instance (no duplicate processes) ---------------------------------------------------
$prev = Read-RunState
if ($Stop) {
  if ($prev) { Stop-Tree $prev.frontend_pid; Stop-Tree $prev.backend_pid; Remove-Item $runFile -Force; Ok "SpaceFire AI servers stopped" }
  else { Ok "No running SpaceFire AI servers were recorded" }
  exit 0
}
if ($prev -and -not $BuildOnly) {
  $alive = (Get-Process -Id $prev.backend_pid -ErrorAction SilentlyContinue) -and (Get-Process -Id $prev.frontend_pid -ErrorAction SilentlyContinue)
  if ($alive -and (Get-Json "http://127.0.0.1:$($prev.frontend_port)/api/v1/health")) {
    $url = "http://localhost:$($prev.frontend_port)"
    Write-Host "SpaceFire AI is already running at $url (started by another launch.cmd window)." -ForegroundColor Green
    Write-Host "Stop it with Ctrl+C in that window, or run: launch.cmd -Stop"
    if (-not $NoBrowser) { Start-Process $url }
    exit 0
  }
  Remove-Item $runFile -Force -ErrorAction SilentlyContinue   # stale record from a closed window
}

# --- Preconditions -------------------------------------------------------------------------------------------------
if (-not (Test-Path $venvPy)) { Fail "backend\.venv is missing." "Run setup.cmd first." }
if (-not (Test-Path $nextBin)) { Fail "frontend\node_modules is missing." "Run setup.cmd first." }
if (-not (Get-Command node -ErrorAction SilentlyContinue)) { Fail "Node.js was not found." "Install Node.js 20 LTS or newer from https://nodejs.org/." }
if (-not $BuildOnly -and -not (Test-Path (Join-Path $root "processed\spacefire.db"))) { Fail "The scientific database is missing." "Run setup.cmd first." }
$node = (Get-Command node).Source
New-Item -ItemType Directory -Force $stateDir | Out-Null
Remove-Item Env:NEXT_DIST_DIR -ErrorAction SilentlyContinue      # always use the standard .next folder
$env:NEXT_TELEMETRY_DISABLED = "1"
$env:PYTHONIOENCODING = "utf-8"

# --- Ports ---------------------------------------------------------------------------------------------------------
if ($BuildOnly) { $bp = $BackendPort } else {
  $bp = Find-FreePort $BackendPort
  $fp = Find-FreePort $FrontendPort
  if ($bp -ne $BackendPort) { Note "Port $BackendPort is busy; the API uses port $bp." }
  if ($fp -ne $FrontendPort) { Note "Port $FrontendPort is busy; the website uses port $fp." }
}
$backendUrl = "http://127.0.0.1:$bp"
$env:BACKEND_URL = $backendUrl

# --- Production build (the API address is fixed into the build, so a different port means a rebuild) -------------
if (-not $Dev) {
  $marker = Join-Path $frontend ".next\spacefire-build.json"
  $head = $null
  if (Get-Command git -ErrorAction SilentlyContinue) { try { $head = (& git -C $root rev-parse HEAD 2>$null) } catch { $head = $null } }
  $why = $null
  if ($Rebuild) { $why = "requested with -Rebuild" }
  elseif (-not (Test-Path (Join-Path $frontend ".next\BUILD_ID"))) { $why = "no production build yet (first start takes a few minutes)" }
  elseif (-not (Test-Path $marker)) { $why = "the existing build was not made by this script" }
  else {
    $m = Get-Content $marker -Raw | ConvertFrom-Json
    if ($m.backend_url -ne $backendUrl) { $why = "the API port changed to $bp" }
    elseif ($head -and $m.git_head -and $m.git_head -ne $head) { $why = "the code changed since the last build" }
  }
  if ($why) {
    Write-Host "== Building the website: $why" -ForegroundColor Cyan
    Push-Location $frontend
    try { & $node $nextBin build; $code = $LASTEXITCODE } finally { Pop-Location }
    if ($code -ne 0) { Fail "The website build failed (see the output above)." "Run launch.cmd -Dev to use the development server, or see Troubleshooting in README.md." }
    @{ backend_url = $backendUrl; git_head = $head; built_at = (Get-Date).ToString("s") } | ConvertTo-Json | Set-Content -Encoding ASCII $marker
    Ok "website built"
  } elseif ($BuildOnly) { Ok "website build is up to date" }
}
if ($BuildOnly) { exit 0 }

# --- Start the backend ---------------------------------------------------------------------------------------------
Write-Host "== Starting SpaceFire AI" -ForegroundColor Cyan
$beLog = Join-Path $stateDir "backend.log"
$feLog = Join-Path $stateDir "frontend.log"
$be = Start-Process -PassThru -NoNewWindow -WorkingDirectory (Join-Path $root "backend") -FilePath $venvPy `
  -ArgumentList "-m", "uvicorn", "app.main:app", "--host", "127.0.0.1", "--port", "$bp" `
  -RedirectStandardOutput (Join-Path $stateDir "backend.out.log") -RedirectStandardError $beLog
$fe = $null
try {
  $health = $null
  for ($i = 0; $i -lt 90 -and -not $health; $i++) {
    if ($be.HasExited) { Show-LogTail $beLog; Fail "The API stopped while starting." "See the log above; run setup.cmd again if packages or the database are missing." }
    Start-Sleep -Seconds 1
    $health = Get-Json "$backendUrl/api/v1/health"
  }
  if (-not $health) { Show-LogTail $beLog; Fail "The API did not answer within 90 s." "See the log above." }
  if ($health.status -ne "ok") { Note "API health is '$($health.status)': the database may be incomplete (run setup.cmd -RebuildData)." }
  Ok "API running at $backendUrl (health: $($health.status))"
  $llm = $health.llm
  if ($llm.mode -eq "synthesis") { Ok "Research Copilot AI answers ON: $($llm.provider) $($llm.model) (key from $($llm.key_source); value not shown)" }
  else { Note "Research Copilot AI answers OFF: evidence-only mode. $($llm.reason) To enable: setup.cmd -SetOpenAIKey, then restart." }

  # --- Start the website -------------------------------------------------------------------------------------------
  if ($Dev) { $feArgs = @("`"$nextBin`"", "dev", "--port", "$fp") }
  else { $feArgs = @("`"$nextBin`"", "start", "--port", "$fp", "--hostname", "127.0.0.1") }
  $fe = Start-Process -PassThru -NoNewWindow -WorkingDirectory $frontend -FilePath $node -ArgumentList $feArgs `
    -RedirectStandardOutput $feLog -RedirectStandardError (Join-Path $stateDir "frontend.err.log")
  $site = "http://127.0.0.1:$fp"
  $up = $false
  for ($i = 0; $i -lt 180 -and -not $up; $i++) {
    if ($fe.HasExited) { Show-LogTail $feLog; Show-LogTail (Join-Path $stateDir "frontend.err.log"); Fail "The website stopped while starting." "See the log above, or try launch.cmd -Rebuild." }
    Start-Sleep -Seconds 1
    try { $r = Invoke-WebRequest -Uri "$site/" -TimeoutSec 5 -UseBasicParsing; $up = ($r.StatusCode -eq 200) } catch { $up = $false }
  }
  if (-not $up) { Show-LogTail $feLog; Fail "The website did not answer within 180 s." "See the log above." }
  $proxied = Get-Json "$site/api/v1/health" 10
  if (-not $proxied) { Fail "The website cannot reach the API through its /api/v1 proxy." "Run launch.cmd -Rebuild." }
  Ok "website running and connected to the API"

  @{ backend_pid = $be.Id; frontend_pid = $fe.Id; backend_port = $bp; frontend_port = $fp; started = (Get-Date).ToString("s") } |
    ConvertTo-Json | Set-Content -Encoding ASCII $runFile

  $url = "http://localhost:$fp"
  Write-Host ""
  Write-Host "SpaceFire AI is running" -ForegroundColor Green
  Write-Host "  Website           $url"
  Write-Host "  Research Copilot  $url/copilot"
  Write-Host "  Guided demo       $url/demo"
  Write-Host "  API docs          $backendUrl/docs"
  Write-Host "  Logs              .spacefire\"
  Write-Host ""
  Write-Host "Keep this window open. Press Ctrl+C to stop both servers."
  if (-not $NoBrowser) { Start-Process $url }

  while (-not $be.HasExited -and -not $fe.HasExited) { Start-Sleep -Seconds 1 }
  if ($be.HasExited) { Show-LogTail $beLog; Note "The API stopped; stopping the website." }
  else { Show-LogTail $feLog; Note "The website stopped; stopping the API." }
} finally {
  if ($fe) { Stop-Tree $fe.Id }
  Stop-Tree $be.Id
  Remove-Item $runFile -Force -ErrorAction SilentlyContinue
  Write-Host "SpaceFire AI stopped."
}
