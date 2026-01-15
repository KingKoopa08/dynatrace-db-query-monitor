<#
.SYNOPSIS
    Collects long-running queries from SQL Server and sends metrics/logs to Dynatrace.

.DESCRIPTION
    Calls the maintenance.dbo.usp_GetLongRunningQueries stored procedure and sends:
    - Metrics to Dynatrace Metrics Ingest API
    - Logs to Dynatrace Logs Ingest API

.PARAMETER ConfigPath
    Path to the configuration JSON file. Defaults to config.json in the script directory.

.EXAMPLE
    .\Get-LongRunningQueries.ps1
    .\Get-LongRunningQueries.ps1 -ConfigPath "C:\monitoring\config.json"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Import Dynatrace helper functions
. "$ScriptDir\Send-ToDynatrace.ps1"

#region Configuration

function Get-Configuration {
    param([string]$Path)

    if ([string]::IsNullOrEmpty($Path)) {
        $Path = Join-Path $ScriptDir "config.json"
    }

    if (-not (Test-Path $Path)) {
        throw "Configuration file not found: $Path"
    }

    $config = Get-Content $Path -Raw | ConvertFrom-Json
    return $config
}

#endregion

#region Main

function Main {
    param([string]$ConfigPath)

    $startTime = Get-Date
    Write-Verbose "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - Starting collection..."

    # Load configuration
    $config = Get-Configuration -Path $ConfigPath

    # Build connection string
    $connParams = @{
        ServerInstance = $config.sqlServer.serverInstance
        Database       = "maintenance"
        QueryTimeout   = 30
    }

    # Execute stored procedure
    $query = @"
EXEC dbo.usp_GetLongRunningQueries
    @DefaultThresholdSeconds = $($config.sqlServer.thresholdSeconds),
    @IncludeQueryStoreId = 1,
    @Debug = 0;
"@

    try {
        $queries = Invoke-Sqlcmd @connParams -Query $query
    }
    catch {
        Write-Error "Failed to execute stored procedure: $_"
        throw
    }

    $queryCount = if ($queries) { @($queries).Count } else { 0 }
    Write-Verbose "Found $queryCount long-running queries"

    # Get Dynatrace API token
    $apiToken = Get-DynatraceApiToken -Config $config

    # Prepare hostname
    $hostname = $config.sqlServer.serverInstance -replace '\\.*$', ''

    # Build metrics
    $metrics = @()

    if ($queryCount -gt 0) {
        # Aggregate by database
        $byDatabase = $queries | Group-Object -Property database_name

        foreach ($dbGroup in $byDatabase) {
            $dbName = $dbGroup.Name
            if ([string]::IsNullOrEmpty($dbName)) { $dbName = "unknown" }

            $dbCount = $dbGroup.Count
            $dbMaxDuration = ($dbGroup.Group | Measure-Object -Property duration_seconds -Maximum).Maximum
            $dbTotalCpu = ($dbGroup.Group | Measure-Object -Property cpu_time -Sum).Sum
            $dbTotalReads = ($dbGroup.Group | Measure-Object -Property reads -Sum).Sum

            $metrics += "custom.db.long_queries.count,db.type=mssql,db.name=$dbName,host=$hostname $dbCount"
            $metrics += "custom.db.long_queries.max_duration_seconds,db.type=mssql,db.name=$dbName,host=$hostname $dbMaxDuration"
            $metrics += "custom.db.long_queries.total_cpu_ms,db.type=mssql,db.name=$dbName,host=$hostname $dbTotalCpu"
            $metrics += "custom.db.long_queries.total_reads,db.type=mssql,db.name=$dbName,host=$hostname $dbTotalReads"
        }

        # Overall metrics
        $maxDuration = ($queries | Measure-Object -Property duration_seconds -Maximum).Maximum
        $metrics += "custom.db.long_queries.total_count,db.type=mssql,host=$hostname $queryCount"
        $metrics += "custom.db.long_queries.overall_max_duration_seconds,db.type=mssql,host=$hostname $maxDuration"
    }
    else {
        # No long-running queries - send zero
        $metrics += "custom.db.long_queries.total_count,db.type=mssql,host=$hostname 0"
    }

    # Send metrics
    if ($metrics.Count -gt 0) {
        $metricsPayload = $metrics -join "`n"
        Send-DynatraceMetrics -EnvironmentUrl $config.dynatrace.environmentUrl -ApiToken $apiToken -MetricsData $metricsPayload
        Write-Verbose "Sent $($metrics.Count) metrics to Dynatrace"
    }

    # Send logs for each query
    if ($queryCount -gt 0) {
        $logs = @()

        foreach ($query in $queries) {
            $severity = if ($query.duration_seconds -gt 300) { "ERROR" } else { "WARN" }

            $logEntry = @{
                "content"                    = if ($query.current_statement) { $query.current_statement } else { "[No statement text]" }
                "log.source"                 = "custom.db.long_running_query"
                "severity"                   = $severity
                "db.type"                    = "mssql"
                "db.name"                    = if ($query.database_name) { $query.database_name } else { "unknown" }
                "db.host"                    = $hostname
                "query.session_id"           = [string]$query.session_id
                "query.duration_seconds"     = [string]$query.duration_seconds
                "query.status"               = if ($query.status) { $query.status } else { "" }
                "query.command"              = if ($query.command) { $query.command } else { "" }
                "query.wait_type"            = if ($query.wait_type) { $query.wait_type } else { "" }
                "query.wait_time"            = [string]$query.wait_time
                "query.cpu_time_ms"          = [string]$query.cpu_time
                "query.reads"                = [string]$query.reads
                "query.writes"               = [string]$query.writes
                "query.logical_reads"        = [string]$query.logical_reads
                "query.blocking_session_id"  = [string]$query.blocking_session_id
                "query.login_name"           = if ($query.login_name) { $query.login_name } else { "" }
                "query.host_name"            = if ($query.host_name) { $query.host_name } else { "" }
                "query.program_name"         = if ($query.program_name) { $query.program_name } else { "" }
                "query.hash"                 = if ($query.query_hash_hex) { $query.query_hash_hex } else { "" }
                "query.plan_hash"            = if ($query.query_plan_hash_hex) { $query.query_plan_hash_hex } else { "" }
            }

            # Query Store IDs (for correlation)
            if ($query.query_id) {
                $logEntry["query.store_query_id"] = [string]$query.query_id
            }
            if ($query.plan_id) {
                $logEntry["query.store_plan_id"] = [string]$query.plan_id
            }

            # Full query text if different from current statement
            if ($query.query_text_truncated -and $query.query_text_truncated -ne $query.current_statement) {
                $logEntry["query.full_text"] = $query.query_text_truncated
            }

            $logs += $logEntry
        }

        Send-DynatraceLogs -EnvironmentUrl $config.dynatrace.environmentUrl -ApiToken $apiToken -LogEntries $logs
        Write-Verbose "Sent $($logs.Count) log entries to Dynatrace"
    }

    $elapsed = ((Get-Date) - $startTime).TotalMilliseconds
    Write-Verbose "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - Collection completed in $($elapsed)ms"
}

# Execute
try {
    Main -ConfigPath $ConfigPath
    exit 0
}
catch {
    Write-Error "Script failed: $_"
    exit 1
}

#endregion
