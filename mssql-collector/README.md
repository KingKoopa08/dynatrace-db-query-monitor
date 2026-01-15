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

### SQL Agent Job Deployment

1. **Update script path** in `Deploy-SQLAgentJob.sql`:
   ```sql
   DECLARE @ScriptPath NVARCHAR(500) = N'C:\Program Files\Scripts\SqlAgent\mssql-collector\Get-LongRunningQueries.ps1';
   ```

2. **Run the deployment script** in SSMS:
   ```sql
   -- Execute Deploy-SQLAgentJob.sql
   ```

3. **Verify the job was created:**
   ```sql
   EXEC msdb.dbo.sp_help_job @job_name = 'Dynatrace - Long Running Query Monitor';
   ```

### Job Management
```sql
-- Run job immediately
EXEC msdb.dbo.sp_start_job @job_name = 'Dynatrace - Long Running Query Monitor';

-- Disable job
EXEC msdb.dbo.sp_update_job @job_name = 'Dynatrace - Long Running Query Monitor', @enabled = 0;

-- Enable job
EXEC msdb.dbo.sp_update_job @job_name = 'Dynatrace - Long Running Query Monitor', @enabled = 1;

-- View recent job history
SELECT TOP 20
    j.name AS JobName,
    h.run_date,
    h.run_time,
    h.run_duration,
    CASE h.run_status
        WHEN 0 THEN 'Failed'
        WHEN 1 THEN 'Succeeded'
        WHEN 2 THEN 'Retry'
        WHEN 3 THEN 'Canceled'
        WHEN 4 THEN 'In Progress'
    END AS Status,
    h.message
FROM msdb.dbo.sysjobhistory h
JOIN msdb.dbo.sysjobs j ON h.job_id = j.job_id
WHERE j.name = 'Dynatrace - Long Running Query Monitor'
ORDER BY h.run_date DESC, h.run_time DESC;
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
- Query text may contain sensitive data (sent to Dynatrace logs)
- Credential Manager encrypts stored credentials
- SQL Agent job runs under SQL Agent service account
- Requires VIEW SERVER STATE permission on SQL Server
