### Backup Log & Rebuild/Reorganize, KHÔNG SỬ DỤNG trên các instance Standalone (không join AG).

- Download bộ script của Ola Hallengren tại repo chính thức và cài đặt

- Tạo các bảng cần thiết
```sql
CREATE TABLE [dbo].[AdaptiveLogBackupLog](
	[LogID] [bigint] IDENTITY(1,1) NOT NULL,
	[RunTime] [datetime2](2) NOT NULL,
	[DatabaseName] [sysname] NOT NULL,
	[TotalLogMB] [decimal](18, 2) NULL,
	[UsedLogMB] [decimal](18, 2) NULL,
	[UsedLogPercent] [decimal](5, 2) NULL,
	[MinutesSinceLastBackup] [int] NULL,
	[LogReuseWait] [nvarchar](60) NULL,
	[MaxSendQueueMB] [bigint] NULL,
	[MaxRedoQueueMB] [bigint] NULL,
	[WorstSyncHealth] [nvarchar](60) NULL,
	[ActionTaken] [varchar](20) NOT NULL,
	[TriggerReason] [nvarchar](255) NULL,
	[ErrorMessage] [nvarchar](4000) NULL,
PRIMARY KEY CLUSTERED 
(
	[LogID] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO

ALTER TABLE [dbo].[AdaptiveLogBackupLog] ADD  DEFAULT (sysdatetime()) FOR [RunTime]
GO 

CREATE TABLE [dbo].[AgGuardHistory](
	[LogId] [bigint] IDENTITY(1,1) NOT NULL,
	[CheckTime] [datetime2](0) NULL,
	[ActionType] [varchar](20) NULL,
	[DatabaseName] [sysname] NOT NULL,
	[Verdict] [varchar](10) NULL,
	[Reason] [nvarchar](1000) NULL,
	[DynamicMaxDOP] [int] NULL,
	[Executed] [bit] NULL,
	[ExecutionStatus] [nvarchar](50) NULL,
	[ErrorMessage] [nvarchar](max) NULL,
PRIMARY KEY CLUSTERED 
(
	[LogId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]
GO

ALTER TABLE [dbo].[AgGuardHistory] ADD  DEFAULT (sysdatetime()) FOR [CheckTime]
GO
```

- =========================================================================
- Chốt chặn bảo vệ hạ tầng (Safety Guard/Telemetry Engine). 
  Procedure này không thực hiện bảo trì, mà chỉ đóng vai trò "khám sức khỏe" cho Database và 
  cụm Always On trước khi cấp phép cho Rebuild/Reorganize Index.
- =========================================================================
```sql
CREATE PROCEDURE [dbo].[usp_AgMaintenanceGuard]
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
```
- =========================================================================
- Sao lưu Transaction Log có khả năng tự điều chỉnh (Adaptive) và tự phối hợp giữa các node Primary – Secondary 
  thông qua Application Lock (sp_getapplock / sp_releaseapplock).
- =========================================================================
```sql
CREATE PROCEDURE [dbo].[usp_AdaptiveLogBackup]
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
GO
```
- =========================================================================
- Reorganize Index
- =========================================================================
CREATE  PROCEDURE [dbo].[usp_AgReorganizeIndex]
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
                @recipients   = 'nghianl.ts@vietsov.com.vn;lamlh.ts@vietsov.com.vn',  -- << Điền Email nhận cảnh báo
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
- =========================================================================
- Rebuild Index
- =========================================================================
```sql
  PROCEDURE [dbo].[usp_AgRebuildIndex]
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
                @recipients   = 'nghianl.ts@vietsov.com.vn;lamlh.ts@vietsov.com.vn', -- << Thay bằng email nhận
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

		-- Xác định phiên bản động
		DECLARE @MajorVersion INT = (@@MICROSOFTVERSION / 0x01000000);
		DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT); -- 3 = Enterprise

		DECLARE 
			@OptResumable VARCHAR(1) = 'N',
			@OptLowPriorityDuration INT = NULL,
			@OptLowPriorityAbort VARCHAR(10) = NULL;

		-- 1. Resumable Online Index Rebuild chỉ hỗ trợ từ SQL 2017 Enterprise/Developer
		IF @MajorVersion >= 14 AND @EngineEdition = 3
		BEGIN
			SET @OptResumable = 'Y';
		END;

		-- 2. Wait at Low Priority chỉ hỗ trợ từ Enterprise/Developer (2014+)
		IF @EngineEdition = 3
		BEGIN
			SET @OptLowPriorityDuration = 5;
			SET @OptLowPriorityAbort = 'SELF';
		END;

		-- Truyền các biến này vào EXECUTE IndexOptimize:
		EXECUTE [master].[dbo].[IndexOptimize]
			@Databases                       = @TargetDB,
			@MinNumberOfPages                = 1000,
			@FragmentationLow                = NULL,
			@FragmentationMedium             = NULL,
			@FragmentationLevel2             = 30,
			@FragmentationHigh               = 'INDEX_REBUILD_ONLINE,INDEX_REBUILD_OFFLINE',
			@MaxDOP                          = @RunMaxDOP,
			@SortInTempdb                    = 'Y',
			@WaitAtLowPriorityMaxDuration    = @OptLowPriorityDuration,
			@WaitAtLowPriorityAbortAfterWait = @OptLowPriorityAbort,
			@LockTimeout                     = 300,
			@Resumable                       = @OptResumable,
			@PartitionLevel                  = 'Y',
			@UpdateStatistics                = 'ALL',
			@OnlyModifiedStatistics          = 'Y',
			@LogToTable                      = 'Y';

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
```

====================================================================================================
- Job thực thi cho Transaction log & 
====================================================================================================
```sql
USE [msdb];
GO

--------------------------------------------------------------------------------
-- 0. CHUẨN BỊ MÔI TRƯỜNG: CATEGORY & OPERATOR (TRÁNH CRASH)
--------------------------------------------------------------------------------
-- 0.1 Category
IF NOT EXISTS (SELECT name FROM msdb.dbo.syscategories WHERE name = N'Database Maintenance' AND category_class = 1)
BEGIN
    EXEC msdb.dbo.sp_add_category @class = N'JOB', @type = N'LOCAL', @name = N'Database Maintenance';
END;

-- 0.2 Operator nhận mail (nếu server mới chưa có thì tạo để job không bị lỗi biên dịch)
IF NOT EXISTS (SELECT name FROM msdb.dbo.sysoperators WHERE name = N'DBA')
BEGIN
    EXEC msdb.dbo.sp_add_operator 
        @name = N'DBA', 
        @enabled = 1, 
        @email_address = N'nghianl.ts@vietsov.com.vn;lamlh.ts@vietsov.com.vn';
END;
GO

--------------------------------------------------------------------------------
-- 1. JOB: AdaptiveLogBackup
--------------------------------------------------------------------------------
IF EXISTS (SELECT job_id FROM msdb.dbo.sysjobs WHERE name = N'AdaptiveLogBackup')
BEGIN
    EXEC msdb.dbo.sp_delete_job @job_name = N'AdaptiveLogBackup', @delete_unused_schedule = 1;
END;
GO

BEGIN TRANSACTION;
DECLARE @ReturnCode INT = 0;
DECLARE @jobId BINARY(16);

EXEC @ReturnCode = msdb.dbo.sp_add_job 
    @job_name                   = N'AdaptiveLogBackup', 
    @enabled                    = 1, 
    @notify_level_eventlog      = 0, 
    @notify_level_email         = 2, -- Chỉ gửi mail khi job Fail
    @notify_level_netsend       = 0, 
    @notify_level_page          = 0, 
    @delete_level               = 0, 
    @description                = N'Job chay 5 phut/lan. Toi thieu 30 phut backup 1 lan hoac kich hoat tuc thi neu log >= 60% va >= 5GB.', 
    @category_name              = N'Database Maintenance', 
    @owner_login_name           = N'sa', 
    @notify_email_operator_name = N'DBA', 
    @job_id                     = @jobId OUTPUT;
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback;

-- Step 1
EXEC @ReturnCode = msdb.dbo.sp_add_jobstep 
    @job_id                 = @jobId, 
    @step_name              = N'Step 1 - Adaptive Log Backup via Ola', 
    @step_id                = 1, 
    @cmdexec_success_code   = 0, 
    @on_success_action      = 1, 
    @on_success_step_id     = 0, 
    @on_fail_action         = 2, 
    @on_fail_step_id        = 0, 
    @retry_attempts         = 0, -- Không retry vì job chạy lặp 5 phút/lần
    @retry_interval         = 0, 
    @os_run_priority        = 0, 
    @subsystem              = N'TSQL', 
    @command                = N'EXEC DbaMonitor.dbo.usp_AdaptiveLogBackup;', 
    @database_name          = N'DbaMonitor', 
    @flags                  = 0;
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback;

EXEC @ReturnCode = msdb.dbo.sp_update_job @job_id = @jobId, @start_step_id = 1;
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback;

-- Schedule: 5 phút / lần
EXEC @ReturnCode = msdb.dbo.sp_add_jobschedule 
    @job_id                 = @jobId, 
    @name                   = N'AdaptiveLogBackup_Every_5_Mins', 
    @enabled                = 1, 
    @freq_type              = 4, -- Daily
    @freq_interval          = 1, 
    @freq_subday_type       = 4, -- Minutes
    @freq_subday_interval   = 5, 
    @freq_relative_interval = 0, 
    @freq_recurrence_factor = 0, 
    @active_start_date      = 20260101, 
    @active_end_date        = 99991231, 
    @active_start_time      = 0, 
    @active_end_time        = 235959;
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback;

EXEC @ReturnCode = msdb.dbo.sp_add_jobserver @job_id = @jobId, @server_name = N'(local)';
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback;

COMMIT TRANSACTION;
GOTO EndSaveJob1;

QuitWithRollback:
    IF (@@TRANCOUNT > 0) ROLLBACK TRANSACTION;
EndSaveJob1:
GO

--------------------------------------------------------------------------------
-- 2. JOB: ReorganizeIndex
--------------------------------------------------------------------------------
IF EXISTS (SELECT job_id FROM msdb.dbo.sysjobs WHERE name = N'ReorganizeIndex')
BEGIN
    EXEC msdb.dbo.sp_delete_job @job_name = N'ReorganizeIndex', @delete_unused_schedule = 1;
END;
GO

BEGIN TRANSACTION;
DECLARE @ReturnCode INT = 0;
DECLARE @jobId BINARY(16);

EXEC @ReturnCode = msdb.dbo.sp_add_job 
    @job_name                   = N'ReorganizeIndex', 
    @enabled                    = 1, 
    @notify_level_eventlog      = 0, 
    @notify_level_email         = 2, 
    @notify_level_netsend       = 0, 
    @notify_level_page          = 0, 
    @delete_level               = 0, 
    @description                = N'Duyet va Reorganize cac index bi phan manh hang ngay.', 
    @category_name              = N'Database Maintenance', 
    @owner_login_name           = N'sa', 
    @notify_email_operator_name = N'DBA', 
    @job_id                     = @jobId OUTPUT;
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback;

-- Step 1: Don CommandLog
EXEC @ReturnCode = msdb.dbo.sp_add_jobstep 
    @job_id                 = @jobId, 
    @step_name              = N'Step 1 - Clear old Ola command log', 
    @step_id                = 1, 
    @cmdexec_success_code   = 0, 
    @on_success_action      = 3, -- Qua buoc tiep theo
    @on_success_step_id     = 0, 
    @on_fail_action         = 3, -- Du loi van tiep tuc chay Reorganize buoc 2
    @on_fail_step_id        = 0, 
    @retry_attempts         = 1, 
    @retry_interval         = 1, 
    @os_run_priority        = 0, 
    @subsystem              = N'TSQL', 
    @command                = N'EXEC DbaMonitor.dbo.usp_ClearCommandLog @RetentionDays = 30;', 
    @database_name          = N'DbaMonitor', 
    @flags                  = 0;
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback;

-- Step 2: Reorganize
EXEC @ReturnCode = msdb.dbo.sp_add_jobstep 
    @job_id                 = @jobId, 
    @step_name              = N'Step 2 - Reorganize Index', 
    @step_id                = 2, 
    @cmdexec_success_code   = 0, 
    @on_success_action      = 1, 
    @on_success_step_id     = 0, 
    @on_fail_action         = 2, 
    @on_fail_step_id        = 0, 
    @retry_attempts         = 2, -- Thu lai 2 lan neu vuong LockTimeout 300s
    @retry_interval         = 5, -- Cho 5 phut moi retry
    @os_run_priority        = 0, 
    @subsystem              = N'TSQL', 
    @command                = N'EXEC DbaMonitor.dbo.usp_AgReorganizeIndex;', 
    @database_name          = N'DbaMonitor', 
    @flags                  = 0;
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback;

EXEC @ReturnCode = msdb.dbo.sp_update_job @job_id = @jobId, @start_step_id = 1;
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback;

-- Schedule: Hang ngay tu Thu 2 den Thu 7 (luc 03:00 Sang)
EXEC @ReturnCode = msdb.dbo.sp_add_jobschedule 
    @job_id                 = @jobId, 
    @name                   = N'ReorganizeSchedule_Mon_To_Sat', 
    @enabled                = 1, 
    @freq_type              = 8,  -- Weekly
    @freq_interval          = 126, -- Thu 2 den Thu 7 (2+4+8+16+32+64 = 126, bo Chu Nhat de chay Rebuild)
    @freq_subday_type       = 1, 
    @freq_subday_interval   = 0, 
    @freq_relative_interval = 0, 
    @freq_recurrence_factor = 1, 
    @active_start_date      = 20260101, 
    @active_end_date        = 99991231, 
    @active_start_time      = 30000, -- 03:00:00 AM
    @active_end_time        = 235959;
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback;

EXEC @ReturnCode = msdb.dbo.sp_add_jobserver @job_id = @jobId, @server_name = N'(local)';
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback;

COMMIT TRANSACTION;
GOTO EndSaveJob2;

QuitWithRollback:
    IF (@@TRANCOUNT > 0) ROLLBACK TRANSACTION;
EndSaveJob2:
GO

--------------------------------------------------------------------------------
-- 3. JOB: RebuildIndex
--------------------------------------------------------------------------------
IF EXISTS (SELECT job_id FROM msdb.dbo.sysjobs WHERE name = N'RebuildIndex')
BEGIN
    EXEC msdb.dbo.sp_delete_job @job_name = N'RebuildIndex', @delete_unused_schedule = 1;
END;
GO

BEGIN TRANSACTION;
DECLARE @ReturnCode INT = 0;
DECLARE @jobId BINARY(16);

EXEC @ReturnCode = msdb.dbo.sp_add_job 
    @job_name                   = N'RebuildIndex', 
    @enabled                    = 1, 
    @notify_level_eventlog      = 0, 
    @notify_level_email         = 2, 
    @notify_level_netsend       = 0, 
    @notify_level_page          = 0, 
    @delete_level               = 0, 
    @description                = N'Rebuild toan dien cac index phan manh cao vao cuoi tuan.', 
    @category_name              = N'Database Maintenance', 
    @owner_login_name           = N'sa', 
    @notify_email_operator_name = N'DBA', 
    @job_id                     = @jobId OUTPUT;
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback;

-- Step 1
EXEC @ReturnCode = msdb.dbo.sp_add_jobstep 
    @job_id                 = @jobId, 
    @step_name              = N'Step 1 - Rebuild Index via Ola and Guard', 
    @step_id                = 1, 
    @cmdexec_success_code   = 0, 
    @on_success_action      = 1, 
    @on_success_step_id     = 0, 
    @on_fail_action         = 2, 
    @on_fail_step_id        = 0, 
    @retry_attempts         = 1,  -- Thu lai duy nhat 1 lan
    @retry_interval         = 20, -- Cho 20 phut de AG Redo queue xa bot log
    @os_run_priority        = 0, 
    @subsystem              = N'TSQL', 
    @command                = N'EXEC DbaMonitor.dbo.usp_AgRebuildIndex;', 
    @database_name          = N'DbaMonitor', 
    @flags                  = 0;
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback;

EXEC @ReturnCode = msdb.dbo.sp_update_job @job_id = @jobId, @start_step_id = 1;
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback;

-- Schedule: Chu Nhat hang tuan luc 20:00 (8:00 PM)
EXEC @ReturnCode = msdb.dbo.sp_add_jobschedule 
    @job_id                 = @jobId, 
    @name                   = N'RebuildIndexSchedule_Sunday_Night', 
    @enabled                = 1, 
    @freq_type              = 8, -- Weekly
    @freq_interval          = 1, -- Chu Nhat (1 = Sunday)
    @freq_subday_type       = 1, 
    @freq_subday_interval   = 0, 
    @freq_relative_interval = 0, 
    @freq_recurrence_factor = 1, 
    @active_start_date      = 20260101, 
    @active_end_date        = 99991231, 
    @active_start_time      = 200000, -- 08:00:00 PM (20000 trong script goc la 02:00:00 AM)
    @active_end_time        = 235959;
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback;

EXEC @ReturnCode = msdb.dbo.sp_add_jobserver @job_id = @jobId, @server_name = N'(local)';
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback;

COMMIT TRANSACTION;
GOTO EndSaveJob3;

QuitWithRollback:
    IF (@@TRANCOUNT > 0) ROLLBACK TRANSACTION;
EndSaveJob3:
GO
```

