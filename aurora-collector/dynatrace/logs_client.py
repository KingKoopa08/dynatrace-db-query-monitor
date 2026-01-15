"""
Dynatrace Logs Ingest API v2 client.
"""

import json
import logging
import time
from typing import Any

import requests

logger = logging.getLogger(__name__)


class DynatraceLogsClient:
    """Client for sending logs to Dynatrace Logs Ingest API v2."""

    def __init__(
        self,
        environment_url: str,
        api_token: str,
        timeout: int = 30,
        batch_size: int = 100,
    ):
        """
        Initialize the logs client.

        Args:
            environment_url: Dynatrace environment URL (e.g., https://abc.live.dynatrace.com)
            api_token: API token with logs.ingest scope
            timeout: Request timeout in seconds
            batch_size: Maximum number of log entries per request
        """
        self.base_url = environment_url.rstrip("/")
        self.api_token = api_token
        self.timeout = timeout
        self.batch_size = batch_size
        self.ingest_url = f"{self.base_url}/api/v2/logs/ingest"

    def send_logs(self, log_entries: list[dict[str, Any]]) -> dict[str, Any]:
        """
        Send log entries to Dynatrace.

        Args:
            log_entries: List of log entry dictionaries. Each entry should have:
                - content: The log message (required)
                - severity: Log level (INFO, WARN, ERROR, etc.)
                - log.source: Source identifier
                - Additional attributes as key-value pairs

        Returns:
            Summary of sent logs

        Raises:
            requests.RequestException: If the request fails
        """
        if not log_entries:
            logger.warning("No log entries to send")
            return {"sent": 0}

        headers = {
            "Authorization": f"Api-Token {self.api_token}",
            "Content-Type": "application/json; charset=utf-8",
        }

        total_sent = 0
        errors = []

        # Process in batches
        for i in range(0, len(log_entries), self.batch_size):
            batch = log_entries[i : i + self.batch_size]

            # Add timestamp if not present
            current_time_ms = int(time.time() * 1000)
            for entry in batch:
                if "timestamp" not in entry:
                    entry["timestamp"] = current_time_ms

            payload = json.dumps(batch)
            logger.debug(f"Sending batch of {len(batch)} log entries to {self.ingest_url}")

            try:
                response = requests.post(
                    self.ingest_url,
                    headers=headers,
                    data=payload,
                    timeout=self.timeout,
                )
                response.raise_for_status()
                total_sent += len(batch)
                logger.debug(f"Batch sent successfully: {len(batch)} entries")

            except requests.exceptions.HTTPError as e:
                error_msg = f"HTTP {e.response.status_code}: {e.response.text}"
                logger.error(f"Error sending log batch: {error_msg}")
                errors.append(error_msg)
            except requests.exceptions.RequestException as e:
                error_msg = str(e)
                logger.error(f"Request error sending log batch: {error_msg}")
                errors.append(error_msg)

        result = {"sent": total_sent, "total": len(log_entries)}
        if errors:
            result["errors"] = errors

        logger.info(f"Logs sent: {total_sent}/{len(log_entries)}")
        return result

    def send_log(self, content: str, severity: str = "INFO", **attributes: Any) -> dict[str, Any]:
        """
        Send a single log entry.

        Args:
            content: Log message content
            severity: Log severity (INFO, WARN, ERROR)
            **attributes: Additional log attributes

        Returns:
            Result of the send operation
        """
        entry = {"content": content, "severity": severity, **attributes}
        return self.send_logs([entry])
