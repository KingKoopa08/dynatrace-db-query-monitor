<#
.SYNOPSIS
    Installs or uninstalls the Long-Running Query Monitor as a Windows Scheduled Task.

.DESCRIPTION
    Creates a scheduled task that runs at system startup and keeps the monitoring
    script running persistently. The script loops internally - no repeated process spawning.

    Works on Windows Server Core (no GUI required).

.PARAMETER Install
    Install the scheduled task (default action).

.PARAMETER Uninstall
    Remove the scheduled task.

.PARAMETER ServiceAccount
    The account to run the task as. Use format: DOMAIN\Username or .\LocalUser
    If not specified, runs as SYSTEM.

.PARAMETER ServicePassword
    Password for the service account. Required if ServiceAccount is specified (unless gMSA).

.EXAMPLE
    # Install as SYSTEM (default)
    .\Install-ScheduledTask.ps1

    # Install with service account
    .\Install-ScheduledTask.ps1 -ServiceAccount "DOMAIN\svc_sqlmonitor" -ServicePassword (Read-Host -AsSecureString)

    # Uninstall
    .\Install-ScheduledTask.ps1 -Uninstall

    # Check status (Server Core)
    Get-ScheduledTask -TaskName "DynatraceSQLMonitor"
    Get-ScheduledTaskInfo -TaskName "DynatraceSQLMonitor"
#>