### Các mục tiêu Monitor:
#### 1. DBA - HealthCheck - Metric Collection
- Chu kỳ: Chạy liên tục 5 phút / lần.
- Ý nghĩa & Mục đích:
- Chụp lát cắt hiệu năng tức thời (Near Real-time Performance)-> Thu thập các chỉ số biến động nhanh như % CPU, 
số task đang xếp hàng đợi core xử lý (Runnable Tasks), áp lực thiếu bộ nhớ RAM (Memory Grants Pending, PLE).
- Lưu vết I/O và Wait Stats: Ghi nhận số liệu tích lũy về đọc/ghi trên từng file dữ liệu và các 
thời gian chờ (wait types). Các số liệu 5 phút này là nguyên liệu sống để tính toán độ trễ đĩa (I/O latency) 
và điểm nghẽn hiệu năng theo phương pháp Delta sau này.
- Bắt vết Deadlock tự động: Đọc file Extended Events (.xel) để gom ngay các đồ thị Deadlock (XML Graph) 
vừa phát sinh, giúp DBA không bị mất dấu vết khi file log bị xoay vòng (rollover).
- Sử dụng Store Procedure: DbaMonitor.dbo.usp_CollectSnapPerformance; EXEC DbaMonitor.dbo.usp_CollectDeadlockHistory;
#### 2. DBA - HealthCheck - Daily Operational Assessment
- Chu kỳ: Chạy hàng ngày vào 06:00 sáng.
- Ý nghĩa & Mục đích:
- Báo cáo tình trạng hoạt động đầu ngày (Operational Readiness) -> Được hẹn giờ chạy trước khi bước vào 
giờ làm việc hành chính, giúp DBA nắm bắt ngay toàn bộ sức khỏe hệ thống.
- Đánh giá các rủi ro vận hành cốt lõi:
- Các service chính (Engine, Agent) có đang chạy không.
- Ổ đĩa còn đủ dung lượng an toàn không.
- Đã có bản Full/Log Backup hợp lệ chưa hay bị trễ (RPO).
- Có job nào bị lỗi trong 24h qua chưa được xử lý không.
- TempDB có bị phình bất thường bởi Version Store hay câu lệnh query rác không.
- Trạng thái đồng bộ của cụm AlwaysOn (Lag send/redo queue).
-  Gửi email cảnh báo: Tự động sinh báo cáo HTML trực quan và gửi qua Database Mail đến DBA nếu phát hiện bất kỳ cảnh báo mức WARN hoặc CRITICAL.
- Sử dụng Store Procedure: usp_ExecuteDailyHealthCheckAndNotify
#### 3. DBA - HealthCheck - Daily Storage & Maintenance
- Chu kỳ: Chạy hàng ngày vào 23:50 đêm.
- Ý nghĩa & Mục đích:
- Ghi nhận mốc tăng trưởng dung lượng (Storage Baseline) -> Đo đạc dung lượng thực tế của từng 
phân vùng ổ cứng (Volume Mount Point) và kích thước từng database (Data MB, Log MB) tại thời điểm cuối ngày. 
Dữ liệu này dùng để dự báo khi nào server sẽ hết dung lượng đĩa (Disk Runway).
- Tự dọn dẹp và duy trì hiệu năng database giám sát (Data Retention/Purge):
- Xóa dọn các bản ghi metric 5 phút và deadlock đã cũ hơn 90 ngày.
- Xóa báo cáo kiểm tra đã cũ hơn 2 năm.
- Dùng cơ chế xóa ngắt quãng theo từng lô nhỏ (TOP 10000 kèm WAITFOR DELAY), tránh tình trạng phình 
transaction log và không gây lock/block đến các tác vụ khác.
#### 4. DBA - HealthCheck - Weekly Comprehensive Assessment
- Chu kỳ: Chạy hàng tuần vào 06:00 sáng Chủ nhật.
- Ý nghĩa & Mục đích:
- Báo cáo tổng kết chuyên sâu (Deep-dive Audit) -> Chạy toàn bộ các đánh giá thường ngày kèm thêm 2 
phân hệ phân tích nặng: Hiệu năng trung hạn và Dung lượng dự phóng.
- Phân tích bức tranh toàn cảnh:
- CPU 30 ngày: Tính toán mức tiêu thụ CPU trung bình cả tháng và tổng số giờ CPU bị quá tải trên 80%.
- I/O Latency Delta: Tính độ trễ đọc/ghi thực tế (ms) của ổ cứng trong 30 ngày qua thay vì nhìn con số tức thời.
- Top Wait Stats 7 ngày: Chỉ rõ tuần qua SQL Server mất nhiều thời gian chờ đợi tài nguyên nào nhất 
(CPU, Disk I/O, Lock hay Network).
- Dự báo cạn đĩa (Runway Forecast): Tính tốc độ tăng trưởng GB/tháng và cảnh báo còn bao nhiêu tháng nữa 
thì ổ cứng sẽ chạm mức sàn nguy hiểm.
- Gửi email báo cáo tuần để DBA và IT Lead có căn cứ lập kế hoạch bảo trì, tối ưu chỉ mục (index) hoặc 
đề xuất nâng cấp phần cứng."

#### #### Script

/* ============================================================================
   DBA MONITOR - HỆ THỐNG GIÁM SÁT SQL SERVER DÙNG BRENT OZAR FIRST RESPONDER KIT

   ĐIỀU KIỆN TIÊN QUYẾT:
   - Download First Responder Kit (FRK) của Brent Ozar tại repo chính thức 
   - Cài đặt bằng cách chạy Install-All-Scripts.sql(vào database monitor: DbaMonitor)
   - Trước khi CHẠY THẬT trên production, hãy chạy trước kiểm tra thủ công một lần để chắc chắn xác nhận tên cột 
   thực tế, danh sách pattern khớp với cài đặt.	 
   ============================================================================ */

### PHẦN 1: KHỞI TẠO DATABASE, TABLES & TOÀN BỘ INDEXES

