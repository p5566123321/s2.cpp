# Build a reusable .s2voice profile from a reference clip (or list existing ones)
# on Windows. Wraps `s2.exe --prompt-audio ... --prompt-text ... --voice <id> --save-voice`.
#
# Usage (from the repo root):
#   powershell -ExecutionPolicy Bypass -File scripts\s2-voice.ps1 create -Id alice -Audio reference.wav -Transcript "What the speaker says."
#   powershell -ExecutionPolicy Bypass -File scripts\s2-voice.ps1 create -Id alice -Audio reference.wav -TranscriptFile alice.txt -Force
#   powershell -ExecutionPolicy Bypass -File scripts\s2-voice.ps1 list
#
# create options:
#   -Id          profile name, letters/digits/-/_ only (required)
#   -Audio       reference audio, WAV or MP3 (required)
#   -Transcript  exact transcript of the reference audio
#   -TranscriptFile  read the transcript from a UTF-8 text file instead
#   -SampleText  text synthesized after saving to verify the profile (default below)
#   -Force       overwrite an existing profile with the same id
#
# Overrides (environment variables):
#   S2_BIN        path to s2.exe       (default: <repo>\build\s2.exe)
#   S2_MODEL      path to GGUF model   (default: <repo>\models\s2-pro-q4_k_m.gguf)
#   S2_TOKENIZER  path to tokenizer    (default: <repo>\tokenizer.json)
#   S2_VOICE_DIR  profile directory    (default: <repo>\voices)

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command = '',
    [string]$Id = '',
    [string]$Audio = '',
    [string]$Transcript = '',
    [string]$TranscriptFile = '',
    [string]$SampleText = 'This is a test of the newly saved voice profile.',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoDir   = Split-Path -Parent $ScriptDir

function Get-Setting([string]$Name, [string]$Default) {
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrEmpty($value)) { return $Default }
    return $value
}

$S2Bin     = Get-Setting 'S2_BIN'       (Join-Path $RepoDir 'build\s2.exe')
$Model     = Get-Setting 'S2_MODEL'     (Join-Path $RepoDir 'models\s2-pro-q4_k_m.gguf')
$Tokenizer = Get-Setting 'S2_TOKENIZER' (Join-Path $RepoDir 'tokenizer.json')
$VoiceDir  = Get-Setting 'S2_VOICE_DIR' (Join-Path $RepoDir 'voices')

function Write-Log([string]$Message) { Write-Host "[s2-voice] $Message" }

function Stop-Script([string]$Message) {
    Write-Host "[s2-voice] error: $Message" -ForegroundColor Red
    exit 1
}

function Show-Usage {
    Write-Host 'Usage:'
    Write-Host '  s2-voice.ps1 create -Id <name> -Audio <file> (-Transcript <text> | -TranscriptFile <file>) [-SampleText <text>] [-Force]'
    Write-Host '  s2-voice.ps1 list'
}

function Require-File([string]$Path, [string]$What) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Stop-Script "$What not found: $Path" }
}

function Get-ProfilePath([string]$Name) { return Join-Path $VoiceDir "$Name.s2voice" }

function New-Voice {
    if ([string]::IsNullOrWhiteSpace($Id))    { Stop-Script '-Id is required' }
    if ($Id -notmatch '^[A-Za-z0-9_-]+$')     { Stop-Script "invalid -Id '$Id' (use letters, digits, '-' or '_')" }
    if ([string]::IsNullOrWhiteSpace($Audio)) { Stop-Script '-Audio is required' }

    $audioPath = (Resolve-Path -LiteralPath $Audio -ErrorAction SilentlyContinue).Path
    if (-not $audioPath) { Stop-Script "audio file not found: $Audio" }
    $ext = [IO.Path]::GetExtension($audioPath).ToLower()
    if ($ext -notin @('.wav', '.mp3')) { Stop-Script "unsupported audio type '$ext' (use WAV or MP3)" }

    if ($TranscriptFile) {
        Require-File $TranscriptFile 'transcript file'
        $Transcript = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $TranscriptFile).Path, [Text.Encoding]::UTF8).Trim()
    }
    if ([string]::IsNullOrWhiteSpace($Transcript)) {
        Stop-Script 'a transcript is required (-Transcript or -TranscriptFile); it must match the audio'
    }

    Require-File $S2Bin 's2 binary (build first with scripts\s2-service.ps1 build, or set S2_BIN)'
    Require-File $Model 'model'
    Require-File $Tokenizer 'tokenizer'

    New-Item -ItemType Directory -Force -Path $VoiceDir | Out-Null
    $profile = Get-ProfilePath $Id
    if ((Test-Path -LiteralPath $profile) -and -not $Force) {
        Stop-Script "profile already exists: $profile (use -Force to overwrite)"
    }
    if (Test-Path -LiteralPath $profile) { Remove-Item -LiteralPath $profile -Force }

    $sampleWav = Join-Path $VoiceDir "$Id.sample.wav"

    # ggml backend DLLs (ggml-cuda.dll, ggml-cpu.dll, ...) live in build\bin; without
    # it on PATH s2.exe fails at startup with exit -1073741515 (STATUS_DLL_NOT_FOUND).
    $binDir = Join-Path (Split-Path -Parent $S2Bin) 'bin'
    if (Test-Path -LiteralPath $binDir) { $env:PATH = "$binDir;$env:PATH" }

    Write-Log "encoding '$audioPath' and saving profile '$Id'..."
    & $S2Bin --model $Model --tokenizer $Tokenizer `
        --prompt-audio $audioPath --prompt-text $Transcript `
        --voice $Id --voice-dir $VoiceDir --save-voice `
        --text $SampleText --output $sampleWav
    if ($LASTEXITCODE -ne 0) { Stop-Script "s2 failed (exit $LASTEXITCODE)" }

    if (-not (Test-Path -LiteralPath $profile)) { Stop-Script "expected profile was not written: $profile" }

    $size = (Get-Item -LiteralPath $profile).Length
    Write-Log "saved $profile ($size bytes)"
    Write-Log "sample audio: $sampleWav"
    Write-Log "use it with: s2.exe --voice $Id --voice-dir `"$VoiceDir`" --text ... --output out.wav"
}

function Show-List {
    if (-not (Test-Path -LiteralPath $VoiceDir)) { Write-Log "no profiles yet ($VoiceDir does not exist)"; return }
    $profiles = Get-ChildItem -LiteralPath $VoiceDir -Filter '*.s2voice' -File
    if (-not $profiles) { Write-Log "no profiles in $VoiceDir"; return }
    $profiles | Select-Object @{n='Id';e={$_.BaseName}}, @{n='KB';e={[math]::Round($_.Length / 1KB, 1)}}, LastWriteTime |
        Format-Table -AutoSize
}

switch ($Command.ToLower()) {
    'create' { New-Voice }
    'list'   { Show-List }
    default  { Show-Usage; if ($Command) { exit 1 } }
}
