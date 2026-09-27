### TỐI ƯU ORGANIZE,REBUILD INDEX  CHO ALWAYS ON

- Xóa CommandLog cũ

```bash
create PROCEDURE sp_ClearCommandLog 
	@RetentionDays int
AS
BEGIN
	SET NOCOUNT ON;

	DECLARE @RowsAffected INT = 1;
	DECLARE @CutoffDate DATETIME = DATEADD(DAY, -@RetentionDays, GETDATE());

	-- Xóa theo từng batch 5.000 dòng để tránh lock bảng và nghẽn log
	WHILE @RowsAffected > 0
	BEGIN
		DELETE TOP (5000)
		FROM [master].[dbo].[CommandLog]
		WHERE StartTime < @CutoffDate;

		SET @RowsAffected = @@ROWCOUNT;
    
		-- Nghỉ ngắn 50ms giữa các batch để nhường I/O
		WAITFOR DELAY '00:00:00.050';
	END
END
GO
```

```script
create PROCEDURE sp_ClearCommandLog 
	@RetentionDays int
AS
BEGIN
	SET NOCOUNT ON;
	EXEC dbo.DatabaseBackup
		@Databases = 'AVAILABILITY_GROUP_DATABASES',
		@Directory = 'D:\Backup\Tranlogs',
		@BackupType = 'LOG',
		@Compress = 'Y',
		@Checksum = 'Y',
		
		-- Tắt Verify để tránh nghẽn I/O đĩa khi file log lớn
		@Verify = 'N',
		
		-- Giữ log tối thiểu 24 - 48 giờ để đảm bảo chuỗi khôi phục (Point-in-time Recovery)
		@CleanupTime = 24,
		@CleanupMode = 'AFTER_BACKUP',
		
		-- Ghi lịch sử vào CommandLog để dễ theo dõi
		@LogToTable = 'Y';
END
```

- Create table audit 
```script
IF OBJECT_ID('dbo.AdaptiveLogBackupLog', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.AdaptiveLogBackupLog (
        LogID                   BIGINT IDENTITY(1,1) PRIMARY KEY,
        RunTime                 DATETIME2(2) NOT NULL DEFAULT SYSDATETIME(),
        DatabaseName            sysname NOT NULL,
        TotalLogMB              DECIMAL(18,2) NULL,
        UsedLogMB               DECIMAL(18,2) NULL,
        UsedLogPercent          DECIMAL(5,2) NULL,
        MinutesSinceLastBackup  INT NULL,
        LogReuseWait            NVARCHAR(60) NULL,
        MaxSendQueueMB          BIGINT NULL,
        MaxRedoQueueMB          BIGINT NULL,
        WorstSyncHealth         NVARCHAR(60) NULL,
        ActionTaken             VARCHAR(20) NOT NULL, -- 'BACKUP', 'SKIP', 'AG_WARNING', 'ERROR'
        TriggerReason           NVARCHAR(255) NULL,
        ErrorMessage            NVARCHAR(4000) NULL
    );

    CREATE NONCLUSTERED INDEX IX_DBA_AdaptiveLogBackupLog_RunTime 
    ON dbo.AdaptiveLogBackupLog (RunTime DESC, ActionTaken);
END;

IF OBJECT_ID('dbo.AgGuardHistory', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.AgGuardHistory
    (
        LogId           BIGINT IDENTITY(1,1) PRIMARY KEY,
        CheckTime       DATETIME2(0) DEFAULT SYSDATETIME(),
        ActionType      VARCHAR(20)  DEFAULT 'REORGANIZE', -- REBUILD hoặc REORGANIZE
        DatabaseName    sysname,
        Verdict         VARCHAR(10),     -- ALLOW, WARN, STOP
        Reason          NVARCHAR(1000),
        DynamicMaxDOP   INT,
        Executed        BIT DEFAULT 0,
        ExecutionStatus NVARCHAR(50) NULL, -- SUCCESS, FAILED, SKIPPED_STOP
        ErrorMessage    NVARCHAR(MAX) NULL
    );

    CREATE NONCLUSTERED INDEX IX_AgGuardHistory_Time 
    ON dbo.AgGuardHistory (CheckTime DESC, DatabaseName);
END
ELSE
BEGIN
    -- Nếu bảng đã tồn tại từ câu hỏi trước, thêm cột ActionType nếu chưa có
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.AgGuardHistory') AND name = 'ActionType')
    BEGIN
        ALTER TABLE dbo.AgGuardHistory ADD ActionType VARCHAR(20) DEFAULT 'REORGANIZE';
    END;
END;
GO
```

- Backup log
```script
create PROCEDURE dbo.usp_AdaptiveLogBackup
    @LogPercentThreshold          DECIMAL(5,2)  = 60.0,             -- Ngưỡng % dung lượng file log để kích hoạt backup
    @MinUsedLogMBToTrigger         INT           = 5120,             -- Dung lượng used tối thiểu (MB) để kích hoạt theo %
    @MaxMinutesBetweenLogBackups   INT           = 30,               -- Khoảng cách tối đa giữa các lần backup (phút)
    @MaxLogSendQueueMBWarning      BIGINT        = 1024,             -- Ngưỡng cảnh báo Send Queue (MB)
    @MaxRedoQueueMBWarning         BIGINT        = 2048,             -- Ngưỡng cảnh báo Redo Queue (MB)
    @BackupDirectory               NVARCHAR(500) = N'D:\Backup\Tranlogs', -- Đường dẫn lưu trữ backup
    @PurgeAuditDays                INT           = 14                -- Giữ lịch sử audit log trong X ngày
AS
BEGIN
    SET NOCOUNT ON;

    --------------------------------------------------------------------
    -- 1. CHỐNG OVERLAP BẰNG MUTEX APPLICATION LOCK (Session Scope)
    --------------------------------------------------------------------
    DECLARE @LockResult INT;
    EXEC @LockResult = sys.sp_getapplock
        @Resource    = N'Global_AdaptiveLogBackup_Lock',
        @LockMode    = N'Exclusive',
        @LockOwner   = N'Session',
        @LockTimeout = 0; -- Nếu phiên trước đang chạy, thoát ngay lập tức

    IF @LockResult < 0
    BEGIN
        PRINT '[MUTEX] Phien AdaptiveLogBackup truoc do chua hoan tat. Thoat phien hien tai.';
        RETURN;
    END

    BEGIN TRY
        ----------------------------------------------------------------
        -- 2. KIỂM TRA ĐIỀU KIỆN AG PRIMARY REPLICA
        ----------------------------------------------------------------
        IF NOT EXISTS (
            SELECT 1 
            FROM sys.databases d
            WHERE d.group_database_id IS NOT NULL 
              AND sys.fn_hadr_is_primary_replica(d.name) = 1
              AND d.state_desc = 'ONLINE'
              AND d.recovery_model_desc = 'FULL'
        )
        BEGIN
            EXEC sys.sp_releaseapplock @Resource = N'Global_AdaptiveLogBackup_Lock', @LockOwner = N'Session';
            RETURN;
        END

        ----------------------------------------------------------------
        -- 3. ĐỌC DUNG LƯỢNG QUA sys.dm_db_log_space_usage (BẮT LỖI TỪNG DB)
        ----------------------------------------------------------------
        -- Bảng tạm này chỉ dùng để chứa kết quả raw của dynamic query cross-database
        CREATE TABLE #LogMetrics (
            DBName sysname PRIMARY KEY,
            TotalLogMB DECIMAL(18,2),
            UsedLogMB DECIMAL(18,2),
            UsedLogPercent DECIMAL(5,2),
            ErrorMessage NVARCHAR(4000) NULL
        );

        DECLARE @SqlCheck NVARCHAR(MAX) = N'';

        SELECT @SqlCheck = @SqlCheck + N'
        BEGIN TRY
            INSERT INTO #LogMetrics (DBName, TotalLogMB, UsedLogMB, UsedLogPercent, ErrorMessage)
            SELECT 
                ' + QUOTENAME(d.name, '''') + N',
                CAST(total_log_size_in_bytes / 1048576.0 AS DECIMAL(18,2)),
                CAST(used_log_space_in_bytes / 1048576.0 AS DECIMAL(18,2)),
                CAST(used_log_space_in_percent AS DECIMAL(5,2)),
                NULL
            FROM ' + QUOTENAME(d.name) + N'.sys.dm_db_log_space_usage;
        END TRY
        BEGIN CATCH
            INSERT INTO #LogMetrics (DBName, TotalLogMB, UsedLogMB, UsedLogPercent, ErrorMessage)
            VALUES (' + QUOTENAME(d.name, '''') + N', NULL, NULL, NULL, ERROR_MESSAGE());
        END CATCH;'
        FROM sys.databases d
        WHERE d.group_database_id IS NOT NULL
          AND sys.fn_hadr_is_primary_replica(d.name) = 1
          AND d.state_desc = 'ONLINE'
          AND d.recovery_model_desc = 'FULL';

        EXEC sys.sp_executesql @SqlCheck;

        ----------------------------------------------------------------
        -- 4. PIPELINE CTE + OUTPUT: ĐÁNH GIÁ, GHI AUDIT VÀ THU THẬP TARGET DB
        -- (Không qua bảng staging, xử lý hoàn toàn qua Memory Stream)
        ----------------------------------------------------------------
        
        -- Biến bảng siêu nhẹ chỉ chứa duy nhất danh sách DB cần backup (vài byte)
        DECLARE @TargetDatabases TABLE (DBName sysname PRIMARY KEY);

        ;WITH EvaluatedMetrics AS (
            SELECT 
                lm.DBName,
                lm.TotalLogMB,
                lm.UsedLogMB,
                lm.UsedLogPercent,
                DATEDIFF(MINUTE, ISNULL(lb.last_log_backup, '1900-01-01'), GETDATE()) AS MinutesSinceLastBackup,
                d.log_reuse_wait_desc AS LogReuseWait,
                ISNULL(ag_stats.MaxSendQueueMB, 0) AS MaxSendQueueMB,
                ISNULL(ag_stats.MaxRedoQueueMB, 0) AS MaxRedoQueueMB,
                -- Ánh xạ severity sang chuỗi text chính xác
                CASE ag_stats.WorstSyncHealthLevel
                    WHEN 3 THEN N'NOT_HEALTHY'
                    WHEN 2 THEN N'PARTIALLY_HEALTHY'
                    WHEN 1 THEN N'HEALTHY'
                    ELSE N'UNKNOWN'
                END AS WorstSyncHealth,
                -- Phân cấp hành vi (ActionTaken)
                CASE 
                    WHEN lm.ErrorMessage IS NOT NULL THEN 'ERROR'
                    WHEN (
                        DATEDIFF(MINUTE, ISNULL(lb.last_log_backup, '1900-01-01'), GETDATE()) >= @MaxMinutesBetweenLogBackups
                        OR (lm.UsedLogPercent >= @LogPercentThreshold AND lm.UsedLogMB >= @MinUsedLogMBToTrigger)
                    ) THEN 'BACKUP'
                    WHEN (
                        ag_stats.MaxSendQueueMB > @MaxLogSendQueueMBWarning
                        OR ag_stats.MaxRedoQueueMB > @MaxRedoQueueMBWarning
                        OR d.log_reuse_wait_desc = 'AVAILABILITY_REPLICA'
                        OR ag_stats.WorstSyncHealthLevel >= 2
                    ) THEN 'AG_WARNING'
                    ELSE 'SKIP'
                END AS ActionTaken,
                -- Chi tiết nguyên nhân theo thứ tự ưu tiên
                CASE 
                    WHEN lm.ErrorMessage IS NOT NULL THEN N'DMV_QUERY_FAILED'
                    WHEN DATEDIFF(MINUTE, ISNULL(lb.last_log_backup, '1900-01-01'), GETDATE()) >= @MaxMinutesBetweenLogBackups
                     AND lm.UsedLogPercent >= @LogPercentThreshold 
                     AND lm.UsedLogMB >= @MinUsedLogMBToTrigger
                        THEN N'RPO + LOG_PRESSURE'
                    WHEN DATEDIFF(MINUTE, ISNULL(lb.last_log_backup, '1900-01-01'), GETDATE()) >= @MaxMinutesBetweenLogBackups
                        THEN CONCAT(N'RPO_INTERVAL (', DATEDIFF(MINUTE, ISNULL(lb.last_log_backup, '1900-01-01'), GETDATE()), N' mins)')
                    WHEN lm.UsedLogPercent >= @LogPercentThreshold 
                     AND lm.UsedLogMB >= @MinUsedLogMBToTrigger
                        THEN CONCAT(N'LOG_PRESSURE (', lm.UsedLogPercent, N'%, ', CAST(lm.UsedLogMB AS INT), N' MB)')
                    ELSE NULL
                END AS TriggerReason,
                lm.ErrorMessage
            FROM #LogMetrics lm
            JOIN sys.databases d ON lm.DBName = d.name
            OUTER APPLY (
                -- Lấy lần log backup gần nhất trên node Primary hiện tại
                SELECT MAX(bs.backup_finish_date) AS last_log_backup
                FROM msdb.dbo.backupset bs
                WHERE bs.database_name = lm.DBName 
                  AND bs.type = 'L'
                  AND bs.server_name = SERVERPROPERTY('ServerName')
            ) lb
            OUTER APPLY (
                -- Đo lường sức khỏe các Secondary Replicas
                SELECT 
                    MAX(drs.log_send_queue_size) / 1024 AS MaxSendQueueMB,
                    MAX(drs.redo_queue_size) / 1024 AS MaxRedoQueueMB,
                    MAX(
                        CASE drs.synchronization_health_desc
                            WHEN 'NOT_HEALTHY'       THEN 3
                            WHEN 'PARTIALLY_HEALTHY' THEN 2
                            WHEN 'HEALTHY'           THEN 1
                            ELSE 0
                        END
                    ) AS WorstSyncHealthLevel
                FROM sys.dm_hadr_database_replica_states drs
                WHERE drs.database_id = d.database_id
                  AND drs.is_local = 0
            ) ag_stats
        )
        INSERT INTO @TargetDatabases (DBName)
        SELECT DatabaseName
        FROM (
            INSERT INTO dbo.AdaptiveLogBackupLog (
                DatabaseName, TotalLogMB, UsedLogMB, UsedLogPercent,
                MinutesSinceLastBackup, LogReuseWait,
                MaxSendQueueMB, MaxRedoQueueMB, WorstSyncHealth,
                ActionTaken, TriggerReason, ErrorMessage
            )
            OUTPUT 
                inserted.DatabaseName,
                inserted.ActionTaken
            SELECT 
                DBName, TotalLogMB, UsedLogMB, UsedLogPercent,
                MinutesSinceLastBackup, LogReuseWait,
                MaxSendQueueMB, MaxRedoQueueMB, WorstSyncHealth,
                ActionTaken, TriggerReason, ErrorMessage
            FROM EvaluatedMetrics
        ) AS LogOutput
        WHERE ActionTaken = 'BACKUP';

        -- Dọn dẹp log lịch sử cũ
        DELETE FROM dbo.AdaptiveLogBackupLog
        WHERE RunTime < DATEADD(DAY, -@PurgeAuditDays, SYSDATETIME());

        ----------------------------------------------------------------
        -- 5. TẬP HỢP DANH SÁCH VÀ GỌI OLA HALLENGREN (1 COMMAND DUY NHẤT)
        ----------------------------------------------------------------
        DECLARE @DatabaseList NVARCHAR(MAX);

        SELECT @DatabaseList = STRING_AGG(DBName, ',') WITHIN GROUP (ORDER BY DBName)
        FROM @TargetDatabases;

        IF @DatabaseList IS NOT NULL
        BEGIN
            PRINT CONCAT(N'[ADAPTIVE LOG BACKUP] Khoi chay backup cho: ', @DatabaseList);

            EXECUTE [master].[dbo].[DatabaseBackup]
                @Databases          = @DatabaseList,
                @Directory          = @BackupDirectory,
                @BackupType         = 'LOG',
                @Verify             = 'N',
                @Compress           = 'Y',
                @CheckSum           = 'Y',
                @LogToTable         = 'Y';
        END

        DROP TABLE #LogMetrics;

    END TRY
    BEGIN CATCH
        -- Luôn giải phóng lock nếu phát sinh lỗi ngoài ý muốn
        EXEC sys.sp_releaseapplock @Resource = N'Global_AdaptiveLogBackup_Lock', @LockOwner = N'Session';
        THROW;
    END CATCH;

    -- Giải phóng lock khi hoàn thành bình thường
    EXEC sys.sp_releaseapplock @Resource = N'Global_AdaptiveLogBackup_Lock', @LockOwner = N'Session';
END;
GO;
```

