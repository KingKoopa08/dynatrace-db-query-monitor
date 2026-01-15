# MS SQL Server Long-Running Query Collector

PowerShell-based collector that monitors SQL Server for long-running queries and sends data to Dynatrace.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Windows Task Scheduler (runs at startup)                       │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │  Get-LongRunningQueries.ps1 (persistent loop)             │  │
│  │                                                           │  │
│  │  while (runtime < maxRuntimeHours):                       │  │
│  │      1. Call SP: usp_GetLongRunningQueries               │  │
│  │      2. Query Store lookup (Invoke-Sqlcmd)               │  │
│  │      3. Send metrics to Dynatrace                        │  │
│  │      4. Send logs to Dynatrace                           │  │
│  │      5. Sleep (intervalSeconds)                          │  │
│  │                                                           │  │
│  │  Exit → Task Scheduler auto-restarts                      │  │
│  └───────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

**Overhead:** One PowerShell.exe process (~50-100MB), minimal CPU (mostly sleeping).

## Files

| File | Description |
|------|-------------|
| `Get-LongRunningQueries.ps1` | Main collector script (persistent loop) |
| `Send-ToDynatrace.ps1` | Dynatrace API helper functions |
| `Deploy-SQLObjects.sql` | Creates stored procedure and exclusions table |
| `Install-ScheduledTask.ps1` | Windows Task Scheduler installer |
| `config.json.example` | Configuration template |

## Prerequisites

1. **PowerShell 5.1+** (comes with Windows Server 2016+)
2. **SqlServer PowerShell module:**
   ```powershell
   Install-Module -Name SqlServer -Scope AllUsers -Force
   ```
3. **SQL Server maintenance database** with the stored procedure deployed
4. **Dynatrace API token** with `metrics.ingest` and `logs.ingest` scopes

## Configuration

Copy `config.json.example` to `config.json` and edit:

```json
{
  "sqlServer": {
    "serverInstance": "localhost",
    "thresholdSeconds": 60
  },
  "dynatrace": {
    "environmentUrl": "https://YOUR_ENVIRONMENT_ID.live.dynatrace.com",
    "apiTokenEnvVar": "DT_API_TOKEN"
  },
  "service": {
    "intervalSeconds": 60,
    "maxRuntimeHours": 6,
    "serviceName": "DynatraceSQLMonitor"
  }
}
```

### Configuration Options

| Setting | Description | Default |
|---------|-------------|---------|
| `serverInstance` | SQL Server instance name | Required |
| `thresholdSeconds` | Minimum query duration to capture | 60 |
| `environmentUrl` | Dynatrace environment URL | Required |
| `apiTokenEnvVar` | Environment variable containing API token | `DT_API_TOKEN` |
| `intervalSeconds` | Polling interval in seconds | 60 |
| `maxRuntimeHours` | Hours before automatic restart | 6 |
| `serviceName` | Task name in Task Scheduler | `DynatraceSQLMonitor` |

## Deployment

### Step 1: Deploy SQL Objects

Run `Deploy-SQLObjects.sql` in SSMS (or via sqlcmd on Server Core):

```powershell
# Server Core - run via sqlcmd
sqlcmd -S localhost -d master -i Deploy-SQLObjects.sql
```

### Step 2: Set Up API Token

```powershell
# Set machine-level environment variable (required for service account)
[Environment]::SetEnvironmentVariable('DT_API_TOKEN', 'dt0c01.xxxxxx', 'Machine')

# Verify
[Environment]::GetEnvironmentVariable('DT_API_TOKEN', 'Machine')
```

### Step 3: Install Scheduled Task

```powershell
# Run as Administrator

# Install as SYSTEM (simplest)
.\Install-ScheduledTask.ps1

# Install with service account (recommended)
.\Install-ScheduledTask.ps1 -ServiceAccount "DOMAIN\svc_sqlmonitor" -ServicePassword (Read-Host -AsSecureString)
```

### Step 4: Verify

```powershell
# Check task status
Get-ScheduledTask -TaskName "DynatraceSQLMonitor" -TaskPath "\Dynatrace\"

# Check if running
Get-ScheduledTaskInfo -TaskName "DynatraceSQLMonitor" -TaskPath "\Dynatrace\"

# View logs
Get-Content .\logs\service.log -Tail 50
```

