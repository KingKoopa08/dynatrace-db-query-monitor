/*
============================================================================
Long-Running Query Monitoring for Dynatrace
SQL Server Deployment Script
Version: 2.2 - Query Store enrichment moved to PowerShell (ADO.NET)
               SQL SP now uses table variable (in-memory, no tempdb I/O)

Run this script on each SQL Server instance you want to monitor.
Requires: maintenance database to exist
============================================================================
*/

USE [maintenance];
GO

PRINT '============================================';
PRINT 'Deploying Long-Running Query Monitoring v2.1';
PRINT '============================================';
PRINT '';

----------------------------------------------------------------------
-- STEP 1: Create Exclusion Types Lookup
----------------------------------------------------------------------
PRINT 'Creating ExclusionTypes table...';

IF OBJECT_ID('dbo.ExclusionTypes', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.ExclusionTypes (
        ExclusionTypeId TINYINT NOT NULL PRIMARY KEY,
        TypeName VARCHAR(20) NOT NULL,
        Description VARCHAR(100) NULL
    );

    INSERT INTO dbo.ExclusionTypes (ExclusionTypeId, TypeName, Description)
    VALUES
        (1, 'TEXT_PATTERN', 'LIKE pattern match against query text'),
        (2, 'LOGIN', 'Exact match on login_name'),
        (3, 'COMMAND', 'LIKE pattern match against command'),
        (4, 'PROGRAM_NAME', 'LIKE pattern match against program_name');

    PRINT '  - ExclusionTypes created and populated';
END
ELSE
    PRINT '  - ExclusionTypes already exists, skipping';
GO

----------------------------------------------------------------------
-- STEP 2: Create Exclusions Configuration Table
----------------------------------------------------------------------
PRINT 'Creating LongQueryExclusions table...';

IF OBJECT_ID('dbo.LongQueryExclusions', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.LongQueryExclusions (
        ExclusionId INT IDENTITY(1,1) NOT NULL,
        ExclusionType TINYINT NOT NULL,
        Pattern VARCHAR(200) NOT NULL,
        ThresholdSeconds INT NOT NULL CONSTRAINT DF_Exclusions_Threshold DEFAULT (60),
        Description VARCHAR(200) NULL,
        IsActive BIT NOT NULL CONSTRAINT DF_Exclusions_IsActive DEFAULT (1),
        CreatedDate DATETIME2 NOT NULL CONSTRAINT DF_Exclusions_Created DEFAULT (GETDATE()),
        CreatedBy NVARCHAR(128) NULL CONSTRAINT DF_Exclusions_CreatedBy DEFAULT (SUSER_SNAME()),
        ModifiedDate DATETIME2 NULL,
        ModifiedBy NVARCHAR(128) NULL,

        CONSTRAINT PK_LongQueryExclusions PRIMARY KEY CLUSTERED (ExclusionId),
        CONSTRAINT FK_Exclusions_Type FOREIGN KEY (ExclusionType)
            REFERENCES dbo.ExclusionTypes (ExclusionTypeId),
        CONSTRAINT UQ_Exclusions_TypePattern UNIQUE (ExclusionType, Pattern)
    );

    CREATE NONCLUSTERED INDEX IX_LongQueryExclusions_Active
    ON dbo.LongQueryExclusions (IsActive, ExclusionType)
    INCLUDE (Pattern, ThresholdSeconds)
    WHERE IsActive = 1;

    PRINT '  - LongQueryExclusions created with index';
END
ELSE
    PRINT '  - LongQueryExclusions already exists, skipping';
GO

----------------------------------------------------------------------
-- STEP 3: Populate Default Exclusions
----------------------------------------------------------------------
PRINT 'Populating default exclusions...';

IF NOT EXISTS (SELECT 1 FROM dbo.LongQueryExclusions)
BEGIN
    INSERT INTO dbo.LongQueryExclusions (ExclusionType, Pattern, ThresholdSeconds, Description)
    VALUES
        -- System/Internal (Type 1: TEXT_PATTERN)
        (1, '%DatabaseMail%SendMail%', 60, 'Database Mail async operations'),
        (1, '%sp_server_diagnostics%', 60, 'Always On health monitoring'),
        (1, '%sp_hadr_%', 60, 'Always On AG procedures'),
        (1, '%sp_cdc_scan%', 60, 'CDC capture process'),
        (1, '%sp_cdc_cleanup%', 60, 'CDC cleanup job'),
        (1, '%lsn_time_mapping%', 60, 'CDC LSN mapping'),
        (1, '%sp_replcmds%', 60, 'Replication log reader'),
        (1, '%sp_repldone%', 60, 'Replication marker'),
        (1, '%HumanEvents%', 60, 'sp_HumanEvents monitoring'),
        (1, '%sp_WhoIsActive%', 60, 'Activity monitoring'),
        (1, '%sp_sqlagent_log_jobhistory%', 60, 'Agent job logging'),

        -- Self-exclusion (CRITICAL)
        (1, '%LongQueryExclusions%', 60, 'This monitoring query'),
        (1, '%dm_exec_requests%dm_exec_sql_text%', 60, 'DMV monitoring queries'),

        -- Maintenance (longer thresholds)
        (1, '%BACKUP DATABASE%', 10800, 'Full backup - 3hr'),
        (1, '%BACKUP LOG%', 3600, 'Log backup - 1hr'),
        (1, '%RESTORE VERIFYONLY%', 10800, 'Backup verify - 3hr'),
        (1, '%UPDATE STATISTICS%', 21600, 'Stats update - 6hr'),
        (1, '%ALTER INDEX%REBUILD%', 21600, 'Index rebuild - 6hr'),
        (1, '%ALTER INDEX%REORGANIZE%', 7200, 'Index reorg - 2hr'),
        (1, '%DBCC CHECKDB%', 14400, 'Integrity check - 4hr'),

        -- Commands (Type 3)
        (3, 'BACKUP DATABASE', 10800, 'Backup command - 3hr'),
        (3, 'BACKUP LOG', 3600, 'Log backup - 1hr'),
        (3, 'DBCC%', 14400, 'DBCC commands - 4hr'),

        -- Program names (Type 4)
        (4, 'DatabaseMail%', 60, 'Database Mail app'),
        (4, 'SQLAgent - Job%', 300, 'SQL Agent jobs - 5min');

    PRINT '  - Default exclusions inserted: ' + CAST(@@ROWCOUNT AS VARCHAR);
END
ELSE
    PRINT '  - Exclusions already exist, skipping default insert';
GO

----------------------------------------------------------------------
-- STEP 4: Create Main Stored Procedure (v2.1 with additional fields)
----------------------------------------------------------------------
PRINT 'Creating usp_GetLongRunningQueries procedure v2.1...';
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetLongRunningQueries
    @DefaultThresholdSeconds INT = 60,
    @IncludeQueryStoreId BIT = 1,
    @Debug BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

    DECLARE @StartTime DATETIME2 = GETDATE();
    DECLARE @ServerName NVARCHAR(128) = @@SERVERNAME;

    -- Load exclusions into table variable
    DECLARE @Exclusions TABLE (
        ExclusionType TINYINT NOT NULL,
        Pattern VARCHAR(200) NOT NULL,
        ThresholdSeconds INT NOT NULL,
        PRIMARY KEY (ExclusionType, Pattern)
    );

    INSERT INTO @Exclusions (ExclusionType, Pattern, ThresholdSeconds)
    SELECT ExclusionType, Pattern, ThresholdSeconds
    FROM maintenance.dbo.LongQueryExclusions WITH (NOLOCK)
    WHERE IsActive = 1;

    IF @Debug = 1
        SELECT 'Exclusions loaded' AS Step, @@ROWCOUNT AS [Count];

    -- Early exit check
    IF NOT EXISTS (
        SELECT 1
        FROM sys.dm_exec_requests WITH (NOLOCK)
        WHERE session_id > 50
            AND status NOT IN ('background', 'sleeping')
            AND sql_handle IS NOT NULL
            AND DATEDIFF(SECOND, start_time, GETDATE()) > @DefaultThresholdSeconds
    )
    BEGIN
        SELECT
            CAST(NULL AS INT) AS session_id,
            CAST(NULL AS DATETIME) AS start_time,
            CAST(NULL AS INT) AS duration_seconds,
            CAST(NULL AS NVARCHAR(128)) AS database_name,
            CAST(NULL AS NVARCHAR(128)) AS server_name,
            CAST(NULL AS NVARCHAR(30)) AS status,
            CAST(NULL AS NVARCHAR(32)) AS command,
            CAST(NULL AS NVARCHAR(60)) AS wait_type,
            CAST(NULL AS INT) AS wait_time,
            CAST(NULL AS NVARCHAR(60)) AS last_wait_type,
            CAST(NULL AS INT) AS cpu_time,
            CAST(NULL AS BIGINT) AS reads,
            CAST(NULL AS BIGINT) AS writes,
            CAST(NULL AS BIGINT) AS logical_reads,
            CAST(NULL AS BIGINT) AS row_count,
            CAST(NULL AS BIGINT) AS granted_query_memory_kb,
            CAST(NULL AS INT) AS blocking_session_id,
            CAST(NULL AS INT) AS open_transaction_count,
            CAST(NULL AS SMALLINT) AS transaction_isolation_level,
            CAST(NULL AS VARCHAR(20)) AS isolation_level_desc,
            CAST(NULL AS REAL) AS percent_complete,
            CAST(NULL AS BIGINT) AS estimated_completion_time_ms,
            CAST(NULL AS NVARCHAR(128)) AS login_name,
            CAST(NULL AS NVARCHAR(128)) AS host_name,
            CAST(NULL AS NVARCHAR(128)) AS program_name,
            CAST(NULL AS NVARCHAR(MAX)) AS current_statement,
            CAST(NULL AS NVARCHAR(4000)) AS query_text_truncated,
            CAST(NULL AS VARCHAR(20)) AS query_hash_hex,
            CAST(NULL AS VARCHAR(20)) AS query_plan_hash_hex,
            CAST(NULL AS BIGINT) AS query_id,
            CAST(NULL AS BIGINT) AS plan_id
        WHERE 1 = 0;
        RETURN;
    END

    -- Results temp table (using temp table so dynamic SQL can access it for Query Store enrichment)
    CREATE TABLE @Results (
        session_id INT NOT NULL PRIMARY KEY,
        start_time DATETIME NOT NULL,
        duration_seconds INT NOT NULL,
        database_id INT NULL,
        database_name NVARCHAR(128) NULL,
        server_name NVARCHAR(128) NULL,
        status NVARCHAR(30) NULL,
        command NVARCHAR(32) NULL,
        wait_type NVARCHAR(60) NULL,
        wait_time INT NULL,
        last_wait_type NVARCHAR(60) NULL,
        cpu_time INT NULL,
        reads BIGINT NULL,
        writes BIGINT NULL,
        logical_reads BIGINT NULL,
        row_count BIGINT NULL,
        granted_query_memory_kb BIGINT NULL,
        blocking_session_id INT NULL,
        open_transaction_count INT NULL,
        transaction_isolation_level SMALLINT NULL,
        percent_complete REAL NULL,
        estimated_completion_time_ms BIGINT NULL,
        login_name NVARCHAR(128) NULL,
        host_name NVARCHAR(128) NULL,
        program_name NVARCHAR(128) NULL,
        current_statement NVARCHAR(MAX) NULL,
        query_text_truncated NVARCHAR(4000) NULL,
        query_hash BINARY(8) NULL,
        query_plan_hash BINARY(8) NULL,
        query_id BIGINT NULL,
        plan_id BIGINT NULL
    );

    -- Main collection query with additional diagnostic fields
    INSERT INTO @Results (
        session_id, start_time, duration_seconds, database_id, database_name, server_name,
        status, command, wait_type, wait_time, last_wait_type, cpu_time, reads, writes,
        logical_reads, row_count, granted_query_memory_kb, blocking_session_id,
        open_transaction_count, transaction_isolation_level, percent_complete,
        estimated_completion_time_ms, login_name, host_name, program_name,
        current_statement, query_text_truncated, query_hash, query_plan_hash
    )
    SELECT
        r.session_id,
        r.start_time,
        DATEDIFF(SECOND, r.start_time, GETDATE()),
        r.database_id,
        DB_NAME(r.database_id),
        @ServerName,
        r.status,
        r.command,
        ISNULL(r.wait_type, ''),
        r.wait_time,
        ISNULL(r.last_wait_type, ''),
        r.cpu_time,
        r.reads,
        r.writes,
        r.logical_reads,
        r.row_count,
        r.granted_query_memory * 8,  -- Convert pages to KB
        r.blocking_session_id,
        r.open_transaction_count,
        r.transaction_isolation_level,
        r.percent_complete,
        r.estimated_completion_time,
        s.login_name,
        s.host_name,
        s.program_name,
        SUBSTRING(t.text,
            (r.statement_start_offset / 2) + 1,
            (CASE r.statement_end_offset
                WHEN -1 THEN DATALENGTH(t.text)
                ELSE r.statement_end_offset
            END - r.statement_start_offset) / 2 + 1
        ),
        LEFT(t.text, 4000),
        r.query_hash,
        r.query_plan_hash
    FROM sys.dm_exec_requests r WITH (NOLOCK)
    INNER JOIN sys.dm_exec_sessions s WITH (NOLOCK) ON r.session_id = s.session_id
    CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) t
    WHERE r.session_id > 50
        AND r.status NOT IN ('background', 'sleeping')
        AND r.sql_handle IS NOT NULL
        AND DATEDIFF(SECOND, r.start_time, GETDATE()) > @DefaultThresholdSeconds
        AND NOT EXISTS (
            SELECT 1 FROM @Exclusions e
            WHERE e.ExclusionType = 1 AND t.text LIKE e.Pattern
                AND DATEDIFF(SECOND, r.start_time, GETDATE()) <= e.ThresholdSeconds
        )
        AND NOT EXISTS (
            SELECT 1 FROM @Exclusions e
            WHERE e.ExclusionType = 2 AND s.login_name = e.Pattern
                AND DATEDIFF(SECOND, r.start_time, GETDATE()) <= e.ThresholdSeconds
        )
        AND NOT EXISTS (
            SELECT 1 FROM @Exclusions e
            WHERE e.ExclusionType = 3 AND r.command LIKE e.Pattern
                AND DATEDIFF(SECOND, r.start_time, GETDATE()) <= e.ThresholdSeconds
        )
        AND NOT EXISTS (
            SELECT 1 FROM @Exclusions e
            WHERE e.ExclusionType = 4 AND s.program_name LIKE e.Pattern
                AND DATEDIFF(SECOND, r.start_time, GETDATE()) <= e.ThresholdSeconds
        )
    OPTION (RECOMPILE);

    IF @Debug = 1
        SELECT 'Queries collected' AS Step, @@ROWCOUNT AS [Count];

    -- Query Store enrichment (temp table is visible to dynamic SQL)
    IF @IncludeQueryStoreId = 1 AND EXISTS (SELECT 1 FROM @Results)
    BEGIN
        DECLARE @DbName NVARCHAR(128);
        DECLARE @Sql NVARCHAR(MAX);

        DECLARE db_cursor CURSOR LOCAL FAST_FORWARD READ_ONLY FOR
            SELECT DISTINCT r.database_name
            FROM @Results r
            INNER JOIN sys.databases d ON d.name = r.database_name
            WHERE d.is_query_store_on = 1 AND d.state = 0;

        OPEN db_cursor;
        FETCH NEXT FROM db_cursor INTO @DbName;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            BEGIN TRY
                -- Dynamic SQL can access @Results directly since temp tables are session-scoped
                SET @Sql = N'
                    UPDATE r
                    SET r.query_id = qs.query_id,
                        r.plan_id = (
                            SELECT TOP 1 qp.plan_id
                            FROM ' + QUOTENAME(@DbName) + N'.sys.query_store_plan qp
                            WHERE qp.query_id = qs.query_id
                            ORDER BY qp.last_execution_time DESC
                        )
                    FROM @Results r
                    INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.query_store_query qs
                        ON r.query_hash = qs.query_hash
                    WHERE r.database_name = @DbName AND r.query_id IS NULL;';

                EXEC sp_executesql @Sql, N'@DbName NVARCHAR(128)', @DbName;

                IF @Debug = 1
                    PRINT 'Query Store enrichment for ' + @DbName + ': ' + CAST(@@ROWCOUNT AS VARCHAR) + ' rows updated';
            END TRY
            BEGIN CATCH
                IF @Debug = 1
                    PRINT 'Query Store lookup failed for ' + @DbName + ': ' + ERROR_MESSAGE();
            END CATCH

            FETCH NEXT FROM db_cursor INTO @DbName;
        END

        CLOSE db_cursor;
        DEALLOCATE db_cursor;
    END

    -- Return results with isolation level description
    SELECT
        session_id,
        start_time,
        duration_seconds,
        database_name,
        server_name,
        status,
        command,
        wait_type,
        wait_time,
        last_wait_type,
        cpu_time,
        reads,
        writes,
        logical_reads,
        row_count,
        granted_query_memory_kb,
        blocking_session_id,
        open_transaction_count,
        transaction_isolation_level,
        CASE transaction_isolation_level
            WHEN 0 THEN 'Unspecified'
            WHEN 1 THEN 'ReadUncommitted'
            WHEN 2 THEN 'ReadCommitted'
            WHEN 3 THEN 'Repeatable'
            WHEN 4 THEN 'Serializable'
            WHEN 5 THEN 'Snapshot'
            ELSE 'Unknown'
        END AS isolation_level_desc,
        percent_complete,
        estimated_completion_time_ms,
        login_name,
        host_name,
        program_name,
        current_statement,
        query_text_truncated,
        CONVERT(VARCHAR(20), query_hash, 1) AS query_hash_hex,
        CONVERT(VARCHAR(20), query_plan_hash, 1) AS query_plan_hash_hex,
        query_id,
        plan_id
    FROM @Results
    ORDER BY duration_seconds DESC;

    IF @Debug = 1
        SELECT 'Complete' AS Step, DATEDIFF(MILLISECOND, @StartTime, GETDATE()) AS ElapsedMs;
END;
GO

PRINT '  - usp_GetLongRunningQueries v2.1 created';
GO

----------------------------------------------------------------------
-- STEP 5: Create Helper Procedures
----------------------------------------------------------------------
PRINT 'Creating helper procedures...';
GO

CREATE OR ALTER PROCEDURE dbo.usp_AddLongQueryExclusion
    @ExclusionType TINYINT,
    @Pattern VARCHAR(200),
    @ThresholdSeconds INT = 60,
    @Description VARCHAR(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO dbo.LongQueryExclusions (ExclusionType, Pattern, ThresholdSeconds, Description)
    VALUES (@ExclusionType, @Pattern, @ThresholdSeconds, @Description);

    SELECT 'Exclusion added' AS Result, SCOPE_IDENTITY() AS ExclusionId;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_ViewLongQueryExclusions
    @ActiveOnly BIT = 1
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        e.ExclusionId,
        t.TypeName,
        e.Pattern,
        e.ThresholdSeconds,
        e.Description,
        e.IsActive
    FROM dbo.LongQueryExclusions e
    INNER JOIN dbo.ExclusionTypes t ON e.ExclusionType = t.ExclusionTypeId
    WHERE e.IsActive = 1 OR @ActiveOnly = 0
    ORDER BY e.ExclusionType, e.ThresholdSeconds;
END;
GO

PRINT '  - Helper procedures created';
GO

----------------------------------------------------------------------
-- DONE
----------------------------------------------------------------------
PRINT '';
PRINT '============================================';
PRINT 'Deployment Complete! (v2.1)';
PRINT '============================================';
PRINT '';
PRINT 'Test with: EXEC maintenance.dbo.usp_GetLongRunningQueries @Debug = 1;';
PRINT 'View exclusions: EXEC maintenance.dbo.usp_ViewLongQueryExclusions;';
GO