- Khuyến nghị DBA: Đặt database giám sát ở SIMPLE recovery model để tránh phình file log
```sql
USE DbaMonitor;
GO
ALTER DATABASE DbaMonitor SET RECOVERY SIMPLE;
```
- =========================================================================
- 1. BẢNG GHI NHẬN LỖI NỘI BỘ (Chống nuốt lỗi trong các khối CATCH)
- =========================================================================
```sql
USE DbaMonitor;
GO

IF OBJECT_ID('dbo.DbaMonitorErrorLog', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.DbaMonitorErrorLog (
        ErrorID BIGINT IDENTITY(1,1) NOT NULL,
        ErrorTime DATETIME2(0) NOT NULL CONSTRAINT DF_DbaMonitorErrorLog_ErrorTime DEFAULT SYSDATETIME(),
        ProcedureName NVARCHAR(128) NOT NULL,
        ErrorStep NVARCHAR(100) NOT NULL,
        ErrorMessage NVARCHAR(4000) NOT NULL,
        ErrorLine INT NOT NULL,
        CONSTRAINT PK_DbaMonitorErrorLog PRIMARY KEY CLUSTERED (ErrorID)
    );

    CREATE NONCLUSTERED INDEX IX_DbaMonitorErrorLog_ErrorTime 
    ON dbo.DbaMonitorErrorLog(ErrorTime);
END;
GO
```
- =========================================================================
- 2. BẢNG LƯU TRỮ METRIC HIỆU NĂNG TỨC THỜI (5 PHÚT)
- =========================================================================
```sql
USE DbaMonitor;
GO
IF OBJECT_ID('dbo.PerformanceSnapHistory', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.PerformanceSnapHistory (
        SnapID BIGINT IDENTITY(1,1) NOT NULL,
        SnapTime DATETIME2(0) NOT NULL CONSTRAINT DF_PerformanceSnapHistory_SnapTime DEFAULT SYSDATETIME(),
        CpuSqlPercent TINYINT NOT NULL,
        CpuIdlePercent TINYINT NOT NULL,
        CpuOtherPercent AS (100 - CpuSqlPercent - CpuIdlePercent),
        PageLifeExpectancy INT NOT NULL,
        MemoryGrantsPending INT NOT NULL,
        RunnableTasksCount INT NOT NULL,
        CONSTRAINT PK_PerformanceSnapHistory PRIMARY KEY CLUSTERED (SnapID)
    );

    CREATE NONCLUSTERED INDEX IX_PerformanceSnapHistory_SnapTime 
    ON dbo.PerformanceSnapHistory(SnapTime)
    INCLUDE (CpuSqlPercent, CpuIdlePercent, PageLifeExpectancy, MemoryGrantsPending, RunnableTasksCount);
END;
GO
```
- =========================================================================
- 3. BẢNG LƯU TRỮ I/O VIRTUAL FILE STATS TÍCH LŨY (5 PHÚT)
- =========================================================================
```sql
USE DbaMonitor;
GO
IF OBJECT_ID('dbo.FileIOStatsSnapshot', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.FileIOStatsSnapshot (
        SnapTime DATETIME2(0) NOT NULL CONSTRAINT DF_FileIOStatsSnapshot_SnapTime DEFAULT SYSDATETIME(),
        DatabaseID SMALLINT NOT NULL,
        FileID SMALLINT NOT NULL,
        DatabaseName NVARCHAR(128) NOT NULL,
        LogicalFileName NVARCHAR(128) NOT NULL,
        PhysicalName NVARCHAR(260) NOT NULL,
        NumOfReads BIGINT NOT NULL,
        IoStallReadMs BIGINT NOT NULL,
        NumOfWrites BIGINT NOT NULL,
        IoStallWriteMs BIGINT NOT NULL,
        SizeOnDiskMB DECIMAL(18,2) NOT NULL,
        CONSTRAINT PK_FileIOStatsSnapshot PRIMARY KEY CLUSTERED (SnapTime, DatabaseID, FileID)
    );

    CREATE NONCLUSTERED INDEX IX_FileIOStatsSnapshot_DbFile_SnapTime
    ON dbo.FileIOStatsSnapshot (DatabaseID, FileID, SnapTime)
    INCLUDE (NumOfReads, IoStallReadMs, NumOfWrites, IoStallWriteMs);
END;
GO
```
- =========================================================================
- 4. BẢNG LƯU DUNG LƯỢNG BASELINE PHÂN VÙNG Ổ CỨNG (23:50 ĐÊM)
- =========================================================================
```sql
USE DbaMonitor;
GO
IF OBJECT_ID('dbo.StorageVolumeBaseline', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.StorageVolumeBaseline (
        SnapDate DATE NOT NULL,
        VolumeMountPoint NVARCHAR(260) NOT NULL,
        TotalSpaceGB DECIMAL(18,2) NOT NULL,
        AvailableSpaceGB DECIMAL(18,2) NOT NULL,
        FreeSpacePercent AS CAST((AvailableSpaceGB / NULLIF(TotalSpaceGB, 0)) * 100 AS DECIMAL(5,2)),
        CONSTRAINT PK_StorageVolumeBaseline PRIMARY KEY CLUSTERED (SnapDate, VolumeMountPoint)
    );
END;
GO
```
- =========================================================================
- 5. BẢNG LƯU DUNG LƯỢNG BASELINE TỪNG DATABASE (23:50 ĐÊM)
- =========================================================================
```sql
USE DbaMonitor;
GO
IF OBJECT_ID('dbo.StorageDatabaseBaseline', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.StorageDatabaseBaseline (
        SnapDate DATE NOT NULL,
        DatabaseName NVARCHAR(128) NOT NULL,
        DataFileMB DECIMAL(18,2) NOT NULL,
        LogFileMB DECIMAL(18,2) NOT NULL,
        TotalMB AS (DataFileMB + LogFileMB),
        CONSTRAINT PK_StorageDatabaseBaseline PRIMARY KEY CLUSTERED (SnapDate, DatabaseName)
    );
END;
GO
```
- =========================================================================
- 6. BẢNG AUDIT LOG KẾT QUẢ ĐÁNH GIÁ SỨC KHỎE ĐẦU NGÀY (06:00 SÁNG)
- =========================================================================
```sql
USE DbaMonitor;
GO
IF OBJECT_ID('dbo.DailyCheckAuditLog', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.DailyCheckAuditLog (
        AuditID BIGINT IDENTITY(1,1) NOT NULL,
        CheckDate DATE NOT NULL,
        CheckCategory VARCHAR(50) NOT NULL,
        SeverityLevel VARCHAR(10) NOT NULL,
        CheckDetails NVARCHAR(MAX) NOT NULL,
        CONSTRAINT PK_DailyCheckAuditLog PRIMARY KEY CLUSTERED (AuditID)
    );

    CREATE NONCLUSTERED INDEX IX_DailyCheckAuditLog_CheckDate 
    ON dbo.DailyCheckAuditLog(CheckDate);
END;
GO
```
- =========================================================================
- 7. KHỞI TẠO BẢNG OUTPUT CỦA FRK & TẠO NON-CLUSTERED INDEXES
- =========================================================================

- Tạo Index tăng tốc truy vấn lọc ngày và dọn dẹp (Purge)
```sql
USE DbaMonitor;
GO
IF OBJECT_ID('dbo.BlitzFirst', 'U') IS NOT NULL AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_BlitzFirst_CheckDate' AND object_id = OBJECT_ID('dbo.BlitzFirst'))
    CREATE NONCLUSTERED INDEX IX_BlitzFirst_CheckDate ON dbo.BlitzFirst (CheckDate, ServerName);

IF OBJECT_ID('dbo.BlitzFirst_WaitStats', 'U') IS NOT NULL AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_BlitzFirst_WaitStats_CheckDate' AND object_id = OBJECT_ID('dbo.BlitzFirst_WaitStats'))
    CREATE NONCLUSTERED INDEX IX_BlitzFirst_WaitStats_CheckDate ON dbo.BlitzFirst_WaitStats (CheckDate, ServerName) INCLUDE (wait_type, wait_time_ms);

IF OBJECT_ID('dbo.BlitzFirst_FileStats', 'U') IS NOT NULL AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_BlitzFirst_FileStats_CheckDate' AND object_id = OBJECT_ID('dbo.BlitzFirst_FileStats'))
    CREATE NONCLUSTERED INDEX IX_BlitzFirst_FileStats_CheckDate ON dbo.BlitzFirst_FileStats (CheckDate, ServerName) INCLUDE (DatabaseName, io_stall_read_ms, io_stall_write_ms);

IF OBJECT_ID('dbo.BlitzFirst_PerfmonStats', 'U') IS NOT NULL AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_BlitzFirst_PerfmonStats_CheckDate' AND object_id = OBJECT_ID('dbo.BlitzFirst_PerfmonStats'))
    CREATE NONCLUSTERED INDEX IX_BlitzFirst_PerfmonStats_CheckDate ON dbo.BlitzFirst_PerfmonStats (CheckDate, ServerName) INCLUDE (counter_name, value_per_second);

IF OBJECT_ID('dbo.BlitzResults', 'U') IS NOT NULL AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_BlitzResults_CheckDate' AND object_id = OBJECT_ID('dbo.BlitzResults'))
    CREATE NONCLUSTERED INDEX IX_BlitzResults_CheckDate ON dbo.BlitzResults (CheckDate, Priority);

IF OBJECT_ID('dbo.BlitzLockHistory', 'U') IS NOT NULL AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_BlitzLockHistory_event_date' AND object_id = OBJECT_ID('dbo.BlitzLockHistory'))
    CREATE NONCLUSTERED INDEX IX_BlitzLockHistory_event_date ON dbo.BlitzLockHistory (event_date);
GO
```

### PHẦN 2: CÁC STORED PROCEDURE TỐI ƯU TOÀN DIỆN

- =========================================================================
- SP 1: THU THẬP METRIC 5 PHÚT (CPU, RAM, WAIT STATS, I/O)
- =========================================================================
```sql
USE DbaMonitor;
GO
CREATE OR ALTER PROCEDURE dbo.usp_CollectSnapPerformance
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Now DATETIME2(0) = SYSDATETIME();

    -- 1. Gọi sp_BlitzFirst với @Seconds = 0 (Snapshot tức thời, không delay sampling)
    BEGIN TRY
        EXEC dbo.sp_BlitzFirst
            @Seconds = 0,
            @OutputDatabaseName = 'DbaMonitor',
            @OutputSchemaName = 'dbo',
            @OutputTableName = 'BlitzFirst',
            @OutputTableNameFileStats = 'BlitzFirst_FileStats',
            @OutputTableNamePerfmonStats = 'BlitzFirst_PerfmonStats',
            @OutputTableNameWaitStats = 'BlitzFirst_WaitStats',
            @OutputType = 'NONE';
    END TRY
    BEGIN CATCH
        INSERT INTO dbo.DbaMonitorErrorLog (ProcedureName, ErrorStep, ErrorMessage, ErrorLine)
        VALUES ('usp_CollectSnapPerformance', 'sp_BlitzFirst', ERROR_MESSAGE(), ERROR_LINE());
    END CATCH;

    -- 2. Chụp Process CPU (SQL) vs Host Idle CPU qua Ring Buffer
    BEGIN TRY
        DECLARE @CpuSql TINYINT = 0, @CpuIdle TINYINT = 0;
        
        SELECT TOP(1)
            @CpuSql = record.value('(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]', 'TINYINT'),
            @CpuIdle = record.value('(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]', 'TINYINT')
        FROM (
            SELECT CAST(record AS XML) AS record 
            FROM sys.dm_os_ring_buffers 
            WHERE ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR' 
              AND record LIKE '%<SystemHealth>%'
        ) AS x
        ORDER BY record.value('(./Record/@id)[1]', 'BIGINT') DESC;

        -- 3. Chụp PLE trung bình Multi-NUMA, Memory Grants Pending, Runnable Tasks
        DECLARE @AvgPLE INT = 0, @MemPending INT = 0, @RunnableTasks INT = 0;

        SELECT @AvgPLE = ISNULL(AVG(cntr_value), 0)
        FROM sys.dm_os_performance_counters 
        WHERE counter_name = 'Page life expectancy' 
          AND object_name LIKE '%Buffer Node%';

        SELECT @MemPending = ISNULL(cntr_value, 0)
        FROM sys.dm_os_performance_counters 
        WHERE counter_name = 'Memory Grants Pending';

        SELECT @RunnableTasks = ISNULL(SUM(runnable_tasks_count), 0)
        FROM sys.dm_os_schedulers 
        WHERE status = 'VISIBLE ONLINE';

        INSERT INTO dbo.PerformanceSnapHistory 
            (SnapTime, CpuSqlPercent, CpuIdlePercent, PageLifeExpectancy, MemoryGrantsPending, RunnableTasksCount)
        VALUES 
            (@Now, ISNULL(@CpuSql, 0), ISNULL(@CpuIdle, 0), @AvgPLE, @MemPending, @RunnableTasks);
    END TRY
    BEGIN CATCH
        INSERT INTO dbo.DbaMonitorErrorLog (ProcedureName, ErrorStep, ErrorMessage, ErrorLine)
        VALUES ('usp_CollectSnapPerformance', 'RingBuffer_Perfmon', ERROR_MESSAGE(), ERROR_LINE());
    END CATCH;

    -- 4. Chụp vết File I/O Stats tích lũy từng file dữ liệu
    BEGIN TRY
        INSERT INTO dbo.FileIOStatsSnapshot
            (SnapTime, DatabaseID, FileID, DatabaseName, LogicalFileName, PhysicalName, 
             NumOfReads, IoStallReadMs, NumOfWrites, IoStallWriteMs, SizeOnDiskMB)
        SELECT 
            @Now,
            fs.database_id,
            fs.file_id,
            DB_NAME(fs.database_id),
            mf.name,
            mf.physical_name,
            fs.num_of_reads,
            fs.io_stall_read_ms,
            fs.num_of_writes,
            fs.io_stall_write_ms,
            CAST((fs.size_on_disk_bytes / 1048576.0) AS DECIMAL(18,2))
        FROM sys.dm_io_virtual_file_stats(NULL, NULL) fs
        INNER JOIN sys.master_files mf 
            ON fs.database_id = mf.database_id AND fs.file_id = mf.file_id;
    END TRY
    BEGIN CATCH
        INSERT INTO dbo.DbaMonitorErrorLog (ProcedureName, ErrorStep, ErrorMessage, ErrorLine)
        VALUES ('usp_CollectSnapPerformance', 'FileIOStatsSnapshot', ERROR_MESSAGE(), ERROR_LINE());
    END CATCH;
END;
GO
```