- Maintenance Guard
```script
CREATE OR ALTER PROCEDURE dbo.usp_AgMaintenanceGuard
(
    @DatabaseName                   sysname,

    ------------------------------------------------------------------------
    -- STOP thresholds (Chặn đứng thao tác)
    ------------------------------------------------------------------------
    @StopLogUsedPct                 INT          = 90,
    @StopLogVolumeFreeSpacePct      INT          = 10,
    @StopLogVolumeMinFreeMB         BIGINT       = 10240,   -- STOP nếu ổ chứa LDF còn < 10 GB
    @StopLogSendQueueMB             BIGINT       = 10240,   -- 10 GB
    @StopRedoQueueMB                BIGINT       = 20480,   -- 20 GB

    ------------------------------------------------------------------------
    -- WARN thresholds (Cảnh báo / Throttle DOP)
    ------------------------------------------------------------------------
    @WarnLogUsedPct                 INT          = 75,
    @WarnLogVolumeFreeSpacePct      INT          = 20,
    @WarnLogVolumeMinFreeMB         BIGINT       = 20480,   -- 20 GB
    @WarnLogSendQueueMB             BIGINT       = 5120,    -- 5 GB
    @WarnRedoQueueMB                BIGINT       = 10240,   -- 10 GB

    ------------------------------------------------------------------------
    -- Policy
    ------------------------------------------------------------------------
    @RequireSecondaryReplicas       BIT          = 1,

    ------------------------------------------------------------------------
    -- Verdict Outputs
    ------------------------------------------------------------------------
    @OverallVerdict                 VARCHAR(10)  OUTPUT,    -- 'ALLOW', 'WARN', 'STOP'
    @Reason                         NVARCHAR(1000) OUTPUT,  -- Lý do chi tiết

    ------------------------------------------------------------------------
    -- Telemetry Outputs
    ------------------------------------------------------------------------
    @LogUsedPct                     DECIMAL(5,2) OUTPUT,
    @LogUsedMB                      DECIMAL(18,2) OUTPUT,
    @TotalLogMB                     DECIMAL(18,2) OUTPUT,
    @LogFreeMB                      DECIMAL(18,2) OUTPUT,
    @LogReuseWait                   NVARCHAR(60) OUTPUT,
    @MinVolumeFreePct               DECIMAL(5,2) OUTPUT,
    @MinVolumeFreeMB                BIGINT       OUTPUT,
    @MaxSendQueueMB                 BIGINT       OUTPUT,
    @MaxRedoQueueMB                 BIGINT       OUTPUT,
    @WorstSyncState                 NVARCHAR(60) OUTPUT,
    @WorstSyncHealth                NVARCHAR(60) OUTPUT,
    @WorstConnectedState            NVARCHAR(60) OUTPUT,
    @HasSynchronousSecondary        BIT          OUTPUT,
    @WorstSendQueueReplica          sysname      OUTPUT,
    @WorstRedoQueueReplica          sysname      OUTPUT,
    @WorstSuspended                 BIT          OUTPUT,
    @WorstSuspendedReplica          sysname      OUTPUT,
    @SuspendReason                  NVARCHAR(60) OUTPUT
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    ------------------------------------------------------------------------
    -- 0. KHỞI TẠO ĐẦU RA AN TOÀN
    ------------------------------------------------------------------------
    SET @OverallVerdict          = 'STOP';
    SET @Reason                  = N'Guard chưa hoàn tất kiểm tra.';

    SET @LogUsedPct              = NULL;
    SET @LogUsedMB               = NULL;
    SET @TotalLogMB              = NULL;
    SET @LogFreeMB               = NULL;
    SET @LogReuseWait            = NULL;
    SET @MinVolumeFreePct        = NULL;
    SET @MinVolumeFreeMB         = NULL;
    SET @MaxSendQueueMB          = NULL;
    SET @MaxRedoQueueMB          = NULL;
    SET @WorstSyncState          = NULL;
    SET @WorstSyncHealth         = NULL;
    SET @WorstConnectedState     = NULL;
    SET @HasSynchronousSecondary = 0;
    SET @WorstSendQueueReplica   = NULL;
    SET @WorstRedoQueueReplica   = NULL;
    SET @WorstSuspended          = NULL;
    SET @WorstSuspendedReplica   = NULL;
    SET @SuspendReason           = NULL;

    ------------------------------------------------------------------------
    -- 1. XÁC THỰC THAM SỐ ĐẦU VÀO (BAO GỒM CẢ CÁC NGƯỠNG MB)
    ------------------------------------------------------------------------
    IF NULLIF(LTRIM(RTRIM(@DatabaseName)), N'') IS NULL
    BEGIN
        SET @Reason = N'DatabaseName không được NULL hoặc rỗng.';
        GOTO ExitWithResultSet;
    END;

    IF @StopLogUsedPct NOT BETWEEN 1 AND 100 
       OR @WarnLogUsedPct NOT BETWEEN 0 AND 100
       OR @StopLogVolumeFreeSpacePct NOT BETWEEN 0 AND 100 
       OR @WarnLogVolumeFreeSpacePct NOT BETWEEN 0 AND 100
       OR @StopLogVolumeMinFreeMB < 0 
       OR @WarnLogVolumeMinFreeMB < 0
       OR @StopLogSendQueueMB < 0 
       OR @WarnLogSendQueueMB < 0 
       OR @StopRedoQueueMB < 0 
       OR @WarnRedoQueueMB < 0
       OR @WarnLogUsedPct >= @StopLogUsedPct
       OR @WarnLogVolumeFreeSpacePct <= @StopLogVolumeFreeSpacePct
       OR @WarnLogVolumeMinFreeMB <= @StopLogVolumeMinFreeMB
       OR @WarnLogSendQueueMB >= @StopLogSendQueueMB
       OR @WarnRedoQueueMB >= @StopRedoQueueMB
    BEGIN
        SET @Reason = N'Tham số cấu hình ngưỡng không hợp lệ hoặc logic WARN/STOP bị sai (ngưỡng WARN phải nhạy hơn STOP và không âm).';
        GOTO ExitWithResultSet;
    END;

    ------------------------------------------------------------------------
    -- 2. KIỂM TRA DATABASE VÀ VAI TRÒ PRIMARY
    ------------------------------------------------------------------------
    DECLARE @DatabaseId INT, @DatabaseState NVARCHAR(60), @GroupDatabaseId UNIQUEIDENTIFIER;

    SELECT 
        @DatabaseId      = d.database_id,
        @DatabaseState   = d.state_desc,
        @GroupDatabaseId = d.group_database_id,
        @LogReuseWait    = d.log_reuse_wait_desc
    FROM sys.databases AS d
    WHERE d.name = @DatabaseName;

    IF @DatabaseId IS NULL
    BEGIN
        SET @Reason = CONCAT(N'Database [', @DatabaseName, N'] không tồn tại.');
        GOTO ExitWithResultSet;
    END;

    IF @DatabaseState <> N'ONLINE'
    BEGIN
        SET @Reason = CONCAT(N'Database [', @DatabaseName, N'] không ONLINE. State = ', @DatabaseState);
        GOTO ExitWithResultSet;
    END;

    IF @GroupDatabaseId IS NOT NULL
    BEGIN
        IF ISNULL(sys.fn_hadr_is_primary_replica(@DatabaseName), 0) <> 1
        BEGIN
            SET @Reason = CONCAT(N'Instance hiện tại KHÔNG PHẢI là Primary Replica của database [', @DatabaseName, N'].');
            GOTO ExitWithResultSet;
        END;
    END;

    ------------------------------------------------------------------------
    -- 3. TRANSACTION LOG TELEMETRY
    ------------------------------------------------------------------------
    DECLARE @SqlDynamic NVARCHAR(MAX) = N'
        SELECT
            @p_TotalLogMB = CAST(total_log_size_in_bytes / 1048576.0 AS DECIMAL(18,2)),
            @p_LogUsedMB  = CAST(used_log_space_in_bytes / 1048576.0 AS DECIMAL(18,2)),
            @p_LogFreeMB  = CAST((total_log_size_in_bytes - used_log_space_in_bytes) / 1048576.0 AS DECIMAL(18,2)),
            @p_LogUsedPct = CAST(used_log_space_in_percent AS DECIMAL(5,2))
        FROM ' + QUOTENAME(@DatabaseName) + N'.sys.dm_db_log_space_usage;';

    BEGIN TRY
        EXEC sys.sp_executesql
            @SqlDynamic,
            N'@p_TotalLogMB DECIMAL(18,2) OUTPUT, @p_LogUsedMB DECIMAL(18,2) OUTPUT, 
              @p_LogFreeMB DECIMAL(18,2) OUTPUT, @p_LogUsedPct DECIMAL(5,2) OUTPUT',
            @p_TotalLogMB = @TotalLogMB OUTPUT,
            @p_LogUsedMB  = @LogUsedMB OUTPUT,
            @p_LogFreeMB  = @LogFreeMB OUTPUT,
            @p_LogUsedPct = @LogUsedPct OUTPUT;
    END TRY
    BEGIN CATCH
        SET @Reason = CONCAT(N'Lỗi đọc DMV log_space_usage của [', @DatabaseName, N']: ', ERROR_MESSAGE());
        GOTO ExitWithResultSet;
    END CATCH;

    IF @TotalLogMB IS NULL OR @LogUsedMB IS NULL OR @LogUsedPct IS NULL
    BEGIN
        SET @Reason = N'Không lấy được dữ liệu Telemetry của Transaction Log. Chuyển STOP an toàn.';
        GOTO ExitWithResultSet;
    END;

    ------------------------------------------------------------------------
    -- 4. VOLUME CHỨA FILE LDF
    ------------------------------------------------------------------------
    BEGIN TRY
        SELECT 
            @MinVolumeFreePct = MIN(CAST(vs.available_bytes * 100.0 / NULLIF(vs.total_bytes, 0) AS DECIMAL(5,2))),
            @MinVolumeFreeMB  = MIN(vs.available_bytes / 1048576)
        FROM (
            SELECT DISTINCT database_id, file_id 
            FROM sys.master_files 
            WHERE database_id = @DatabaseId AND type_desc = N'LOG'
        ) AS mf
        CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) AS vs;
    END TRY
    BEGIN CATCH
        SET @Reason = CONCAT(N'Không thể kiểm tra dung lượng Volume chứa LDF: ', ERROR_MESSAGE());
        GOTO ExitWithResultSet;
    END CATCH;

    IF @MinVolumeFreePct IS NULL OR @MinVolumeFreeMB IS NULL
    BEGIN
        SET @Reason = N'Không xác định được dung lượng Volume chứa LDF. Chuyển STOP an toàn.';
        GOTO ExitWithResultSet;
    END;

    ------------------------------------------------------------------------
    -- 5. AG TELEMETRY (TẬP TRUNG 1 QUERY, SỬA DỨT ĐIỂM UNKNOWN MAPPING & TIE-BREAKER)
    ------------------------------------------------------------------------
    IF @GroupDatabaseId IS NULL
    BEGIN
        SET @MaxSendQueueMB          = 0;
        SET @MaxRedoQueueMB          = 0;
        SET @WorstSyncState          = N'NOT_IN_AG';
        SET @WorstSyncHealth         = N'NOT_IN_AG';
        SET @WorstConnectedState     = N'NOT_IN_AG';
        SET @HasSynchronousSecondary = 0;
        SET @WorstSuspended          = 0;
        SET @SuspendReason           = N'NOT_IN_AG';
    END
    ELSE
    BEGIN
        ;WITH RemoteReplicas AS (
            SELECT 
                ar.replica_server_name,
                CAST(drs.log_send_queue_size / 1024.0 AS BIGINT) AS SendQueueMB,
                CAST(drs.redo_queue_size / 1024.0 AS BIGINT) AS RedoQueueMB,
                drs.connected_state_desc,
                drs.synchronization_state_desc,
                drs.synchronization_health_desc,
                ar.availability_mode_desc,
                drs.is_suspended,
                drs.suspend_reason_desc,
                -- Tie-breaker: Thêm tên replica để ổn định tuyệt đối
                ROW_NUMBER() OVER (ORDER BY drs.log_send_queue_size DESC, ar.replica_server_name ASC) AS RankSendQ,
                ROW_NUMBER() OVER (ORDER BY drs.redo_queue_size DESC, ar.replica_server_name ASC) AS RankRedoQ,
                ROW_NUMBER() OVER (ORDER BY drs.is_suspended DESC, drs.suspend_reason DESC, ar.replica_server_name ASC) AS RankSuspend
            FROM sys.dm_hadr_database_replica_states drs
            INNER JOIN sys.availability_replicas ar ON ar.replica_id = drs.replica_id
            WHERE drs.database_id = @DatabaseId 
              AND drs.is_local = 0
        )
        SELECT 
            @MaxSendQueueMB = MAX(SendQueueMB),
            @MaxRedoQueueMB = MAX(RedoQueueMB),
            
            -- Sửa bug: Không dùng ELSE 1. Trạng thái không nhận diện được/NULL bắt buộc là UNKNOWN
            @WorstConnectedState = CASE MAX(CASE connected_state_desc 
                                                WHEN N'DISCONNECTED' THEN 3 
                                                WHEN N'UNKNOWN'      THEN 2 
                                                WHEN N'CONNECTED'    THEN 1 
                                                ELSE 0 END)
                                        WHEN 3 THEN N'DISCONNECTED' 
                                        WHEN 2 THEN N'UNKNOWN' 
                                        WHEN 1 THEN N'CONNECTED' 
                                        ELSE N'UNKNOWN' END,

            @WorstSyncState = CASE MAX(CASE synchronization_state_desc 
                                            WHEN N'NOT SYNCHRONIZING' THEN 3 
                                            WHEN N'SYNCHRONIZING'     THEN 2 
                                            WHEN N'SYNCHRONIZED'      THEN 1 
                                            ELSE 0 END)
                                   WHEN 3 THEN N'NOT SYNCHRONIZING' 
                                   WHEN 2 THEN N'SYNCHRONIZING' 
                                   WHEN 1 THEN N'SYNCHRONIZED' 
                                   ELSE N'UNKNOWN' END,

            @WorstSyncHealth = CASE MAX(CASE synchronization_health_desc 
                                             WHEN N'NOT_HEALTHY'       THEN 3 
                                             WHEN N'PARTIALLY_HEALTHY' THEN 2 
                                             WHEN N'HEALTHY'           THEN 1 
                                             ELSE 0 END)
                                    WHEN 3 THEN N'NOT_HEALTHY' 
                                    WHEN 2 THEN N'PARTIALLY_HEALTHY' 
                                    WHEN 1 THEN N'HEALTHY' 
                                    ELSE N'UNKNOWN' END,

            @HasSynchronousSecondary = ISNULL(MAX(CASE WHEN availability_mode_desc = N'SYNCHRONOUS_COMMIT' THEN 1 ELSE 0 END), 0),
            @WorstSuspended = ISNULL(MAX(CAST(is_suspended AS INT)), 0),
            @WorstSendQueueReplica = MAX(CASE WHEN RankSendQ = 1 THEN replica_server_name END),
            @WorstRedoQueueReplica = MAX(CASE WHEN RankRedoQ = 1 THEN replica_server_name END),
            @WorstSuspendedReplica = MAX(CASE WHEN RankSuspend = 1 AND is_suspended = 1 THEN replica_server_name END),
            @SuspendReason = MAX(CASE WHEN RankSuspend = 1 AND is_suspended = 1 THEN suspend_reason_desc END)
        FROM RemoteReplicas;

        -- Kiểm tra policy: Bắt buộc phải có ít nhất một Secondary hợp lệ
        IF @RequireSecondaryReplicas = 1
        BEGIN
            IF @WorstConnectedState IS NULL
            BEGIN
                SET @OverallVerdict = 'STOP';
                SET @Reason = N'Không phát hiện thấy bản ghi Secondary Replica nào trong DMV AG.';
                GOTO ExitWithResultSet;
            END;
            IF @WorstConnectedState = N'UNKNOWN'
            BEGIN
                SET @OverallVerdict = 'STOP';
                SET @Reason = N'Không thể xác định trạng thái kết nối của Secondary Replica (Trạng thái UNKNOWN).';
                GOTO ExitWithResultSet;
            END;
        END;
    END;

    ------------------------------------------------------------------------
    -- 6. VERDICT ENGINE TẬP TRUNG (SẮP XẾP ƯU TIÊN NGUYÊN NHÂN RÕ RÀNG)
    ------------------------------------------------------------------------
    DECLARE @StopReason NVARCHAR(MAX) = N'', @WarnReason NVARCHAR(MAX) = N'';

    -- 6.1. STOP CONDITIONS (Ưu tiên: Kết nối -> Suspend -> Sync -> Volume -> Log -> Queues)
    IF @GroupDatabaseId IS NOT NULL
    BEGIN
        IF @WorstConnectedState IN (N'DISCONNECTED', N'UNKNOWN')
            SET @StopReason += CONCAT(N'Secondary [', @WorstConnectedState, N']; ');

        -- Policy: Khi Rebuild Index lớn, Secondary bị SUSPENDED bắt buộc phải STOP để tránh giữ Log LSN
        IF @WorstSuspended = 1
            SET @StopReason += CONCAT(N'Secondary SUSPENDED [Node: ', @WorstSuspendedReplica, 
                                      N', Lý do: ', ISNULL(@SuspendReason, N'Không rõ'), N']; ');

        IF @WorstSyncState = N'NOT SYNCHRONIZING'
            SET @StopReason += N'Secondary NOT SYNCHRONIZING; ';
    END;

    IF @MinVolumeFreePct <= @StopLogVolumeFreeSpacePct OR @MinVolumeFreeMB <= @StopLogVolumeMinFreeMB
        SET @StopReason += CONCAT(N'Volume chứa LDF sắp hết: Còn ', @MinVolumeFreePct, N'% (', @MinVolumeFreeMB, N' MB); ');

    IF @LogUsedPct >= @StopLogUsedPct
        SET @StopReason += CONCAT(N'File LDF đầy ', @LogUsedPct, N'% >= STOP ', @StopLogUsedPct, N'%; ');

    IF @GroupDatabaseId IS NOT NULL
    BEGIN
        IF @MaxSendQueueMB >= @StopLogSendQueueMB
            SET @StopReason += CONCAT(N'Send Queue ', @MaxSendQueueMB, N' MB >= STOP ', @StopLogSendQueueMB, N' MB [Node: ', @WorstSendQueueReplica, N']; ');
        IF @MaxRedoQueueMB >= @StopRedoQueueMB
            SET @StopReason += CONCAT(N'Redo Queue ', @MaxRedoQueueMB, N' MB >= STOP ', @StopRedoQueueMB, N' MB [Node: ', @WorstRedoQueueReplica, N']; ');
    END;

    -- 6.2. WARN CONDITIONS (Chỉ đánh giá nếu không dính STOP)
    IF LEN(@StopReason) = 0
    BEGIN
        IF @GroupDatabaseId IS NOT NULL
        BEGIN
            IF @WorstSyncHealth IN (N'NOT_HEALTHY', N'PARTIALLY_HEALTHY')
                SET @WarnReason += CONCAT(N'Sync Health = ', @WorstSyncHealth, N'; ');
            IF @WorstSyncState = N'SYNCHRONIZING'
                SET @WarnReason += N'Secondary đang SYNCHRONIZING; ';
            IF @MaxSendQueueMB >= @WarnLogSendQueueMB
                SET @WarnReason += CONCAT(N'Send Queue cảnh báo: ', @MaxSendQueueMB, N' MB [Node: ', @WorstSendQueueReplica, N']; ');
            IF @MaxRedoQueueMB >= @WarnRedoQueueMB
                SET @WarnReason += CONCAT(N'Redo Queue cảnh báo: ', @MaxRedoQueueMB, N' MB [Node: ', @WorstRedoQueueReplica, N']; ');
        END;

        IF @LogReuseWait = N'AVAILABILITY_REPLICA'
            SET @WarnReason += N'Log truncation đang bị giữ bởi AVAILABILITY_REPLICA; ';

        IF @MinVolumeFreePct <= @WarnLogVolumeFreeSpacePct OR @MinVolumeFreeMB <= @WarnLogVolumeMinFreeMB
            SET @WarnReason += CONCAT(N'Volume LDF ở mức cảnh báo: Còn ', @MinVolumeFreePct, N'% (', @MinVolumeFreeMB, N' MB); ');

        IF @LogUsedPct >= @WarnLogUsedPct
            SET @WarnReason += CONCAT(N'Log Used ở mức cảnh báo: ', @LogUsedPct, N'%; ');
    END;

    ------------------------------------------------------------------------
    -- 7. CHỐT VERDICT CUỐI CÙNG
    ------------------------------------------------------------------------
    IF LEN(@StopReason) > 0
    BEGIN
        SET @OverallVerdict = 'STOP';
        SET @Reason = LEFT(N'STOP: ' + @StopReason, 1000);
    END
    ELSE IF LEN(@WarnReason) > 0
    BEGIN
        SET @OverallVerdict = 'WARN';
        SET @Reason = LEFT(N'WARN: ' + @WarnReason, 1000);
    END
    ELSE
    BEGIN
        SET @OverallVerdict = 'ALLOW';
        SET @Reason = N'AG Replicas, dung lượng Transaction Log và Volume lưu trữ hoàn toàn an toàn. Đủ điều kiện bảo trì.';
    END;

    ------------------------------------------------------------------------
    -- 8. XUẤT THÔNG TIN: PRINT (JOB LOG) + RESULT SET (AUTOMATION CONTROLLER)
    ------------------------------------------------------------------------
    PRINT CONCAT(N'[AG MAINTENANCE GUARD] DB: ', @DatabaseName, 
                 N' | Verdict: ', @OverallVerdict, 
                 N' | LogUsed: ', @LogUsedPct, N'% (', CAST(@LogUsedMB AS INT), N' MB / ', CAST(@TotalLogMB AS INT), N' MB)',
                 N' | FreeVol: ', @MinVolumeFreePct, N'% (', @MinVolumeFreeMB, N' MB)',
                 N' | SendQ: ', @MaxSendQueueMB, N' MB (Worst: ', ISNULL(@WorstSendQueueReplica, N'-'), N')',
                 N' | RedoQ: ', @MaxRedoQueueMB, N' MB (Worst: ', ISNULL(@WorstRedoQueueReplica, N'-'), N')',
                 N' | Sync: ', ISNULL(@WorstSyncState, N'-'), N' (Health: ', ISNULL(@WorstSyncHealth, N'-'), N')',
                 N' | Suspended: ', ISNULL(CAST(@WorstSuspended AS VARCHAR(5)), N'-'),
                 N' | Reason: ', @Reason);

ExitWithResultSet:
    SELECT
        @OverallVerdict          AS Verdict,
        @Reason                  AS Reason,
        @DatabaseName            AS DatabaseName,
        @LogUsedPct              AS LogUsedPct,
        @LogUsedMB               AS LogUsedMB,
        @TotalLogMB              AS TotalLogMB,
        @LogFreeMB               AS LogFreeMB,
        @LogReuseWait            AS LogReuseWait,
        @MinVolumeFreePct        AS VolumeFreePct,
        @MinVolumeFreeMB         AS VolumeFreeMB,
        @MaxSendQueueMB          AS MaxSendQueueMB,
        @MaxRedoQueueMB          AS MaxRedoQueueMB,
        @WorstSendQueueReplica   AS WorstSendQueueReplica,
        @WorstRedoQueueReplica   AS WorstRedoQueueReplica,
        @WorstSyncState          AS WorstSyncState,
        @WorstSyncHealth         AS WorstSyncHealth,
        @WorstConnectedState     AS WorstConnectedState,
        @HasSynchronousSecondary AS HasSynchronousSecondary,
        @WorstSuspended          AS WorstSuspended,
        @WorstSuspendedReplica   AS WorstSuspendedReplica,
        @SuspendReason           AS SuspendReason;
END;
GO
```

