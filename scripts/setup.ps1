# SpaceFire AI - one-step Windows setup for a fresh clone.
#
# Usage, from the repository root:
#   setup.cmd                                   (same as: powershell -ExecutionPolicy Bypass -File scripts\setup.ps1)
# Options:
#   -SetOpenAIKey   ask for an OpenAI API key (hidden input) and store it in the local, gitignored .env
#   -RebuildData    rebuild processed\spacefire.db even if it already exists
#   -SkipBuild      skip the production frontend build (launch.cmd builds it on first start)
#
# What it does: checks Python, Node.js, npm and Git; creates backend\.venv; installs the backend and frontend
# dependencies; checks the committed NASA data; creates .env from .env.example if it is missing (an existing .env is
# never overwritten); builds the scientific database; builds the website. Secrets are never printed.
param([switch]$SetOpenAIKey, [switch]$RebuildData, [switch]$SkipBuild)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

function Step([string]$msg) { Write-Host ""; Write-Host "== $msg" -ForegroundColor Cyan }
function Ok([string]$msg) { Write-Host "   OK    $msg" -ForegroundColor Green }
function Note([string]$msg) { Write-Host "   NOTE  $msg" -ForegroundColor Yellow }
function Fail([string]$msg, [string]$hint) {
  Write-Host ""
  Write-Host "SETUP FAILED: $msg" -ForegroundColor Red
  if ($hint) { Write-Host "  What to do: $hint" -ForegroundColor Yellow }
  exit 1
}

# Runs a command and returns its first output line, or $null when it is missing or fails (never throws).
function Probe([string]$exe, [string[]]$argv) {
  if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) { return $null }
  try {
    $out = & $exe @argv 2>$null | Select-Object -First 1
    if ($LASTEXITCODE -ne 0) { return $null }
    return "$out".Trim()
  } catch { return $null }
}

Write-Host "SpaceFire AI setup  ($root)" -ForegroundColor White

# --- 1. Tools ------------------------------------------------------------------------------------------------------
Step "Checking Python, Node.js, npm and Git"
$pyCmd = $null; $pyArgs = @(); $pyVer = $null
foreach ($c in @(@("python"), @("py", "-3"), @("python3"))) {
  $rest = @(); if ($c.Count -gt 1) { $rest = $c[1..($c.Count - 1)] }
  $v = Probe $c[0] ($rest + @("-c", "import sys; print('%d.%d.%d' % sys.version_info[:3])"))
  if ($v -match '^\d+\.\d+\.\d+$') { $pyCmd = $c[0]; $pyArgs = $rest; $pyVer = [version]$v; break }
}
if (-not $pyCmd) { Fail "Python was not found." "Install Python 3.11-3.13 from https://www.python.org/downloads/ (tick 'Add python.exe to PATH'), open a new terminal and run setup.cmd again." }
if ($pyVer -lt [version]"3.11") { Fail "Python $pyVer is too old (3.11 or newer is required)." "Install Python 3.13 from https://www.python.org/downloads/." }
Ok "Python $pyVer ($pyCmd $($pyArgs -join ' '))"
if ($pyVer -ge [version]"3.14") { Note "SpaceFire is tested on Python 3.13; if package installation fails, install Python 3.13." }

$nodeV = Probe "node" @("--version")
if (-not $nodeV) { Fail "Node.js was not found." "Install Node.js 20 LTS or newer from https://nodejs.org/, open a new terminal and run setup.cmd again." }
if ([version]($nodeV.TrimStart("v")) -lt [version]"20.9") { Fail "Node.js $nodeV is too old (20.9 or newer is required)." "Install the current LTS from https://nodejs.org/." }
Ok "Node.js $nodeV"
$npmV = Probe "npm.cmd" @("--version")
if (-not $npmV) { Fail "npm was not found." "Reinstall Node.js from https://nodejs.org/ (npm is included)." }
Ok "npm $npmV"
$gitV = Probe "git" @("--version")
if ($gitV) { Ok $gitV } else { Note "Git was not found. It is only needed to clone or update the repository." }

# --- 2. Backend ----------------------------------------------------------------------------------------------------
Step "Backend: Python virtual environment and packages"
$venvPy = Join-Path $root "backend\.venv\Scripts\python.exe"
if ((Test-Path $venvPy) -and -not (Probe $venvPy @("-c", "print(1)"))) {
  Note "backend\.venv exists but does not run (Python was moved or reinstalled); recreating it."
  Remove-Item -Recurse -Force (Join-Path $root "backend\.venv")
}
if (-not (Test-Path $venvPy)) {
  & $pyCmd @($pyArgs + @("-m", "venv", "backend\.venv"))
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path $venvPy)) { Fail "Could not create backend\.venv." "Check that the Python installation includes the 'venv' module." }
  Ok "created backend\.venv"
} else { Ok "backend\.venv already exists" }
& $venvPy -m pip install --disable-pip-version-check --no-input -r backend\requirements.txt
if ($LASTEXITCODE -ne 0) { Fail "Installing the Python packages failed (see the pip output above)." "Check the internet connection and run setup.cmd again. On Python 3.14+, use Python 3.13." }
Ok "Python packages installed"

