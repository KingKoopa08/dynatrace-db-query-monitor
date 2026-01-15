"""
Dynatrace Metrics Ingest API v2 client.
"""

import logging
from typing import Any

import requests

logger = logging.getLogger(__name__)


class DynatraceMetricsClient:
    """Client for sending metrics to Dynatrace Metrics Ingest API v2."""

    def __init__(self, environment_url: str, api_token: str, timeout: int = 30):
        """
        Initialize the metrics client.

        Args:
            environment_url: Dynatrace environment URL (e.g., https://abc.live.dynatrace.com)
            api_token: API token with metrics.ingest scope
            timeout: Request timeout in seconds
        """
        self.base_url = environment_url.rstrip("/")
        self.api_token = api_token
        self.timeout = timeout
        self.ingest_url = f"{self.base_url}/api/v2/metrics/ingest"

    def send_metrics(self, metrics: list[str]) -> dict[str, Any]:
        """
        Send metrics to Dynatrace.

        Args:
            metrics: List of metrics in line protocol format
                    Example: ["custom.metric,dim=value 123", "custom.other,dim=value 456"]

        Returns:
            Response from Dynatrace API

        Raises:
            requests.RequestException: If the request fails
        """
        if not metrics:
            logger.warning("No metrics to send")
            return {"linesOk": 0, "linesInvalid": 0}

        headers = {
            "Authorization": f"Api-Token {self.api_token}",
            "Content-Type": "text/plain; charset=utf-8",
        }

        payload = "\n".join(metrics)
        logger.debug(f"Sending {len(metrics)} metrics to {self.ingest_url}")

        try:
            response = requests.post(
                self.ingest_url,
                headers=headers,
                data=payload,
                timeout=self.timeout,
            )
            response.raise_for_status()

            result = response.json() if response.text else {}
            logger.info(
                f"Metrics sent: {result.get('linesOk', 0)} OK, "
                f"{result.get('linesInvalid', 0)} invalid"
            )

            if result.get("linesInvalid", 0) > 0:
                logger.warning(f"Invalid metrics: {result.get('error', {})}")

            return result

        except requests.exceptions.HTTPError as e:
            logger.error(f"HTTP error sending metrics: {e.response.status_code}")
            logger.error(f"Response: {e.response.text}")
            raise
        except requests.exceptions.RequestException as e:
            logger.error(f"Request error sending metrics: {e}")
            raise

    def test_connection(self) -> bool:
        """Test connectivity to Dynatrace API."""
        test_url = f"{self.base_url}/api/v2/metrics/descriptors?pageSize=1"
        headers = {"Authorization": f"Api-Token {self.api_token}"}

        try:
            response = requests.get(test_url, headers=headers, timeout=10)
            response.raise_for_status()
            logger.info("Dynatrace connection test successful")
            return True
        except requests.RequestException as e:
            logger.error(f"Dynatrace connection test failed: {e}")
            return False
