<#
.SYNOPSIS
    Helper functions for sending data to Dynatrace APIs.

.DESCRIPTION
    This module provides functions to send metrics and logs to Dynatrace:
    - Send-DynatraceMetrics: Sends metrics via the Metrics Ingest API v2
    - Send-DynatraceLogs: Sends log entries via the Logs Ingest API v2

.NOTES
    Required API Token Scopes:
    - metrics.ingest (for metrics)
    - logs.ingest (for logs)
#>

#region API Token Management

function Get-DynatraceApiToken {
    <#
    .SYNOPSIS
        Retrieves the Dynatrace API token from various sources.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config
    )

    $token = $null

    # Try environment variable first
    if ($Config.dynatrace.apiTokenEnvVar) {
        $token = [Environment]::GetEnvironmentVariable($Config.dynatrace.apiTokenEnvVar)
        if ($token) {
            Write-Verbose "Retrieved API token from environment variable"
            return $token
        }
    }

    # Try Windows Credential Manager
    if ($Config.dynatrace.credentialName) {
        try {
            $cred = Get-StoredCredential -Target $Config.dynatrace.credentialName
            if ($cred) {
                $token = $cred.GetNetworkCredential().Password
                Write-Verbose "Retrieved API token from Credential Manager"
                return $token
            }
        }
        catch {
            Write-Verbose "Could not retrieve from Credential Manager: $_"
        }
    }

    # Try direct value (not recommended for production)
    if ($Config.dynatrace.apiToken) {
        Write-Warning "Using API token from config file. Consider using environment variables or Credential Manager for production."
        return $Config.dynatrace.apiToken
    }

    throw "No Dynatrace API token found. Set environment variable '$($Config.dynatrace.apiTokenEnvVar)' or configure credential."
}

#endregion

#region Metrics API

function Send-DynatraceMetrics {
    <#
    .SYNOPSIS
        Sends metrics to Dynatrace Metrics Ingest API v2.

    .PARAMETER EnvironmentUrl
        The Dynatrace environment URL (e.g., https://abc12345.live.dynatrace.com)

    .PARAMETER ApiToken
        The API token with metrics.ingest scope

    .PARAMETER MetricsData
        The metrics data in Dynatrace metrics ingest format (line protocol)

    .EXAMPLE
        $metrics = "custom.db.query.count,db=mydb 5"
        Send-DynatraceMetrics -EnvironmentUrl "https://abc.live.dynatrace.com" -ApiToken $token -MetricsData $metrics
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$EnvironmentUrl,

        [Parameter(Mandatory = $true)]
        [string]$ApiToken,

        [Parameter(Mandatory = $true)]
        [string]$MetricsData
    )

    $uri = "$($EnvironmentUrl.TrimEnd('/'))/api/v2/metrics/ingest"

    $headers = @{
        "Authorization" = "Api-Token $ApiToken"
        "Content-Type"  = "text/plain; charset=utf-8"
    }

    try {
        Write-Verbose "Sending metrics to: $uri"
        Write-Verbose "Payload:`n$MetricsData"

        $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $MetricsData -TimeoutSec 30

        if ($response.linesOk -gt 0) {
            Write-Verbose "Successfully sent $($response.linesOk) metric lines"
        }
        if ($response.linesInvalid -gt 0) {
            Write-Warning "Failed to send $($response.linesInvalid) metric lines"
            if ($response.error) {
                Write-Warning "Errors: $($response.error | ConvertTo-Json -Compress)"
            }
        }

        return $response
    }
    catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        $errorBody = $null

        try {
            $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
            $errorBody = $reader.ReadToEnd()
        }
        catch { }

        Write-Error "Failed to send metrics to Dynatrace (HTTP $statusCode): $errorBody"
        throw
    }
}

#endregion

#region Logs API