- =========================================================================
- SP 2: THU THẬP DEADLOCK TỰ ĐỘNG BẰNG SP_BLITZLOCK (Đọc trực tiếp file .xel)
- =========================================================================
```sql
USE DbaMonitor;
GO
CREATE OR ALTER PROCEDURE dbo.usp_CollectDeadlockHistory
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        EXEC dbo.sp_BlitzLock 
            @OutputDatabaseName = 'DbaMonitor',
            @OutputSchemaName = 'dbo',
            @OutputTableName = 'BlitzLockHistory';
    END TRY
    BEGIN CATCH
        INSERT INTO dbo.DbaMonitorErrorLog (ProcedureName, ErrorStep, ErrorMessage, ErrorLine)
        VALUES ('usp_CollectDeadlockHistory', 'sp_BlitzLock', ERROR_MESSAGE(), ERROR_LINE());
    END CATCH;
END;
GO
```

- ================================================================================================
- DAILY OPERATIONAL ASSESSMENT & ALERT NOTIFICATION
- Daily Operational Assessment (06:00 Sáng)
- Cấu hình @CheckUserDatabaseObjects = 0 và @BringThePain = 0 chạy siêu nhẹ trong 2-3 giây.
- ================================================================================================
```sql
USE DbaMonitor;
GO
CREATE OR ALTER PROCEDURE dbo.usp_ExecuteDailyHealthCheckAndNotify
    @MailProfileName NVARCHAR(128) = 'DBA',
    @RecipientEmail VARCHAR(MAX) = 'nghianl.ts@vietsov.com.vn;lamlh.ts@vietsov.com.vn'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @CheckDate DATE = CAST(SYSDATETIME() AS DATE);
    DECLARE @AlertCount INT = 0;

    CREATE TABLE #DailyIssues (
        Category VARCHAR(50),
        Severity VARCHAR(10),
        Details NVARCHAR(MAX)
    );

    -- 0. TỰ GIÁM SÁT HỆ THỐNG MONITORING (WATCHDOG: 4 Job & Bảng Log lỗi)
    BEGIN TRY
        -- A. Kiểm tra nếu bất kỳ Job cốt lõi nào bị disable
        INSERT INTO #DailyIssues (Category, Severity, Details)
        SELECT 'Monitoring Job Health', 'CRITICAL',
               CONCAT('Job giam sat [', j.name, '] dang bi DISABLE! He thong bi vo hieu hoa.')
        FROM msdb.dbo.sysjobs j
        WHERE j.name IN (
            'DBA - HealthCheck - Metric Collection',
            'DBA - HealthCheck - Daily Operational Assessment',
            'DBA - HealthCheck - Daily Storage & Maintenance',
            'DBA - HealthCheck - Weekly Comprehensive Assessment'
        ) AND j.enabled = 0;

        -- B. Kiểm tra nếu Job 5 phút không chạy thành công trong 30 phút qua
        IF NOT EXISTS (
            SELECT 1 
            FROM msdb.dbo.sysjobs j
            INNER JOIN msdb.dbo.sysjobhistory jh ON j.job_id = jh.job_id
            WHERE j.name = 'DBA - HealthCheck - Metric Collection'
              AND jh.step_id = 0
              AND jh.run_status = 1
              AND msdb.dbo.agent_datetime(jh.run_date, jh.run_time) >= DATEADD(MINUTE, -30, SYSDATETIME())
        )
        BEGIN
            INSERT INTO #DailyIssues (Category, Severity, Details)
            VALUES ('Monitoring Job Health', 'CRITICAL', 'Job [DBA - HealthCheck - Metric Collection] khong co lan chay thanh cong nao trong 30 phut qua!');
        END;

        -- C. Kiểm tra lỗi hệ thống nội bộ ghi trong DbaMonitorErrorLog 24h qua
        INSERT INTO #DailyIssues (Category, Severity, Details)
        SELECT 'Internal Monitoring Error', 'WARN',
               CONCAT('[', ProcedureName, ' / ', ErrorStep, '] luc ', CONVERT(VARCHAR(19), ErrorTime, 120), ': ', ErrorMessage)
        FROM dbo.DbaMonitorErrorLog
        WHERE ErrorTime >= DATEADD(HOUR, -24, SYSDATETIME());
    END TRY
    BEGIN CATCH
        INSERT INTO dbo.DbaMonitorErrorLog (ProcedureName, ErrorStep, ErrorMessage, ErrorLine)
        VALUES ('usp_ExecuteDailyHealthCheckAndNotify', 'Watchdog_MonitoringJobs', ERROR_MESSAGE(), ERROR_LINE());
    END CATCH;

    -- 1. Kiểm tra trạng thái SQL Engine và SQL Agent Service
    BEGIN TRY
        INSERT INTO #DailyIssues (Category, Severity, Details)
        SELECT 'Core Services', 'CRITICAL',
               CONCAT('Dich vu [', servicename, '] dang o trang thai: ', status_desc)
        FROM sys.dm_server_services
        WHERE (servicename LIKE 'SQL Server (%' OR servicename LIKE 'SQL Server Agent (%')
          AND status_desc <> 'Running';
    END TRY
    BEGIN CATCH
        INSERT INTO dbo.DbaMonitorErrorLog (ProcedureName, ErrorStep, ErrorMessage, ErrorLine)
        VALUES ('usp_ExecuteDailyHealthCheckAndNotify', 'CheckServices', ERROR_MESSAGE(), ERROR_LINE());
    END CATCH;

    -- 2. Audit cấu hình qua sp_Blitz: AN TOÀN TUYỆT ĐỐI (Dùng Snapshot Watermark, @CheckUserDatabaseObjects = 0, @BringThePain = 0)
    BEGIN TRY
        DECLARE @BlitzStartTime DATETIMEOFFSET = SYSDATETIMEOFFSET();

        EXEC dbo.sp_Blitz 
            @OutputDatabaseName = 'DbaMonitor',
            @OutputSchemaName = 'dbo',
            @OutputTableName = 'BlitzResults',
            @CheckUserDatabaseObjects = 0, -- Không quét sâu objects của 50+ DBs
            @CheckServerInfo = 1,
            @BringThePain = 0;

        -- Xác định chính xác mốc CheckDate của lần chạy vừa xong
        DECLARE @LatestBlitzDate DATETIMEOFFSET;

        SELECT @LatestBlitzDate = MAX(CheckDate)
        FROM dbo.BlitzResults
        WHERE CheckDate >= DATEADD(MINUTE, -2, @BlitzStartTime); -- Trừ hao 2 phút phòng lệch clock nội bộ

        IF @LatestBlitzDate IS NOT NULL
        BEGIN
            INSERT INTO #DailyIssues (Category, Severity, Details)
            SELECT 'FRK Blitz Finding', 
                   CASE WHEN Priority <= 20 THEN 'CRITICAL' ELSE 'WARN' END,
                   CONCAT('[', FindingsGroup, '] ', Finding, ' - DB: ', ISNULL(DatabaseName, 'Global'), ': ', Details)
            FROM dbo.BlitzResults
            WHERE CheckDate = @LatestBlitzDate -- Khớp CHÍNH XÁC đợt audit vừa chạy
              AND Priority <= 50;
        END;
    END TRY
    BEGIN CATCH
        INSERT INTO dbo.DbaMonitorErrorLog (ProcedureName, ErrorStep, ErrorMessage, ErrorLine)
        VALUES ('usp_ExecuteDailyHealthCheckAndNotify', 'sp_Blitz', ERROR_MESSAGE(), ERROR_LINE());

        INSERT INTO #DailyIssues (Category, Severity, Details)
        VALUES ('FRK Blitz Engine', 'WARN', CONCAT('sp_Blitz gap su co: ', ERROR_MESSAGE()));
    END CATCH;

    -- 3. Kiểm tra SLA Backup (Loại trừ tempdb, model; Full <= 24h & Log <= 30m)
    BEGIN TRY
        INSERT INTO #DailyIssues (Category, Severity, Details)
        SELECT 'Backup SLA', 'CRITICAL',
               CONCAT('Database [', d.name, '] khong co ban FULL backup trong 24 gio qua!')
        FROM sys.databases d
        WHERE d.name NOT IN ('tempdb', 'model') 
          AND d.source_database_id IS NULL 
          AND d.state_desc = 'ONLINE'
          AND NOT EXISTS (
              SELECT 1 FROM msdb.dbo.backupset b 
              WHERE b.database_name = d.name AND b.type = 'D' AND b.backup_finish_date >= DATEADD(HOUR, -24, SYSDATETIME())
          );

        INSERT INTO #DailyIssues (Category, Severity, Details)
        SELECT 'Backup SLA', 'CRITICAL',
               CONCAT('Database [', d.name, '] (FULL recovery) khong co LOG backup trong 30 phut qua!')
        FROM sys.databases d
        WHERE d.recovery_model_desc = 'FULL' 
          AND d.state_desc = 'ONLINE' 
          AND d.name NOT IN ('tempdb', 'model')
          AND NOT EXISTS (
              SELECT 1 FROM msdb.dbo.backupset b 
              WHERE b.database_name = d.name AND b.type = 'L' AND b.backup_finish_date >= DATEADD(MINUTE, -30, SYSDATETIME())
          );
    END TRY
    BEGIN CATCH
        INSERT INTO dbo.DbaMonitorErrorLog (ProcedureName, ErrorStep, ErrorMessage, ErrorLine)
        VALUES ('usp_ExecuteDailyHealthCheckAndNotify', 'CheckBackups', ERROR_MESSAGE(), ERROR_LINE());
    END CATCH;

    -- 4. Kiểm tra AlwaysOn Availability Groups (Lag send/redo queue)
    IF SERVERPROPERTY('IsHadrEnabled') = 1
    BEGIN
        BEGIN TRY
            INSERT INTO #DailyIssues (Category, Severity, Details)
            SELECT 'AlwaysOn Health', 'CRITICAL',
                   CONCAT('AG Replica [', rcs.replica_server_name, '] tren DB [', DB_NAME(drs.database_id), '] lech! Redo Queue: ', 
                          drs.redo_queue_size, ' KB, Send Queue: ', drs.log_send_queue_size, ' KB, State: ', drs.synchronization_health_desc)
            FROM sys.dm_hadr_database_replica_states drs
            INNER JOIN sys.dm_hadr_availability_replica_cluster_states rcs ON drs.replica_id = rcs.replica_id
            WHERE drs.synchronization_health_desc <> 'HEALTHY' 
               OR drs.redo_queue_size > 51200
               OR drs.log_send_queue_size > 51200;
        END TRY
        BEGIN CATCH
            INSERT INTO dbo.DbaMonitorErrorLog (ProcedureName, ErrorStep, ErrorMessage, ErrorLine)
            VALUES ('usp_ExecuteDailyHealthCheckAndNotify', 'CheckAlwaysOn', ERROR_MESSAGE(), ERROR_LINE());
        END CATCH;
    END;

    -- 5. Kiểm tra TempDB phình dung lượng và Version Store
    BEGIN TRY
        INSERT INTO #DailyIssues (Category, Severity, Details)
        SELECT 'TempDB Health', 'WARN',
               CONCAT('TempDB Space can kieng! Free: ', CAST(free_space_mb AS VARCHAR), ' MB, Version Store chiem: ', 
                      CAST(version_store_mb AS VARCHAR), ' MB (', CAST((version_store_mb * 100.0 / total_space_mb) AS DECIMAL(5,2)), '%)')
        FROM (
            SELECT 
                SUM(total_page_count) * 8.0 / 1024.0 AS total_space_mb,
                SUM(unallocated_extent_page_count) * 8.0 / 1024.0 AS free_space_mb,
                SUM(version_store_reserved_page_count) * 8.0 / 1024.0 AS version_store_mb
            FROM tempdb.sys.dm_db_file_space_usage
        ) t
        WHERE free_space_mb < 2048 OR (version_store_mb * 100.0 / total_space_mb) > 30.0;
    END TRY
    BEGIN CATCH
        INSERT INTO dbo.DbaMonitorErrorLog (ProcedureName, ErrorStep, ErrorMessage, ErrorLine)
        VALUES ('usp_ExecuteDailyHealthCheckAndNotify', 'CheckTempDB', ERROR_MESSAGE(), ERROR_LINE());
    END CATCH;

    -- 6. Kiểm tra các SQL Agent Jobs thất bại trong 24h qua
    BEGIN TRY
        INSERT INTO #DailyIssues (Category, Severity, Details)
        SELECT 'SQL Agent Job', 'WARN',
               CONCAT('Job [', j.name, '] that bai luc ', msdb.dbo.agent_datetime(jh.run_date, jh.run_time), '. Message: ', jh.message)
        FROM msdb.dbo.sysjobs j
        INNER JOIN msdb.dbo.sysjobhistory jh ON j.job_id = jh.job_id
        WHERE jh.run_status = 0 AND jh.step_id = 0
          AND msdb.dbo.agent_datetime(jh.run_date, jh.run_time) >= DATEADD(HOUR, -24, SYSDATETIME());
    END TRY
    BEGIN CATCH
        INSERT INTO dbo.DbaMonitorErrorLog (ProcedureName, ErrorStep, ErrorMessage, ErrorLine)
        VALUES ('usp_ExecuteDailyHealthCheckAndNotify', 'CheckJobs', ERROR_MESSAGE(), ERROR_LINE());
    END CATCH;

    -- 7. Kiểm tra phân vùng đĩa cứng (< 15% Free)
    BEGIN TRY
        INSERT INTO #DailyIssues (Category, Severity, Details)
        SELECT DISTINCT 'Disk Space', 'CRITICAL',
               CONCAT('Drive ', vs.volume_mount_point, ' chi con ', CAST(vs.available_bytes / 1073741824.0 AS DECIMAL(10,2)), ' GB (', 
                      CAST((vs.available_bytes * 100.0 / vs.total_bytes) AS DECIMAL(5,2)), '% free)!')
        FROM sys.master_files mf
        CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) vs
        WHERE (vs.available_bytes * 100.0 / vs.total_bytes) < 15.0;
    END TRY
    BEGIN CATCH
        INSERT INTO dbo.DbaMonitorErrorLog (ProcedureName, ErrorStep, ErrorMessage, ErrorLine)
        VALUES ('usp_ExecuteDailyHealthCheckAndNotify', 'CheckDiskSpace', ERROR_MESSAGE(), ERROR_LINE());
    END CATCH;

    -- Ghi nhận dữ liệu vào bảng DailyCheckAuditLog
    INSERT INTO dbo.DailyCheckAuditLog (CheckDate, CheckCategory, SeverityLevel, CheckDetails)
    SELECT @CheckDate, Category, Severity, Details FROM #DailyIssues;

    SELECT @AlertCount = COUNT(*) FROM #DailyIssues;

    -- 8. Gửi mail cảnh báo HTML
    IF @AlertCount > 0
    BEGIN
        DECLARE @HtmlBody NVARCHAR(MAX);
        DECLARE @EmailSubject NVARCHAR(255) = CONCAT('SQL Server Daily Health Alert: [', @@SERVERNAME, '] - ', CAST(@AlertCount AS VARCHAR), ' Issues Found');

        SET @HtmlBody = N'
        <html>
        <head>
            <style>
                body {font-family: Arial, sans-serif; font-size: 13px;}
                table {border-collapse: collapse; width: 100%;}
                th {background-color: #004D40; color: white; text-align: left; padding: 8px;}
                td {border: 1px solid #ddd; padding: 8px;}
                .CRITICAL {background-color: #FFCDD2; color: #B71C1C; font-weight: bold;}
                .WARN {background-color: #FFF9C4; color: #F57F17;}
            </style>
        </head>
        <body>
            <h3>Ket qua Daily Operational Assessment: ' + @@SERVERNAME + N'</h3>
            <p>Phat hien <b>' + CAST(@AlertCount AS VARCHAR) + N'</b> muc can chu y truoc gio lam viec:</p>
            <table>
                <tr><th>Category</th><th>Severity</th><th>Details</th></tr>' +
                CAST((
                    SELECT 
                        td = Category, '',
                        td = Severity, '',
                        td = Details, ''
                    FROM #DailyIssues
                    ORDER BY CASE WHEN Severity = 'CRITICAL' THEN 1 ELSE 2 END
                    FOR XML PATH('tr'), TYPE
                ) AS NVARCHAR(MAX)) +
            N'</table>
            <br/><p><i>Bao cao tao tu dong boi DbaMonitor - Chay luc 06:00 AM hang ngay.</i></p>
        </body></html>';

        EXEC msdb.dbo.sp_send_dbmail
            @profile_name = @MailProfileName,
            @recipients = @RecipientEmail,
            @subject = @EmailSubject,
            @body = @HtmlBody,
            @body_format = 'HTML';
    END;
END;
GO
```