- View AG GUARD
```script
CREATE OR ALTER PROCEDURE dbo.usp_AgMaintenanceGuard
(
    @DatabaseName                   sysname,

    ------------------------------------------------------------------------
    -- STOP thresholds
    ------------------------------------------------------------------------
    @StopLogUsedPct                 INT          = 90,
    @StopLogVolumeFreeSpacePct      INT          = 10,
    @StopLogVolumeMinFreeMB         BIGINT       = 10240,   -- 10 GB
    @StopLogSendQueueMB             BIGINT       = 10240,   -- 10 GB
    @StopRedoQueueMB                BIGINT       = 20480,   -- 20 GB

    ------------------------------------------------------------------------
    -- WARN thresholds
    ------------------------------------------------------------------------
    @WarnLogUsedPct                 INT          = 75,
    @WarnLogVolumeFreeSpacePct      INT          = 20,
    @WarnLogVolumeMinFreeMB         BIGINT       = 20480,   -- 20 GB
    @WarnLogSendQueueMB             BIGINT       = 5120,    -- 5 GB
    @WarnRedoQueueMB                BIGINT       = 10240,   -- 10 GB

    ------------------------------------------------------------------------
    -- Policy
    ------------------------------------------------------------------------
    @RequireSecondaryReplicas       BIT          = 1,

    ------------------------------------------------------------------------
    -- CIRCUIT BREAKER OUTPUT
    ------------------------------------------------------------------------
    @OverallVerdict                 VARCHAR(10)  OUTPUT,    -- ALLOW/WARN/STOP
    @Reason                         NVARCHAR(1000) OUTPUT
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    ------------------------------------------------------------------------
    -- 0. SAFE INITIALIZATION
    ------------------------------------------------------------------------
    SET @OverallVerdict = 'STOP';
    SET @Reason         = N'Guard chưa hoàn tất kiểm tra.';

    ------------------------------------------------------------------------
    -- INTERNAL TELEMETRY
    ------------------------------------------------------------------------
    DECLARE
        @DatabaseId                 INT,
        @DatabaseState              NVARCHAR(60),
        @GroupDatabaseId            UNIQUEIDENTIFIER,

        @LogUsedPct                 DECIMAL(5,2),
        @LogUsedMB                  DECIMAL(18,2),
        @TotalLogMB                 DECIMAL(18,2),
        @LogFreeMB                  DECIMAL(18,2),
        @LogReuseWait               NVARCHAR(60),

        @MinVolumeFreePct           DECIMAL(5,2),
        @MinVolumeFreeMB            BIGINT,

        @MaxSendQueueMB             BIGINT,
        @MaxRedoQueueMB             BIGINT,

        @WorstSyncState             NVARCHAR(60),
        @WorstSyncHealth            NVARCHAR(60),
        @WorstConnectedState        NVARCHAR(60),

        @HasSynchronousSecondary    BIT,

        @WorstSendQueueReplica      sysname,
        @WorstRedoQueueReplica      sysname,

        @WorstSuspended             BIT,
        @WorstSuspendedReplica      sysname,
        @SuspendReason              NVARCHAR(60),

        @SqlDynamic                 NVARCHAR(MAX),

        @StopReason                 NVARCHAR(MAX) = N'',
        @WarnReason                 NVARCHAR(MAX) = N'',

        -- Biến phụ dùng để log qua RAISERROR (tránh lỗi hàm/biểu thức bên trong RAISERROR)
        @PrintMaxSendQueueMB        BIGINT,
        @PrintMaxRedoQueueMB        BIGINT,
        @PrintWorstSyncState        NVARCHAR(60),
        @PrintWorstConnectedState   NVARCHAR(60),
        @PrintWorstSuspended        INT;

    ------------------------------------------------------------------------
    -- 1. VALIDATE INPUT
    ------------------------------------------------------------------------
    IF NULLIF(LTRIM(RTRIM(@DatabaseName)), N'') IS NULL
    BEGIN
        SET @Reason = N'DatabaseName không được NULL hoặc rỗng.';
        GOTO ExitGuard;
    END;

    IF @StopLogUsedPct NOT BETWEEN 1 AND 100
       OR @WarnLogUsedPct NOT BETWEEN 0 AND 100
       OR @StopLogVolumeFreeSpacePct NOT BETWEEN 0 AND 100
       OR @WarnLogVolumeFreeSpacePct NOT BETWEEN 0 AND 100
       OR @StopLogVolumeMinFreeMB < 0
       OR @WarnLogVolumeMinFreeMB < 0
       OR @StopLogSendQueueMB < 0
       OR @WarnLogSendQueueMB < 0
       OR @StopRedoQueueMB < 0
       OR @WarnRedoQueueMB < 0
       OR @WarnLogUsedPct >= @StopLogUsedPct
       OR @WarnLogVolumeFreeSpacePct <= @StopLogVolumeFreeSpacePct
       OR @WarnLogVolumeMinFreeMB <= @StopLogVolumeMinFreeMB
       OR @WarnLogSendQueueMB >= @StopLogSendQueueMB
       OR @WarnRedoQueueMB >= @StopRedoQueueMB
    BEGIN
        SET @Reason =
            N'Tham số cấu hình ngưỡng không hợp lệ hoặc logic WARN/STOP bị sai.';
        GOTO ExitGuard;
    END;

    ------------------------------------------------------------------------
    -- 2. DATABASE / PRIMARY VALIDATION
    ------------------------------------------------------------------------
    SELECT
        @DatabaseId      = d.database_id,
        @DatabaseState   = d.state_desc,
        @GroupDatabaseId = d.group_database_id,
        @LogReuseWait    = d.log_reuse_wait_desc
    FROM sys.databases AS d
    WHERE d.name = @DatabaseName;

    IF @DatabaseId IS NULL
    BEGIN
        SET @Reason =
            CONCAT(N'Database [', @DatabaseName, N'] không tồn tại.');
        GOTO ExitGuard;
    END;

    IF @DatabaseState <> N'ONLINE'
    BEGIN
        SET @Reason =
            CONCAT(
                N'Database [', @DatabaseName,
                N'] không ONLINE. State = ', @DatabaseState
            );
        GOTO ExitGuard;
    END;

    ------------------------------------------------------------------------
    -- Nếu DB thuộc AG thì chỉ Primary mới được phép chạy maintenance.
    ------------------------------------------------------------------------
    IF @GroupDatabaseId IS NOT NULL
    BEGIN
        IF ISNULL(sys.fn_hadr_is_primary_replica(@DatabaseName), 0) <> 1
        BEGIN
            SET @Reason =
                CONCAT(
                    N'Instance hiện tại KHÔNG PHẢI Primary Replica của database [',
                    @DatabaseName, N'].'
                );
            GOTO ExitGuard;
        END;
    END;

    ------------------------------------------------------------------------
    -- 3. TRANSACTION LOG TELEMETRY
    ------------------------------------------------------------------------
    SET @SqlDynamic = N'
        SELECT
            @p_TotalLogMB =
                CAST(total_log_size_in_bytes / 1048576.0 AS DECIMAL(18,2)),

            @p_LogUsedMB =
                CAST(used_log_space_in_bytes / 1048576.0 AS DECIMAL(18,2)),

            @p_LogFreeMB =
                CAST(
                    (total_log_size_in_bytes - used_log_space_in_bytes)
                    / 1048576.0
                    AS DECIMAL(18,2)
                ),

            @p_LogUsedPct =
                CAST(
                    used_log_space_in_percent
                    AS DECIMAL(5,2)
                )
        FROM ' + QUOTENAME(@DatabaseName) + N'.sys.dm_db_log_space_usage;';

    BEGIN TRY
        EXEC sys.sp_executesql
            @SqlDynamic,
            N'
                @p_TotalLogMB DECIMAL(18,2) OUTPUT,
                @p_LogUsedMB  DECIMAL(18,2) OUTPUT,
                @p_LogFreeMB  DECIMAL(18,2) OUTPUT,
                @p_LogUsedPct DECIMAL(5,2) OUTPUT
            ',
            @p_TotalLogMB = @TotalLogMB OUTPUT,
            @p_LogUsedMB  = @LogUsedMB  OUTPUT,
            @p_LogFreeMB  = @LogFreeMB  OUTPUT,
            @p_LogUsedPct = @LogUsedPct OUTPUT;
    END TRY
    BEGIN CATCH
        SET @Reason =
            CONCAT(
                N'Lỗi đọc Transaction Log của [',
                @DatabaseName,
                N']: ',
                ERROR_MESSAGE()
            );
        GOTO ExitGuard;
    END CATCH;

    ------------------------------------------------------------------------
    -- Fail-safe: Kiểm tra dữ liệu log
    ------------------------------------------------------------------------
    IF @TotalLogMB IS NULL
       OR @LogUsedMB IS NULL
       OR @LogFreeMB IS NULL
       OR @LogUsedPct IS NULL
    BEGIN
        SET @Reason =
            N'Không lấy được đầy đủ telemetry Transaction Log. Chuyển STOP an toàn.';
        GOTO ExitGuard;
    END;

    ------------------------------------------------------------------------
    -- 4. VOLUME CHỨA LDF
    ------------------------------------------------------------------------
    BEGIN TRY
        SELECT
            @MinVolumeFreePct =
                MIN(
                    CAST(
                        vs.available_bytes * 100.0
                        / NULLIF(vs.total_bytes, 0)
                        AS DECIMAL(5,2)
                    )
                ),

            @MinVolumeFreeMB =
                MIN(vs.available_bytes / 1048576)
        FROM
        (
            SELECT DISTINCT
                database_id,
                file_id
            FROM sys.master_files
            WHERE database_id = @DatabaseId
              AND type_desc = N'LOG'
        ) AS mf
        CROSS APPLY sys.dm_os_volume_stats(
            mf.database_id,
            mf.file_id
        ) AS vs;
    END TRY
    BEGIN CATCH
        SET @Reason =
            CONCAT(
                N'Không thể kiểm tra Volume chứa LDF: ',
                ERROR_MESSAGE()
            );
        GOTO ExitGuard;
    END CATCH;

    ------------------------------------------------------------------------
    -- Fail-safe: Kiểm tra volume
    ------------------------------------------------------------------------
    IF @MinVolumeFreePct IS NULL
       OR @MinVolumeFreeMB IS NULL
    BEGIN
        SET @Reason =
            N'Không xác định được dung lượng Volume chứa LDF. Chuyển STOP an toàn.';
        GOTO ExitGuard;
    END;

    ------------------------------------------------------------------------
    -- 5. AG TELEMETRY
    ------------------------------------------------------------------------
    IF @GroupDatabaseId IS NULL
    BEGIN
        SET @MaxSendQueueMB          = 0;
        SET @MaxRedoQueueMB          = 0;
        SET @WorstSyncState          = N'NOT_IN_AG';
        SET @WorstSyncHealth         = N'NOT_IN_AG';
        SET @WorstConnectedState     = N'NOT_IN_AG';
        SET @HasSynchronousSecondary = 0;
        SET @WorstSuspended          = 0;
        SET @SuspendReason           = N'NOT_IN_AG';
    END
    ELSE
    BEGIN
        ;WITH RemoteReplicas AS
        (
            SELECT
                ar.replica_server_name,

                CAST(
                    drs.log_send_queue_size / 1024.0
                    AS BIGINT
                ) AS SendQueueMB,

                CAST(
                    drs.redo_queue_size / 1024.0
                    AS BIGINT
                ) AS RedoQueueMB,

                ars.connected_state_desc,

                drs.synchronization_state_desc,
                drs.synchronization_health_desc,

                ar.availability_mode_desc,

                drs.is_suspended,
                drs.suspend_reason_desc,

                ROW_NUMBER() OVER
                (
                    ORDER BY
                        drs.log_send_queue_size DESC,
                        ar.replica_server_name ASC
                ) AS RankSendQ,

                ROW_NUMBER() OVER
                (
                    ORDER BY
                        drs.redo_queue_size DESC,
                        ar.replica_server_name ASC
                ) AS RankRedoQ,

                ROW_NUMBER() OVER
                (
                    ORDER BY
                        drs.is_suspended DESC,
                        drs.suspend_reason DESC,
                        ar.replica_server_name ASC
                ) AS RankSuspend

            FROM sys.dm_hadr_database_replica_states AS drs

            INNER JOIN sys.availability_replicas AS ar
                ON ar.replica_id = drs.replica_id

            LEFT JOIN sys.dm_hadr_availability_replica_states AS ars
                ON ars.replica_id = drs.replica_id

            WHERE drs.database_id = @DatabaseId
              AND drs.is_local = 0
        )
        SELECT
            @MaxSendQueueMB =
                MAX(SendQueueMB),

            @MaxRedoQueueMB =
                MAX(RedoQueueMB),

            @WorstConnectedState =
                CASE MAX(
                    CASE connected_state_desc
                        WHEN N'DISCONNECTED' THEN 3
                        WHEN N'UNKNOWN'      THEN 2
                        WHEN N'CONNECTED'    THEN 1
                        ELSE 0
                    END
                )
                    WHEN 3 THEN N'DISCONNECTED'
                    WHEN 2 THEN N'UNKNOWN'
                    WHEN 1 THEN N'CONNECTED'
                    ELSE N'UNKNOWN'
                END,

            @WorstSyncState =
                CASE MAX(
                    CASE synchronization_state_desc
                        WHEN N'NOT SYNCHRONIZING' THEN 3
                        WHEN N'SYNCHRONIZING'     THEN 2
                        WHEN N'SYNCHRONIZED'      THEN 1
                        ELSE 0
                    END
                )
                    WHEN 3 THEN N'NOT SYNCHRONIZING'
                    WHEN 2 THEN N'SYNCHRONIZING'
                    WHEN 1 THEN N'SYNCHRONIZED'
                    ELSE N'UNKNOWN'
                END,

            @WorstSyncHealth =
                CASE MAX(
                    CASE synchronization_health_desc
                        WHEN N'NOT_HEALTHY'       THEN 3
                        WHEN N'PARTIALLY_HEALTHY' THEN 2
                        WHEN N'HEALTHY'           THEN 1
                        ELSE 0
                    END
                )
                    WHEN 3 THEN N'NOT_HEALTHY'
                    WHEN 2 THEN N'PARTIALLY_HEALTHY'
                    WHEN 1 THEN N'HEALTHY'
                    ELSE N'UNKNOWN'
                END,

            @HasSynchronousSecondary =
                ISNULL(
                    MAX(
                        CASE
                            WHEN availability_mode_desc =
                                 N'SYNCHRONOUS_COMMIT'
                            THEN 1
                            ELSE 0
                        END
                    ),
                    0
                ),

            @WorstSuspended =
                ISNULL(
                    MAX(CAST(is_suspended AS INT)),
                    0
                ),

            @WorstSendQueueReplica =
                MAX(
                    CASE
                        WHEN RankSendQ = 1
                        THEN replica_server_name
                    END
                ),

            @WorstRedoQueueReplica =
                MAX(
                    CASE
                        WHEN RankRedoQ = 1
                        THEN replica_server_name
                    END
                ),

            @WorstSuspendedReplica =
                MAX(
                    CASE
                        WHEN RankSuspend = 1
                         AND is_suspended = 1
                        THEN replica_server_name
                    END
                ),

            @SuspendReason =
                MAX(
                    CASE
                        WHEN RankSuspend = 1
                         AND is_suspended = 1
                        THEN suspend_reason_desc
                    END
                )

        FROM RemoteReplicas;

        --------------------------------------------------------------------
        -- POLICY: Phải có Secondary hợp lệ.
        ------------------------------------------------------------------------
        IF @RequireSecondaryReplicas = 1
        BEGIN
            IF @WorstConnectedState IS NULL
            BEGIN
                SET @Reason =
                    N'Không phát hiện Secondary Replica trong DMV AG.';
                GOTO ExitGuard;
            END;

            IF @WorstConnectedState = N'UNKNOWN'
            BEGIN
                SET @Reason =
                    N'Không thể xác định trạng thái kết nối của Secondary Replica.';
                GOTO ExitGuard;
            END;
        END;
    END;

    ------------------------------------------------------------------------
    -- 6. VERDICT ENGINE
    ------------------------------------------------------------------------

    ------------------------------------------------------------------------
    -- 6.1 STOP CONDITIONS
    ------------------------------------------------------------------------
    IF @GroupDatabaseId IS NOT NULL
    BEGIN
        IF @WorstConnectedState IN
           (N'DISCONNECTED', N'UNKNOWN')
        BEGIN
            SET @StopReason +=
                CONCAT(
                    N'Secondary [',
                    @WorstConnectedState,
                    N']; '
                );
        END;

        IF @WorstSuspended = 1
        BEGIN
            SET @StopReason +=
                CONCAT(
                    N'Secondary SUSPENDED [Node: ',
                    @WorstSuspendedReplica,
                    N', Lý do: ',
                    ISNULL(@SuspendReason, N'Không rõ'),
                    N']; '
                );
        END;

        IF @WorstSyncState = N'NOT SYNCHRONIZING'
        BEGIN
            SET @StopReason +=
                N'Secondary NOT SYNCHRONIZING; ';
        END;
    END;

    IF @MinVolumeFreePct <= @StopLogVolumeFreeSpacePct
       OR @MinVolumeFreeMB <= @StopLogVolumeMinFreeMB
    BEGIN
        SET @StopReason +=
            CONCAT(
                N'Volume chứa LDF sắp hết: Còn ',
                @MinVolumeFreePct,
                N'% (',
                @MinVolumeFreeMB,
                N' MB); '
            );
    END;

    IF @LogUsedPct >= @StopLogUsedPct
    BEGIN
        SET @StopReason +=
            CONCAT(
                N'File LDF đầy ',
                @LogUsedPct,
                N'% >= STOP ',
                @StopLogUsedPct,
                N'%; '
            );
    END;

    IF @GroupDatabaseId IS NOT NULL
    BEGIN
        IF @MaxSendQueueMB >= @StopLogSendQueueMB
        BEGIN
            SET @StopReason +=
                CONCAT(
                    N'Send Queue ',
                    @MaxSendQueueMB,
                    N' MB >= STOP ',
                    @StopLogSendQueueMB,
                    N' MB [Node: ',
                    @WorstSendQueueReplica,
                    N']; '
                );
        END;

        IF @MaxRedoQueueMB >= @StopRedoQueueMB
        BEGIN
            SET @StopReason +=
                CONCAT(
                    N'Redo Queue ',
                    @MaxRedoQueueMB,
                    N' MB >= STOP ',
                    @StopRedoQueueMB,
                    N' MB [Node: ',
                    @WorstRedoQueueReplica,
                    N']; '
                );
        END;
    END;

    ------------------------------------------------------------------------
    -- 6.2 WARN CONDITIONS
    ------------------------------------------------------------------------
    IF LEN(@StopReason) = 0
    BEGIN
        IF @GroupDatabaseId IS NOT NULL
        BEGIN
            IF @WorstSyncHealth IN
               (N'NOT_HEALTHY', N'PARTIALLY_HEALTHY')
            BEGIN
                SET @WarnReason +=
                    CONCAT(
                        N'Sync Health = ',
                        @WorstSyncHealth,
                        N'; '
                    );
            END;

            IF @WorstSyncState = N'SYNCHRONIZING'
            BEGIN
                SET @WarnReason +=
                    N'Secondary đang SYNCHRONIZING; ';
            END;

            IF @MaxSendQueueMB >= @WarnLogSendQueueMB
            BEGIN
                SET @WarnReason +=
                    CONCAT(
                        N'Send Queue cảnh báo: ',
                        @MaxSendQueueMB,
                        N' MB [Node: ',
                        @WorstSendQueueReplica,
                        N']; '
                    );
            END;

            IF @MaxRedoQueueMB >= @WarnRedoQueueMB
            BEGIN
                SET @WarnReason +=
                    CONCAT(
                        N'Redo Queue cảnh báo: ',
                        @MaxRedoQueueMB,
                        N' MB [Node: ',
                        @WorstRedoQueueReplica,
                        N']; '
                    );
            END;
        END;

        IF @LogReuseWait = N'AVAILABILITY_REPLICA'
        BEGIN
            SET @WarnReason +=
                N'Log truncation đang bị giữ bởi AVAILABILITY_REPLICA; ';
        END;

        IF @MinVolumeFreePct <= @WarnLogVolumeFreeSpacePct
           OR @MinVolumeFreeMB <= @WarnLogVolumeMinFreeMB
        BEGIN
            SET @WarnReason +=
                CONCAT(
                    N'Volume LDF ở mức cảnh báo: Còn ',
                    @MinVolumeFreePct,
                    N'% (',
                    @MinVolumeFreeMB,
                    N' MB); '
                );
        END;

        IF @LogUsedPct >= @WarnLogUsedPct
        BEGIN
            SET @WarnReason +=
                CONCAT(
                    N'Log Used ở mức cảnh báo: ',
                    @LogUsedPct,
                    N'%; '
                );
        END;
    END;

    ------------------------------------------------------------------------
    -- 7. FINAL VERDICT
    ------------------------------------------------------------------------
    IF LEN(@StopReason) > 0
    BEGIN
        SET @OverallVerdict = 'STOP';

        SET @Reason =
            LEFT(
                N'STOP: ' + @StopReason,
                1000
            );
    END
    ELSE IF LEN(@WarnReason) > 0
    BEGIN
        SET @OverallVerdict = 'WARN';

        SET @Reason =
            LEFT(
                N'WARN: ' + @WarnReason,
                1000
            );
    END
    ELSE
    BEGIN
        SET @OverallVerdict = 'ALLOW';

        SET @Reason =
            N'AG Replicas, Transaction Log và Volume lưu trữ an toàn. Đủ điều kiện bảo trì.';
    END;

    ------------------------------------------------------------------------
    -- 8. CIRCUIT BREAKER LOG
    ------------------------------------------------------------------------
    DECLARE
        @StrLogUsedPct              NVARCHAR(20) = FORMAT(@LogUsedPct, 'N2'),
        @StrLogFreeMB               NVARCHAR(30) = FORMAT(@LogFreeMB, 'N2'),
        @StrMinVolumeFreePct        NVARCHAR(20) = FORMAT(@MinVolumeFreePct, 'N2');

    -- Gán trước vào biến đơn để an toàn cú pháp cho RAISERROR
    SET @PrintMaxSendQueueMB      = ISNULL(@MaxSendQueueMB, 0);
    SET @PrintMaxRedoQueueMB      = ISNULL(@MaxRedoQueueMB, 0);
    SET @PrintWorstSyncState      = ISNULL(@WorstSyncState, N'-');
    SET @PrintWorstConnectedState = ISNULL(@WorstConnectedState, N'-');
    SET @PrintWorstSuspended      = ISNULL(@WorstSuspended, 0);

    -- Dùng %s cho các biến số thập phân đã chuyển thành chuỗi
    RAISERROR(
        N'[AG MAINTENANCE GUARD] DB: %s | Verdict: %s | LogUsed: %s%% | LogFree: %s MB | VolumeFree: %s%% (%I64d MB) | SendQ: %I64d MB | RedoQ: %I64d MB | Sync: %s | Connected: %s | Suspended: %d | Reason: %s',
        10,
        1,
        @DatabaseName,
        @OverallVerdict,
        @StrLogUsedPct,          -- Đã đổi sang %s
        @StrLogFreeMB,           -- Đã đổi sang %s
        @StrMinVolumeFreePct,    -- Đã đổi sang %s
        @MinVolumeFreeMB,
        @PrintMaxSendQueueMB,
        @PrintMaxRedoQueueMB,
        @PrintWorstSyncState,
        @PrintWorstConnectedState,
        @PrintWorstSuspended,
        @Reason
    ) WITH NOWAIT;

    RETURN;

    ------------------------------------------------------------------------
    -- FAIL-SAFE EXIT
    ------------------------------------------------------------------------
ExitGuard:

    RAISERROR(
        N'[AG MAINTENANCE GUARD] DB: %s | Verdict: STOP | Reason: %s',
        10,
        1,
        @DatabaseName,
        @Reason
    ) WITH NOWAIT;

    RETURN;
END;
GO
```