[CmdletBinding(DefaultParameterSetName = 'Install')]
param(
    [Parameter(ParameterSetName = 'Install')]
    [switch]$Install,

    [Parameter(ParameterSetName = 'Uninstall')]
    [switch]$Uninstall,

    [Parameter(ParameterSetName = 'Install')]
    [string]$ServiceAccount,

    [Parameter(ParameterSetName = 'Install')]
    [SecureString]$ServicePassword
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

#region Configuration

# Load config to get task name
$configPath = Join-Path $ScriptDir "config.json"
if (Test-Path $configPath) {
    $config = Get-Content $configPath -Raw | ConvertFrom-Json
    $TaskName = if ($config.service.serviceName) { $config.service.serviceName } else { "DynatraceSQLMonitor" }
}
else {
    $TaskName = "DynatraceSQLMonitor"
}

$TaskDescription = "Monitors SQL Server for long-running queries and sends metrics/logs to Dynatrace. Runs persistently from startup."
$TaskPath = "\Dynatrace\"
$ScriptPath = Join-Path $ScriptDir "Get-LongRunningQueries.ps1"
$LogDir = Join-Path $ScriptDir "logs"

#endregion

#region Install Task

function Install-MonitoringTask {
    param(
        [string]$Account,
        [SecureString]$Password
    )

    Write-Host "Installing scheduled task: $TaskName" -ForegroundColor Cyan
    Write-Host "  Script: $ScriptPath"
    Write-Host "  Task Path: $TaskPath"

    # Create log directory
    if (-not (Test-Path $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
        Write-Host "  Created log directory: $LogDir"
    }

    # Remove existing task if present
    $existingTask = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
    if ($existingTask) {
        Write-Host "  Removing existing task..." -ForegroundColor Yellow
        Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Confirm:$false
    }

    # Build the action - PowerShell with logging
    $logFile = Join-Path $LogDir "service.log"
    $errorLogFile = Join-Path $LogDir "service-error.log"

    # PowerShell command that logs output to files
    $psCommand = @"
-NoProfile -ExecutionPolicy Bypass -Command "&{ `$ErrorActionPreference='Continue'; & '$ScriptPath' *>> '$logFile' 2>> '$errorLogFile' }"
"@

    $action = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument $psCommand `
        -WorkingDirectory $ScriptDir

    # Triggers:
    # 1. At system startup
    # 2. Repeating trigger every 10 minutes - ensures restart after maxRuntimeHours
    #    (MultipleInstances IgnoreNew prevents duplicate instances)
    $startupTrigger = New-ScheduledTaskTrigger -AtStartup

    # Create a daily trigger with 10-minute repetition for 24 hours (effectively forever)
    $repetitionTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes 10)

    $triggers = @($startupTrigger, $repetitionTrigger)

    # Settings
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -RestartCount 999 `
        -ExecutionTimeLimit (New-TimeSpan -Days 365) `
        -MultipleInstances IgnoreNew

    # Principal (who runs the task)
    if ($Account) {
        Write-Host "  Running as: $Account"
        if ($Password) {
            $plainPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
            )
            $principal = New-ScheduledTaskPrincipal `
                -UserId $Account `
                -LogonType Password `
                -RunLevel Highest

            Register-ScheduledTask `
                -TaskName $TaskName `
                -TaskPath $TaskPath `
                -Action $action `
                -Trigger $triggers `
                -Settings $settings `
                -Principal $principal `
                -Description $TaskDescription `
                -User $Account `
                -Password $plainPassword | Out-Null
        }
        else {
            # gMSA account
            $principal = New-ScheduledTaskPrincipal `
                -UserId $Account `
                -LogonType Password `
                -RunLevel Highest

            Register-ScheduledTask `
                -TaskName $TaskName `
                -TaskPath $TaskPath `
                -Action $action `
                -Trigger $triggers `
                -Settings $settings `
                -Principal $principal `
                -Description $TaskDescription | Out-Null
        }
    }
    else {
        Write-Host "  Running as: SYSTEM"
        $principal = New-ScheduledTaskPrincipal `
            -UserId "SYSTEM" `
            -LogonType ServiceAccount `
            -RunLevel Highest

        Register-ScheduledTask `
            -TaskName $TaskName `
            -TaskPath $TaskPath `
            -Action $action `
            -Trigger $trigger `
            -Settings $settings `
            -Principal $principal `
            -Description $TaskDescription | Out-Null
    }

    Write-Host ""
    Write-Host "Scheduled task installed successfully!" -ForegroundColor Green
    Write-Host ""
    Write-Host "Task Management (Server Core compatible):" -ForegroundColor Cyan
    Write-Host "  Status:    Get-ScheduledTask -TaskName '$TaskName' -TaskPath '$TaskPath'"
    Write-Host "  Info:      Get-ScheduledTaskInfo -TaskName '$TaskName' -TaskPath '$TaskPath'"
    Write-Host "  Start:     Start-ScheduledTask -TaskName '$TaskName' -TaskPath '$TaskPath'"
    Write-Host "  Stop:      Stop-ScheduledTask -TaskName '$TaskName' -TaskPath '$TaskPath'"
    Write-Host "  Logs:      Get-Content '$logFile' -Tail 50"
    Write-Host "  Errors:    Get-Content '$errorLogFile' -Tail 50"
    Write-Host ""
    Write-Host "The task runs at startup and restarts automatically on failure."
    Write-Host ""

    # Ask to start
    $start = Read-Host "Start the task now? (Y/n)"
    if ($start -ne 'n' -and $start -ne 'N') {
        Write-Host "Starting task..."
        Start-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath
        Start-Sleep -Seconds 3

        $taskInfo = Get-ScheduledTaskInfo -TaskName $TaskName -TaskPath $TaskPath
        $task = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath

        Write-Host ""
        Write-Host "Task Status:" -ForegroundColor Cyan
        Write-Host "  State: $($task.State)"
        Write-Host "  Last Run: $($taskInfo.LastRunTime)"
        Write-Host "  Last Result: $($taskInfo.LastTaskResult)"

        if ($task.State -eq 'Running') {
            Write-Host ""
            Write-Host "Task is running. Check logs for output:" -ForegroundColor Green
            Write-Host "  Get-Content '$logFile' -Tail 20 -Wait"
        }
    }
}

#endregion

#region Uninstall Task

function Uninstall-MonitoringTask {
    Write-Host "Uninstalling scheduled task: $TaskName" -ForegroundColor Cyan

    $existingTask = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
    if (-not $existingTask) {
        Write-Host "Task not found. Nothing to uninstall." -ForegroundColor Yellow
        return
    }

    # Stop if running
    if ($existingTask.State -eq 'Running') {
        Write-Host "  Stopping task..."
        Stop-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath
        Start-Sleep -Seconds 2
    }

    Write-Host "  Removing task..."
    Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Confirm:$false

    Write-Host "Scheduled task uninstalled successfully!" -ForegroundColor Green
}

#endregion

#region Main

# Check for admin rights
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    throw "This script must be run as Administrator"
}

# Verify script exists
if (-not (Test-Path $ScriptPath)) {
    throw "Monitoring script not found: $ScriptPath"
}

# Execute action
if ($Uninstall) {
    Uninstall-MonitoringTask
}
else {
    Install-MonitoringTask -Account $ServiceAccount -Password $ServicePassword
}

#endregion
