<#
.SYNOPSIS
    Installs or uninstalls the Long-Running Query Monitor as a Windows Service using NSSM.

.DESCRIPTION
    Uses NSSM (Non-Sucking Service Manager) to run the PowerShell monitoring script as a Windows Service.
    The service will automatically restart when it exits (after max runtime or on error).

.PARAMETER Install
    Install the service (default action).

.PARAMETER Uninstall
    Remove the service.

.PARAMETER ServiceAccount
    The account to run the service as. Use format: DOMAIN\Username or .\LocalUser
    If not specified, runs as Local System.

.PARAMETER ServicePassword
    Password for the service account. Required if ServiceAccount is specified.
    For gMSA accounts, omit this parameter.

.PARAMETER NssmPath
    Path to nssm.exe. If not specified, looks in script directory, then PATH.

.EXAMPLE
    # Install as Local System
    .\Install-Service.ps1

    # Install with service account
    .\Install-Service.ps1 -ServiceAccount "DOMAIN\svc_sqlmonitor" -ServicePassword (Read-Host -AsSecureString)

    # Install with gMSA (no password needed)
    .\Install-Service.ps1 -ServiceAccount "DOMAIN\gMSA_SQLMon$"

    # Uninstall
    .\Install-Service.ps1 -Uninstall
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
    [SecureString]$ServicePassword,

    [Parameter()]
    [string]$NssmPath
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

#region Configuration

# Load config to get service name
$configPath = Join-Path $ScriptDir "config.json"
if (Test-Path $configPath) {
    $config = Get-Content $configPath -Raw | ConvertFrom-Json
    $ServiceName = if ($config.service.serviceName) { $config.service.serviceName } else { "DynatraceSQLMonitor" }
}
else {
    $ServiceName = "DynatraceSQLMonitor"
}

$ServiceDisplayName = "Dynatrace SQL Server Long-Running Query Monitor"
$ServiceDescription = "Monitors SQL Server for long-running queries and sends metrics/logs to Dynatrace"
$ScriptPath = Join-Path $ScriptDir "Get-LongRunningQueries.ps1"

#endregion

#region Find NSSM

function Find-Nssm {
    param([string]$ProvidedPath)

    # Check provided path
    if ($ProvidedPath -and (Test-Path $ProvidedPath)) {
        return $ProvidedPath
    }

    # Check script directory
    $localNssm = Join-Path $ScriptDir "nssm.exe"
    if (Test-Path $localNssm) {
        return $localNssm
    }

    # Check PATH
    $pathNssm = Get-Command nssm.exe -ErrorAction SilentlyContinue
    if ($pathNssm) {
        return $pathNssm.Source
    }

    return $null
}

#endregion

#region Install Service

function Install-MonitoringService {
    param(
        [string]$Nssm,
        [string]$Account,
        [SecureString]$Password
    )

    Write-Host "Installing service: $ServiceName" -ForegroundColor Cyan
    Write-Host "  Display Name: $ServiceDisplayName"
    Write-Host "  Script: $ScriptPath"

    # Check if service already exists
    $existingService = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($existingService) {
        Write-Host "  Service already exists. Stopping and removing..." -ForegroundColor Yellow
        & $Nssm stop $ServiceName 2>$null
        & $Nssm remove $ServiceName confirm
        Start-Sleep -Seconds 2
    }

    # Install service
    Write-Host "  Installing service..."
    & $Nssm install $ServiceName "powershell.exe" "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to install service"
    }

    # Configure service settings
    Write-Host "  Configuring service..."

    # Display name and description
    & $Nssm set $ServiceName DisplayName $ServiceDisplayName
    & $Nssm set $ServiceName Description $ServiceDescription

    # Working directory
    & $Nssm set $ServiceName AppDirectory $ScriptDir

    # Startup type: Automatic
    & $Nssm set $ServiceName Start SERVICE_AUTO_START

    # Restart on exit (this is the key feature)
    & $Nssm set $ServiceName AppExit Default Restart
    & $Nssm set $ServiceName AppRestartDelay 5000  # 5 second delay before restart

    # Stdout/Stderr logging
    $logDir = Join-Path $ScriptDir "logs"
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    & $Nssm set $ServiceName AppStdout (Join-Path $logDir "service.log")
    & $Nssm set $ServiceName AppStderr (Join-Path $logDir "service-error.log")
    & $Nssm set $ServiceName AppStdoutCreationDisposition 4  # Append
    & $Nssm set $ServiceName AppStderrCreationDisposition 4  # Append
    & $Nssm set $ServiceName AppRotateFiles 1
    & $Nssm set $ServiceName AppRotateBytes 10485760  # 10 MB

    # Service account
    if ($Account) {
        Write-Host "  Setting service account: $Account"
        if ($Password) {
            $plainPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
            )
            & $Nssm set $ServiceName ObjectName $Account $plainPassword
        }
        else {
            # gMSA account (no password)
            & $Nssm set $ServiceName ObjectName $Account
        }
    }
    else {
        Write-Host "  Running as: Local System"
    }

    Write-Host ""
    Write-Host "Service installed successfully!" -ForegroundColor Green
    Write-Host ""
    Write-Host "Commands:" -ForegroundColor Cyan
    Write-Host "  Start:   Start-Service $ServiceName"
    Write-Host "  Stop:    Stop-Service $ServiceName"
    Write-Host "  Status:  Get-Service $ServiceName"
    Write-Host "  Logs:    Get-Content '$logDir\service.log' -Tail 50"
    Write-Host ""
    Write-Host "The service will automatically restart after max runtime or on error."
    Write-Host ""

    # Ask to start
    $start = Read-Host "Start the service now? (Y/n)"
    if ($start -ne 'n' -and $start -ne 'N') {
        Write-Host "Starting service..."
        Start-Service $ServiceName
        Start-Sleep -Seconds 2
        Get-Service $ServiceName | Format-Table Name, Status, StartType -AutoSize
    }
}

#endregion

#region Uninstall Service

function Uninstall-MonitoringService {
    param([string]$Nssm)

    Write-Host "Uninstalling service: $ServiceName" -ForegroundColor Cyan

    $existingService = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $existingService) {
        Write-Host "Service not found. Nothing to uninstall." -ForegroundColor Yellow
        return
    }

    Write-Host "  Stopping service..."
    & $Nssm stop $ServiceName 2>$null
    Start-Sleep -Seconds 2

    Write-Host "  Removing service..."
    & $Nssm remove $ServiceName confirm

    if ($LASTEXITCODE -eq 0) {
        Write-Host "Service uninstalled successfully!" -ForegroundColor Green
    }
    else {
        throw "Failed to uninstall service"
    }
}

#endregion

#region Main

# Check for admin rights
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    throw "This script must be run as Administrator"
}

# Find NSSM
$nssm = Find-Nssm -ProvidedPath $NssmPath
if (-not $nssm) {
    Write-Host "NSSM (Non-Sucking Service Manager) not found!" -ForegroundColor Red
    Write-Host ""
    Write-Host "Please download NSSM from: https://nssm.cc/download" -ForegroundColor Yellow
    Write-Host "Extract nssm.exe to one of these locations:"
    Write-Host "  - $ScriptDir"
    Write-Host "  - A directory in your PATH"
    Write-Host ""
    throw "NSSM not found"
}

Write-Host "Using NSSM: $nssm"
Write-Host ""

# Execute action
if ($Uninstall) {
    Uninstall-MonitoringService -Nssm $nssm
}
else {
    Install-MonitoringService -Nssm $nssm -Account $ServiceAccount -Password $ServicePassword
}

#endregion
