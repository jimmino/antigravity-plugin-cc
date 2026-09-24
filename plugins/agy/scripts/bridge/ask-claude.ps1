# ask-claude.ps1: the fixed path the Antigravity CLI (agy) calls on Windows to
# hand a task to Claude Code. Written by agy-run.sh bridge install, removed by
# bridge uninstall. Do not edit it: the next install overwrites it.
#
# agy runs commands through PowerShell here. `bash` on PATH is often WSL's
# bash.exe, which cannot see this machine's Claude Code, so this script finds
# Git for Windows' bash and runs the `ask-claude` launcher next to it.
#
# Keep this file ASCII. Windows PowerShell 5.1 reads a script that has no BOM
# in the ANSI code page.

$ErrorActionPreference = 'Stop'

function Find-GitBash {
    if ($env:AGY_BRIDGE_BASH) {
        if (Test-Path -LiteralPath $env:AGY_BRIDGE_BASH) { return $env:AGY_BRIDGE_BASH }
        return $null
    }
    # git.exe is usually in <Git>\cmd. <Git>\bin\bash.exe sets up the MSYS
    # environment before it starts the shell; <Git>\usr\bin\bash.exe does not.
    $roots = @()
    foreach ($git in @(Get-Command git.exe -CommandType Application -All -ErrorAction SilentlyContinue)) {
        $roots += Split-Path (Split-Path $git.Source -Parent) -Parent
    }
    $roots += "$env:ProgramFiles\Git", "$env:LOCALAPPDATA\Programs\Git"
    foreach ($root in $roots) {
        if (-not $root) { continue }
        $bash = Join-Path $root 'bin\bash.exe'
        if (Test-Path -LiteralPath $bash) { return $bash }
    }
    return $null
}

$bash = Find-GitBash
if (-not $bash) {
    [Console]::Error.WriteLine('ask-claude: cannot find Git for Windows (bin\bash.exe). Install it, or set AGY_BRIDGE_BASH to its bin\bash.exe.')
    exit 127
}

# Send the arguments base64-encoded, not on the command line: bash reads a
# Windows command line with its own quoting rules and changes any double quote
# inside an argument. Each argument is NUL-terminated UTF-8.
$bytes = New-Object System.Collections.Generic.List[byte]
foreach ($arg in $args) {
    $bytes.AddRange([Text.Encoding]::UTF8.GetBytes([string]$arg))
    $bytes.Add(0)
}
$encoded = [Convert]::ToBase64String($bytes.ToArray())
# An environment variable holds at most 32767 characters.
if ($encoded.Length -gt 32000) {
    [Console]::Error.WriteLine('ask-claude: the arguments are too long. Name the files Claude should read instead of pasting them into the task.')
    exit 64
}
$env:AGY_BRIDGE_ARGV = $encoded

# The answer is UTF-8. Without this, PowerShell decodes it in the console code
# page on its way through.
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false

$launcher = (Join-Path $PSScriptRoot 'ask-claude').Replace('\', '/')
& $bash $launcher
exit $LASTEXITCODE