- =========================================================================
- DAILY STORAGE RECORDING & BATCH RETENTION PURGE
- Daily Storage & Maintenance (23:50 Đêm)
- Sử dụng CTE chuẩn hóa để lưu baseline và dọn dẹp theo batch 10.000 dòng.
- =========================================================================
```sql 
USE [DbaMonitor];
GO

ALTER PROCEDURE [dbo].[usp_ExecuteDailyHealthCheckAndNotify]
    @MailProfileName NVARCHAR(128) = 'DBA',
    @RecipientEmail VARCHAR(MAX) = 'nghianl.ts@vietsov.com.vn;lamlh.ts@vietsov.com.vn'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @CheckDate DATE = CAST(SYSDATETIME() AS DATE);
    DECLARE @AlertCount INT = 0;

    CREATE TABLE #DailyIssues (
        Category VARCHAR(50),
        Severity VARCHAR(10),
        Details NVARCHAR(MAX)
    );

    -- 0. TỰ GIÁM SÁT HỆ THỐNG MONITORING (WATCHDOG: 4 Job & Bảng Log lỗi)
    BEGIN TRY
        -- A. Kiểm tra nếu bất kỳ Job cốt lõi nào bị disable
        INSERT INTO #DailyIssues (Category, Severity, Details)
        SELECT 'Monitoring Job Health', 'CRITICAL',
               CONCAT('Job giam sat [', j.name, '] dang bi DISABLE! He thong bi vo hieu hoa.')
        FROM msdb.dbo.sysjobs j
        WHERE j.name IN (
            'DBA - HealthCheck - Metric Collection',
            'DBA - HealthCheck - Daily Operational Assessment',
            'DBA - HealthCheck - Daily Storage & Maintenance',
            'DBA - HealthCheck - Weekly Comprehensive Assessment'
        ) AND j.enabled = 0;

        -- B. Kiểm tra nếu Job 5 phút không chạy thành công trong 30 phút qua
        IF NOT EXISTS (
            SELECT 1 
            FROM msdb.dbo.sysjobs j
            INNER JOIN msdb.dbo.sysjobhistory jh ON j.job_id = jh.job_id
            WHERE j.name = 'DBA - HealthCheck - Metric Collection'
              AND jh.step_id = 0
              AND jh.run_status = 1
              AND msdb.dbo.agent_datetime(jh.run_date, jh.run_time) >= DATEADD(MINUTE, -30, SYSDATETIME())
        )
        BEGIN
            INSERT INTO #DailyIssues (Category, Severity, Details)
            VALUES ('Monitoring Job Health', 'CRITICAL', 'Job [DBA - HealthCheck - Metric Collection] khong co lan chay thanh cong nao trong 30 phut qua!');
        END;

        -- C. Kiểm tra lỗi hệ thống nội bộ ghi trong DbaMonitorErrorLog 24h qua
        INSERT INTO #DailyIssues (Category, Severity, Details)
        SELECT 'Internal Monitoring Error', 'WARN',
               CONCAT('[', ProcedureName, ' / ', ErrorStep, '] luc ', CONVERT(VARCHAR(19), ErrorTime, 120), ': ', ErrorMessage)
        FROM dbo.DbaMonitorErrorLog
        WHERE ErrorTime >= DATEADD(HOUR, -24, SYSDATETIME());
    END TRY
    BEGIN CATCH
        INSERT INTO dbo.DbaMonitorErrorLog (ProcedureName, ErrorStep, ErrorMessage, ErrorLine)
        VALUES ('usp_ExecuteDailyHealthCheckAndNotify', 'Watchdog_MonitoringJobs', ERROR_MESSAGE(), ERROR_LINE());
    END CATCH;

    -- 1. Kiểm tra trạng thái SQL Engine và SQL Agent Service
    BEGIN TRY
        INSERT INTO #DailyIssues (Category, Severity, Details)
        SELECT 'Core Services', 'CRITICAL',
               CONCAT('Dich vu [', servicename, '] dang o trang thai: ', status_desc)
        FROM sys.dm_server_services
        WHERE (servicename LIKE 'SQL Server (%' OR servicename LIKE 'SQL Server Agent (%')
          AND status_desc <> 'Running';
    END TRY
    BEGIN CATCH
        INSERT INTO dbo.DbaMonitorErrorLog (ProcedureName, ErrorStep, ErrorMessage, ErrorLine)
        VALUES ('usp_ExecuteDailyHealthCheckAndNotify', 'CheckServices', ERROR_MESSAGE(), ERROR_LINE());
    END CATCH;

    -- 2. Audit cấu hình qua sp_Blitz
    BEGIN TRY
        DECLARE @BlitzStartTime DATETIMEOFFSET = SYSDATETIMEOFFSET();

        EXEC dbo.sp_Blitz 
            @OutputDatabaseName = 'DbaMonitor',
            @OutputSchemaName = 'dbo',
            @OutputTableName = 'BlitzResults',
            @CheckUserDatabaseObjects = 0, -- Không quét sâu objects của 50+ DBs
            @CheckServerInfo = 1,
            @BringThePain = 0;

        DECLARE @LatestBlitzDate DATETIMEOFFSET;

        SELECT @LatestBlitzDate = MAX(CheckDate)
        FROM dbo.BlitzResults
        WHERE CheckDate >= DATEADD(MINUTE, -2, @BlitzStartTime);

        IF @LatestBlitzDate IS NOT NULL
        BEGIN
            INSERT INTO #DailyIssues (Category, Severity, Details)
            SELECT 'FRK Blitz Finding', 
                   CASE WHEN Priority <= 20 THEN 'CRITICAL' ELSE 'WARN' END,
                   CONCAT('[', FindingsGroup, '] ', Finding, ' - DB: ', ISNULL(DatabaseName, 'Global'), ': ', Details)
            FROM dbo.BlitzResults
            WHERE CheckDate = @LatestBlitzDate
              AND Priority <= 50
              -- [BỎ CẢNH BÁO BACKUP DO DÙNG VEEAM]
              AND FindingsGroup <> 'Backup'
              AND Finding NOT LIKE '%Backup%'
              -- [LOẠI BỎ HÀNG THÔNG TIN PHIÊN BẢN FIRST RESPONDER KIT]
              AND Finding NOT LIKE '%First Responder Kit%'
              AND Finding NOT LIKE '%sp_Blitz%';
        END;
    END TRY
    BEGIN CATCH
        INSERT INTO dbo.DbaMonitorErrorLog (ProcedureName, ErrorStep, ErrorMessage, ErrorLine)
        VALUES ('usp_ExecuteDailyHealthCheckAndNotify', 'sp_Blitz', ERROR_MESSAGE(), ERROR_LINE());

        INSERT INTO #DailyIssues (Category, Severity, Details)
        VALUES ('FRK Blitz Engine', 'WARN', CONCAT('sp_Blitz gap su co: ', ERROR_MESSAGE()));
    END CATCH;

    -- 3. Kiểm tra SLA Backup (Log backup <= 30m cho FULL recovery model)
    BEGIN TRY
        INSERT INTO #DailyIssues (Category, Severity, Details)
        SELECT 'Backup SLA', 'CRITICAL',
               CONCAT('Database [', d.name, '] (FULL recovery) khong co LOG backup trong 30 phut qua!')
        FROM sys.databases d
        WHERE d.recovery_model_desc = 'FULL' 
          AND d.state_desc = 'ONLINE' 
          AND d.name NOT IN ('tempdb', 'model')
          AND NOT EXISTS (
              SELECT 1 FROM msdb.dbo.backupset b 
              WHERE b.database_name = d.name AND b.type = 'L' AND b.backup_finish_date >= DATEADD(MINUTE, -30, SYSDATETIME())
          );
    END TRY
    BEGIN CATCH
        INSERT INTO dbo.DbaMonitorErrorLog (ProcedureName, ErrorStep, ErrorMessage, ErrorLine)
        VALUES ('usp_ExecuteDailyHealthCheckAndNotify', 'CheckBackups', ERROR_MESSAGE(), ERROR_LINE());
    END CATCH;

    -- 4. Kiểm tra AlwaysOn Availability Groups (Lag send/redo queue)
    IF SERVERPROPERTY('IsHadrEnabled') = 1
    BEGIN
        BEGIN TRY
            INSERT INTO #DailyIssues (Category, Severity, Details)
            SELECT 'AlwaysOn Health', 'CRITICAL',
                   CONCAT('AG Replica [', rcs.replica_server_name, '] tren DB [', DB_NAME(drs.database_id), '] lech! Redo Queue: ', 
                          drs.redo_queue_size, ' KB, Send Queue: ', drs.log_send_queue_size, ' KB, State: ', drs.synchronization_health_desc)
            FROM sys.dm_hadr_database_replica_states drs
            INNER JOIN sys.dm_hadr_availability_replica_cluster_states rcs ON drs.replica_id = rcs.replica_id
            WHERE drs.synchronization_health_desc <> 'HEALTHY' 
               OR drs.redo_queue_size > 51200
               OR drs.log_send_queue_size > 51200;
        END TRY
        BEGIN CATCH
            INSERT INTO dbo.DbaMonitorErrorLog (ProcedureName, ErrorStep, ErrorMessage, ErrorLine)
            VALUES ('usp_ExecuteDailyHealthCheckAndNotify', 'CheckAlwaysOn', ERROR_MESSAGE(), ERROR_LINE());
        END CATCH;
    END;

    -- 5. Kiểm tra TempDB phình dung lượng và Version Store
    BEGIN TRY
        INSERT INTO #DailyIssues (Category, Severity, Details)
        SELECT 'TempDB Health', 'WARN',
               CONCAT('TempDB Space can kieng! Free: ', CAST(free_space_mb AS VARCHAR), ' MB, Version Store chiem: ', 
                      CAST(version_store_mb AS VARCHAR), ' MB (', CAST((version_store_mb * 100.0 / total_space_mb) AS DECIMAL(5,2)), '%)')
        FROM (
            SELECT 
                SUM(total_page_count) * 8.0 / 1024.0 AS total_space_mb,
                SUM(unallocated_extent_page_count) * 8.0 / 1024.0 AS free_space_mb,
                SUM(version_store_reserved_page_count) * 8.0 / 1024.0 AS version_store_mb
            FROM tempdb.sys.dm_db_file_space_usage
        ) t
        WHERE free_space_mb < 2048 OR (version_store_mb * 100.0 / total_space_mb) > 30.0;
    END TRY
    BEGIN CATCH
        INSERT INTO dbo.DbaMonitorErrorLog (ProcedureName, ErrorStep, ErrorMessage, ErrorLine)
        VALUES ('usp_ExecuteDailyHealthCheckAndNotify', 'CheckTempDB', ERROR_MESSAGE(), ERROR_LINE());
    END CATCH;

    -- 6. Kiểm tra các SQL Agent Jobs thất bại trong 24h qua
    BEGIN TRY
        INSERT INTO #DailyIssues (Category, Severity, Details)
        SELECT 'SQL Agent Job', 'WARN',
               CONCAT('Job [', j.name, '] that bai luc ', msdb.dbo.agent_datetime(jh.run_date, jh.run_time), '. Message: ', jh.message)
        FROM msdb.dbo.sysjobs j
        INNER JOIN msdb.dbo.sysjobhistory jh ON j.job_id = jh.job_id
        WHERE jh.run_status = 0 AND jh.step_id = 0
          AND msdb.dbo.agent_datetime(jh.run_date, jh.run_time) >= DATEADD(HOUR, -24, SYSDATETIME());
    END TRY
    BEGIN CATCH
        INSERT INTO dbo.DbaMonitorErrorLog (ProcedureName, ErrorStep, ErrorMessage, ErrorLine)
        VALUES ('usp_ExecuteDailyHealthCheckAndNotify', 'CheckJobs', ERROR_MESSAGE(), ERROR_LINE());
    END CATCH;

    -- 7. Kiểm tra phân vùng đĩa cứng (< 15% Free)
    BEGIN TRY
        INSERT INTO #DailyIssues (Category, Severity, Details)
        SELECT DISTINCT 'Disk Space', 'CRITICAL',
               CONCAT('Drive ', vs.volume_mount_point, ' chi con ', CAST(vs.available_bytes / 1073741824.0 AS DECIMAL(10,2)), ' GB (', 
                      CAST((vs.available_bytes * 100.0 / vs.total_bytes) AS DECIMAL(5,2)), '% free)!')
        FROM sys.master_files mf
        CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) vs
        WHERE (vs.available_bytes * 100.0 / vs.total_bytes) < 15.0;
    END TRY
    BEGIN CATCH
        INSERT INTO dbo.DbaMonitorErrorLog (ProcedureName, ErrorStep, ErrorMessage, ErrorLine)
        VALUES ('usp_ExecuteDailyHealthCheckAndNotify', 'CheckDiskSpace', ERROR_MESSAGE(), ERROR_LINE());
    END CATCH;

    -- Ghi nhận dữ liệu vào bảng DailyCheckAuditLog
    INSERT INTO dbo.DailyCheckAuditLog (CheckDate, CheckCategory, SeverityLevel, CheckDetails)
    SELECT @CheckDate, Category, Severity, Details FROM #DailyIssues;

    SELECT @AlertCount = COUNT(*) FROM #DailyIssues;

    -- 8. Gửi mail cảnh báo HTML sinh động, bỏ cột Category
    IF @AlertCount > 0
    BEGIN
        DECLARE @HtmlBody NVARCHAR(MAX);
        DECLARE @EmailSubject NVARCHAR(255) = CONCAT('SQL Server Daily Health Alert: [', @@SERVERNAME, '] - ', CAST(@AlertCount AS VARCHAR), ' Issues Found');

        SET @HtmlBody = N'
        <html>
        <head>
            <style>
                body {
                    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Arial, sans-serif;
                    font-size: 13px;
                    color: #212121;
                    line-height: 1.5;
                }
                .container { max-width: 900px; margin: 0 auto; padding: 10px; }
                .header {
                    background: linear-gradient(135deg, #004D40 0%, #00796B 100%);
                    color: #ffffff;
                    padding: 16px 20px;
                    border-radius: 6px 6px 0 0;
                }
                .header h3 { margin: 0; font-size: 17px; }
                .subtext { margin: 8px 0 0 0; font-size: 13px; opacity: 0.9; }
                table {
                    border-collapse: collapse;
                    width: 100%;
                    border: 1px solid #E0E0E0;
                    box-shadow: 0 1px 3px rgba(0,0,0,0.08);
                }
                th {
                    background-color: #ECEFF1;
                    color: #37474F;
                    font-weight: 600;
                    text-align: left;
                    padding: 10px 14px;
                    border-bottom: 2px solid #CFD8DC;
                    font-size: 12px;
                    text-transform: uppercase;
                    letter-spacing: 0.5px;
                }
                td {
                    border-bottom: 1px solid #ECEFF1;
                    padding: 10px 14px;
                    vertical-align: top;
                }
                .row-crit { background-color: #FFEBEE; }
                .row-warn { background-color: #FFFDE7; }
                .badge {
                    display: inline-block;
                    padding: 3px 10px;
                    border-radius: 12px;
                    font-size: 11px;
                    font-weight: 700;
                    letter-spacing: 0.5px;
                    text-align: center;
                }
                .badge-crit { background-color: #D32F2F; color: #FFFFFF; }
                .badge-warn { background-color: #F57C00; color: #FFFFFF; }
                .details-text { font-family: Consolas, "Courier New", monospace; font-size: 12px; color: #263238; }
                .footer { margin-top: 14px; font-size: 12px; color: #78909C; font-style: italic; }
            </style>
        </head>
        <body>
            <div class="container">
                <div class="header">
                    <h3>Daily Operational Assessment: ' + @@SERVERNAME + N'</h3>
                    <p class="subtext"><b>' + CAST(@AlertCount AS VARCHAR) + N'</b> Hạng mục cần xem xét:</p>
                </div>
                <table>
                    <thead>
                        <tr>
                            <th style="width: 120px;">Severity</th>
                            <th>Details</th>
                        </tr>
                    </thead>
                    <tbody>' +
                    CAST((
                        SELECT 
                            [@class] = CASE WHEN Severity = 'CRITICAL' THEN 'row-crit' ELSE 'row-warn' END,
                            td = CAST(
                                '<span class="badge ' + 
                                CASE WHEN Severity = 'CRITICAL' THEN 'badge-crit' ELSE 'badge-warn' END + 
                                '">' + Severity + '</span>' 
                                AS XML
                            ), '',
                            td = CAST(
                                '<span class="details-text">' + 
                                REPLACE(REPLACE(Details, '&', '&amp;'), '<', '&lt;') + 
                                '</span>' 
                                AS XML
                            ), ''
                        FROM #DailyIssues
                        ORDER BY CASE WHEN Severity = 'CRITICAL' THEN 1 ELSE 2 END
                        FOR XML PATH('tr'), TYPE
                    ) AS NVARCHAR(MAX)) +
                    N'</tbody>
                </table>
                <p class="footer">Báo cáo tự động của DBA Team - 06:00 AM hằng ngày.</p>
            </div>
        </body></html>';

        EXEC msdb.dbo.sp_send_dbmail
            @profile_name = @MailProfileName,
            @recipients = @RecipientEmail,
            @subject = @EmailSubject,
            @body = @HtmlBody,
            @body_format = 'HTML';
    END;
END;
GO
```

