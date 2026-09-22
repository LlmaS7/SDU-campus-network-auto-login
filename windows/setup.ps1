[CmdletBinding()]
param(
    [switch]$SkipTest
)

$ErrorActionPreference = 'Stop'
$TaskName = 'SrunLogin'
$InstallRoot = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'SrunLogin'
$InstalledScript = Join-Path $InstallRoot 'srun_login.ps1'
$InstalledConfig = Join-Path $InstallRoot 'config.ini'
$InstalledLogDirectory = Join-Path $InstallRoot 'logs'
$SourceScript = Join-Path $PSScriptRoot 'srun_login.ps1'
$LegacyConfig = Join-Path $PSScriptRoot 'config.ini'

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Restart-Elevated {
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $PSCommandPath)
    )
    if ($SkipTest) { $arguments += '-SkipTest' }

    Write-Host 'Administrator access is required to install the startup task.'
    $process = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $arguments -Wait -PassThru
    exit $process.ExitCode
}

function Read-ConfigFile {
    param([string]$Path)

    $values = @{}
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $values
    }

    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or
            $trimmed.StartsWith('#') -or
            $trimmed.StartsWith(';') -or
            ($trimmed.StartsWith('[') -and $trimmed.EndsWith(']'))) {
            continue
        }
        $separator = $line.IndexOf('=')
        if ($separator -lt 1) { continue }
        $key = $line.Substring(0, $separator).Trim().ToLowerInvariant()
        $values[$key] = $line.Substring($separator + 1).Trim()
    }
    return $values
}

function ConvertFrom-SecureInput {
    param([Security.SecureString]$SecureValue)

    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

function Read-ValueWithDefault {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [AllowEmptyString()][string]$DefaultValue
    )

    $label = if ([string]::IsNullOrWhiteSpace($DefaultValue)) { $Prompt } else { "$Prompt [$DefaultValue]" }
    $value = Read-Host $label
    if ([string]::IsNullOrWhiteSpace($value)) { return $DefaultValue }
    return $value.Trim()
}

function Get-StartupArtifactPaths {
    $paths = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($env:APPDATA)) {
        $paths.Add((Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\srun_login.vbs'))
    }

    try {
        foreach ($profile in Get-CimInstance Win32_UserProfile -ErrorAction Stop | Where-Object { -not $_.Special -and $_.LocalPath }) {
            $paths.Add((Join-Path $profile.LocalPath 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\srun_login.vbs'))
        }
    }
    catch {
        Write-Warning 'Could not enumerate every user profile; the current-user Startup folder will still be cleaned.'
    }

    return $paths | Select-Object -Unique
}

function Remove-LegacyStartupArtifacts {
    $removed = 0
    foreach ($path in Get-StartupArtifactPaths) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Remove-Item -LiteralPath $path -Force
            Write-Host "Removed legacy Startup launcher: $path"
            $removed++
        }
    }
    if ($removed -eq 0) {
        Write-Host 'No legacy Startup/VBS launcher was found.'
    }
}

function Stop-LegacyKeepaliveProcesses {
    try {
        $legacyProcesses = @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
            $_.Name -in @('powershell.exe', 'pwsh.exe') -and
            $_.CommandLine -match '(?i)(srun_login\.ps1.*-keepalive|-keepalive.*srun_login\.ps1)'
        })
        foreach ($process in $legacyProcesses) {
            Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
            Write-Host "Stopped legacy keepalive process $($process.ProcessId)."
        }
    }
    catch {
        Write-Warning 'A legacy keepalive process could not be inspected or stopped. A reboot will clear it.'
    }
}

