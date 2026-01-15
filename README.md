# Database Long-Running Query Monitoring for Dynatrace

Monitor long-running queries on MS SQL Server 2019 and AWS Aurora PostgreSQL Serverless V2, sending metrics and logs to Dynatrace for alerting and analysis.

## Architecture

```
┌─────────────────────┐              ┌─────────────────────┐
│   MS SQL 2019       │              │  Aurora PostgreSQL  │
│  (DMV queries)      │              │  (pg_stat_activity) │
└─────────┬───────────┘              └─────────┬───────────┘
          │                                    │
          ▼                                    ▼
┌─────────────────────┐              ┌─────────────────────┐
│  PowerShell Script  │              │   AWS Lambda        │
│  (Windows Task      │              │   (Python, VPC,     │
│   Scheduler)        │              │    EventBridge)     │
└─────────┬───────────┘              └─────────┬───────────┘
          │                                    │
          └──────────────┬─────────────────────┘
                         ▼
              ┌─────────────────────┐
              │  Dynatrace APIs     │
              │  - Metrics Ingest   │
              │  - Logs Ingest      │
              └─────────────────────┘
```

## Components

### 1. MS SQL Server Collector (`mssql-collector/`)

PowerShell-based collector for Windows servers running SQL Server.

**Features:**
- Queries `sys.dm_exec_requests` DMV for long-running queries
- Captures query text and execution plans
- Sends metrics (count, duration, CPU, reads) to Dynatrace
- Sends query details as logs for investigation
- Configurable thresholds
- Windows Task Scheduler integration

### 2. Aurora PostgreSQL Collector (`aurora-collector/`)

AWS Lambda-based collector for Aurora PostgreSQL.

**Features:**
- Queries `pg_stat_activity` for long-running queries
- Runs in VPC with access to Aurora cluster
- Triggered by EventBridge schedule
- Secrets stored in AWS Secrets Manager
- SAM/CloudFormation deployment template

## Prerequisites

### Dynatrace
- [ ] Dynatrace environment with ActiveGate deployed
- [ ] API token with scopes: `metrics.ingest`, `logs.ingest`

### MS SQL Server
- [ ] SQL Server 2019 (or compatible version)
- [ ] Monitoring login with VIEW SERVER STATE permission:
  ```sql
  CREATE LOGIN DynatraceMonitor WITH PASSWORD = '<secure_password>';
  GRANT VIEW SERVER STATE TO DynatraceMonitor;
  ```

### Aurora PostgreSQL
- [ ] Aurora PostgreSQL Serverless V2 cluster
- [ ] Parameter group with:
  - `track_activity_query_size = 4096`
  - `pg_stat_statements.track = ALL` (optional)
- [ ] Monitoring role:
  ```sql
  CREATE ROLE dynatrace_monitor WITH LOGIN PASSWORD '<secure_password>';
  GRANT pg_monitor TO dynatrace_monitor;
  ```

## Quick Start

### MS SQL Server

1. **Copy files to your SQL Server:**
   ```powershell
   Copy-Item -Path .\mssql-collector\* -Destination C:\DynatraceMonitor\ -Recurse
   ```

2. **Configure `config.json`:**
   ```json
   {
     "sqlServer": {
       "serverInstance": "YOUR_SERVER\\INSTANCE",
       "database": "master",
       "thresholdSeconds": 60,
       "includeExecutionPlan": true
     },
     "dynatrace": {
       "environmentUrl": "https://YOUR_ENV.live.dynatrace.com",
       "apiTokenEnvVar": "DT_API_TOKEN"
     }
   }
   ```

3. **Set environment variable (as Administrator):**
   ```powershell
   [Environment]::SetEnvironmentVariable('DT_API_TOKEN', 'dt0c01.xxxxxx', 'Machine')
   ```

4. **Install the scheduled task:**
   ```powershell
   .\Install-ScheduledTask.ps1 -IntervalSeconds 60
   ```

### Aurora PostgreSQL

