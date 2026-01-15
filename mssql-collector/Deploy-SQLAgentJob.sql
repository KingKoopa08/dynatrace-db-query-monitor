/*
============================================================================
Long-Running Query Monitoring - SQL Agent Job Deployment
Creates a SQL Agent job to run the PowerShell collector every minute

Prerequisites:
- SQL Agent must be running
- PowerShell script deployed to the path specified below
- config.json configured with correct settings
- DT_API_TOKEN environment variable set (machine-level)
============================================================================
*/

USE [msdb];
GO

-- Configuration: Update this path to match your deployment location
DECLARE @ScriptPath NVARCHAR(500) = N'C:\Program Files\Scripts\SqlAgent\mssql-collector\Get-LongRunningQueries.ps1';
DECLARE @JobName NVARCHAR(128) = N'Dynatrace - Long Running Query Monitor';
DECLARE @JobDescription NVARCHAR(512) = N'Monitors for long-running queries and sends metrics/logs to Dynatrace. Runs every minute.';
DECLARE @JobCategory NVARCHAR(128) = N'Database Maintenance';

-- Variables
DECLARE @JobId BINARY(16);
DECLARE @ScheduleId INT;
DECLARE @StepCommand NVARCHAR(MAX);

PRINT '============================================';
PRINT 'Deploying SQL Agent Job: ' + @JobName;
PRINT '============================================';
PRINT '';

----------------------------------------------------------------------
-- STEP 1: Create job category if it doesn't exist
----------------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM msdb.dbo.syscategories WHERE name = @JobCategory AND category_class = 1)
BEGIN
    EXEC msdb.dbo.sp_add_category
        @class = N'JOB',
        @type = N'LOCAL',
        @name = @JobCategory;
    PRINT 'Created job category: ' + @JobCategory;
END
ELSE
    PRINT 'Job category already exists: ' + @JobCategory;

----------------------------------------------------------------------
-- STEP 2: Remove existing job if it exists
----------------------------------------------------------------------
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = @JobName)
BEGIN
    EXEC msdb.dbo.sp_delete_job @job_name = @JobName, @delete_unused_schedule = 1;
    PRINT 'Removed existing job: ' + @JobName;
END

----------------------------------------------------------------------
-- STEP 3: Create the job
----------------------------------------------------------------------
EXEC msdb.dbo.sp_add_job
    @job_name = @JobName,
    @enabled = 1,
    @description = @JobDescription,
    @category_name = @JobCategory,
    @owner_login_name = N'sa',
    @notify_level_eventlog = 2,  -- On failure
    @notify_level_email = 0,
    @notify_level_page = 0,
    @delete_level = 0;

SELECT @JobId = job_id FROM msdb.dbo.sysjobs WHERE name = @JobName;
PRINT 'Created job: ' + @JobName;

----------------------------------------------------------------------
-- STEP 4: Add job step - PowerShell execution
----------------------------------------------------------------------
SET @StepCommand = N'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + @ScriptPath + N'"';

EXEC msdb.dbo.sp_add_jobstep
    @job_id = @JobId,
    @step_name = N'Collect Long-Running Queries',
    @step_id = 1,
    @subsystem = N'CmdExec',
    @command = @StepCommand,
    @on_success_action = 1,  -- Quit with success
    @on_fail_action = 2,     -- Quit with failure
    @retry_attempts = 0,
    @retry_interval = 0,
    @flags = 0;

PRINT 'Added job step: Collect Long-Running Queries';
PRINT '  Command: ' + @StepCommand;

----------------------------------------------------------------------
-- STEP 5: Create schedule - Every 1 minute
----------------------------------------------------------------------
EXEC msdb.dbo.sp_add_jobschedule
    @job_id = @JobId,
    @name = N'Every 1 Minute',
    @enabled = 1,
    @freq_type = 4,              -- Daily
    @freq_interval = 1,          -- Every 1 day
    @freq_subday_type = 4,       -- Minutes
    @freq_subday_interval = 1,   -- Every 1 minute
    @freq_relative_interval = 0,
    @freq_recurrence_factor = 0,
    @active_start_date = 20200101,
    @active_end_date = 99991231,
    @active_start_time = 0,      -- 00:00:00
    @active_end_time = 235959;   -- 23:59:59

PRINT 'Added schedule: Every 1 Minute';

----------------------------------------------------------------------
-- STEP 6: Add job to local server
----------------------------------------------------------------------
EXEC msdb.dbo.sp_add_jobserver
    @job_id = @JobId,
    @server_name = N'(local)';

PRINT 'Added job to local server';

----------------------------------------------------------------------
-- DONE
----------------------------------------------------------------------
PRINT '';
PRINT '============================================';
PRINT 'SQL Agent Job Deployment Complete!';
PRINT '============================================';
PRINT '';
PRINT 'Job Name: ' + @JobName;
PRINT 'Schedule: Every 1 minute';
PRINT 'Script:   ' + @ScriptPath;
PRINT '';
PRINT 'To verify:';
PRINT '  EXEC msdb.dbo.sp_help_job @job_name = ''' + @JobName + ''';';
PRINT '';
PRINT 'To run immediately:';
PRINT '  EXEC msdb.dbo.sp_start_job @job_name = ''' + @JobName + ''';';
PRINT '';
PRINT 'To disable:';
PRINT '  EXEC msdb.dbo.sp_update_job @job_name = ''' + @JobName + ''', @enabled = 0;';
PRINT '';
PRINT 'To view history:';
PRINT '  SELECT TOP 20 * FROM msdb.dbo.sysjobhistory WHERE job_id = ''' + CONVERT(VARCHAR(36), @JobId) + ''' ORDER BY run_date DESC, run_time DESC;';
GO