function Install-ScheduledTask {
    Import-Module ScheduledTasks -ErrorAction Stop

    $existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($null -ne $existingTask) {
        if ($existingTask.State -eq 'Running') {
            Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        }
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }

    $actionArguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $InstalledScript
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $actionArguments -WorkingDirectory $InstallRoot
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet `
        -MultipleInstances IgnoreNew `
        -StartWhenAvailable `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries

    $task = New-ScheduledTask `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings `
        -Description 'One-shot Srun campus-network authentication at Windows startup.'

    Register-ScheduledTask -TaskName $TaskName -InputObject $task -Force | Out-Null
}

if (-not (Test-Administrator)) {
    Restart-Elevated
}

Write-Host ''
Write-Host '========================================'
Write-Host ' SrunLogin Windows one-shot installer'
Write-Host '========================================'
Write-Host ''

if (-not (Test-Path -LiteralPath $SourceScript -PathType Leaf)) {
    throw "Runtime script not found: $SourceScript"
}

$existingConfigPath = if (Test-Path -LiteralPath $InstalledConfig -PathType Leaf) {
    $InstalledConfig
}
elseif (Test-Path -LiteralPath $LegacyConfig -PathType Leaf) {
    $LegacyConfig
}
else {
    $null
}
$existing = Read-ConfigFile -Path $existingConfigPath

$username = Read-ValueWithDefault -Prompt '学号' -DefaultValue ([string]$existing['username'])
while ([string]::IsNullOrWhiteSpace($username)) {
    Write-Warning '学号不能为空。'
    $username = Read-ValueWithDefault -Prompt '学号' -DefaultValue ''
}

$hasExistingPassword = -not [string]::IsNullOrWhiteSpace([string]$existing['password'])
$passwordPrompt = if ($hasExistingPassword) { '密码（直接按回车保留原密码）' } else { '密码' }
$password = ConvertFrom-SecureInput (Read-Host $passwordPrompt -AsSecureString)
if ([string]::IsNullOrEmpty($password) -and $hasExistingPassword) {
    $password = [string]$existing['password']
}
while ([string]::IsNullOrEmpty($password)) {
    Write-Warning '密码不能为空。'
    $password = ConvertFrom-SecureInput (Read-Host '密码' -AsSecureString)
}

$defaultServer = if ([string]::IsNullOrWhiteSpace([string]$existing['server'])) { 'http://192.168.75.252' } else { [string]$existing['server'] }
$server = Read-ValueWithDefault -Prompt '确认登录认证网址' -DefaultValue $defaultServer
$server = $server.Trim().TrimEnd('/')
$serverUri = $null
while (-not [Uri]::TryCreate($server, [UriKind]::Absolute, [ref]$serverUri) -or
       $serverUri.Scheme -notin @('http', 'https') -or
       [string]::IsNullOrWhiteSpace($serverUri.Host)) {
    Write-Warning '请输入以 http:// 或 https:// 开头的完整网址。'
    $server = (Read-ValueWithDefault -Prompt '确认登录认证网址' -DefaultValue 'http://192.168.75.252').Trim().TrimEnd('/')
    $serverUri = $null
}

$acId = '1'

Write-Host ''
Write-Host "Installing runtime files to $InstallRoot ..."
New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
New-Item -ItemType Directory -Path $InstalledLogDirectory -Force | Out-Null
Copy-Item -LiteralPath $SourceScript -Destination $InstalledScript -Force

$configText = @"
[srun]
username = $username
password = $password
server = $server
ac_id = $acId
"@
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
[IO.File]::WriteAllText($InstalledConfig, $configText.Trim() + [Environment]::NewLine, $utf8Bom)

Remove-LegacyStartupArtifacts
Stop-LegacyKeepaliveProcesses

Write-Host "Creating the $TaskName startup task ..."
Install-ScheduledTask

$installedTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
if ($installedTask.Principal.UserId -notin @('SYSTEM', 'S-1-5-18')) {
    throw 'The scheduled task was created with an unexpected execution identity.'
}
Write-Host '[OK] Startup task installed for the SYSTEM account.'
Write-Host '[OK] Duplicate instances are configured as IgnoreNew.'

if (-not $SkipTest) {
    $runTest = Read-Host 'Run one authentication test now? [Y/n]'
    if ([string]::IsNullOrWhiteSpace($runTest) -or $runTest -match '^(?i)y(es)?$') {
        Write-Host ''
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $InstalledScript
        $testExitCode = $LASTEXITCODE
        Write-Host "Authentication test exit code: $testExitCode"
        if ($testExitCode -ne 0) {
            Write-Warning "The installation is complete, but the authentication test failed. See $InstallRoot\logs\srun.log"
        }
    }
}

Write-Host ''
Write-Host 'Installation complete.'
Write-Host "Task: $TaskName (At startup, SYSTEM)"
Write-Host "Log:  $InstallRoot\logs\srun.log"
Write-Host 'The PowerShell process exits after success or bounded failure; it does not remain resident.'
