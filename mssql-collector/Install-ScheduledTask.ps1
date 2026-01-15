<#
.SYNOPSIS
    Creates a Windows Scheduled Task to run the long-running query collector.

.DESCRIPTION
    This script creates a scheduled task that runs Get-LongRunningQueries.ps1
    at a configurable interval (default: every 60 seconds).

.PARAMETER TaskName
    The name of the scheduled task. Default: "DynatraceSQLQueryMonitor"

.PARAMETER IntervalSeconds
    How often to run the task in seconds. Default: 60

.PARAMETER ScriptPath
    Path to the Get-LongRunningQueries.ps1 script. Defaults to same directory.

.PARAMETER RunAsUser
    Username to run the task as. Default: SYSTEM

.PARAMETER Uninstall
    If specified, removes the scheduled task instead of creating it.

.EXAMPLE
    .\Install-ScheduledTask.ps1
    .\Install-ScheduledTask.ps1 -IntervalSeconds 30
    .\Install-ScheduledTask.ps1 -Uninstall

.NOTES
    Requires: Administrator privileges
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$TaskName = "DynatraceSQLQueryMonitor",

    [Parameter(Mandatory = $false)]
    [ValidateRange(30, 3600)]
    [int]$IntervalSeconds = 60,

    [Parameter(Mandatory = $false)]
    [string]$ScriptPath,

    [Parameter(Mandatory = $false)]
    [string]$RunAsUser = "SYSTEM",

    [Parameter(Mandatory = $false)]
    [switch]$Uninstall
)

# Requires admin privileges
#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Determine script path
if ([string]::IsNullOrEmpty($ScriptPath)) {
    $ScriptPath = Join-Path $ScriptDir "Get-LongRunningQueries.ps1"
}

if (-not (Test-Path $ScriptPath) -and -not $Uninstall) {
    throw "Script not found: $ScriptPath"
}

function Remove-MonitoringTask {
    param([string]$Name)

    $existingTask = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue

    if ($existingTask) {
        Write-Host "Removing scheduled task: $Name"
        Unregister-ScheduledTask -TaskName $Name -Confirm:$false
        Write-Host "Task removed successfully" -ForegroundColor Green
    }
    else {
        Write-Host "Task not found: $Name" -ForegroundColor Yellow
    }
}

function Install-MonitoringTask {
    param(
        [string]$Name,
        [string]$Path,
        [int]$Interval,
        [string]$User
    )

    # Remove existing task if present
    $existingTask = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
    if ($existingTask) {
        Write-Host "Removing existing task..."
        Unregister-ScheduledTask -TaskName $Name -Confirm:$false
    }

    Write-Host "Creating scheduled task: $Name"
    Write-Host "  Script: $Path"
    Write-Host "  Interval: $Interval seconds"
    Write-Host "  Run As: $User"

    # Create the action
    $action = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$Path`"" `
        -WorkingDirectory (Split-Path $Path -Parent)

    # Create a trigger that runs at startup and repeats
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $trigger.Repetition = (New-ScheduledTaskTrigger -Once -At "00:00" -RepetitionInterval (New-TimeSpan -Seconds $Interval)).Repetition

    # Also create a trigger that starts immediately
    $triggerNow = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Seconds $Interval)

    # Create settings
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -RunOnlyIfNetworkAvailable `
        -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

    # Create principal (run as)
    if ($User -eq "SYSTEM") {
        $principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    }
    else {
        $principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Password -RunLevel Highest
    }

    # Register the task
    $task = Register-ScheduledTask `
        -TaskName $Name `
        -Action $action `
        -Trigger $triggerNow `
        -Settings $settings `
        -Principal $principal `
        -Description "Monitors SQL Server for long-running queries and sends data to Dynatrace"

    Write-Host "Task created successfully" -ForegroundColor Green

    # Start the task immediately
    Write-Host "Starting task..."
    Start-ScheduledTask -TaskName $Name
    Write-Host "Task started" -ForegroundColor Green

    return $task
}

# Main execution
if ($Uninstall) {
    Remove-MonitoringTask -Name $TaskName
}
else {
    # Validate prerequisites
    Write-Host "Checking prerequisites..."

    # Check for SqlServer module
    if (-not (Get-Module -ListAvailable -Name SqlServer)) {
        Write-Warning "SqlServer PowerShell module not found. Installing..."
        try {
            Install-Module -Name SqlServer -Scope CurrentUser -Force -AllowClobber
            Write-Host "SqlServer module installed" -ForegroundColor Green
        }
        catch {
            Write-Error "Failed to install SqlServer module. Please run: Install-Module -Name SqlServer"
            throw
        }
    }

    # Check for config file
    $configPath = Join-Path $ScriptDir "config.json"
    if (-not (Test-Path $configPath)) {
        Write-Warning "Config file not found at: $configPath"
        Write-Warning "Please create the config file before running the task"
    }

    # Check for API token
    $envToken = [Environment]::GetEnvironmentVariable("DT_API_TOKEN", "Machine")
    if (-not $envToken) {
        Write-Warning "DT_API_TOKEN environment variable not set at machine level"
        Write-Warning "Set it with: [Environment]::SetEnvironmentVariable('DT_API_TOKEN', 'your-token', 'Machine')"
    }

    Install-MonitoringTask -Name $TaskName -Path $ScriptPath -Interval $IntervalSeconds -User $RunAsUser
}

Write-Host ""
Write-Host "Task Management Commands:" -ForegroundColor Cyan
Write-Host "  View status:  Get-ScheduledTask -TaskName '$TaskName'"
Write-Host "  Start:        Start-ScheduledTask -TaskName '$TaskName'"
Write-Host "  Stop:         Stop-ScheduledTask -TaskName '$TaskName'"
Write-Host "  Run now:      Start-ScheduledTask -TaskName '$TaskName'"
Write-Host "  Remove:       .\Install-ScheduledTask.ps1 -Uninstall"