- REORGANIZE INDEX AG
```script
CREATE OR ALTER PROCEDURE dbo.usp_ReorganizeIndex
AS
BEGIN
    SET NOCOUNT ON;

    -- 1. KIỂM TRA ROLE TỔNG THỂ: NODE HIỆN TẠI PHẢI LÀ PRIMARY CỦA ÍT NHẤT 1 DB
    IF NOT EXISTS (
        SELECT 1 
        FROM sys.databases d
        WHERE d.group_database_id IS NOT NULL 
          AND sys.fn_hadr_is_primary_replica(d.name) = 1
    )
    BEGIN
        RAISERROR(N'[CIRCUIT BREAKER] Node hien tai khong phai Primary Replica. Ket thuc tien trinh Reorganize.', 10, 1) WITH NOWAIT;
        RETURN;
    END;

    -- 2. KHAI BÁO BIẾN ĐIỀU KHIỂN
    DECLARE 
        @BatchTime      DATETIME2(0) = SYSDATETIME(),
        @CurrentDB      sysname,
        @Verdict        VARCHAR(10),
        @Reason         NVARCHAR(1000),
        @MailErrText    NVARCHAR(4000),
        @ErrText        NVARCHAR(MAX);

    -- Danh sách Database ứng viên (Phải là Primary, Online và Read/Write)
    DECLARE @CandidateDatabases TABLE (
        DBName sysname PRIMARY KEY,
        Evaluated BIT DEFAULT 0
    );

    INSERT INTO @CandidateDatabases (DBName)
    SELECT d.name
    FROM sys.databases d
    WHERE d.group_database_id IS NOT NULL
      AND sys.fn_hadr_is_primary_replica(d.name) = 1
      AND d.state_desc = 'ONLINE'
      AND d.is_read_only = 0;

    -- 3. GIAI ĐOẠN 1: QUÉT GUARD VÀ GHI LOG BAN ĐẦU
    WHILE EXISTS (SELECT 1 FROM @CandidateDatabases WHERE Evaluated = 0)
    BEGIN
        SELECT TOP (1) @CurrentDB = DBName
        FROM @CandidateDatabases
        WHERE Evaluated = 0
        ORDER BY DBName;

        -- Gọi Guard kiểm tra sức khỏe AG, Queue và Disk Log
        EXEC dbo.usp_AgMaintenanceGuard
            @DatabaseName   = @CurrentDB,
            @OverallVerdict = @Verdict OUTPUT,
            @Reason         = @Reason OUTPUT;

        -- Lưu vết đánh giá vào bảng
        INSERT INTO dbo.AgGuardHistory (CheckTime, ActionType, DatabaseName, Verdict, Reason, DynamicMaxDOP, Executed, ExecutionStatus)
        VALUES (
            @BatchTime, 
            'REORGANIZE',
            @CurrentDB, 
            @Verdict, 
            @Reason, 
            NULL, -- Reorganize là Single-Thread nên MaxDOP không áp dụng
            0,
            CASE WHEN @Verdict = 'STOP' THEN N'SKIPPED_STOP' ELSE N'PENDING' END
        );

        UPDATE @CandidateDatabases
        SET Evaluated = 1
        WHERE DBName = @CurrentDB;
    END;

    -- 4. GIAI ĐOẠN 2: CHỈ GỬI EMAIL NẾU CÓ DATABASE BỊ STOP
    IF EXISTS (
        SELECT 1 
        FROM dbo.AgGuardHistory 
        WHERE CheckTime = @BatchTime 
          AND ActionType = 'REORGANIZE' 
          AND Verdict = 'STOP'
    )
    BEGIN
        DECLARE @XmlBody NVARCHAR(MAX), @HtmlTable NVARCHAR(MAX), @MailSubject NVARCHAR(255);

        SET @XmlBody = CAST((
            SELECT 
                td = DatabaseName, '',
                td = Verdict, '',
                td = Reason, ''
            FROM dbo.AgGuardHistory
            WHERE CheckTime = @BatchTime 
              AND ActionType = 'REORGANIZE' 
              AND Verdict = 'STOP'
            ORDER BY DatabaseName
            FOR XML PATH('tr'), ELEMENTS
        ) AS NVARCHAR(MAX));

        SET @HtmlTable = N'
        <html>
        <body>
            <h3 style="color: #d35400;">CẢNH BÁO: Bỏ qua Reorganize Index do AG Guard [STOP]</h3>
            <p>Hệ thống bảo trì phát hiện các Database sau trên Primary <b>' + @@SERVERNAME + N'</b> không đủ điều kiện an toàn để Reorganize:</p>
            <table border="1" cellpadding="6" cellspacing="0" style="border-collapse:collapse; font-family:Segoe UI, Tahoma, Arial; font-size:13px;">
                <tr style="background-color:#fcf3cf; color:#7d6608;">
                    <th>Database Name</th>
                    <th>Verdict</th>
                    <th>Lý do từ chối (Guard Reason)</th>
                </tr>' 
                + @XmlBody + 
            N'</table>
            <p><i>Hệ thống tự động bỏ qua để tránh gây đầy ổ đĩa Log (LDF) hoặc nghẽn Redo Queue của Secondary.</i></p>
        </body>
        </html>';

        SET @MailSubject = N'[SQL ALERT] ' + @@SERVERNAME + N' - Database bị STOP Reorganize Index';

        BEGIN TRY
            EXEC msdb.dbo.sp_send_dbmail
                @profile_name = 'DBA',        -- << Điền Database Mail Profile của bạn
                @recipients   = 'nghianl.ts@vietsov.com.vn;lamll.ts@vietsov.com.vn',  -- << Điền Email nhận cảnh báo
                @subject      = @MailSubject,
                @body         = @HtmlTable,
                @body_format  = 'HTML';

            RAISERROR(N'>>> Da gui email canh bao cac DB bi STOP cho Admin.', 10, 1) WITH NOWAIT;
        END TRY
        BEGIN CATCH
            SET @MailErrText = ERROR_MESSAGE();
            RAISERROR(N'>>> Khong the gui email canh bao: %s', 10, 1, @MailErrText) WITH NOWAIT;
        END CATCH;
    END;

    -- 5. GIAI ĐOẠN 3: THỰC THI REORGANIZE CHO CÁC DB HỢP LỆ (ALLOW / WARN)
    IF NOT EXISTS (
        SELECT 1 
        FROM dbo.AgGuardHistory 
        WHERE CheckTime = @BatchTime 
          AND ActionType = 'REORGANIZE' 
          AND Verdict IN ('ALLOW', 'WARN')
    )
    BEGIN
        RAISERROR(N'>>> Khong co DB nao du dieu kien (ALLOW/WARN). Ket thuc tien trinh.', 10, 1) WITH NOWAIT;
        RETURN;
    END;

    DECLARE 
        @TargetDB sysname;

    WHILE EXISTS (
        SELECT 1 
        FROM dbo.AgGuardHistory 
        WHERE CheckTime = @BatchTime 
          AND ActionType = 'REORGANIZE' 
          AND Verdict IN ('ALLOW', 'WARN') 
          AND Executed = 0
    )
    BEGIN
        SELECT TOP (1) 
            @TargetDB = DatabaseName
        FROM dbo.AgGuardHistory
        WHERE CheckTime = @BatchTime 
          AND ActionType = 'REORGANIZE' 
          AND Verdict IN ('ALLOW', 'WARN') 
          AND Executed = 0
        ORDER BY DatabaseName;

        RAISERROR(N'--------------------------------------------------------------------------------', 10, 1) WITH NOWAIT;
        RAISERROR(N'>>> [BAT DAU REORGANIZE] DB: [%s]', 10, 1, @TargetDB) WITH NOWAIT;

        BEGIN TRY
            -- Chạy Reorganize qua Ola Hallengren
            EXECUTE [master].[dbo].[IndexOptimize]
                @Databases              = @TargetDB,
                @MinNumberOfPages       = 1000,
                @FragmentationLow       = NULL,
                @FragmentationMedium    = 'INDEX_REORGANIZE',
                @FragmentationHigh      = 'INDEX_REORGANIZE',
                @FragmentationLevel1    = 10,
                @FragmentationLevel2    = 30,
                @LockTimeout            = 300,
                @UpdateStatistics       = 'ALL',
                @OnlyModifiedStatistics = 'Y',
                @LogToTable             = 'Y';

            -- Cập nhật thành công vào bảng log
            UPDATE dbo.AgGuardHistory
            SET Executed        = 1,
                ExecutionStatus = N'SUCCESS'
            WHERE CheckTime = @BatchTime 
              AND ActionType = 'REORGANIZE' 
              AND DatabaseName = @TargetDB;

            RAISERROR(N'>>> [HOAN TAT REORGANIZE] DB: [%s]', 10, 1, @TargetDB) WITH NOWAIT;
        END TRY
        BEGIN CATCH
            SET @ErrText = ERROR_MESSAGE();

            -- Ghi vết lỗi vào bảng log
            UPDATE dbo.AgGuardHistory
            SET Executed        = 1,
                ExecutionStatus = N'FAILED',
                ErrorMessage    = @ErrText
            WHERE CheckTime = @BatchTime 
              AND ActionType = 'REORGANIZE' 
              AND DatabaseName = @TargetDB;

            RAISERROR(N'>>> [LOI REORGANIZE] DB: [%s]: %s', 10, 1, @TargetDB, @ErrText) WITH NOWAIT;
        END CATCH;
    END;

    RAISERROR(N'================================================================================', 10, 1) WITH NOWAIT;
    RAISERROR(N'[HOAN TAT TOAN BO TIEN TRINH REORGANIZE]', 10, 1) WITH NOWAIT;
END;
GO
```

