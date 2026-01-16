<#
.SYNOPSIS
    Monitors SQL Server for long-running queries and sends data to Dynatrace.

.DESCRIPTION
    Runs as a persistent service that:
    - Polls for long-running queries at configurable intervals
    - Sends metrics and logs to Dynatrace
    - Logs service start/restart/shutdown events
    - Auto-restarts after configurable max runtime

.PARAMETER ConfigPath
    Path to the configuration JSON file. Defaults to config.json in the script directory.

.PARAMETER SingleRun
    Run once and exit (for testing). Default is persistent service mode.

.EXAMPLE
    .\Get-LongRunningQueries.ps1
    .\Get-LongRunningQueries.ps1 -SingleRun
    .\Get-LongRunningQueries.ps1 -ConfigPath "C:\config\config.json"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $false)]
    [switch]$SingleRun
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

    # Set defaults for service settings
    if (-not $config.service) {
        $config | Add-Member -NotePropertyName "service" -NotePropertyValue ([PSCustomObject]@{
            intervalSeconds = 60
            maxRuntimeHours = 6
            serviceName = "DynatraceSQLMonitor"
        })
    }
    if (-not $config.service.intervalSeconds) { $config.service.intervalSeconds = 60 }
    if (-not $config.service.maxRuntimeHours) { $config.service.maxRuntimeHours = 6 }
    if (-not $config.service.serviceName) { $config.service.serviceName = "DynatraceSQLMonitor" }

    return $config
}

#endregion

#region Service Lifecycle Logging

function Send-ServiceEvent {
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config,
        [Parameter(Mandatory = $true)]
        [string]$ApiToken,
        [Parameter(Mandatory = $true)]
        [string]$Hostname,
        [Parameter(Mandatory = $true)]
        [ValidateSet("START", "STOP", "RESTART", "ERROR")]
        [string]$EventType,
        [Parameter(Mandatory = $false)]
        [string]$Message = ""
    )

    $severity = switch ($EventType) {
        "START"   { "INFO" }
        "STOP"    { "INFO" }
        "RESTART" { "WARN" }
        "ERROR"   { "ERROR" }
    }

    $content = switch ($EventType) {
        "START"   { "Long-running query monitoring service started" }
        "STOP"    { "Long-running query monitoring service stopped (max runtime reached)" }
        "RESTART" { "Long-running query monitoring service restarting" }
        "ERROR"   { "Long-running query monitoring service error: $Message" }
    }

    $logEntry = @{
        "content"           = $content
        "log.source"        = "custom.db.monitoring_service"
        "severity"          = $severity
        "db.type"           = "mssql"
        "db.host"           = $Hostname
        "db.server"         = $Config.sqlServer.serverInstance
        "service.name"      = $Config.service.serviceName
        "service.event"     = $EventType
        "service.interval"  = [string]$Config.service.intervalSeconds
        "service.max_runtime_hours" = [string]$Config.service.maxRuntimeHours
    }

    if ($Message) {
        $logEntry["service.message"] = $Message
    }

    try {
        Send-DynatraceLogs -EnvironmentUrl $Config.dynatrace.environmentUrl -ApiToken $ApiToken -LogEntries @($logEntry)
        Write-Verbose "Sent service event: $EventType"
    }
    catch {
        Write-Warning "Failed to send service event to Dynatrace: $_"
    }
}

#endregion

#region Query Store Lookup

function Get-QueryStoreIds {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServerInstance,
        [Parameter(Mandatory = $true)]
        [array]$Queries
    )

    $queryStoreCache = @{}

    # Get unique databases
    $databases = @($Queries | Select-Object -ExpandProperty database_name -Unique | Where-Object { $_ })

    foreach ($dbName in $databases) {
        try {
            # Get query hashes for this database
            $dbQueryHashes = @($Queries | Where-Object { $_.database_name -eq $dbName } |
                Select-Object -ExpandProperty query_hash_hex -Unique | Where-Object { $_ })

            if ($dbQueryHashes.Count -eq 0) { continue }

            # Build IN clause
            $hashList = ($dbQueryHashes | ForEach-Object {
                $h = $_.TrimStart("0x")
                "0x$h"
            }) -join ","

            $qsQuery = @"
SELECT
    CONVERT(VARCHAR(20), q.query_hash, 1) AS query_hash_hex,
    q.query_id,
    (SELECT TOP 1 p.plan_id FROM sys.query_store_plan p WHERE p.query_id = q.query_id ORDER BY p.last_execution_time DESC) AS plan_id
FROM sys.query_store_query q
WHERE q.query_hash IN ($hashList);
"@

            $qsResults = Invoke-Sqlcmd -ServerInstance $ServerInstance -Database $dbName -Query $qsQuery -QueryTimeout 10 -ErrorAction SilentlyContinue

            if ($qsResults) {
                $dbCache = @{}
                foreach ($row in @($qsResults)) {
                    $hash = $row.query_hash_hex.ToString().ToUpper()
                    $dbCache[$hash] = @{
                        query_id = $row.query_id
                        plan_id = $row.plan_id
                    }
                }
                $queryStoreCache[$dbName] = $dbCache
                Write-Verbose "Query Store lookup for $dbName`: $($dbCache.Count) queries matched"
            }
        }
        catch {
            Write-Verbose "Query Store lookup skipped for $dbName`: $_"
        }
    }

    return $queryStoreCache
}

