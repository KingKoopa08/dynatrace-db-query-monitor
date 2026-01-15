"""
PostgreSQL collector for long-running queries using pg_stat_activity.
"""

import logging
from typing import Any

import psycopg2
from psycopg2.extras import RealDictCursor

logger = logging.getLogger(__name__)


class PostgresCollector:
    """Collects long-running queries from PostgreSQL/Aurora PostgreSQL."""

    def __init__(
        self,
        host: str,
        port: int,
        database: str,
        user: str,
        password: str,
        threshold_seconds: int = 60,
    ):
        """
        Initialize the PostgreSQL collector.

        Args:
            host: Database host
            port: Database port
            database: Database name
            user: Database user
            password: Database password
            threshold_seconds: Minimum query duration to capture
        """
        self.host = host
        self.port = port
        self.database = database
        self.user = user
        self.password = password
        self.threshold_seconds = threshold_seconds

    def _get_connection(self) -> psycopg2.extensions.connection:
        """Create a database connection."""
        return psycopg2.connect(
            host=self.host,
            port=self.port,
            dbname=self.database,
            user=self.user,
            password=self.password,
            connect_timeout=10,
            application_name="dynatrace_monitor",
        )

    def get_long_running_queries(self) -> list[dict[str, Any]]:
        """
        Query pg_stat_activity for long-running queries.

        Returns:
            List of dictionaries containing query information
        """
        query = """
        SELECT
            pid,
            usename,
            datname,
            state,
            wait_event_type,
            wait_event,
            query_start,
            EXTRACT(EPOCH FROM (now() - query_start))::integer AS duration_seconds,
            LEFT(query, 10000) AS query,
            backend_type,
            client_addr::text,
            client_hostname,
            application_name
        FROM pg_stat_activity
        WHERE state = 'active'
            AND pid != pg_backend_pid()
            AND query NOT LIKE '%%pg_stat_activity%%'
            AND query NOT LIKE '%%dynatrace_monitor%%'
            AND now() - query_start > interval '%s seconds'
            AND backend_type = 'client backend'
        ORDER BY duration_seconds DESC;
        """

        try:
            conn = self._get_connection()
            try:
                with conn.cursor(cursor_factory=RealDictCursor) as cur:
                    cur.execute(query, (self.threshold_seconds,))
                    results = cur.fetchall()
                    return [dict(row) for row in results]
            finally:
                conn.close()
        except psycopg2.Error as e:
            logger.error(f"Database error: {e}")
            raise

    def get_blocked_queries(self) -> list[dict[str, Any]]:
        """
        Query for blocked queries (waiting on locks).

        Returns:
            List of blocked query information
        """
        query = """
        SELECT
            blocked.pid AS blocked_pid,
            blocked.usename AS blocked_user,
            blocked.query AS blocked_query,
            EXTRACT(EPOCH FROM (now() - blocked.query_start))::integer AS blocked_duration,
            blocking.pid AS blocking_pid,
            blocking.usename AS blocking_user,
            blocking.query AS blocking_query,
            blocking.state AS blocking_state
        FROM pg_stat_activity blocked
        JOIN pg_stat_activity blocking
            ON blocking.pid = ANY(pg_blocking_pids(blocked.pid))
        WHERE blocked.state = 'active'
            AND blocked.pid != pg_backend_pid()
        ORDER BY blocked_duration DESC;
        """

        try:
            conn = self._get_connection()
            try:
                with conn.cursor(cursor_factory=RealDictCursor) as cur:
                    cur.execute(query)
                    results = cur.fetchall()
                    return [dict(row) for row in results]
            finally:
                conn.close()
        except psycopg2.Error as e:
            logger.error(f"Database error: {e}")
            raise

    def get_query_stats(self) -> dict[str, Any]:
        """
        Get aggregate query statistics from pg_stat_statements (if available).

        Returns:
            Dictionary with query statistics
        """
        query = """
        SELECT
            COUNT(*) AS total_queries,
            SUM(calls) AS total_calls,
            SUM(total_exec_time)::bigint AS total_exec_time_ms,
            AVG(mean_exec_time)::numeric(10,2) AS avg_exec_time_ms,
            MAX(max_exec_time)::numeric(10,2) AS max_exec_time_ms
        FROM pg_stat_statements
        WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database());
        """

        try:
            conn = self._get_connection()
            try:
                with conn.cursor(cursor_factory=RealDictCursor) as cur:
                    cur.execute(query)
                    result = cur.fetchone()
                    return dict(result) if result else {}
            except psycopg2.errors.UndefinedTable:
                logger.warning("pg_stat_statements extension not available")
                return {}
            finally:
                conn.close()
        except psycopg2.Error as e:
            logger.error(f"Database error: {e}")
            raise

    def test_connection(self) -> bool:
        """Test the database connection."""
        try:
            conn = self._get_connection()
            conn.close()
            return True
        except psycopg2.Error as e:
            logger.error(f"Connection test failed: {e}")
            return False