- ===========================================================================================================
- WEEKLY DEEP-DIVE COMPREHENSIVE ASSESSMENT (06:00 CHỦ NHẬT)
- Bỏ quét deep-dive sp_Blitz, chỉ khai thác dữ liệu lịch sử đã thu gom (CPU, Waits, I/O Delta, Disk Runway).
- ===========================================================================================================
```sql 
USE [DbaMonitor];
GO

ALTER PROCEDURE [dbo].[usp_ExecuteWeeklyAssessmentAndNotify]
    @MailProfileName NVARCHAR(128) = 'DBA',
    @RecipientEmail VARCHAR(MAX) = 'nghianl.ts@vietsov.com.vn; lamlh.ts@vietsov.com.vn'
AS
BEGIN
    SET NOCOUNT ON;

    -- 1. Phân tích CPU 30 ngày (SQL Process CPU vs Host CPU)
    DECLARE @AvgSqlCpu INT = 0, @AvgHostCpu INT = 0, @HighCpuHours DECIMAL(6,2) = 0;

    BEGIN TRY
        SELECT 
            @AvgSqlCpu = AVG(CAST(CpuSqlPercent AS INT)),
            @AvgHostCpu = AVG(CAST((100 - CpuIdlePercent) AS INT)),
            @HighCpuHours = CAST(COUNT(CASE WHEN (100 - CpuIdlePercent) >= 80 THEN 1 END) * 5.0 / 60.0 AS DECIMAL(6,2))
        FROM dbo.PerformanceSnapHistory
        WHERE SnapTime >= DATEADD(DAY, -30, SYSDATETIME());
    END TRY
    BEGIN CATCH
        INSERT INTO dbo.DbaMonitorErrorLog (ProcedureName, ErrorStep, ErrorMessage, ErrorLine)
        VALUES ('usp_ExecuteWeeklyAssessmentAndNotify', 'CPU_30d', ERROR_MESSAGE(), ERROR_LINE());
    END CATCH;

    -- 2. Top Wait Stats 7 ngày từ BlitzFirst_WaitStats_Deltas (Ignorable = 0)
    IF OBJECT_ID('tempdb..#TopWaits7d') IS NOT NULL DROP TABLE #TopWaits7d;
    CREATE TABLE #TopWaits7d (
        WaitType NVARCHAR(128),
        TotalWaitSec DECIMAL(18,2),
        PctOfTotal DECIMAL(5,2)
    );

    BEGIN TRY
        IF OBJECT_ID('dbo.BlitzFirst_WaitStats_Deltas', 'V') IS NOT NULL
        BEGIN
            ;WITH WaitSummary AS (
                SELECT 
                    wait_type AS WaitType,
                    SUM(wait_time_ms_delta) / 1000.0 AS TotalWaitSec
                FROM dbo.BlitzFirst_WaitStats_Deltas
                WHERE CheckDate >= DATEADD(DAY, -7, SYSDATETIME())
                  AND Ignorable = 0
                GROUP BY wait_type
                HAVING SUM(wait_time_ms_delta) > 0
            )
            INSERT INTO #TopWaits7d (WaitType, TotalWaitSec, PctOfTotal)
            SELECT TOP 5
                WaitType,
                CAST(TotalWaitSec AS DECIMAL(18,2)),
                CAST(TotalWaitSec * 100.0 / NULLIF(SUM(TotalWaitSec) OVER(), 0) AS DECIMAL(5,2))
            FROM WaitSummary
            ORDER BY TotalWaitSec DESC;
        END;
    END TRY
    BEGIN CATCH
        INSERT INTO dbo.DbaMonitorErrorLog (ProcedureName, ErrorStep, ErrorMessage, ErrorLine)
        VALUES ('usp_ExecuteWeeklyAssessmentAndNotify', 'TopWaits7d', ERROR_MESSAGE(), ERROR_LINE());
    END CATCH;

    -- 3. 30-Day Weighted Average I/O Latency (Lọc counter reset do Server restart)
    IF OBJECT_ID('tempdb..#IoStats30d') IS NOT NULL DROP TABLE #IoStats30d;
    CREATE TABLE #IoStats30d (
        DatabaseName NVARCHAR(128),
        LogicalFileName NVARCHAR(128),
        WeightedAvgReadLatencyMs DECIMAL(10,2),
        WeightedAvgWriteLatencyMs DECIMAL(10,2)
    );

    BEGIN TRY
        ;WITH Snaps AS (
            SELECT DatabaseID, FileID, DatabaseName, LogicalFileName,
                   NumOfReads, IoStallReadMs, NumOfWrites, IoStallWriteMs, SnapTime,
                   ROW_NUMBER() OVER (PARTITION BY DatabaseID, FileID ORDER BY SnapTime ASC) AS rn_first,
                   ROW_NUMBER() OVER (PARTITION BY DatabaseID, FileID ORDER BY SnapTime DESC) AS rn_last
            FROM dbo.FileIOStatsSnapshot
            WHERE SnapTime >= DATEADD(DAY, -30, SYSDATETIME())
        ),
        Boundaries AS (
            SELECT 
                l.DatabaseName, l.LogicalFileName,
                (l.NumOfReads - e.NumOfReads) AS DeltaReads,
                (l.IoStallReadMs - e.IoStallReadMs) AS DeltaReadStall,
                (l.NumOfWrites - e.NumOfWrites) AS DeltaWrites,
                (l.IoStallWriteMs - e.IoStallWriteMs) AS DeltaWriteStall
            FROM Snaps l
            INNER JOIN Snaps e ON l.DatabaseID = e.DatabaseID AND l.FileID = e.FileID AND e.rn_first = 1 AND l.rn_last = 1
            WHERE l.NumOfReads >= e.NumOfReads AND l.NumOfWrites >= e.NumOfWrites
        )
        INSERT INTO #IoStats30d (DatabaseName, LogicalFileName, WeightedAvgReadLatencyMs, WeightedAvgWriteLatencyMs)
        SELECT TOP 5
            DatabaseName,
            LogicalFileName,
            CAST(DeltaReadStall * 1.0 / NULLIF(DeltaReads, 0) AS DECIMAL(10,2)) AS WeightedAvgReadLatencyMs,
            CAST(DeltaWriteStall * 1.0 / NULLIF(DeltaWrites, 0) AS DECIMAL(10,2)) AS WeightedAvgWriteLatencyMs
        FROM Boundaries
        WHERE DeltaReads > 0 OR DeltaWrites > 0
        ORDER BY WeightedAvgReadLatencyMs DESC;
    END TRY
    BEGIN CATCH
        INSERT INTO dbo.DbaMonitorErrorLog (ProcedureName, ErrorStep, ErrorMessage, ErrorLine)
        VALUES ('usp_ExecuteWeeklyAssessmentAndNotify', 'IoStats30d', ERROR_MESSAGE(), ERROR_LINE());
    END CATCH;

    -- 4. Dự báo Cạn đĩa (Runway Forecast) - ĐÃ BỔ SUNG: TotalSpaceGB và FreePct
    IF OBJECT_ID('tempdb..#Runway') IS NOT NULL DROP TABLE #Runway;
    CREATE TABLE #Runway (
        VolumeMountPoint NVARCHAR(260),
        TotalSpaceGB DECIMAL(18,2),
        AvailableSpaceGB DECIMAL(18,2),
        FreePct DECIMAL(5,2),
        MonthlyDropGB DECIMAL(18,2),
        RunwayMonths DECIMAL(5,1)
    );

    BEGIN TRY
        INSERT INTO #Runway (VolumeMountPoint, TotalSpaceGB, AvailableSpaceGB, FreePct, MonthlyDropGB, RunwayMonths)
        SELECT 
            curr.VolumeMountPoint,
            curr.TotalSpaceGB,
            curr.AvailableSpaceGB,
            CAST((curr.AvailableSpaceGB * 100.0 / NULLIF(curr.TotalSpaceGB, 0)) AS DECIMAL(5,2)) AS FreePct,
            CAST((past.AvailableSpaceGB - curr.AvailableSpaceGB) * 1.0 / DATEDIFF(DAY, past.SnapDate, curr.SnapDate) * 30.4375 AS DECIMAL(18,2)),
            CASE 
                WHEN (past.AvailableSpaceGB - curr.AvailableSpaceGB) > 0 
                THEN CAST(curr.AvailableSpaceGB / NULLIF((past.AvailableSpaceGB - curr.AvailableSpaceGB) * 1.0 / DATEDIFF(DAY, past.SnapDate, curr.SnapDate) * 30.4375, 0) AS DECIMAL(5,1))
                ELSE 999.0 
            END
        FROM dbo.StorageVolumeBaseline curr
        INNER JOIN dbo.StorageVolumeBaseline past ON curr.VolumeMountPoint = past.VolumeMountPoint
        WHERE curr.SnapDate = CAST(SYSDATETIME() AS DATE)
          AND past.SnapDate = (
              SELECT MAX(SnapDate) FROM dbo.StorageVolumeBaseline 
              WHERE SnapDate <= DATEADD(DAY, -25, CAST(SYSDATETIME() AS DATE))
          );
    END TRY
    BEGIN CATCH
        INSERT INTO dbo.DbaMonitorErrorLog (ProcedureName, ErrorStep, ErrorMessage, ErrorLine)
        VALUES ('usp_ExecuteWeeklyAssessmentAndNotify', 'RunwayForecast', ERROR_MESSAGE(), ERROR_LINE());
    END CATCH;

    /*
    -- ==========================================================================================
    -- 5. Lấy lại Top Findings khẩn cấp đã ghi nhận trong tuần qua từ BlitzResults
    -- (TẠM THỜI COMMENT ĐỂ TRÁNH LOÃNG BÁO CÁO TUẦN DO ĐÃ DÙNG VEEAM BACKUP VÀ ĐÃ CÓ BÁO CÁO NGÀY)
    -- ==========================================================================================
    IF OBJECT_ID('tempdb..#WeeklyTopFindings') IS NOT NULL DROP TABLE #WeeklyTopFindings;
    CREATE TABLE #WeeklyTopFindings (
        Priority TINYINT,
        FindingsGroup VARCHAR(50),
        Finding VARCHAR(200),
        DatabaseName NVARCHAR(128),
        Details NVARCHAR(MAX)
    );

    BEGIN TRY
        INSERT INTO #WeeklyTopFindings (Priority, FindingsGroup, Finding, DatabaseName, Details)
        SELECT TOP 5 Priority, FindingsGroup, Finding, DatabaseName, Details
        FROM dbo.BlitzResults
        WHERE CheckDate >= DATEADD(DAY, -7, SYSDATETIME())
          AND Priority <= 50
          -- [BỎ CẢNH BÁO LIÊN QUAN ĐẾN BACKUP DO DÙNG VEEAM]
          AND FindingsGroup <> 'Backup'
          AND Finding NOT LIKE '%Backup%'
        ORDER BY Priority ASC, CheckDate DESC;
    END TRY
    BEGIN CATCH
        INSERT INTO dbo.DbaMonitorErrorLog (ProcedureName, ErrorStep, ErrorMessage, ErrorLine)
        VALUES ('usp_ExecuteWeeklyAssessmentAndNotify', 'GetWeeklyFindings', ERROR_MESSAGE(), ERROR_LINE());
    END CATCH;
    -- ==========================================================================================
    */

    -- 6. Render HTML an toàn và gửi Mail Báo cáo Tuần
    BEGIN TRY
        DECLARE @Body NVARCHAR(MAX);
        SET @Body = N'
        <html>
        <head>
            <style>
                body {font-family: Arial, sans-serif; font-size: 13px;}
                table {border-collapse: collapse; width: 95%; margin-bottom: 20px;}
                th {background-color: #1A237E; color: white; padding: 7px; text-align: left;}
                td {border: 1px solid #ccc; padding: 7px;}
                .warn {color: #E65100; font-weight: bold;}
                .crit {color: #B71C1C; font-weight: bold;}
            </style>
        </head>
        <body>
            <h2>BÁO CÁO ĐÁNH GIÁ CHUYÊN SÂU HỆ THỐNG (WEEKLY) - ' + @@SERVERNAME + N'</h2>

            <h3>1. Tải CPU trong 30 Ngày</h3>
            <ul>
                <li>SQL Server Process CPU Trung bình: <b>' + CAST(ISNULL(@AvgSqlCpu, 0) AS VARCHAR) + N'%</b></li>
                <li>Host/Server OS CPU Trung bình: <b>' + CAST(ISNULL(@AvgHostCpu, 0) AS VARCHAR) + N'%</b></li>
                <li>Tổng số giờ CPU máy chủ quá tải (>= 80%): <b>' + CAST(ISNULL(@HighCpuHours, 0) AS VARCHAR) + N' giờ</b></li>
            </ul>

            <h3>2. Top Wait Stats trong 7 Ngày (BlitzFirst_WaitStats_Deltas)</h3>
            <table>
                <tr><th>Wait Type</th><th>Total Wait Delta (s)</th><th>% Trong Top</th></tr>' +
                ISNULL(CAST((
                    SELECT td = WaitType, '', td = TotalWaitSec, '', td = PctOfTotal, ''
                    FROM #TopWaits7d FOR XML PATH('tr'), TYPE
                ) AS NVARCHAR(MAX)), '<tr><td colspan="3">Chua du du lieu 7 ngay Wait Stats</td></tr>') +
            N'</table>

            <h3>3. 30-Day Weighted Average I/O Latency (Độ trễ Đọc/Ghi thực tế)</h3>
            <table>
                <tr><th>Database</th><th>File Logic</th><th>Avg Read Latency (ms)</th><th>Avg Write Latency (ms)</th></tr>' +
                ISNULL(CAST((
                    SELECT td = DatabaseName, '', td = LogicalFileName, '', 
                           td = WeightedAvgReadLatencyMs, '', td = WeightedAvgWriteLatencyMs, ''
                    FROM #IoStats30d FOR XML PATH('tr'), TYPE
                ) AS NVARCHAR(MAX)), '<tr><td colspan="4">Chua co du lieu I/O thoa man</td></tr>') +
            N'</table>

            <h3>4. Dự báo Cạn đĩa & Tình trạng Lưu trữ (Runway Forecast)</h3>
            <table>
                <tr>
                    <th>Phân vùng</th>
                    <th>Tổng dung lượng (GB)</th>
                    <th>Còn trống (GB)</th>
                    <th>Tỷ lệ trống</th>
                    <th>Mức tiêu thụ ước tính (GB/tháng)</th>
                    <th>Dự phóng cạn đĩa</th>
                </tr>' +
                ISNULL(CAST((
                    SELECT td = VolumeMountPoint, '', 
                           td = TotalSpaceGB, '',
                           td = AvailableSpaceGB, '', 
                           td = CAST(FreePct AS VARCHAR) + '%', '',
                           td = MonthlyDropGB, '',
                           td = CASE 
                                    WHEN RunwayMonths <= 1.5 THEN CONCAT('CRITICAL: con ', RunwayMonths, ' thang')
                                    WHEN RunwayMonths <= 3.0 THEN CONCAT('WARN: con ', RunwayMonths, ' thang')
                                    ELSE CONCAT(RunwayMonths, ' thang')
                                END, ''
                    FROM #Runway FOR XML PATH('tr'), TYPE
                ) AS NVARCHAR(MAX)), '<tr><td colspan="6">Chua du moc baseline 30 ngay</td></tr>') +
            N'</table>' +

            /*
            -- ==================================================================================
            -- TẠM COMMENT KHỐI HIỂN THỊ MỤC 5 TRONG EMAIL ĐỂ BÁO CÁO GỌN GÀNG VÀ TẬP TRUNG HƠN
            -- ==================================================================================
            N'<h3>5. Top Cảnh Báo Cấu Hình Nổi Bật Trong Tuần (sp_Blitz)</h3>
            <table>
                <tr><th>Priority</th><th>Nhóm</th><th>Finding</th><th>Database</th><th>Details</th></tr>' +
                ISNULL(CAST((
                    SELECT td = Priority, '', td = FindingsGroup, '', td = Finding, '', 
                           td = ISNULL(DatabaseName, 'Global'), '', td = Details, ''
                    FROM #WeeklyTopFindings FOR XML PATH('tr'), TYPE
                ) AS NVARCHAR(MAX)), '<tr><td colspan="5">Khong co canh bao Priority <= 50 nao trong tuan qua</td></tr>') +
            N'</table>' +
            -- ==================================================================================
            */

            N'<br/><p><i>Báo cáo tự động của DBA Team - 06:00 AM Chủ Nhật.</i></p>
        </body></html>';

        EXEC msdb.dbo.sp_send_dbmail
            @profile_name = @MailProfileName,
            @recipients = @RecipientEmail,
            @subject = N'SQL Server Weekly Comprehensive Health Audit',
            @body = @Body,
            @body_format = 'HTML';
    END TRY
    BEGIN CATCH
        INSERT INTO dbo.DbaMonitorErrorLog (ProcedureName, ErrorStep, ErrorMessage, ErrorLine)
        VALUES ('usp_ExecuteWeeklyAssessmentAndNotify', 'RenderAndSendMail', ERROR_MESSAGE(), ERROR_LINE());
    END CATCH;
END;
GO
```

