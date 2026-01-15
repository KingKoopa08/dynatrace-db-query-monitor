# MS SQL Server Long-Running Query Collector

PowerShell-based collector that monitors SQL Server for long-running queries and sends data to Dynatrace.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Windows Service (via NSSM)                                     │
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
│  │  Exit → NSSM auto-restarts → Log restart event           │  │
│  └───────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

## Files

| File | Description |
|------|-------------|
| `Get-LongRunningQueries.ps1` | Main collector script (persistent service) |
| `Send-ToDynatrace.ps1` | Dynatrace API helper functions |
| `Deploy-SQLObjects.sql` | Creates stored procedure and exclusions table |
| `Install-Service.ps1` | NSSM Windows Service installer |
| `config.json.example` | Configuration template |

## Prerequisites

1. **PowerShell 5.1+** (comes with Windows Server 2016+)
2. **SqlServer PowerShell module:**
   ```powershell
   Install-Module -Name SqlServer -Scope AllUsers -Force
   ```
3. **NSSM** (Non-Sucking Service Manager):
   - Download from: https://nssm.cc/download
   - Extract `nssm.exe` to the script directory or add to PATH
4. **SQL Server maintenance database** with the stored procedure deployed
5. **Dynatrace API token** with `metrics.ingest` and `logs.ingest` scopes

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
| `serviceName` | Windows service name | `DynatraceSQLMonitor` |

## Deployment

### Step 1: Deploy SQL Objects

Run `Deploy-SQLObjects.sql` in SSMS on each SQL Server instance:

```sql
-- Creates maintenance.dbo.usp_GetLongRunningQueries
-- Creates exclusions table for filtering
```

### Step 2: Set Up API Token

```powershell
# Set machine-level environment variable (required for service account)
[Environment]::SetEnvironmentVariable('DT_API_TOKEN', 'dt0c01.xxxxxx', 'Machine')
```

### Step 3: Create Service Account (Recommended)

```powershell
# Create a dedicated service account with minimal permissions
# Grant it:
#   - VIEW SERVER STATE on SQL Server
#   - Read access to script directory
#   - Access to DT_API_TOKEN environment variable
```

### Step 4: Install Windows Service

```powershell
# Run as Administrator

# Install with Local System (simple, but high privilege)
.\Install-Service.ps1

# Install with service account (recommended)
.\Install-Service.ps1 -ServiceAccount "DOMAIN\svc_sqlmonitor" -ServicePassword (Read-Host -AsSecureString)

# Install with gMSA (no password needed)
.\Install-Service.ps1 -ServiceAccount "DOMAIN\gMSA_SQLMon$"
```

### Step 5: Verify

```powershell
# Check service status
Get-Service DynatraceSQLMonitor

# View logs
Get-Content .\logs\service.log -Tail 50

# Check Dynatrace for service start event
# Search: log.source="custom.db.monitoring_service"
```

## Service Management

```powershell
# Start/Stop
Start-Service DynatraceSQLMonitor
Stop-Service DynatraceSQLMonitor

# Restart
Restart-Service DynatraceSQLMonitor

# View status
Get-Service DynatraceSQLMonitor

# View logs
Get-Content .\logs\service.log -Tail 100 -Wait

# Uninstall
.\Install-Service.ps1 -Uninstall
```

## Testing

### Test Single Run (No Service)

```powershell
# Single collection run for testing
.\Get-LongRunningQueries.ps1 -SingleRun -Verbose
```

### Create Test Long-Running Query

```sql
-- Run in SSMS to create a test query
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

| Event | Severity | Description |
|-------|----------|-------------|
| `START` | INFO | Service started |
| `STOP` | INFO | Service stopped (max runtime reached, will restart) |
| `ERROR` | ERROR | Collection failed (includes error message) |

Search in Dynatrace:
```
log.source="custom.db.monitoring_service" AND service.event="START"
```

## Troubleshooting

### Service Won't Start

1. Check logs: `Get-Content .\logs\service-error.log`
2. Verify config.json is valid JSON
3. Verify SQL Server is accessible
4. Verify DT_API_TOKEN environment variable is set at machine level

### No Data in Dynatrace

1. Check service is running: `Get-Service DynatraceSQLMonitor`
2. Check logs for errors: `Get-Content .\logs\service.log -Tail 50`
3. Test single run: `.\Get-LongRunningQueries.ps1 -SingleRun -Verbose`
4. Verify API token has correct scopes

### High Memory Usage

The service automatically restarts after `maxRuntimeHours` to prevent memory leaks.
Reduce this value if memory is a concern:

```json
{
  "service": {
    "maxRuntimeHours": 2
  }
}
```

### Query Store IDs Missing

Query Store IDs only populate if:
1. Query Store is enabled: `ALTER DATABASE YourDB SET QUERY_STORE = ON`
2. The query pattern has been executed and captured before

## Security Notes

- API tokens are stored in environment variables, never in config files
- Service account should have minimal required permissions
- Query text sent to Dynatrace may contain sensitive data
- Consider using gMSA for service account (no password management)
- Log files are stored locally and rotated at 10MB