- REBUILD INDEX AG
```script
CREATE OR ALTER PROCEDURE dbo.usp_AGRebuildIndex
AS
BEGIN
    SET NOCOUNT ON;

    -- 1. Kiểm tra node hiện tại có phải Primary hay không
    IF NOT EXISTS (
        SELECT 1 
        FROM sys.databases d
        WHERE d.group_database_id IS NOT NULL 
          AND sys.fn_hadr_is_primary_replica(d.name) = 1
    )
    BEGIN
        RAISERROR(N'[CIRCUIT BREAKER] Node hien tai khong phai Primary Replica. Ket thuc.', 10, 1) WITH NOWAIT;
        RETURN;
    END;

    -- 2. Khai báo biến
    DECLARE 
        @BatchTime      DATETIME2(0) = SYSDATETIME(),
        @CurrentDB      sysname,
        @Verdict        VARCHAR(10),
        @Reason         NVARCHAR(1000),
        @DynamicMaxDOP  INT,
        @MailErrText    NVARCHAR(4000),
        @ErrText        NVARCHAR(MAX);

    -- Lấy danh sách DB là Primary
    DECLARE @CandidateDatabases TABLE (
        DBName sysname PRIMARY KEY,
        Evaluated BIT DEFAULT 0
    );

    INSERT INTO @CandidateDatabases (DBName)
    SELECT d.name
    FROM sys.databases d
    WHERE d.group_database_id IS NOT NULL
      AND sys.fn_hadr_is_primary_replica(d.name) = 1
      AND d.state_desc = 'ONLINE'
      AND d.is_read_only = 0;

    -- 3. GIAI ĐOẠN 1: QUÉT GUARD VÀ GHI VÀO BẢNG LOG
    WHILE EXISTS (SELECT 1 FROM @CandidateDatabases WHERE Evaluated = 0)
    BEGIN
        SELECT TOP (1) @CurrentDB = DBName
        FROM @CandidateDatabases
        WHERE Evaluated = 0
        ORDER BY DBName;

        EXEC dbo.usp_AgMaintenanceGuard
            @DatabaseName   = @CurrentDB,
            @OverallVerdict = @Verdict OUTPUT,
            @Reason         = @Reason OUTPUT;

        SET @DynamicMaxDOP = CASE WHEN @Verdict = 'WARN' THEN 2 ELSE 4 END;

        -- Lưu kết quả vào bảng lịch sử (Chuẩn hóa ActionType = 'REBUILD')
        INSERT INTO dbo.AgGuardHistory (CheckTime, ActionType, DatabaseName, Verdict, Reason, DynamicMaxDOP, Executed, ExecutionStatus)
        VALUES (
            @BatchTime, 
            'REBUILD',
            @CurrentDB, 
            @Verdict, 
            @Reason, 
            @DynamicMaxDOP, 
            0,
            CASE WHEN @Verdict = 'STOP' THEN N'SKIPPED_STOP' ELSE N'PENDING' END
        );

        UPDATE @CandidateDatabases
        SET Evaluated = 1
        WHERE DBName = @CurrentDB;
    END;

    -- 4. GIAI ĐOẠN 2: CHỈ GỬI EMAIL NẾU TỒN TẠI DB BỊ STOP
    IF EXISTS (
        SELECT 1 
        FROM dbo.AgGuardHistory 
        WHERE CheckTime = @BatchTime 
          AND ActionType = 'REBUILD'
          AND Verdict = 'STOP'
    )
    BEGIN
        DECLARE @XmlBody NVARCHAR(MAX), @HtmlTable NVARCHAR(MAX), @MailSubject NVARCHAR(255);

        -- Tạo bảng HTML liệt kê các DB bị STOP
        SET @XmlBody = CAST((
            SELECT 
                td = DatabaseName, '',
                td = Verdict, '',
                td = Reason, ''
            FROM dbo.AgGuardHistory
            WHERE CheckTime = @BatchTime 
              AND ActionType = 'REBUILD'
              AND Verdict = 'STOP'
            ORDER BY DatabaseName
            FOR XML PATH('tr'), ELEMENTS
        ) AS NVARCHAR(MAX));

        SET @HtmlTable = N'
        <html>
        <body>
            <h3 style="color: #c0392b;">CẢNH BÁO: Database không đủ điều kiện Rebuild Index</h3>
            <p>Hệ thống phát hiện các Database dưới đây trên Primary <b>' + @@SERVERNAME + N'</b> bị chặn bởi AG Guard:</p>
            <table border="1" cellpadding="5" cellspacing="0" style="border-collapse:collapse; font-family:Arial; font-size:13px;">
                <tr style="background-color:#f2f2f2;">
                    <th>Database</th>
                    <th>Verdict</th>
                    <th>Lý do từ chối (Reason)</th>
                </tr>' 
                + @XmlBody + 
            N'</table>
            <p><i>Vui lòng kiểm tra dung lượng ổ đĩa, log synchronization hoặc AG queue của secondary.</i></p>
        </body>
        </html>';

        SET @MailSubject = N'[SQL ALERT] ' + @@SERVERNAME + N' - Phát hiện Database bị STOP Rebuild Index';

        -- Gửi mail qua Database Mail
        BEGIN TRY
            EXEC msdb.dbo.sp_send_dbmail
                @profile_name = 'DBA',        -- << Thay bằng Profile Mail của bạn
                @recipients   = 'nghianl.ts@vietsov.com.vn;lamll.ts@vietsov.com.vn', -- << Thay bằng email nhận
                @subject      = @MailSubject,
                @body         = @HtmlTable,
                @body_format  = 'HTML';

            RAISERROR(N'>>> Da gui email canh bao DB STOP thanh cong cho Admin.', 10, 1) WITH NOWAIT;
        END TRY
        BEGIN CATCH
            SET @MailErrText = ERROR_MESSAGE();
            RAISERROR(N'>>> Khong the gui email canh bao: %s', 10, 1, @MailErrText) WITH NOWAIT;
        END CATCH;
    END;

    -- 5. GIAI ĐOẠN 3: THỰC THI REBUILD (NẾU CÓ DB ĐƯỢC PHÉP CHẠY)
    IF NOT EXISTS (
        SELECT 1 
        FROM dbo.AgGuardHistory 
        WHERE CheckTime = @BatchTime 
          AND ActionType = 'REBUILD'
          AND Verdict IN ('ALLOW', 'WARN')
    )
    BEGIN
        RAISERROR(N'>>> Khong co Database nao du dieu kien (ALLOW/WARN). Ket thuc khong can Rebuild.', 10, 1) WITH NOWAIT;
        RETURN;
    END;

    DECLARE 
        @TargetDB       sysname,
        @RunMaxDOP      INT,
        @CurrentVerdict VARCHAR(10);

    WHILE EXISTS (
        SELECT 1 
        FROM dbo.AgGuardHistory 
        WHERE CheckTime = @BatchTime 
          AND ActionType = 'REBUILD'
          AND Verdict IN ('ALLOW', 'WARN') 
          AND Executed = 0
    )
    BEGIN
        SELECT TOP (1) 
            @TargetDB       = DatabaseName,
            @RunMaxDOP      = DynamicMaxDOP,
            @CurrentVerdict = Verdict
        FROM dbo.AgGuardHistory
        WHERE CheckTime = @BatchTime 
          AND ActionType = 'REBUILD'
          AND Verdict IN ('ALLOW', 'WARN') 
          AND Executed = 0
        ORDER BY DatabaseName;

        RAISERROR(N'--------------------------------------------------------------------------------', 10, 1) WITH NOWAIT;
        RAISERROR(N'>>> [THUC THI] Rebuild DB: [%s] | MaxDOP: %d', 10, 1, @TargetDB, @RunMaxDOP) WITH NOWAIT;

        BEGIN TRY
            EXECUTE [master].[dbo].[IndexOptimize]
                @Databases                       = @TargetDB,
                @MinNumberOfPages                = 1000,
                @FragmentationLow                = NULL,
                @FragmentationMedium             = NULL,
                @FragmentationLevel2             = 30,
                @FragmentationHigh               = 'INDEX_REBUILD_ONLINE,INDEX_REBUILD_OFFLINE',
                @MaxDOP                          = @RunMaxDOP,
                @SortInTempdb                    = 'Y',
                @WaitAtLowPriorityMaxDuration    = 5,
                @WaitAtLowPriorityAbortAfterWait = 'SELF',
                @LockTimeout                     = 300,
                @Resumable                       = 'Y',
                @PartitionLevel                  = 'Y',
                @UpdateStatistics                = 'ALL',
                @OnlyModifiedStatistics          = 'Y',
                @LogToTable                      = 'Y';

            -- Cập nhật thành công vào bảng log
            UPDATE dbo.AgGuardHistory
            SET Executed        = 1,
                ExecutionStatus = N'SUCCESS'
            WHERE CheckTime = @BatchTime 
              AND ActionType = 'REBUILD'
              AND DatabaseName = @TargetDB;

            RAISERROR(N'>>> [THANH CONG] DB: [%s]', 10, 1, @TargetDB) WITH NOWAIT;
        END TRY
        BEGIN CATCH
            SET @ErrText = ERROR_MESSAGE();

            -- Ghi nhận lỗi vào bảng log
            UPDATE dbo.AgGuardHistory
            SET Executed        = 1,
                ExecutionStatus = N'FAILED',
                ErrorMessage    = @ErrText
            WHERE CheckTime = @BatchTime 
              AND ActionType = 'REBUILD'
              AND DatabaseName = @TargetDB;

            RAISERROR(N'>>> [LOI REBUILD] DB: [%s]: %s', 10, 1, @TargetDB, @ErrText) WITH NOWAIT;
        END CATCH;
    END;

    RAISERROR(N'================================================================================', 10, 1) WITH NOWAIT;
    RAISERROR(N'[HOAN TAT TIEN TRINH REBUILD VA GHI LOG]', 10, 1) WITH NOWAIT;
END;
GO
```

