# Aurora PostgreSQL Long-Running Query Collector

AWS Lambda-based collector that monitors Aurora PostgreSQL for long-running queries and sends data to Dynatrace.

## Files

| File | Description |
|------|-------------|
| `lambda_function.py` | Lambda handler |
| `collectors/postgres_collector.py` | PostgreSQL query logic |
| `dynatrace/metrics_client.py` | Dynatrace Metrics API client |
| `dynatrace/logs_client.py` | Dynatrace Logs API client |
| `template.yaml` | SAM/CloudFormation template |
| `requirements.txt` | Python dependencies |
| `deploy.sh` | Deployment script |

## Prerequisites

1. **AWS CLI** configured with appropriate permissions
2. **AWS SAM CLI** for deployment
3. **Aurora PostgreSQL** cluster in a VPC
4. **Secrets in AWS Secrets Manager:**
   - Database password
   - Dynatrace API token

## Database Setup

Create a monitoring role in Aurora PostgreSQL:

```sql
-- Connect as admin
CREATE ROLE dynatrace_monitor WITH LOGIN PASSWORD 'YourSecurePassword';
GRANT pg_monitor TO dynatrace_monitor;

-- Optional: for pg_stat_statements
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
```

Update your Aurora parameter group:
- `track_activity_query_size = 4096`
- `pg_stat_statements.track = ALL` (optional)

## AWS Secrets Setup

```bash
# Store database password
aws secretsmanager create-secret \
  --name aurora-monitor-password \
  --secret-string '{"password":"YourSecurePassword"}'

# Store Dynatrace API token
aws secretsmanager create-secret \
  --name dynatrace-api-token \
  --secret-string '{"apiToken":"dt0c01.xxxxxx"}'
```

## Deployment

### 1. Create Parameters File

```bash
cp parameters.json.example parameters.json
```

Edit `parameters.json` with your values:

```json
{
  "AuroraHost": "your-cluster.cluster-xxxxx.us-east-1.rds.amazonaws.com",
  "AuroraPort": "5432",
  "AuroraDatabase": "your_database",
  "AuroraUser": "dynatrace_monitor",
  "AuroraPasswordSecretArn": "arn:aws:secretsmanager:us-east-1:123456789012:secret:aurora-monitor-password-xxxxx",
  "DynatraceEnvironmentUrl": "https://abc12345.live.dynatrace.com",
  "DynatraceApiTokenSecretArn": "arn:aws:secretsmanager:us-east-1:123456789012:secret:dynatrace-api-token-xxxxx",
  "ThresholdSeconds": "60",
  "VpcId": "vpc-xxxxxxxxx",
  "SubnetIds": "subnet-aaaaaaa,subnet-bbbbbbb",
  "SecurityGroupIds": "sg-xxxxxxxxx",
  "ScheduleExpression": "rate(1 minute)"
}
```

### 2. Deploy

```bash
chmod +x deploy.sh
./deploy.sh aurora-query-collector parameters.json
```

Or using SAM directly:

```bash
sam build --use-container
sam deploy \
  --stack-name aurora-query-collector \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides file://parameters.json
```

## VPC Configuration

The Lambda function must run in the same VPC as your Aurora cluster.

### Required Network Access

1. **To Aurora cluster:**
   - Security group must allow outbound TCP to Aurora port (5432)
   - Aurora security group must allow inbound from Lambda security group

2. **To Dynatrace API:**
   - Lambda subnet needs NAT Gateway for internet access, OR
   - Use VPC endpoints for Secrets Manager and add NAT Gateway for Dynatrace

### Security Group Example

**Lambda Security Group (sg-lambda):**
- Outbound: TCP 5432 to Aurora security group
- Outbound: TCP 443 to 0.0.0.0/0 (for Dynatrace API)

**Aurora Security Group (sg-aurora):**
- Inbound: TCP 5432 from sg-lambda

## Testing

### Invoke Lambda Manually

```bash
aws lambda invoke \
  --function-name aurora-long-running-query-collector \
  --payload '{}' \
  response.json

cat response.json
```

### Create Test Long-Running Query

```sql
-- Connect to Aurora and run:
SELECT pg_sleep(120); -- Sleep for 2 minutes
```

### View Logs

```bash
aws logs tail /aws/lambda/aurora-long-running-query-collector --follow
```

## Configuration Options

| Environment Variable | Description | Default |
|---------------------|-------------|---------|
| `AURORA_HOST` | Aurora cluster endpoint | Required |
| `AURORA_PORT` | Database port | 5432 |
| `AURORA_DATABASE` | Database name | Required |
| `AURORA_USER` | Database user | Required |
| `AURORA_PASSWORD_SECRET_ARN` | Secrets Manager ARN for password | Required |
| `DT_ENVIRONMENT_URL` | Dynatrace environment URL | Required |
| `DT_API_TOKEN_SECRET_ARN` | Secrets Manager ARN for API token | Required |
| `THRESHOLD_SECONDS` | Minimum query duration | 60 |

## Troubleshooting

### Lambda Timeout

If the Lambda times out:
1. Increase timeout in `template.yaml` (max 15 minutes)
2. Check VPC connectivity to Aurora
3. Verify security groups allow traffic

### Database Connection Failed

1. Verify Aurora endpoint is correct
2. Check security groups allow Lambda → Aurora
3. Ensure monitoring user has correct grants
4. Test from an EC2 instance in the same VPC

### Secrets Manager Access Denied

1. Check IAM permissions in `template.yaml`
2. Verify secret ARNs are correct
3. Ensure Lambda role has secretsmanager:GetSecretValue

### No Metrics in Dynatrace

1. Verify API token has `metrics.ingest` scope
2. Check Lambda has internet access (NAT Gateway)
3. Review CloudWatch logs for errors

## Local Development

```bash
# Create virtual environment
python -m venv venv
source venv/bin/activate  # Linux/Mac
.\venv\Scripts\activate   # Windows

# Install dependencies
pip install -r requirements.txt

# Run locally (set environment variables first)
python -c "from lambda_function import lambda_handler; print(lambda_handler({}, None))"
```

## Cleanup

Remove the deployment:

```bash
aws cloudformation delete-stack --stack-name aurora-query-collector
```