## Task Management (Server Core)

All commands work via PowerShell - no GUI required:

```powershell
# Variables for convenience
$TaskName = "DynatraceSQLMonitor"
$TaskPath = "\Dynatrace\"

# Status
Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath

# Detailed info (last run, next run, result)
Get-ScheduledTaskInfo -TaskName $TaskName -TaskPath $TaskPath

# Start
Start-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath

# Stop
Stop-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath

# Disable (keeps task but prevents it from running)
Disable-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath

# Enable
Enable-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath

# Uninstall
.\Install-ScheduledTask.ps1 -Uninstall

# View logs
Get-Content .\logs\service.log -Tail 100
Get-Content .\logs\service.log -Tail 50 -Wait  # Live tail

# View errors
Get-Content .\logs\service-error.log -Tail 50
```

## Testing

### Test Single Run

```powershell
# Single collection run for testing (no loop)
.\Get-LongRunningQueries.ps1 -SingleRun -Verbose
```

### Create Test Long-Running Query

```sql
-- Run in SSMS or sqlcmd to create a test query
WAITFOR DELAY '00:02:00'; -- Wait 2 minutes
SELECT 1;
```

### Verify in Dynatrace

**Metrics:** Data Explorer → Search for `custom.db.long_queries`

**Logs:** Logs & Events → Filter:
- `log.source="custom.db.long_running_query"` (query events)
- `log.source="custom.db.monitoring_service"` (service events)

## Service Lifecycle Events

The service logs these events to Dynatrace:

| Event | Severity | When |
|-------|----------|------|
| `START` | INFO | Service started |
| `STOP` | INFO | Max runtime reached (will restart) |
| `ERROR` | ERROR | Collection failed |

Search in Dynatrace:
```
log.source="custom.db.monitoring_service"
```

## Troubleshooting

### Task Won't Start

```powershell
# Check task status
Get-ScheduledTask -TaskName "DynatraceSQLMonitor" -TaskPath "\Dynatrace\"

# Check last result (0 = success)
(Get-ScheduledTaskInfo -TaskName "DynatraceSQLMonitor" -TaskPath "\Dynatrace\").LastTaskResult

# Check error log
Get-Content .\logs\service-error.log -Tail 50

# Common issues:
# - config.json missing or invalid
# - DT_API_TOKEN not set at machine level
# - SQL Server not accessible
# - SqlServer module not installed
```

### No Data in Dynatrace

```powershell
# 1. Verify task is running
Get-ScheduledTask -TaskName "DynatraceSQLMonitor" -TaskPath "\Dynatrace\" | Select-Object State

# 2. Check logs
Get-Content .\logs\service.log -Tail 50

# 3. Test manually
.\Get-LongRunningQueries.ps1 -SingleRun -Verbose

# 4. Verify API token
[Environment]::GetEnvironmentVariable('DT_API_TOKEN', 'Machine')
```

### High Memory Usage

The script automatically restarts after `maxRuntimeHours` to prevent memory leaks.
Reduce this value if needed:

```json
{
  "service": {
    "maxRuntimeHours": 2
  }
}
```

Then restart the task:
```powershell
Stop-ScheduledTask -TaskName "DynatraceSQLMonitor" -TaskPath "\Dynatrace\"
Start-ScheduledTask -TaskName "DynatraceSQLMonitor" -TaskPath "\Dynatrace\"
```

### Query Store IDs Missing

Query Store IDs only populate if:
1. Query Store is enabled: `ALTER DATABASE YourDB SET QUERY_STORE = ON`
2. The query pattern has been executed and captured before

## Security Notes

- API tokens stored in machine-level environment variables
- Service account should have minimal required permissions:
  - `VIEW SERVER STATE` on SQL Server
  - Read access to script directory
  - Network access to Dynatrace API
- Query text sent to Dynatrace may contain sensitive data
- Log files stored locally in `.\logs\` directory
- Task runs with "Highest" privilege level (required for SQL access)