- SQL 2014 - 2016:
```script
USE [DBA_Admin]; -- Đổi thành database quản trị của bạn
GO

-- Tạo procedure rỗng nếu chưa tồn tại (tương thích SQL Server 2014/2016)
IF OBJECT_ID('dbo.usp_AGRebuildIndex', 'P') IS NULL
    EXEC ('CREATE PROCEDURE dbo.usp_AGRebuildIndex AS SELECT 1;');
GO

ALTER PROCEDURE dbo.usp_AGRebuildIndex
AS
BEGIN
    SET NOCOUNT ON;

    -- 1. Kiểm tra node hiện tại có phải Primary hay không
    IF NOT EXISTS (
        SELECT 1 
        FROM sys.databases d
        WHERE d.group_database_id IS NOT NULL 
          AND sys.fn_hadr_is_primary_replica(d.name) = 1
    )
    BEGIN
        RAISERROR(N'[CIRCUIT BREAKER] Node hien tai khong phai Primary Replica. Ket thuc.', 10, 1) WITH NOWAIT;
        RETURN;
    END;

    -- 2. Khai báo biến
    DECLARE 
        @BatchTime      DATETIME2(0) = SYSDATETIME(),
        @CurrentDB      sysname,
        @Verdict        VARCHAR(10),
        @Reason         NVARCHAR(1000),
        @DynamicMaxDOP  INT,
        @MailErrText    NVARCHAR(4000),
        @ErrText        NVARCHAR(MAX);

    -- Lấy danh sách DB là Primary
    DECLARE @CandidateDatabases TABLE (
        DBName sysname PRIMARY KEY,
        Evaluated BIT DEFAULT 0
    );

    INSERT INTO @CandidateDatabases (DBName)
    SELECT d.name
    FROM sys.databases d
    WHERE d.group_database_id IS NOT NULL
      AND sys.fn_hadr_is_primary_replica(d.name) = 1
      AND d.state_desc = 'ONLINE'
      AND d.is_read_only = 0;

    -- 3. GIAI ĐOẠN 1: QUÉT GUARD VÀ GHI VÀO BẢNG LOG
    WHILE EXISTS (SELECT 1 FROM @CandidateDatabases WHERE Evaluated = 0)
    BEGIN
        SELECT TOP (1) @CurrentDB = DBName
        FROM @CandidateDatabases
        WHERE Evaluated = 0
        ORDER BY DBName;

        EXEC dbo.usp_AgMaintenanceGuard
            @DatabaseName   = @CurrentDB,
            @OverallVerdict = @Verdict OUTPUT,
            @Reason         = @Reason OUTPUT;

        SET @DynamicMaxDOP = CASE WHEN @Verdict = 'WARN' THEN 2 ELSE 4 END;

        -- Ghi log đánh giá ban đầu
        INSERT INTO dbo.AgGuardHistory (CheckTime, ActionType, DatabaseName, Verdict, Reason, DynamicMaxDOP, Executed, ExecutionStatus)
        VALUES (
            @BatchTime, 
            'REBUILD',
            @CurrentDB, 
            @Verdict, 
            @Reason, 
            @DynamicMaxDOP, 
            0,
            CASE WHEN @Verdict = 'STOP' THEN N'SKIPPED_STOP' ELSE N'PENDING' END
        );

        UPDATE @CandidateDatabases
        SET Evaluated = 1
        WHERE DBName = @CurrentDB;
    END;

    -- 4. GIAI ĐOẠN 2: CHỈ GỬI EMAIL NẾU TỒN TẠI DB BỊ STOP
    IF EXISTS (
        SELECT 1 
        FROM dbo.AgGuardHistory 
        WHERE CheckTime = @BatchTime 
          AND ActionType = 'REBUILD'
          AND Verdict = 'STOP'
    )
    BEGIN
        DECLARE @XmlBody NVARCHAR(MAX), @HtmlTable NVARCHAR(MAX), @MailSubject NVARCHAR(255);

        SET @XmlBody = CAST((
            SELECT 
                td = DatabaseName, '',
                td = Verdict, '',
                td = Reason, ''
            FROM dbo.AgGuardHistory
            WHERE CheckTime = @BatchTime 
              AND ActionType = 'REBUILD'
              AND Verdict = 'STOP'
            ORDER BY DatabaseName
            FOR XML PATH('tr'), ELEMENTS
        ) AS NVARCHAR(MAX));

        SET @HtmlTable = N'
        <html>
        <body>
            <h3 style="color: #c0392b;">CẢNH BÁO: Database không đủ điều kiện Rebuild Index</h3>
            <p>Hệ thống phát hiện các Database dưới đây trên Primary <b>' + @@SERVERNAME + N'</b> bị chặn bởi AG Guard:</p>
            <table border="1" cellpadding="5" cellspacing="0" style="border-collapse:collapse; font-family:Arial; font-size:13px;">
                <tr style="background-color:#f2f2f2;">
                    <th>Database</th>
                    <th>Verdict</th>
                    <th>Lý do từ chối (Reason)</th>
                </tr>' 
                + @XmlBody + 
            N'</table>
            <p><i>Vui lòng kiểm tra dung lượng ổ đĩa LDF, log synchronization hoặc AG queue của secondary.</i></p>
        </body>
        </html>';

        SET @MailSubject = N'[SQL ALERT] ' + @@SERVERNAME + N' - Phát hiện Database bị STOP Rebuild Index';

        BEGIN TRY
            EXEC msdb.dbo.sp_send_dbmail
                @profile_name = 'DBA',                     -- Đã điền Profile DBA
                @recipients   = 'nghianl.ts@vietsov.com.vn;lamll.ts@vietsov.com.vn', -- Thay đổi email nhận thực tế
                @subject      = @MailSubject,
                @body         = @HtmlTable,
                @body_format  = 'HTML';

            RAISERROR(N'>>> Da gui email canh bao DB STOP thanh cong cho Admin.', 10, 1) WITH NOWAIT;
        END TRY
        BEGIN CATCH
            SET @MailErrText = ERROR_MESSAGE();
            RAISERROR(N'>>> Khong the gui email canh bao: %s', 10, 1, @MailErrText) WITH NOWAIT;
        END CATCH;
    END;

    -- 5. GIAI ĐOẠN 3: THỰC THI REBUILD (NẾU CÓ DB HỢP LỆ)
    IF NOT EXISTS (
        SELECT 1 
        FROM dbo.AgGuardHistory 
        WHERE CheckTime = @BatchTime 
          AND ActionType = 'REBUILD'
          AND Verdict IN ('ALLOW', 'WARN')
    )
    BEGIN
        RAISERROR(N'>>> Khong co Database nao du dieu kien (ALLOW/WARN). Ket thuc khong can Rebuild.', 10, 1) WITH NOWAIT;
        RETURN;
    END;

    DECLARE 
        @TargetDB       sysname,
        @RunMaxDOP      INT,
        @CurrentVerdict VARCHAR(10);

    WHILE EXISTS (
        SELECT 1 
        FROM dbo.AgGuardHistory 
        WHERE CheckTime = @BatchTime 
          AND ActionType = 'REBUILD'
          AND Verdict IN ('ALLOW', 'WARN') 
          AND Executed = 0
    )
    BEGIN
        SELECT TOP (1) 
            @TargetDB       = DatabaseName,
            @RunMaxDOP      = DynamicMaxDOP,
            @CurrentVerdict = Verdict
        FROM dbo.AgGuardHistory
        WHERE CheckTime = @BatchTime 
          AND ActionType = 'REBUILD'
          AND Verdict IN ('ALLOW', 'WARN') 
          AND Executed = 0
        ORDER BY DatabaseName;

        RAISERROR(N'--------------------------------------------------------------------------------', 10, 1) WITH NOWAIT;
        RAISERROR(N'>>> [THUC THI] Rebuild DB: [%s] | MaxDOP: %d', 10, 1, @TargetDB, @RunMaxDOP) WITH NOWAIT;

        BEGIN TRY
            -- ĐÃ LOẠI BỎ @Resumable = 'Y' (Không hỗ trợ trên SQL Server 2014 & 2016)
            EXECUTE [master].[dbo].[IndexOptimize]
                @Databases                       = @TargetDB,
                @MinNumberOfPages                = 1000,
                @FragmentationLow                = NULL,
                @FragmentationMedium             = NULL,
                @FragmentationLevel2             = 30,
                @FragmentationHigh               = 'INDEX_REBUILD_ONLINE,INDEX_REBUILD_OFFLINE',
                @MaxDOP                          = @RunMaxDOP,
                @SortInTempdb                    = 'Y',
                @WaitAtLowPriorityMaxDuration    = 5,
                @WaitAtLowPriorityAbortAfterWait = 'SELF',
                @LockTimeout                     = 300,
                @PartitionLevel                  = 'Y',
                @UpdateStatistics                = 'ALL',
                @OnlyModifiedStatistics          = 'Y',
                @LogToTable                      = 'Y';

            UPDATE dbo.AgGuardHistory
            SET Executed        = 1,
                ExecutionStatus = N'SUCCESS'
            WHERE CheckTime = @BatchTime 
              AND ActionType = 'REBUILD'
              AND DatabaseName = @TargetDB;

            RAISERROR(N'>>> [THANH CONG] DB: [%s]', 10, 1, @TargetDB) WITH NOWAIT;
        END TRY
        BEGIN CATCH
            SET @ErrText = ERROR_MESSAGE();

            UPDATE dbo.AgGuardHistory
            SET Executed        = 1,
                ExecutionStatus = N'FAILED',
                ErrorMessage    = @ErrText
            WHERE CheckTime = @BatchTime 
              AND ActionType = 'REBUILD'
              AND DatabaseName = @TargetDB;

            RAISERROR(N'>>> [LOI REBUILD] DB: [%s]: %s', 10, 1, @TargetDB, @ErrText) WITH NOWAIT;
        END CATCH;
    END;

    RAISERROR(N'================================================================================', 10, 1) WITH NOWAIT;
    RAISERROR(N'[HOAN TAT TIEN TRINH REBUILD VA GHI LOG]', 10, 1) WITH NOWAIT;
END;
GO
```