function Send-DynatraceLogs {
    <#
    .SYNOPSIS
        Sends log entries to Dynatrace Logs Ingest API v2.

    .PARAMETER EnvironmentUrl
        The Dynatrace environment URL (e.g., https://abc12345.live.dynatrace.com)

    .PARAMETER ApiToken
        The API token with logs.ingest scope

    .PARAMETER LogEntries
        Array of hashtables representing log entries

    .EXAMPLE
        $logs = @(
            @{ content = "Query text"; "db.name" = "mydb"; severity = "WARN" }
        )
        Send-DynatraceLogs -EnvironmentUrl "https://abc.live.dynatrace.com" -ApiToken $token -LogEntries $logs
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$EnvironmentUrl,

        [Parameter(Mandatory = $true)]
        [string]$ApiToken,

        [Parameter(Mandatory = $true)]
        [array]$LogEntries
    )

    $uri = "$($EnvironmentUrl.TrimEnd('/'))/api/v2/logs/ingest"

    $headers = @{
        "Authorization" = "Api-Token $ApiToken"
        "Content-Type"  = "application/json; charset=utf-8"
    }

    # Batch logs if there are many (Dynatrace has limits)
    $batchSize = 100
    $totalSent = 0

    for ($i = 0; $i -lt $LogEntries.Count; $i += $batchSize) {
        $batch = $LogEntries[$i..([Math]::Min($i + $batchSize - 1, $LogEntries.Count - 1))]

        # Add timestamp if not present
        foreach ($entry in $batch) {
            if (-not $entry.ContainsKey("timestamp")) {
                $entry["timestamp"] = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            }
        }

        $body = $batch | ConvertTo-Json -Depth 10 -Compress

        # Ensure it's always an array
        if ($batch.Count -eq 1) {
            $body = "[$body]"
        }

        try {
            Write-Verbose "Sending $($batch.Count) log entries to: $uri"

            $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body -TimeoutSec 30
            $totalSent += $batch.Count

            Write-Verbose "Successfully sent batch of $($batch.Count) log entries"
        }
        catch {
            $statusCode = $_.Exception.Response.StatusCode.value__
            $errorBody = $null

            try {
                $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                $errorBody = $reader.ReadToEnd()
            }
            catch { }

            Write-Error "Failed to send logs to Dynatrace (HTTP $statusCode): $errorBody"
            throw
        }
    }

    Write-Verbose "Total log entries sent: $totalSent"
    return @{ sent = $totalSent }
}

#endregion

#region Credential Helper

function Get-StoredCredential {
    <#
    .SYNOPSIS
        Retrieves a credential from Windows Credential Manager.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Target
    )

    # Try using CredentialManager module if available
    if (Get-Module -ListAvailable -Name CredentialManager) {
        Import-Module CredentialManager -ErrorAction SilentlyContinue
        return Get-StoredCredential -Target $Target
    }

    # Fallback: Use cmdkey and parse output (basic implementation)
    $output = cmdkey /list:$Target 2>&1
    if ($output -match "not found") {
        return $null
    }

    # For full implementation, consider using the CredentialManager module
    Write-Warning "CredentialManager module not found. Install it with: Install-Module CredentialManager"
    return $null
}

function Set-DynatraceCredential {
    <#
    .SYNOPSIS
        Stores Dynatrace API token in Windows Credential Manager.

    .EXAMPLE
        Set-DynatraceCredential -Target "DynatraceApiToken" -ApiToken "dt0c01.xxxxx"
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Target,

        [Parameter(Mandatory = $true)]
        [string]$ApiToken
    )

    if (Get-Module -ListAvailable -Name CredentialManager) {
        Import-Module CredentialManager
        New-StoredCredential -Target $Target -UserName "dynatrace" -Password $ApiToken -Type Generic -Persist LocalMachine
        Write-Host "Credential stored successfully"
    }
    else {
        # Fallback using cmdkey
        cmdkey /generic:$Target /user:dynatrace /pass:$ApiToken
        Write-Host "Credential stored using cmdkey"
    }
}

#endregion

#region Utility Functions

function Test-DynatraceConnection {
    <#
    .SYNOPSIS
        Tests connectivity to Dynatrace environment.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$EnvironmentUrl,

        [Parameter(Mandatory = $true)]
        [string]$ApiToken
    )

    $uri = "$($EnvironmentUrl.TrimEnd('/'))/api/v2/metrics/descriptors?pageSize=1"

    $headers = @{
        "Authorization" = "Api-Token $ApiToken"
    }

    try {
        $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers -TimeoutSec 10
        Write-Host "Successfully connected to Dynatrace environment" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Error "Failed to connect to Dynatrace: $_"
        return $false
    }
}

#endregion
