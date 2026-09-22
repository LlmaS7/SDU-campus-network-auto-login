[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$TaskName = 'SrunLogin'
$InstallRoot = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'SrunLogin'

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Restart-Elevated {
    Write-Host 'Administrator access is required to remove the startup task.'
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath))
    $process = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $arguments -Wait -PassThru
    exit $process.ExitCode
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
        Write-Warning 'Could not enumerate every user profile.'
    }
    return $paths | Select-Object -Unique
}

if (-not (Test-Administrator)) {
    Restart-Elevated
}

Import-Module ScheduledTasks -ErrorAction Stop
$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($null -ne $task) {
    if ($task.State -eq 'Running') {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    }
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Removed scheduled task: $TaskName"
}
else {
    Write-Host "Scheduled task not found: $TaskName"
}

foreach ($path in Get-StartupArtifactPaths) {
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        Remove-Item -LiteralPath $path -Force
        Write-Host "Removed legacy Startup launcher: $path"
    }
}

$expectedRoot = [IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'SrunLogin')).TrimEnd('\')
$resolvedTarget = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
if (-not [string]::Equals($resolvedTarget, $expectedRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to remove unexpected path: $resolvedTarget"
}

if (Test-Path -LiteralPath $resolvedTarget -PathType Container) {
    Remove-Item -LiteralPath $resolvedTarget -Recurse -Force
    Write-Host "Removed installed runtime files and logs: $resolvedTarget"
}
else {
    Write-Host "Installed runtime directory not found: $resolvedTarget"
}

Write-Host 'SrunLogin Windows startup integration has been uninstalled.'