#endregion

#region Collection Logic

function Invoke-Collection {
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config,
        [Parameter(Mandatory = $true)]
        [string]$ApiToken,
        [Parameter(Mandatory = $true)]
        [string]$Hostname
    )

    $iterationStart = Get-Date

    # Execute stored procedure
    $query = @"
EXEC dbo.usp_GetLongRunningQueries
    @DefaultThresholdSeconds = $($Config.sqlServer.thresholdSeconds),
    @Debug = 0;
"@

    try {
        $queries = Invoke-Sqlcmd -ServerInstance $Config.sqlServer.serverInstance -Database "maintenance" -Query $query -QueryTimeout 30
    }
    catch {
        Write-Error "Failed to execute stored procedure: $_"
        throw
    }

    $queryCount = if ($queries) { @($queries).Count } else { 0 }
    Write-Verbose "Found $queryCount long-running queries"

    # Query Store enrichment
    $queryStoreCache = @{}
    if ($queryCount -gt 0) {
        $queryStoreCache = Get-QueryStoreIds -ServerInstance $Config.sqlServer.serverInstance -Queries $queries
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

            $metrics += "custom.db.long_queries.count,db.type=mssql,db.name=$dbName,host=$Hostname $dbCount"
            $metrics += "custom.db.long_queries.max_duration_seconds,db.type=mssql,db.name=$dbName,host=$Hostname $dbMaxDuration"
            $metrics += "custom.db.long_queries.total_cpu_ms,db.type=mssql,db.name=$dbName,host=$Hostname $dbTotalCpu"
            $metrics += "custom.db.long_queries.total_reads,db.type=mssql,db.name=$dbName,host=$Hostname $dbTotalReads"
            $metrics += "custom.db.long_queries.total_logical_reads,db.type=mssql,db.name=$dbName,host=$Hostname $dbTotalLogicalReads"
            $metrics += "custom.db.long_queries.total_memory_kb,db.type=mssql,db.name=$dbName,host=$Hostname $dbTotalMemoryKb"
        }

        # Overall metrics
        $maxDuration = ($queries | Measure-Object -Property duration_seconds -Maximum).Maximum
        $blockedCount = @($queries | Where-Object { $_.blocking_session_id -gt 0 }).Count

        $metrics += "custom.db.long_queries.total_count,db.type=mssql,host=$Hostname $queryCount"
        $metrics += "custom.db.long_queries.overall_max_duration_seconds,db.type=mssql,host=$Hostname $maxDuration"
        $metrics += "custom.db.long_queries.blocked_count,db.type=mssql,host=$Hostname $blockedCount"
    }
    else {
        $metrics += "custom.db.long_queries.total_count,db.type=mssql,host=$Hostname 0"
    }

    # Send metrics
    if (@($metrics).Count -gt 0) {
        $metricsPayload = $metrics -join "`n"
        Send-DynatraceMetrics -EnvironmentUrl $Config.dynatrace.environmentUrl -ApiToken $ApiToken -MetricsData $metricsPayload
        Write-Verbose "Sent $(@($metrics).Count) metrics to Dynatrace"
    }

    # Send logs for each query
    if ($queryCount -gt 0) {
        $logs = @()

        foreach ($q in $queries) {
            $severity = if ($q.duration_seconds -gt 300) { "ERROR" } else { "WARN" }

            $logEntry = @{
                "content"                    = if ($q.current_statement) { $q.current_statement } else { "[No statement text]" }
                "log.source"                 = "custom.db.long_running_query"
                "severity"                   = $severity
                "db.type"                    = "mssql"
                "db.name"                    = if ($q.database_name) { $q.database_name } else { "unknown" }
                "db.host"                    = $Hostname
                "db.server"                  = if ($q.server_name) { $q.server_name } else { $Hostname }
                "query.session_id"           = [string]$q.session_id
                "query.login_name"           = if ($q.login_name) { $q.login_name } else { "" }
                "query.client_host"          = if ($q.host_name) { $q.host_name } else { "" }
                "query.program_name"         = if ($q.program_name) { $q.program_name } else { "" }
                "query.duration_seconds"     = [string]$q.duration_seconds
                "query.start_time"           = if ($q.start_time) { $q.start_time.ToString("yyyy-MM-ddTHH:mm:ss") } else { "" }
                "query.cpu_time_ms"          = [string]$q.cpu_time
                "query.status"               = if ($q.status) { $q.status } else { "" }
                "query.command"              = if ($q.command) { $q.command } else { "" }
                "query.wait_type"            = if ($q.wait_type) { $q.wait_type } else { "" }
                "query.wait_time_ms"         = [string]$q.wait_time
                "query.last_wait_type"       = if ($q.last_wait_type) { $q.last_wait_type } else { "" }
                "query.reads"                = [string]$q.reads
                "query.writes"               = [string]$q.writes
                "query.logical_reads"        = [string]$q.logical_reads
                "query.row_count"            = [string]$q.row_count
                "query.granted_memory_kb"    = [string]$q.granted_query_memory_kb
                "query.blocking_session_id"  = [string]$q.blocking_session_id
                "query.is_blocked"           = if ($q.blocking_session_id -gt 0) { "true" } else { "false" }
                "query.open_transaction_count" = [string]$q.open_transaction_count
                "query.isolation_level"      = if ($q.isolation_level_desc) { $q.isolation_level_desc } else { "" }
                "query.percent_complete"     = [string]$q.percent_complete
                "query.estimated_completion_ms" = [string]$q.estimated_completion_time_ms
                "query.hash"                 = if ($q.query_hash_hex) { $q.query_hash_hex } else { "" }
                "query.plan_hash"            = if ($q.query_plan_hash_hex) { $q.query_plan_hash_hex } else { "" }
            }

            # Query Store IDs from cache
            $dbName = if ($q.database_name -and $q.database_name -isnot [DBNull]) { $q.database_name } else { "" }
            $qHash = if ($q.query_hash_hex -and $q.query_hash_hex -isnot [DBNull]) { $q.query_hash_hex.ToString().ToUpper() } else { "" }
            if ($queryStoreCache.ContainsKey($dbName) -and $queryStoreCache[$dbName].ContainsKey($qHash)) {
                $qsData = $queryStoreCache[$dbName][$qHash]
                if ($qsData.query_id) {
                    $logEntry["query.store_query_id"] = [string]$qsData.query_id
                }
                if ($qsData.plan_id) {
                    $logEntry["query.store_plan_id"] = [string]$qsData.plan_id
                }
            }

            # Full query text if different
            if ($q.query_text_truncated -and $q.query_text_truncated -ne $q.current_statement) {
                $logEntry["query.full_text"] = $q.query_text_truncated
            }

            $logs += $logEntry
        }

        Send-DynatraceLogs -EnvironmentUrl $Config.dynatrace.environmentUrl -ApiToken $ApiToken -LogEntries $logs
        Write-Verbose "Sent $(@($logs).Count) log entries to Dynatrace"
    }

    $elapsed = ((Get-Date) - $iterationStart).TotalMilliseconds
    Write-Verbose "Collection completed in $($elapsed)ms"
}