### PHẦN 3: SCRIPT TẠO 4 SQL SERVER AGENT JOBS CHUẨN PRODUCTION

```sql 
USE msdb;
GO

-- 1. Job 5 Phút: Metric Collection
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'DBA - HealthCheck - Metric Collection')
    EXEC dbo.sp_delete_job @job_name = N'DBA - HealthCheck - Metric Collection';

EXEC dbo.sp_add_job 
    @job_name = N'DBA - HealthCheck - Metric Collection', 
    @enabled = 1,
    @owner_login_name = N'[vietsov\sqlcluster]',
    @description = N'Chup lat cat hieu nang tuc thoi moi 5 phut (CPU, PLE, Waits, I/O, Deadlock qua .xel)';

EXEC dbo.sp_add_jobstep 
    @job_name = N'DBA - HealthCheck - Metric Collection', 
    @step_name = N'Collect Performance and Deadlocks',
    @subsystem = N'TSQL', 
    @database_name = N'DbaMonitor',
    @command = N'EXEC dbo.usp_CollectSnapPerformance; EXEC dbo.usp_CollectDeadlockHistory;',
	@retry_attempts=0, 
	@retry_interval=1, 
    @on_fail_action = 2; -- Quit With Failure

EXEC dbo.sp_add_jobschedule 
    @job_name = N'DBA - HealthCheck - Metric Collection', 
    @name = N'Every_5_Minutes',
    @freq_type = 4, 
    @freq_interval = 1, 
    @freq_subday_type = 4, 
    @freq_subday_interval = 5;

EXEC dbo.sp_add_jobserver 
    @job_name = N'DBA - HealthCheck - Metric Collection';

-- 2. Job 06:00 Sáng: Daily Operational Assessment
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'DBA - HealthCheck - Daily Operational Assessment')
    EXEC dbo.sp_delete_job @job_name = N'DBA - HealthCheck - Daily Operational Assessment';

EXEC dbo.sp_add_job 
    @job_name = N'DBA - HealthCheck - Daily Operational Assessment', 
    @enabled = 1,
    @owner_login_name = N'[vietsov\sqlcluster]',
    @description = N'Danh gia rui ro van hanh dau ngay: Watchdog, Services, sp_Blitz (@CheckUserDatabaseObjects=0), Backup SLA, AG, TempDB va gui Mail';

EXEC dbo.sp_add_jobstep 
    @job_name = N'DBA - HealthCheck - Daily Operational Assessment', 
    @step_name = N'Execute Daily Health Check',
    @subsystem = N'TSQL', 
    @database_name = N'DbaMonitor',
    @command = N'EXEC dbo.usp_ExecuteDailyHealthCheckAndNotify @MailProfileName = ''DBA_Alerts'', @RecipientEmail = ''dba-team@example.com'';',
    @retry_attempts = 2,
    @retry_interval = 3
	@on_fail_action = 2;

EXEC dbo.sp_add_jobschedule 
    @job_name = N'DBA - HealthCheck - Daily Operational Assessment', 
    @name = N'Daily_06AM',
    @freq_type = 4, 
    @freq_interval = 1, 
    @active_start_time = 060000;

EXEC dbo.sp_add_jobserver 
    @job_name = N'DBA - HealthCheck - Daily Operational Assessment';

-- 3. Job 23:50 Đêm: Daily Storage & Maintenance
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'DBA - HealthCheck - Daily Storage & Maintenance')
    EXEC dbo.sp_delete_job @job_name = N'DBA - HealthCheck - Daily Storage & Maintenance';

EXEC dbo.sp_add_job 
    @job_name = N'DBA - HealthCheck - Daily Storage & Maintenance', 
    @enabled = 1,
    @owner_login_name = N'[vietsov\sqlcluster]',
    @description = N'Ghi nhan storage baseline va chay batch retention (90 ngay metric / 2 nam audit / 3 nam storage) cho FRK tables';

EXEC dbo.sp_add_jobstep 
    @job_name = N'DBA - HealthCheck - Daily Storage & Maintenance', 
    @step_name = N'Record Storage and Purge Old Logs',
    @subsystem = N'TSQL', 
    @database_name = N'DbaMonitor',
    @command = N'EXEC dbo.usp_DailyStorageAndMaintenance;',
	@retry_attempts = 1,
    @retry_interval = 5
    @on_fail_action = 2;

EXEC dbo.sp_add_jobschedule 
    @job_name = N'DBA - HealthCheck - Daily Storage & Maintenance', 
    @name = N'Daily_2350PM',
    @freq_type = 4, 
    @freq_interval = 1, 
    @active_start_time = 235000;

EXEC dbo.sp_add_jobserver 
    @job_name = N'DBA - HealthCheck - Daily Storage & Maintenance';

-- 4. Job 06:00 Sáng Chủ Nhật: Weekly Comprehensive Assessment
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'DBA - HealthCheck - Weekly Comprehensive Assessment')
    EXEC dbo.sp_delete_job @job_name = N'DBA - HealthCheck - Weekly Comprehensive Assessment';

EXEC dbo.sp_add_job 
    @job_name = N'DBA - HealthCheck - Weekly Comprehensive Assessment', 
    @enabled = 1,
    @owner_login_name = N'[vietsov\sqlcluster]',
    @description = N'Bao cao tong hop chuyen sau tuan: CPU 30d, Top Waits Deltas 7d, I/O Weighted Latency, Disk Runway Forecast';

EXEC dbo.sp_add_jobstep 
    @job_name = N'DBA - HealthCheck - Weekly Comprehensive Assessment', 
    @step_name = N'Execute Weekly Deep-Dive',
    @subsystem = N'TSQL', 
    @database_name = N'DbaMonitor',
    @command = N'EXEC dbo.usp_ExecuteWeeklyAssessmentAndNotify @MailProfileName = ''DBA_Alerts'', @RecipientEmail = ''dba-team@example.com'';',
    @retry_attempts = 2,
    @retry_interval = 5
	@on_fail_action = 2;

EXEC dbo.sp_add_jobschedule 
    @job_name = N'DBA - HealthCheck - Weekly Comprehensive Assessment', 
    @name = N'Weekly_Sunday_06AM',
    @freq_type = 8, 
    @freq_interval = 1, -- Sunday
    @freq_recurrence_factor = 1, 
    @active_start_time = 060000;

EXEC dbo.sp_add_jobserver 
    @job_name = N'DBA - HealthCheck - Weekly Comprehensive Assessment';
GO
```

