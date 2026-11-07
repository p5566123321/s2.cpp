# Start / stop / status the s2.cpp HTTP server on Windows (CUDA by default;
# Vulkan or CPU selectable with S2_BACKEND). Windows counterpart of
# scripts/s2-service.sh.
#
# Usage (from the repo root):
#   powershell -ExecutionPolicy Bypass -File scripts\s2-service.ps1 start
#   powershell -ExecutionPolicy Bypass -File scripts\s2-service.ps1 stop
#   powershell -ExecutionPolicy Bypass -File scripts\s2-service.ps1 restart
#   powershell -ExecutionPolicy Bypass -File scripts\s2-service.ps1 status
#   powershell -ExecutionPolicy Bypass -File scripts\s2-service.ps1 build
#
# Overrides (environment variables):
#   S2_MODEL      path to GGUF model   (default: %USERPROFILE%\personal\Hibiki\s2cpp\models\s2-pro-q4_k_m.gguf)
#   S2_TOKENIZER  path to tokenizer    (default: <repo>\tokenizer.json)
#   S2_PORT       HTTP port            (default: 13030)
#   S2_LOG_DIR    log directory        (default: %LOCALAPPDATA%\s2cpp\logs)
#   S2_BACKEND    cuda|vulkan|cpu      (default: cuda)

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command = ''
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoDir   = Split-Path -Parent $ScriptDir

# Optional scripts\env.ps1 sets the S2_* overrides (e.g. `$env:S2_MODEL = '...'`).
# It is dot-sourced so the variables land in this process's environment.
$EnvFile = Join-Path $ScriptDir 'env.ps1'
if (Test-Path $EnvFile -PathType Leaf) { . $EnvFile }

function Get-Setting([string]$Name, [string]$Default) {
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrEmpty($value)) { return $Default }
    return $value
}

$BuildDir  = Join-Path $RepoDir 'build'
$Model     = Get-Setting 'S2_MODEL'     (Join-Path $env:USERPROFILE 'personal\Hibiki\s2cpp\models\s2-pro-q4_k_m.gguf')
$Tokenizer = Get-Setting 'S2_TOKENIZER' (Join-Path $RepoDir 'tokenizer.json')
$Port      = Get-Setting 'S2_PORT'      '13030'
$Backend   = (Get-Setting 'S2_BACKEND'  'cuda').ToLower()
$LogDir    = Get-Setting 'S2_LOG_DIR'   (Join-Path $env:LOCALAPPDATA 's2cpp\logs')
$PidFile   = Join-Path $LogDir 's2.pid'
$LogFile   = Join-Path $LogDir 's2.log'
$ErrFile   = Join-Path $LogDir 's2.err.log'

function Write-Log([string]$Message) { Write-Host "[s2] $Message" }

function Stop-Script([string]$Message) {
    Write-Host "[s2] error: $Message" -ForegroundColor Red
    exit 1
}

function Quote-Arg([string]$Value) { return '"' + $Value + '"' }

function Get-BackendFlag {
    switch ($Backend) {
        'cuda'   { return '-DS2_CUDA=ON' }
        'vulkan' { return '-DS2_VULKAN=ON' }
        'cpu'    { return $null }
        default  { Stop-Script "unknown S2_BACKEND '$Backend' (expected cuda, vulkan or cpu)" }
    }
}

function Build-Server {
    $cmakeArgs = @('-B', 'build', '-DCMAKE_BUILD_TYPE=Release',
                   '-DS2_METAL=OFF', '-DS2_CUDA=OFF', '-DS2_VULKAN=OFF',
                   '-DGGML_CCACHE=OFF')
    $flag = Get-BackendFlag
    if ($flag) { $cmakeArgs += $flag }

    # Always configure: cmake reuses the cache, and this lets switching backends
    # take effect. Explicitly turn the other backends off so stale cache entries
    # cannot leave two backends enabled at once.
    $jobs = [Math]::Max(1, [int]$env:NUMBER_OF_PROCESSORS)

    Push-Location $RepoDir
    try {
        Write-Log "configuring ($Backend, Release)..."
        & cmake @cmakeArgs
        if ($LASTEXITCODE -ne 0) { Stop-Script "cmake configure failed (exit $LASTEXITCODE)" }

        Write-Log 'building...'
        # --config Release is needed for multi-config generators (Visual Studio).
        & cmake --build build --config Release --parallel $jobs
        if ($LASTEXITCODE -ne 0) { Stop-Script "build failed (exit $LASTEXITCODE)" }
    }
    finally {
        Pop-Location
    }
}

function Find-Binary {
    # Visual Studio puts multi-config output in build\Release; Ninja/Make use build\.
    $candidates = @((Join-Path $BuildDir 'Release\s2.exe'), (Join-Path $BuildDir 's2.exe'))
    foreach ($candidate in $candidates) {
        if (Test-Path $candidate -PathType Leaf) { return $candidate }
    }
    return $null
}

function Get-ServerProcess {
    if (-not (Test-Path $PidFile -PathType Leaf)) { return $null }
    $raw = (Get-Content $PidFile -Raw).Trim()
    $id = 0
    if (-not [int]::TryParse($raw, [ref]$id)) { return $null }
    # Check the process name too, so a reused PID is not mistaken for the server.
    $proc = Get-Process -Id $id -ErrorAction SilentlyContinue
    if ($proc -and $proc.ProcessName -eq 's2') { return $proc }
    return $null
}