#endregion

#region Main Service Loop

function Start-ServiceLoop {
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config,
        [Parameter(Mandatory = $true)]
        [string]$ApiToken,
        [Parameter(Mandatory = $true)]
        [string]$Hostname
    )

    $serviceStartTime = Get-Date
    $maxRuntimeSeconds = $Config.service.maxRuntimeHours * 3600
    $intervalSeconds = $Config.service.intervalSeconds

    Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - Service starting..."
    Write-Host "  Interval: $intervalSeconds seconds"
    Write-Host "  Max runtime: $($Config.service.maxRuntimeHours) hours"
    Write-Host "  Server: $($Config.sqlServer.serverInstance)"

    # Send startup event to Dynatrace
    Send-ServiceEvent -Config $Config -ApiToken $ApiToken -Hostname $Hostname -EventType "START"

    $iterationCount = 0

    try {
        while ($true) {
            $iterationCount++
            $elapsed = ((Get-Date) - $serviceStartTime).TotalSeconds

            # Check max runtime
            if ($elapsed -ge $maxRuntimeSeconds) {
                Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - Max runtime reached ($($Config.service.maxRuntimeHours) hours). Stopping for restart..."
                Send-ServiceEvent -Config $Config -ApiToken $ApiToken -Hostname $Hostname -EventType "STOP"
                break
            }

            Write-Verbose "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - Iteration $iterationCount (runtime: $([math]::Round($elapsed/60, 1)) min)"

            try {
                Invoke-Collection -Config $Config -ApiToken $ApiToken -Hostname $Hostname
            }
            catch {
                Write-Warning "Collection failed: $_"
                Send-ServiceEvent -Config $Config -ApiToken $ApiToken -Hostname $Hostname -EventType "ERROR" -Message $_.ToString()
            }

            # Sleep for interval
            Start-Sleep -Seconds $intervalSeconds
        }
    }
    finally {
        Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - Service stopped after $iterationCount iterations"
    }
}

#endregion

#region Entry Point

try {
    # Load configuration
    $config = Get-Configuration -Path $ConfigPath

    # Get API token
    $apiToken = Get-DynatraceApiToken -Config $config

    # Get hostname
    $hostname = $env:COMPUTERNAME
    if ([string]::IsNullOrEmpty($hostname)) {
        $hostname = [System.Net.Dns]::GetHostName()
    }

    if ($SingleRun) {
        # Single execution mode (for testing)
        Write-Verbose "Running in single-run mode..."
        Invoke-Collection -Config $config -ApiToken $apiToken -Hostname $hostname
        exit 0
    }
    else {
        # Persistent service mode
        Start-ServiceLoop -Config $config -ApiToken $apiToken -Hostname $hostname
        exit 0  # Clean exit for NSSM to restart
    }
}
catch {
    Write-Error "Service failed: $_"
    exit 1
}

#endregion