# --- 3. Frontend ---------------------------------------------------------------------------------------------------
Step "Frontend: npm packages"
$lock = Join-Path $root "frontend\package-lock.json"
$installed = Join-Path $root "frontend\node_modules\.package-lock.json"
if ((-not (Test-Path $installed)) -or ((Get-Item $lock).LastWriteTime -gt (Get-Item $installed).LastWriteTime)) {
  Push-Location frontend
  try { & npm.cmd ci --no-audit --no-fund; $code = $LASTEXITCODE } finally { Pop-Location }
  if ($code -ne 0) { Fail "npm ci failed (see the npm output above)." "Check the internet connection, close other programs using frontend\node_modules and run setup.cmd again." }
  Ok "npm packages installed from package-lock.json"
} else { Ok "npm packages are already up to date" }

# --- 4. NASA data --------------------------------------------------------------------------------------------------
Step "Checking the committed NASA data"
$missing = @()
foreach ($p in @("FLEX", "BASS-II", "SAFFIRE-1", "processed\curated\bass2_table_5_1.json",
                 "processed\curated\phase13\investigation_registry.json", "processed\curated\phase13\cfig_tests.json")) {
  if (-not (Test-Path (Join-Path $root $p))) { $missing += $p }
}
if ($missing.Count) { Fail "Committed NASA data is missing: $($missing -join ', ')." "Clone the full repository again (git clone https://github.com/COngtuthien/SpaceFire-AI.git); do not use a partial download." }
$curated = @(Get-ChildItem (Join-Path $root "processed\curated") -Recurse -Filter *.json).Count
Ok "FLEX, BASS-II and SAFFIRE-I source folders and $curated curated NASA tables found"
$optional = @("ACME CFI-G", "ACME Flame Design", "ACME BRE", "SAME", "PSI-117", "FLEX-2", "PSI-62") | Where-Object { Test-Path (Join-Path $root $_) }
if ($optional.Count) { Ok "optional local NASA document folders found: $($optional -join ', ')" }
else { Note "The 7 optional NASA document folders are not present. All datasets, charts and 3D studios still work; only full-text search of those reports is limited (see README)." }

# --- 5. Local configuration ----------------------------------------------------------------------------------------
Step "Local configuration (.env, never committed)"
$envFile = Join-Path $root ".env"
if (-not (Test-Path $envFile)) {
  Copy-Item (Join-Path $root ".env.example") $envFile
  Ok "created .env from .env.example"
} else { Ok ".env already exists and was left unchanged" }

if ($SetOpenAIKey) {
  $sec = Read-Host "Paste the OpenAI API key (input is hidden; press Enter to skip)" -AsSecureString
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
  try { $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
  $plain = "$plain".Trim()
  if ($plain) {
    if (-not $plain.StartsWith("sk-")) { Note "The key does not start with 'sk-'; it was saved anyway. Check it if the Copilot reports an authentication error." }
    $set = [ordered]@{ "LLM_PROVIDER" = "openai"; "LLM_MODEL" = "gpt-4.1-mini"; "OPENAI_API_KEY" = $plain }
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($l in [IO.File]::ReadAllLines($envFile)) {
      $name = ($l -split "=", 2)[0].Trim()
      if ($set.Contains($name)) { $lines.Add("$name=$($set[$name])"); $set.Remove($name) } else { $lines.Add($l) }
    }
    foreach ($k in $set.Keys) { $lines.Add("$k=$($set[$k])") }
    [IO.File]::WriteAllLines($envFile, $lines)   # UTF-8 without BOM
    $plain = $null
    Ok "OpenAI key saved to .env (LLM_PROVIDER=openai, LLM_MODEL=gpt-4.1-mini). The key is not shown."
  } else { Note "No key entered; .env was not changed." }
}

$envText = [IO.File]::ReadAllText($envFile)
$keyVars = @("OPENAI_API_KEY", "GEMINI_API_KEY", "LLM_API_KEY") | Where-Object { $envText -match "(?m)^$_=\S+" }
if ($keyVars) { Ok "AI key variable(s) set: $($keyVars -join ', ') (values not shown)" }
else { Note "No AI key is set: the Research Copilot will show NASA evidence only (all other features work). To enable AI answers later: setup.cmd -SetOpenAIKey" }

# --- 6. Scientific database ----------------------------------------------------------------------------------------
Step "Scientific database (processed\spacefire.db)"
$db = Join-Path $root "processed\spacefire.db"
if ($RebuildData -or -not (Test-Path $db)) {
  Push-Location backend
  try { $env:PYTHONIOENCODING = "utf-8"; & $venvPy -m app.ingest.run; $code = $LASTEXITCODE } finally { Pop-Location }
  if ($code -ne 0) { Fail "Building the database failed (see the output above)." "If the SpaceFire backend is running, stop it (launch.cmd -Stop) and run setup.cmd -RebuildData." }
  Ok "database, search index and knowledge graph built"
} else { Ok "database already built (run setup.cmd -RebuildData to rebuild it)" }

# --- 7. Website build ----------------------------------------------------------------------------------------------
if ($SkipBuild) {
  Step "Website build skipped (-SkipBuild); launch.cmd builds it on first start"
} else {
  Step "Building the website (production build, a few minutes the first time)"
  & (Join-Path $PSScriptRoot "start.ps1") -BuildOnly
  if ($LASTEXITCODE -ne 0) { Fail "The website build failed (see the output above)." "Run launch.cmd -Dev to use the development server instead, or see Troubleshooting in README.md." }
}

Write-Host ""
Write-Host "Setup complete." -ForegroundColor Green
Write-Host "Start SpaceFire AI with:  launch.cmd     (or: powershell -ExecutionPolicy Bypass -File scripts\start.ps1)"
exit 0