```script
USE [DBA_Admin]; -- Đổi thành database quản trị của bạn
GO

-- Tạo procedure rỗng nếu chưa tồn tại
IF OBJECT_ID('dbo.usp_ReorganizeIndex', 'P') IS NULL
    EXEC ('CREATE PROCEDURE dbo.usp_ReorganizeIndex AS SELECT 1;');
GO

ALTER PROCEDURE dbo.usp_ReorganizeIndex
AS
BEGIN
    SET NOCOUNT ON;

    -- 1. KIỂM TRA ROLE TỔNG THỂ: NODE HIỆN TẠI PHẢI LÀ PRIMARY
    IF NOT EXISTS (
        SELECT 1 
        FROM sys.databases d
        WHERE d.group_database_id IS NOT NULL 
          AND sys.fn_hadr_is_primary_replica(d.name) = 1
    )
    BEGIN
        RAISERROR(N'[CIRCUIT BREAKER] Node hien tai khong phai Primary Replica. Ket thuc tien trinh Reorganize.', 10, 1) WITH NOWAIT;
        RETURN;
    END;

    -- 2. KHAI BÁO BIẾN ĐIỀU KHIỂN
    DECLARE 
        @BatchTime      DATETIME2(0) = SYSDATETIME(),
        @CurrentDB      sysname,
        @Verdict        VARCHAR(10),
        @Reason         NVARCHAR(1000),
        @MailErrText    NVARCHAR(4000),
        @ErrText        NVARCHAR(MAX);

    -- Lấy danh sách DB là Primary
    DECLARE @CandidateDatabases TABLE (
        DBName sysname PRIMARY KEY,
        Evaluated BIT DEFAULT 0
    );

    INSERT INTO @CandidateDatabases (DBName)
    SELECT d.name
    FROM sys.databases d
    WHERE d.group_database_id IS NOT NULL
      AND sys.fn_hadr_is_primary_replica(d.name) = 1
      AND d.state_desc = 'ONLINE'
      AND d.is_read_only = 0;

    -- 3. GIAI ĐOẠN 1: QUÉT GUARD VÀ GHI LOG BAN ĐẦU
    WHILE EXISTS (SELECT 1 FROM @CandidateDatabases WHERE Evaluated = 0)
    BEGIN
        SELECT TOP (1) @CurrentDB = DBName
        FROM @CandidateDatabases
        WHERE Evaluated = 0
        ORDER BY DBName;

        EXEC dbo.usp_AgMaintenanceGuard
            @DatabaseName   = @CurrentDB,
            @OverallVerdict = @Verdict OUTPUT,
            @Reason         = @Reason OUTPUT;

        INSERT INTO dbo.AgGuardHistory (CheckTime, ActionType, DatabaseName, Verdict, Reason, DynamicMaxDOP, Executed, ExecutionStatus)
        VALUES (
            @BatchTime, 
            'REORGANIZE',
            @CurrentDB, 
            @Verdict, 
            @Reason, 
            NULL,
            0,
            CASE WHEN @Verdict = 'STOP' THEN N'SKIPPED_STOP' ELSE N'PENDING' END
        );

        UPDATE @CandidateDatabases
        SET Evaluated = 1
        WHERE DBName = @CurrentDB;
    END;

    -- 4. GIAI ĐOẠN 2: CHỈ GỬI EMAIL NẾU CÓ DATABASE BỊ STOP
    IF EXISTS (
        SELECT 1 
        FROM dbo.AgGuardHistory 
        WHERE CheckTime = @BatchTime 
          AND ActionType = 'REORGANIZE' 
          AND Verdict = 'STOP'
    )
    BEGIN
        DECLARE @XmlBody NVARCHAR(MAX), @HtmlTable NVARCHAR(MAX), @MailSubject NVARCHAR(255);

        SET @XmlBody = CAST((
            SELECT 
                td = DatabaseName, '',
                td = Verdict, '',
                td = Reason, ''
            FROM dbo.AgGuardHistory
            WHERE CheckTime = @BatchTime 
              AND ActionType = 'REORGANIZE' 
              AND Verdict = 'STOP'
            ORDER BY DatabaseName
            FOR XML PATH('tr'), ELEMENTS
        ) AS NVARCHAR(MAX));

        SET @HtmlTable = N'
        <html>
        <body>
            <h3 style="color: #d35400;">CẢNH BÁO: Bỏ qua Reorganize Index do AG Guard [STOP]</h3>
            <p>Hệ thống bảo trì phát hiện các Database sau trên Primary <b>' + @@SERVERNAME + N'</b> không đủ điều kiện an toàn để Reorganize:</p>
            <table border="1" cellpadding="6" cellspacing="0" style="border-collapse:collapse; font-family:Segoe UI, Tahoma, Arial; font-size:13px;">
                <tr style="background-color:#fcf3cf; color:#7d6608;">
                    <th>Database Name</th>
                    <th>Verdict</th>
                    <th>Lý do từ chối (Guard Reason)</th>
                </tr>' 
                + @XmlBody + 
            N'</table>
            <p><i>Hệ thống tự động bỏ qua để tránh gây đầy ổ đĩa Log (LDF) hoặc nghẽn Redo Queue của Secondary.</i></p>
        </body>
        </html>';

        SET @MailSubject = N'[SQL ALERT] ' + @@SERVERNAME + N' - Database bị STOP Reorganize Index';

        BEGIN TRY
            EXEC msdb.dbo.sp_send_dbmail
                @profile_name = 'DBA',
                @recipients   = 'nghianl.ts@vietsov.com.vn;lamll.ts@vietsov.com.vn',
                @subject      = @MailSubject,
                @body         = @HtmlTable,
                @body_format  = 'HTML';

            RAISERROR(N'>>> Da gui email canh bao cac DB bi STOP cho Admin.', 10, 1) WITH NOWAIT;
        END TRY
        BEGIN CATCH
            SET @MailErrText = ERROR_MESSAGE();
            RAISERROR(N'>>> Khong the gui email canh bao: %s', 10, 1, @MailErrText) WITH NOWAIT;
        END CATCH;
    END;

    -- 5. GIAI ĐOẠN 3: THỰC THI REORGANIZE CHO CÁC DB HỢP LỆ
    IF NOT EXISTS (
        SELECT 1 
        FROM dbo.AgGuardHistory 
        WHERE CheckTime = @BatchTime 
          AND ActionType = 'REORGANIZE' 
          AND Verdict IN ('ALLOW', 'WARN')
    )
    BEGIN
        RAISERROR(N'>>> Khong co DB nao du dieu kien (ALLOW/WARN). Ket thuc tien trinh.', 10, 1) WITH NOWAIT;
        RETURN;
    END;

    DECLARE 
        @TargetDB sysname;

    WHILE EXISTS (
        SELECT 1 
        FROM dbo.AgGuardHistory 
        WHERE CheckTime = @BatchTime 
          AND ActionType = 'REORGANIZE' 
          AND Verdict IN ('ALLOW', 'WARN') 
          AND Executed = 0
    )
    BEGIN
        SELECT TOP (1) 
            @TargetDB = DatabaseName
        FROM dbo.AgGuardHistory
        WHERE CheckTime = @BatchTime 
          AND ActionType = 'REORGANIZE' 
          AND Verdict IN ('ALLOW', 'WARN') 
          AND Executed = 0
        ORDER BY DatabaseName;

        RAISERROR(N'--------------------------------------------------------------------------------', 10, 1) WITH NOWAIT;
        RAISERROR(N'>>> [BAT DAU REORGANIZE] DB: [%s]', 10, 1, @TargetDB) WITH NOWAIT;

        BEGIN TRY
            EXECUTE [master].[dbo].[IndexOptimize]
                @Databases              = @TargetDB,
                @MinNumberOfPages       = 1000,
                @FragmentationLow       = NULL,
                @FragmentationMedium    = 'INDEX_REORGANIZE',
                @FragmentationHigh      = 'INDEX_REORGANIZE',
                @FragmentationLevel1    = 10,
                @FragmentationLevel2    = 30,
                @LockTimeout            = 300,
                @UpdateStatistics       = 'ALL',
                @OnlyModifiedStatistics = 'Y',
                @LogToTable             = 'Y';

            UPDATE dbo.AgGuardHistory
            SET Executed        = 1,
                ExecutionStatus = N'SUCCESS'
            WHERE CheckTime = @BatchTime 
              AND ActionType = 'REORGANIZE' 
              AND DatabaseName = @TargetDB;

            RAISERROR(N'>>> [HOAN TAT REORGANIZE] DB: [%s]', 10, 1, @TargetDB) WITH NOWAIT;
        END TRY
        BEGIN CATCH
            SET @ErrText = ERROR_MESSAGE();

            UPDATE dbo.AgGuardHistory
            SET Executed        = 1,
                ExecutionStatus = N'FAILED',
                ErrorMessage    = @ErrText
            WHERE CheckTime = @BatchTime 
              AND ActionType = 'REORGANIZE' 
              AND DatabaseName = @TargetDB;

            RAISERROR(N'>>> [LOI REORGANIZE] DB: [%s]: %s', 10, 1, @TargetDB, @ErrText) WITH NOWAIT;
        END CATCH;
    END;

    RAISERROR(N'================================================================================', 10, 1) WITH NOWAIT;
    RAISERROR(N'[HOAN TAT TOAN BO TIEN TRINH REORGANIZE]', 10, 1) WITH NOWAIT;
END;
GO
```