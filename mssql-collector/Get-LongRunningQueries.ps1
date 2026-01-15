<#
.SYNOPSIS
    Collects long-running queries from SQL Server and sends metrics/logs to Dynatrace.

.DESCRIPTION
    Calls the maintenance.dbo.usp_GetLongRunningQueries stored procedure and sends:
    - Metrics to Dynatrace Metrics Ingest API
    - Logs to Dynatrace Logs Ingest API (with full diagnostic details)

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

    # Prepare hostname - use actual computer name, not config value
    $hostname = $env:COMPUTERNAME
    if ([string]::IsNullOrEmpty($hostname)) {
        $hostname = [System.Net.Dns]::GetHostName()
    }

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
            $dbTotalLogicalReads = ($dbGroup.Group | Measure-Object -Property logical_reads -Sum).Sum
            $dbTotalMemoryKb = ($dbGroup.Group | Measure-Object -Property granted_query_memory_kb -Sum).Sum

            $metrics += "custom.db.long_queries.count,db.type=mssql,db.name=$dbName,host=$hostname $dbCount"
            $metrics += "custom.db.long_queries.max_duration_seconds,db.type=mssql,db.name=$dbName,host=$hostname $dbMaxDuration"
            $metrics += "custom.db.long_queries.total_cpu_ms,db.type=mssql,db.name=$dbName,host=$hostname $dbTotalCpu"
            $metrics += "custom.db.long_queries.total_reads,db.type=mssql,db.name=$dbName,host=$hostname $dbTotalReads"
            $metrics += "custom.db.long_queries.total_logical_reads,db.type=mssql,db.name=$dbName,host=$hostname $dbTotalLogicalReads"
            $metrics += "custom.db.long_queries.total_memory_kb,db.type=mssql,db.name=$dbName,host=$hostname $dbTotalMemoryKb"
        }

        # Overall metrics
        $maxDuration = ($queries | Measure-Object -Property duration_seconds -Maximum).Maximum
        $blockedCount = ($queries | Where-Object { $_.blocking_session_id -gt 0 }).Count

        $metrics += "custom.db.long_queries.total_count,db.type=mssql,host=$hostname $queryCount"
        $metrics += "custom.db.long_queries.overall_max_duration_seconds,db.type=mssql,host=$hostname $maxDuration"
        $metrics += "custom.db.long_queries.blocked_count,db.type=mssql,host=$hostname $blockedCount"
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

    # Send logs for each query with full diagnostic details
    if ($queryCount -gt 0) {
        $logs = @()

        foreach ($q in $queries) {
            $severity = if ($q.duration_seconds -gt 300) { "ERROR" } else { "WARN" }

            $logEntry = @{
                # Core identifiers
                "content"                    = if ($q.current_statement) { $q.current_statement } else { "[No statement text]" }
                "log.source"                 = "custom.db.long_running_query"
                "severity"                   = $severity

                # Database info
                "db.type"                    = "mssql"
                "db.name"                    = if ($q.database_name) { $q.database_name } else { "unknown" }
                "db.host"                    = $hostname
                "db.server"                  = if ($q.server_name) { $q.server_name } else { $hostname }

                # Session info
                "query.session_id"           = [string]$q.session_id
                "query.login_name"           = if ($q.login_name) { $q.login_name } else { "" }
                "query.client_host"          = if ($q.host_name) { $q.host_name } else { "" }
                "query.program_name"         = if ($q.program_name) { $q.program_name } else { "" }

                # Timing
                "query.duration_seconds"     = [string]$q.duration_seconds
                "query.start_time"           = if ($q.start_time) { $q.start_time.ToString("yyyy-MM-ddTHH:mm:ss") } else { "" }
                "query.cpu_time_ms"          = [string]$q.cpu_time

                # Status
                "query.status"               = if ($q.status) { $q.status } else { "" }
                "query.command"              = if ($q.command) { $q.command } else { "" }

                # Wait info
                "query.wait_type"            = if ($q.wait_type) { $q.wait_type } else { "" }
                "query.wait_time_ms"         = [string]$q.wait_time
                "query.last_wait_type"       = if ($q.last_wait_type) { $q.last_wait_type } else { "" }

                # I/O
                "query.reads"                = [string]$q.reads
                "query.writes"               = [string]$q.writes
                "query.logical_reads"        = [string]$q.logical_reads
                "query.row_count"            = [string]$q.row_count

                # Memory
                "query.granted_memory_kb"    = [string]$q.granted_query_memory_kb

                # Blocking
                "query.blocking_session_id"  = [string]$q.blocking_session_id
                "query.is_blocked"           = if ($q.blocking_session_id -gt 0) { "true" } else { "false" }

                # Transaction
                "query.open_transaction_count" = [string]$q.open_transaction_count
                "query.isolation_level"      = if ($q.isolation_level_desc) { $q.isolation_level_desc } else { "" }

                # Progress (for long operations like backups)
                "query.percent_complete"     = [string]$q.percent_complete
                "query.estimated_completion_ms" = [string]$q.estimated_completion_time_ms

                # Query Store correlation
                "query.hash"                 = if ($q.query_hash_hex) { $q.query_hash_hex } else { "" }
                "query.plan_hash"            = if ($q.query_plan_hash_hex) { $q.query_plan_hash_hex } else { "" }
            }

            # Query Store IDs (if available)
            if ($q.query_id) {
                $logEntry["query.store_query_id"] = [string]$q.query_id
            }
            if ($q.plan_id) {
                $logEntry["query.store_plan_id"] = [string]$q.plan_id
            }

            # Full query text if different from current statement
            if ($q.query_text_truncated -and $q.query_text_truncated -ne $q.current_statement) {
                $logEntry["query.full_text"] = $q.query_text_truncated
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
