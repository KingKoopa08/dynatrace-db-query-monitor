# MS SQL Server Long-Running Query Collector

PowerShell-based collector that monitors SQL Server for long-running queries and sends data to Dynatrace.

## Files

| File | Description |
|------|-------------|
| `Get-LongRunningQueries.ps1` | Main collector script |
| `Send-ToDynatrace.ps1` | Dynatrace API helper functions |
| `Deploy-SQLObjects.sql` | Creates stored procedure and exclusions table |
| `Deploy-SQLAgentJob.sql` | Creates SQL Agent job (runs every minute) |
| `config.json.example` | Configuration template |

## Prerequisites

1. **PowerShell 5.1+** (comes with Windows Server 2016+)
2. **SqlServer PowerShell module:**
   ```powershell
   Install-Module -Name SqlServer -Scope CurrentUser
   ```
3. **SQL Server login with VIEW SERVER STATE:**
   ```sql
   CREATE LOGIN DynatraceMonitor WITH PASSWORD = 'YourSecurePassword';
   GRANT VIEW SERVER STATE TO DynatraceMonitor;
   ```

## Configuration

Edit `config.json`:

```json
{
  "sqlServer": {
    "serverInstance": "localhost\\SQLEXPRESS",
    "database": "master",
    "thresholdSeconds": 60,
    "includeExecutionPlan": true,
    "credentialName": null
  },
  "dynatrace": {
    "environmentUrl": "https://YOUR_ENV.live.dynatrace.com",
    "apiTokenEnvVar": "DT_API_TOKEN",
    "credentialName": null
  }
}
```

### Configuration Options

| Setting | Description |
|---------|-------------|
| `serverInstance` | SQL Server instance (e.g., `SERVER\INSTANCE` or `localhost`) |
| `database` | Database to connect to (use `master` for server-level monitoring) |
| `thresholdSeconds` | Minimum query duration to capture |
| `includeExecutionPlan` | Whether to capture query execution plans |
| `credentialName` | Windows Credential Manager target (optional) |
| `apiTokenEnvVar` | Environment variable containing API token |

## API Token Setup

**Option 1: Environment Variable (Recommended)**
```powershell
# Set machine-level environment variable (requires admin)
[Environment]::SetEnvironmentVariable('DT_API_TOKEN', 'dt0c01.xxxxxx', 'Machine')

# Or user-level
[Environment]::SetEnvironmentVariable('DT_API_TOKEN', 'dt0c01.xxxxxx', 'User')
```

**Option 2: Windows Credential Manager**
```powershell
# Install CredentialManager module
Install-Module -Name CredentialManager -Scope CurrentUser

# Store credential
. .\Send-ToDynatrace.ps1
Set-DynatraceCredential -Target "DynatraceApiToken" -ApiToken "dt0c01.xxxxxx"

# Update config.json to use credentialName
```

## Usage

### Manual Execution
```powershell
# Run with default config
.\Get-LongRunningQueries.ps1

# Run with verbose output
.\Get-LongRunningQueries.ps1 -Verbose

# Run with custom config path
.\Get-LongRunningQueries.ps1 -ConfigPath "C:\path\to\config.json"
```

### Scheduled Task Installation
```powershell
# Install with default settings (60 second interval)
.\Install-ScheduledTask.ps1

# Install with custom interval
.\Install-ScheduledTask.ps1 -IntervalSeconds 30

# Remove the scheduled task
.\Install-ScheduledTask.ps1 -Uninstall
```

### Task Management
```powershell
# View task status
Get-ScheduledTask -TaskName "DynatraceSQLQueryMonitor"

# Run task immediately
Start-ScheduledTask -TaskName "DynatraceSQLQueryMonitor"

# Stop task
Stop-ScheduledTask -TaskName "DynatraceSQLQueryMonitor"

# View task info
Get-ScheduledTaskInfo -TaskName "DynatraceSQLQueryMonitor"
```

## Testing

### Test Dynatrace Connection
```powershell
. .\Send-ToDynatrace.ps1
$token = [Environment]::GetEnvironmentVariable('DT_API_TOKEN')
Test-DynatraceConnection -EnvironmentUrl "https://YOUR_ENV.live.dynatrace.com" -ApiToken $token
```

### Create Test Long-Running Query
```sql
-- Run this in SSMS to create a test query
WAITFOR DELAY '00:02:00'; -- Wait 2 minutes
SELECT 1;
```

### Verify Metrics in Dynatrace
1. Go to **Data Explorer**
2. Search for `custom.db.long_queries`
3. You should see metrics with dimensions for db.type, db.name, and host

## Troubleshooting

### Common Issues

**"SqlServer module not found"**
```powershell
Install-Module -Name SqlServer -Scope CurrentUser -Force
```

**"Cannot connect to SQL Server"**
- Verify server name and instance
- Check Windows Firewall allows SQL Server traffic
- Ensure SQL Server Browser service is running (for named instances)

**"Access denied" or "VIEW SERVER STATE permission"**
```sql
-- Run as sysadmin
GRANT VIEW SERVER STATE TO [YourLogin];
```

**"Failed to send metrics to Dynatrace"**
- Verify environment URL is correct
- Check API token has `metrics.ingest` and `logs.ingest` scopes
- Ensure firewall allows outbound HTTPS to Dynatrace

### Enable Detailed Logging
```powershell
$VerbosePreference = "Continue"
.\Get-LongRunningQueries.ps1
```

## Security Notes

- API tokens are never logged
- Execution plans may contain sensitive schema information
- Credential Manager encrypts stored credentials
- Task runs as SYSTEM by default (high privilege)