function Start-Server {
    if (-not (Test-Path $Model -PathType Leaf)) { Stop-Script "model not found: $Model (set S2_MODEL)" }
    if (-not (Test-Path $Tokenizer -PathType Leaf)) { Stop-Script "tokenizer not found: $Tokenizer (set S2_TOKENIZER)" }

    $running = Get-ServerProcess
    if ($running) {
        Write-Log "already running (pid $($running.Id), port $Port)"
        return
    }

    Build-Server
    $bin = Find-Binary
    if (-not $bin) { Stop-Script "binary not found after build under $BuildDir" }

    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

    $serverArgs = @(
        '--model', (Quote-Arg $Model),
        '--tokenizer', (Quote-Arg $Tokenizer),
        '--server', '--port', $Port
    )
    # Building with a GPU backend is not enough: s2 runs on the CPU unless the
    # backend device is selected at runtime.
    switch ($Backend) {
        'cuda'   { $serverArgs += @('--cuda', '0') }
        'vulkan' { $serverArgs += @('--vulkan', '0') }
    }
    # The ggml DLLs are built into build\bin; the child process needs them on PATH
    # or it dies with STATUS_DLL_NOT_FOUND (0xC0000135) before printing anything.
    # This only affects this script's process, which exits after starting the server.
    $env:PATH = (Join-Path $BuildDir 'bin') + ';' + (Split-Path -Parent $bin) + ';' + $env:PATH

    # Start-Process -Redirect* launches the child with handle inheritance on, so
    # the server would inherit this script's stdout/stderr and any caller piping
    # our output would hang until the server exits. Instead, start it without
    # redirection (ShellExecute, no inherited handles) through cmd.exe, which
    # does the log redirection itself. The hidden window keeps the server
    # running after this shell exits; logs are overwritten on each start.
    $cmdLine = '/d /s /c "' + (Quote-Arg $bin) + ' ' + ($serverArgs -join ' ') +
               ' > ' + (Quote-Arg $LogFile) + ' 2> ' + (Quote-Arg $ErrFile) + '"'
    $wrapper = Start-Process -FilePath $env:ComSpec -ArgumentList $cmdLine `
        -WorkingDirectory $RepoDir -WindowStyle Hidden -PassThru

    # Track the s2 process itself (child of the cmd wrapper), not the wrapper.
    $proc = $null
    for ($i = 0; $i -lt 20 -and -not $proc; $i++) {
        Start-Sleep -Milliseconds 250
        $child = Get-CimInstance Win32_Process -Filter "ParentProcessId = $($wrapper.Id) AND Name = 's2.exe'"
        if ($child) { $proc = Get-Process -Id ($child | Select-Object -First 1).ProcessId -ErrorAction SilentlyContinue }
        if (-not $proc -and $wrapper.HasExited) { break }
    }
    if (-not $proc) { Stop-Script "server did not start; see $ErrFile" }

    Set-Content -Path $PidFile -Value $proc.Id -Encoding ascii

    Start-Sleep -Seconds 1
    if ($proc.HasExited) {
        Remove-Item $PidFile -ErrorAction SilentlyContinue
        Stop-Script "server exited immediately; see $ErrFile"
    }

    Write-Log "started (pid $($proc.Id), port $Port)"
    Write-Log "log: $LogFile"
    Write-Log "err: $ErrFile"
}

function Stop-Server {
    $running = Get-ServerProcess
    if (-not $running) {
        Write-Log 'not running'
        Remove-Item $PidFile -ErrorAction SilentlyContinue
        return
    }

    # Windows has no SIGTERM for a windowless console process, so this is a
    # forced termination.
    Write-Log "stopping pid $($running.Id)..."
    Stop-Process -Id $running.Id -Force
    $running.WaitForExit(10000) | Out-Null
    Remove-Item $PidFile -ErrorAction SilentlyContinue
    Write-Log 'stopped'
}

function Show-Status {
    $running = Get-ServerProcess
    if ($running) {
        Write-Log "running (pid $($running.Id), port $Port)"
        Write-Log "log: $LogFile"
        return $true
    }
    Write-Log 'not running'
    return $false
}

function Show-Usage {
    Write-Host 'Usage: s2-service.ps1 {start|stop|restart|status|build}'
    Write-Host '  start    build if needed, then start the server in the background'
    Write-Host '  stop     stop the server'
    Write-Host '  restart  stop, then start'
    Write-Host '  status   show whether the server is running'
    Write-Host '  build    configure + build only'
    Write-Host 'Set S2_MODEL, S2_TOKENIZER, S2_PORT, S2_LOG_DIR, S2_BACKEND to override defaults.'
}

switch ($Command.ToLower()) {
    'start'   { Start-Server }
    'stop'    { Stop-Server }
    'restart' { Stop-Server; Start-Server }
    'status'  { if (-not (Show-Status)) { exit 1 } }
    'build'   { Build-Server }
    default   { Show-Usage; exit 2 }
}