1. **Create secrets in AWS Secrets Manager:**
   ```bash
   # Database password
   aws secretsmanager create-secret \
     --name aurora-monitor-password \
     --secret-string '{"password":"your-password"}'

   # Dynatrace API token
   aws secretsmanager create-secret \
     --name dynatrace-api-token \
     --secret-string '{"apiToken":"dt0c01.xxxxxx"}'
   ```

2. **Create `parameters.json`:**
   ```bash
   cp aurora-collector/parameters.json.example aurora-collector/parameters.json
   # Edit with your values
   ```

3. **Deploy with SAM:**
   ```bash
   cd aurora-collector
   chmod +x deploy.sh
   ./deploy.sh my-query-collector parameters.json
   ```

## Metrics Sent to Dynatrace

| Metric | Description |
|--------|-------------|
| `custom.db.long_queries.count` | Number of long-running queries |
| `custom.db.long_queries.max_duration_seconds` | Longest running query duration |
| `custom.db.long_queries.avg_duration_seconds` | Average query duration |
| `custom.db.long_queries.total_cpu_ms` | Total CPU time consumed |
| `custom.db.long_queries.total_reads` | Total disk reads |

**Dimensions:**
- `db.type`: mssql or postgres
- `db.name`: Database name
- `host`: Server/cluster hostname

## Log Attributes

Each long-running query is sent as a log entry with:

| Attribute | Description |
|-----------|-------------|
| `content` | Query text |
| `severity` | WARN (<5 min) or ERROR (>5 min) |
| `db.type` | Database type |
| `db.name` | Database name |
| `query.duration_seconds` | How long the query has been running |
| `query.session_id` / `query.pid` | Session/process identifier |
| `query.wait_type` / `query.wait_event` | What the query is waiting on |
| `query.execution_plan` | XML execution plan (SQL Server only) |

## Dynatrace Configuration

### Create Metric Events for Alerting

1. Go to **Settings → Anomaly detection → Metric events**
2. Create event:
   - Name: "Long Running Database Query"
   - Metric: `custom.db.long_queries.count`
   - Condition: `> 0`
   - Severity: Warning

3. Create critical event:
   - Name: "Critical Long Running Query (>5 min)"
   - Metric: `custom.db.long_queries.max_duration_seconds`
   - Condition: `> 300`
   - Severity: Error

### Create Dashboard

Create a custom dashboard with:
- Timeseries: Long-running query count over time
- Single value: Current max query duration
- Pie chart: Queries by database
- Log viewer: Recent long-running query logs filtered by `log.source="custom.db.long_running_query"`

## Troubleshooting

### MS SQL Server

**Test the script manually:**
```powershell
.\Get-LongRunningQueries.ps1 -Verbose
```

**Check scheduled task status:**
```powershell
Get-ScheduledTask -TaskName "DynatraceSQLQueryMonitor"
Get-ScheduledTaskInfo -TaskName "DynatraceSQLQueryMonitor"
```

**View task history:**
```powershell
Get-WinEvent -LogName 'Microsoft-Windows-TaskScheduler/Operational' |
  Where-Object { $_.Message -like '*DynatraceSQLQueryMonitor*' } |
  Select-Object -First 10
```

### Aurora PostgreSQL

**Test Lambda manually:**
```bash
aws lambda invoke \
  --function-name aurora-long-running-query-collector \
  --payload '{}' \
  response.json

cat response.json
```

**View Lambda logs:**
```bash
aws logs tail /aws/lambda/aurora-long-running-query-collector --follow
```

**Test database connectivity:**
```bash
# From a host in the same VPC
psql -h your-cluster.cluster-xxx.region.rds.amazonaws.com \
  -U dynatrace_monitor -d your_database \
  -c "SELECT * FROM pg_stat_activity LIMIT 1;"
```

## Security Considerations

1. **Never store API tokens in code** - Use environment variables or secrets management
2. **Use least-privilege database users** - Only VIEW SERVER STATE / pg_monitor
3. **Encrypt secrets at rest** - Use AWS Secrets Manager or Windows Credential Manager
4. **Restrict network access** - Lambda should only access Aurora and Dynatrace APIs
5. **Audit access** - Enable CloudTrail and SQL Server audit logging

## License

MIT License
