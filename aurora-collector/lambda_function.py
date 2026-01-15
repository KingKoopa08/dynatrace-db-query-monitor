"""
AWS Lambda function for collecting long-running queries from Aurora PostgreSQL
and sending metrics/logs to Dynatrace.

Environment Variables:
    AURORA_HOST: Aurora cluster endpoint
    AURORA_PORT: Database port (default: 5432)
    AURORA_DATABASE: Database name
    AURORA_USER: Database user
    AURORA_PASSWORD_SECRET_ARN: ARN of the Secrets Manager secret containing the password
    DT_ENVIRONMENT_URL: Dynatrace environment URL
    DT_API_TOKEN_SECRET_ARN: ARN of the Secrets Manager secret containing the API token
    THRESHOLD_SECONDS: Query duration threshold (default: 60)
"""

import json
import logging
import os
from datetime import datetime
from typing import Any

from collectors.postgres_collector import PostgresCollector
from dynatrace.metrics_client import DynatraceMetricsClient
from dynatrace.logs_client import DynatraceLogsClient

# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)


def get_secret(secret_arn: str) -> str:
    """Retrieve a secret value from AWS Secrets Manager."""
    import boto3

    client = boto3.client("secretsmanager")
    response = client.get_secret_value(SecretId=secret_arn)

    if "SecretString" in response:
        secret = response["SecretString"]
        # Handle JSON-formatted secrets
        try:
            secret_dict = json.loads(secret)
            return secret_dict.get("password") or secret_dict.get("apiToken") or secret
        except json.JSONDecodeError:
            return secret
    else:
        raise ValueError(f"Secret {secret_arn} does not contain a string value")


def get_config() -> dict[str, Any]:
    """Load configuration from environment variables."""
    config = {
        "aurora": {
            "host": os.environ.get("AURORA_HOST"),
            "port": int(os.environ.get("AURORA_PORT", "5432")),
            "database": os.environ.get("AURORA_DATABASE"),
            "user": os.environ.get("AURORA_USER"),
            "password_secret_arn": os.environ.get("AURORA_PASSWORD_SECRET_ARN"),
        },
        "dynatrace": {
            "environment_url": os.environ.get("DT_ENVIRONMENT_URL"),
            "api_token_secret_arn": os.environ.get("DT_API_TOKEN_SECRET_ARN"),
        },
        "threshold_seconds": int(os.environ.get("THRESHOLD_SECONDS", "60")),
    }

    # Validate required config
    required = [
        ("AURORA_HOST", config["aurora"]["host"]),
        ("AURORA_DATABASE", config["aurora"]["database"]),
        ("AURORA_USER", config["aurora"]["user"]),
        ("AURORA_PASSWORD_SECRET_ARN", config["aurora"]["password_secret_arn"]),
        ("DT_ENVIRONMENT_URL", config["dynatrace"]["environment_url"]),
        ("DT_API_TOKEN_SECRET_ARN", config["dynatrace"]["api_token_secret_arn"]),
    ]

    missing = [name for name, value in required if not value]
    if missing:
        raise ValueError(f"Missing required environment variables: {', '.join(missing)}")

    return config


def lambda_handler(event: dict, context: Any) -> dict[str, Any]:
    """
    Lambda handler function.

    Args:
        event: Lambda event (from EventBridge schedule or test invocation)
        context: Lambda context

    Returns:
        Response dict with status and details
    """
    start_time = datetime.utcnow()
    logger.info(f"Starting long-running query collection at {start_time.isoformat()}")

    try:
        # Load configuration
        config = get_config()

        # Get secrets
        logger.info("Retrieving secrets from Secrets Manager")
        db_password = get_secret(config["aurora"]["password_secret_arn"])
        dt_api_token = get_secret(config["dynatrace"]["api_token_secret_arn"])

        # Initialize collector
        collector = PostgresCollector(
            host=config["aurora"]["host"],
            port=config["aurora"]["port"],
            database=config["aurora"]["database"],
            user=config["aurora"]["user"],
            password=db_password,
            threshold_seconds=config["threshold_seconds"],
        )

        # Initialize Dynatrace clients
        metrics_client = DynatraceMetricsClient(
            environment_url=config["dynatrace"]["environment_url"],
            api_token=dt_api_token,
        )
        logs_client = DynatraceLogsClient(
            environment_url=config["dynatrace"]["environment_url"],
            api_token=dt_api_token,
        )

        # Collect long-running queries
        logger.info(
            f"Querying Aurora PostgreSQL for queries running > {config['threshold_seconds']}s"
        )
        queries = collector.get_long_running_queries()
        query_count = len(queries)
        logger.info(f"Found {query_count} long-running queries")

        # Prepare hostname for metrics
        hostname = config["aurora"]["host"].split(".")[0]  # Use cluster identifier
        db_name = config["aurora"]["database"]

        # Send metrics
        metrics = []
        if query_count > 0:
            max_duration = max(q["duration_seconds"] for q in queries)
            avg_duration = sum(q["duration_seconds"] for q in queries) / query_count
            total_duration = sum(q["duration_seconds"] for q in queries)

            metrics.extend(
                [
                    f"custom.db.long_queries.count,db.type=postgres,db.name={db_name},host={hostname} {query_count}",
                    f"custom.db.long_queries.max_duration_seconds,db.type=postgres,db.name={db_name},host={hostname} {max_duration}",
                    f"custom.db.long_queries.avg_duration_seconds,db.type=postgres,db.name={db_name},host={hostname} {avg_duration:.2f}",
                    f"custom.db.long_queries.total_duration_seconds,db.type=postgres,db.name={db_name},host={hostname} {total_duration}",
                ]
            )
        else:
            metrics.append(
                f"custom.db.long_queries.count,db.type=postgres,db.name={db_name},host={hostname} 0"
            )

        logger.info(f"Sending {len(metrics)} metrics to Dynatrace")
        metrics_result = metrics_client.send_metrics(metrics)
        logger.info(f"Metrics result: {metrics_result}")

        # Send logs for each long-running query
        if query_count > 0:
            log_entries = []
            for query in queries:
                severity = "ERROR" if query["duration_seconds"] > 300 else "WARN"
                log_entry = {
                    "content": query["query"][:10000],  # Truncate very long queries
                    "log.source": "custom.db.long_running_query",
                    "severity": severity,
                    "db.type": "postgres",
                    "db.name": db_name,
                    "db.host": hostname,
                    "query.pid": str(query["pid"]),
                    "query.duration_seconds": str(query["duration_seconds"]),
                    "query.state": query["state"],
                    "query.wait_event_type": query.get("wait_event_type") or "",
                    "query.wait_event": query.get("wait_event") or "",
                    "query.username": query["usename"],
                    "query.database": query["datname"],
                }
                log_entries.append(log_entry)

            logger.info(f"Sending {len(log_entries)} log entries to Dynatrace")
            logs_result = logs_client.send_logs(log_entries)
            logger.info(f"Logs result: {logs_result}")

        # Calculate execution time
        end_time = datetime.utcnow()
        execution_time_ms = (end_time - start_time).total_seconds() * 1000

        return {
            "statusCode": 200,
            "body": json.dumps(
                {
                    "message": "Collection completed successfully",
                    "queries_found": query_count,
                    "metrics_sent": len(metrics),
                    "logs_sent": query_count,
                    "execution_time_ms": execution_time_ms,
                }
            ),
        }

    except Exception as e:
        logger.error(f"Error during collection: {str(e)}", exc_info=True)
        return {
            "statusCode": 500,
            "body": json.dumps({"error": str(e)}),
        }
