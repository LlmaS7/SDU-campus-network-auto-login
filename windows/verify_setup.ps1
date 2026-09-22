[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$TaskName = 'SrunLogin'
$InstallRoot = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'SrunLogin'
$RuntimeScript = Join-Path $InstallRoot 'srun_login.ps1'
$ConfigFile = Join-Path $InstallRoot 'config.ini'
$LogDirectory = Join-Path $InstallRoot 'logs'
$failed = $false

function Show-Check {
    param(
        [Parameter(Mandatory = $true)][bool]$Passed,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ($Passed) {
        Write-Host "[OK]   $Message" -ForegroundColor Green
    }
    else {
        Write-Host "[FAIL] $Message" -ForegroundColor Red
        $script:failed = $true
    }
}

Write-Host ''
Write-Host 'SrunLogin Windows setup verification'
Write-Host '-----------------------------------'

Import-Module ScheduledTasks -ErrorAction Stop
$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
Show-Check ($null -ne $task) "Scheduled task '$TaskName' exists"

if ($null -ne $task) {
    $principalOk = $task.Principal.UserId -in @('SYSTEM', 'S-1-5-18')
    Show-Check $principalOk 'Task runs as SYSTEM'
    Show-Check ($task.Settings.MultipleInstances -eq 'IgnoreNew') 'Task rejects duplicate instances'

    $startupTrigger = @($task.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskBootTrigger' })
    Show-Check ($startupTrigger.Count -gt 0) 'Task has an At startup trigger'

    $expectedScriptFragment = [regex]::Escape($RuntimeScript)
    $actionMatches = @($task.Actions | Where-Object {
        $_.Execute -match '(?i)powershell(\.exe)?$' -and $_.Arguments -match $expectedScriptFragment
    })
    Show-Check ($actionMatches.Count -gt 0) 'Task launches the installed runtime script'

    try {
        $info = Get-ScheduledTaskInfo -TaskName $TaskName
        Write-Host "       State: $($task.State)"
        Write-Host "       Last run: $($info.LastRunTime)"
        Write-Host "       Last result/exit code: $($info.LastTaskResult)"
    }
    catch {
        Write-Warning 'Task history information could not be read.'
    }
}

Show-Check (Test-Path -LiteralPath $RuntimeScript -PathType Leaf) "Runtime script exists at $RuntimeScript"
Show-Check (Test-Path -LiteralPath $ConfigFile -PathType Leaf) "Configuration exists at $ConfigFile"
Show-Check (Test-Path -LiteralPath $LogDirectory -PathType Container) "Log directory exists at $LogDirectory"

$legacyVbs = if ([string]::IsNullOrWhiteSpace($env:APPDATA)) {
    $null
}
else {
    Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\srun_login.vbs'
}
if ($null -ne $legacyVbs) {
    Show-Check (-not (Test-Path -LiteralPath $legacyVbs -PathType Leaf)) 'Legacy Startup/VBS launcher is absent for the current user'
}

Write-Host ''
if ($failed) {
    Write-Host 'Verification found one or more setup problems.' -ForegroundColor Red
    exit 1
}

Write-Host 'The Windows startup integration is installed correctly.' -ForegroundColor Green
exit 0
