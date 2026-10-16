/*
==========================================================================================
 - PRE-FAILOVER SAFETY AUDIT (T-SQL WORKBENCH)
 
 - HƯỚNG DẪN CHẠY:
     - Bước 1: Mở SSMS kết nối vào PRIMARY hiện tại để xem Long-Running Tx & Backup(Mục 2,3).
     - Bước 2: Mở SSMS kết nối vào TARGET SECONDARY để xem Sync State, Queue, ETA.
     - Khi mục 6 báo 'PASS - READY FOR MANUAL FAILOVER', chạy:
         ALTER AVAILABILITY GROUP [Your-AG-Name-Group] FAILOVER;
     - Nếu mục 4B báo hàng đợi đang GROWING hoặc ETA quá cao, NÊN CHỜ hoặc giảm tải
       ghi (write workload) trên Primary trước khi failover để tránh downtime kéo dài.
==========================================================================================
*/

SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

--------------------------------------------------------------------------------
-- CẤU HÌNH THAM SỐ TOÀN CỤC (CHỈ CẦN SỬA DUY NHẤT TẠI ĐÂY)
--------------------------------------------------------------------------------
EXEC sp_set_session_context @key = N'AGName',                   @value = N'Your-AG-Name-Group';
EXEC sp_set_session_context @key = N'MaxAllowedRedoQueueMB',    @value = 512;  -- Ngưỡng cảnh báo Redo Queue (MB)
EXEC sp_set_session_context @key = N'MaxAllowedSendQueueMB',    @value = 50;   -- Ngưỡng cảnh báo Log Send Queue (MB)
EXEC sp_set_session_context @key = N'LongTxThresholdMinutes',   @value = 15;   -- Ngưỡng cảnh báo Transaction dài (Phút)
EXEC sp_set_session_context @key = N'LongTxCriticalMinutes',    @value = 45;   -- Ngưỡng CHẶN failover nếu Tx dài hơn (Phút)
EXEC sp_set_session_context @key = N'MaxHoursSinceFullBackup',  @value = 24;   -- Ngưỡng cảnh báo Full Backup cũ (Giờ)
EXEC sp_set_session_context @key = N'MinAvailableWorkers',      @value = 40;   -- Ngưỡng CHẶN nếu Worker khả dụng thấp hơn
EXEC sp_set_session_context @key = N'MaxAcceptableEtaSeconds',  @value = 30;   -- ETA tối đa chấp nhận để hàng đợi về 0

PRINT '=== BẮT ĐẦU AUDIT AN TOÀN TRƯỚC FAILOVER: [' + CAST(SESSION_CONTEXT(N'AGName') AS sysname) + '] ===';
PRINT 'Thời gian: ' + CONVERT(VARCHAR(30), GETDATE(), 120);
PRINT 'Instance hiện tại: ' + @@SERVERNAME;
PRINT '';
GO

--------------------------------------------------------------------------------
-- 1. KIỂM TRA WORKER THREAD KHẢ DỤNG
--------------------------------------------------------------------------------
PRINT '--- 1. WORKER THREAD HEALTH ---';

SELECT
    osi.max_workers_count AS [Max_Workers],
    osi.current_workers_count AS [Allocated_Workers],
    (osi.max_workers_count - osi.current_workers_count) AS [Available_Workers],
    CAST(osi.current_workers_count * 100.0 / NULLIF(osi.max_workers_count, 0) AS DECIMAL(5,2)) AS [Worker_Utilization_Percent],
    CASE
        WHEN (osi.max_workers_count - osi.current_workers_count) < CAST(SESSION_CONTEXT(N'MinAvailableWorkers') AS INT)
            THEN 'FAIL: Cạn kiệt Worker Threads (< ' + CAST(SESSION_CONTEXT(N'MinAvailableWorkers') AS VARCHAR(10)) + ')'
        ELSE 'PASS'
    END AS [Thread_Health_Status]
FROM sys.dm_os_sys_info osi;
GO

--------------------------------------------------------------------------------
-- 2. LONG-RUNNING TRANSACTIONS & LOG USAGE
--------------------------------------------------------------------------------
PRINT '--- 2. ACTIVE LONG TRANSACTIONS (Chạy trên Primary) ---';

SELECT
    s.session_id,
    s.login_name,
    s.host_name,
    s.program_name,
    DB_NAME(dt.database_id) AS [Database_Name],
    at.transaction_begin_time,
    DATEDIFF(MINUTE, at.transaction_begin_time, GETDATE()) AS [Duration_Minutes],
    tst.is_user_transaction,
    CAST(dt.database_transaction_log_bytes_used / 1048576.0 AS DECIMAL(18,2)) AS [Log_Used_MB],
    t.[text] AS [Executing_SQL],
    CASE
        WHEN DATEDIFF(MINUTE, at.transaction_begin_time, GETDATE()) >= CAST(SESSION_CONTEXT(N'LongTxCriticalMinutes') AS INT)
            THEN 'FAIL: Vượt ngưỡng nghiêm trọng (>= ' + CAST(SESSION_CONTEXT(N'LongTxCriticalMinutes') AS VARCHAR(10)) + ' phút) — có thể kéo dài Undo sau failover'
        WHEN DATEDIFF(MINUTE, at.transaction_begin_time, GETDATE()) >= CAST(SESSION_CONTEXT(N'LongTxThresholdMinutes') AS INT)
            THEN 'WARN: Transaction dài, theo dõi thêm'
        ELSE 'INFO'
    END AS [Tx_Risk_Level]
FROM sys.dm_tran_active_transactions at
JOIN sys.dm_tran_database_transactions dt ON at.transaction_id = dt.transaction_id
JOIN sys.dm_tran_session_transactions tst ON at.transaction_id = tst.transaction_id
JOIN sys.dm_exec_sessions s ON tst.session_id = s.session_id
LEFT JOIN sys.dm_exec_connections c ON c.session_id = s.session_id
OUTER APPLY sys.dm_exec_sql_text(c.most_recent_sql_handle) t
WHERE dt.database_id IN (
        SELECT drs.database_id
        FROM sys.dm_hadr_database_replica_states drs
        JOIN sys.availability_groups ag ON drs.group_id = ag.group_id
        WHERE ag.name = CAST(SESSION_CONTEXT(N'AGName') AS sysname)
          AND drs.is_local = 1
  )
  AND DATEDIFF(MINUTE, at.transaction_begin_time, GETDATE()) >= CAST(SESSION_CONTEXT(N'LongTxThresholdMinutes') AS INT)
ORDER BY [Duration_Minutes] DESC;
GO

--------------------------------------------------------------------------------
-- 3. LỊCH SỬ FULL BACKUP
--------------------------------------------------------------------------------
PRINT '--- 3. FULL BACKUP RECENCY CHECK ---';

DECLARE @BackupPreference NVARCHAR(60);
SELECT @BackupPreference = ag.automated_backup_preference_desc
FROM sys.availability_groups ag
WHERE ag.name = CAST(SESSION_CONTEXT(N'AGName') AS sysname);

IF @BackupPreference NOT IN ('PRIMARY', 'NONE')
    PRINT 'LƯU Ý: Automated_Backup_Preference = ' + @BackupPreference
        + '. Nếu backup job không chạy trên instance [' + @@SERVERNAME
        + '] này, kết quả "CHƯA TỪNG BACKUP" dưới đây CÓ THỂ là false-warning.'
        + ' Hãy đối chiếu thêm msdb.dbo.backupset trên các replica khác.';

;WITH LastFullBackup AS (
    SELECT
        d.name AS [Database_Name],
        MAX(bs.backup_finish_date) AS [Last_Full_Backup_Date]
    FROM sys.databases d
    JOIN sys.availability_databases_cluster adc ON d.name = adc.database_name
    JOIN sys.availability_groups ag ON adc.group_id = ag.group_id
    LEFT JOIN msdb.dbo.backupset bs
        ON d.name = bs.database_name AND bs.[type] = 'D'
    WHERE ag.name = CAST(SESSION_CONTEXT(N'AGName') AS sysname)
    GROUP BY d.name
)
SELECT
    lfb.Database_Name,
    ISNULL(CONVERT(VARCHAR(30), lfb.Last_Full_Backup_Date, 120), 'CHƯA TỪNG BACKUP (trên instance này)') AS [Last_Full_Backup],
    ISNULL(DATEDIFF(HOUR, lfb.Last_Full_Backup_Date, GETDATE()), 999999) AS [Hours_Since_Backup],
    CASE
        WHEN lfb.Last_Full_Backup_Date IS NULL THEN 'WARN: Không thấy Full Backup trên instance này'
        WHEN DATEDIFF(HOUR, lfb.Last_Full_Backup_Date, GETDATE()) > CAST(SESSION_CONTEXT(N'MaxHoursSinceFullBackup') AS INT)
            THEN 'WARN: Quá ' + CAST(SESSION_CONTEXT(N'MaxHoursSinceFullBackup') AS VARCHAR(10)) + 'h chưa Full Backup'
        ELSE 'PASS'
    END AS [Backup_Readiness]
FROM LastFullBackup lfb
ORDER BY [Hours_Since_Backup] DESC;
GO

--------------------------------------------------------------------------------
-- 4. HÀNG ĐỢI & TRẠNG THÁI SẴN SÀNG
--------------------------------------------------------------------------------
PRINT '--- 4. DATABASE QUEUES & READY STATE ---';

SELECT
    adc.database_name AS [Database_Name],
    drs.synchronization_state_desc AS [Sync_State],
    drs.synchronization_health_desc AS [Health_State],
    drs.is_suspended AS [Is_Suspended],
    drs.suspend_reason_desc AS [Suspend_Reason],
    dbrcs.is_failover_ready AS [Is_Failover_Ready],
    dbrcs.is_database_joined AS [Is_Joined],
    CAST(ISNULL(drs.log_send_queue_size, 0) / 1024.0 AS DECIMAL(18,2)) AS [Log_Send_Queue_MB],
    CAST(ISNULL(drs.redo_queue_size, 0) / 1024.0 AS DECIMAL(18,2)) AS [Redo_Queue_MB],
    drs.redo_rate AS [Redo_Rate_KB_s],
    CASE WHEN ISNULL(drs.redo_rate, 0) > 0
         THEN CAST(drs.redo_queue_size / drs.redo_rate AS DECIMAL(18,1))
         ELSE NULL END AS [Redo_ETA_Seconds_Instant],
    drs.last_sent_lsn, drs.last_received_lsn, drs.last_hardened_lsn, drs.last_redone_lsn,
    CASE
        WHEN drs.synchronization_state_desc <> 'SYNCHRONIZED' THEN 'FAIL: Chưa SYNCHRONIZED'
        WHEN drs.is_suspended = 1 THEN 'FAIL: Đang bị SUSPEND'
        WHEN ISNULL(dbrcs.is_failover_ready, 0) <> 1 THEN 'FAIL: Cluster báo chưa sẵn sàng'
        WHEN ISNULL(dbrcs.is_database_joined, 0) <> 1 THEN 'FAIL: Database chưa JOINED vào AG'
        WHEN ISNULL(drs.log_send_queue_size, 0) / 1024.0 > CAST(SESSION_CONTEXT(N'MaxAllowedSendQueueMB') AS INT)
            THEN 'FAIL: Log Send Queue lớn (> ' + CAST(SESSION_CONTEXT(N'MaxAllowedSendQueueMB') AS VARCHAR(10)) + ' MB)'
        WHEN ISNULL(drs.redo_queue_size, 0) / 1024.0 > CAST(SESSION_CONTEXT(N'MaxAllowedRedoQueueMB') AS INT)
            THEN 'WARN: Redo Queue lớn (> ' + CAST(SESSION_CONTEXT(N'MaxAllowedRedoQueueMB') AS VARCHAR(10)) + ' MB)'
        ELSE 'PASS'
    END AS [Database_Readiness]
FROM sys.availability_groups ag
JOIN sys.dm_hadr_database_replica_states drs ON ag.group_id = drs.group_id
JOIN sys.availability_databases_cluster adc ON drs.group_database_id = adc.group_database_id
LEFT JOIN sys.dm_hadr_database_replica_cluster_states dbrcs
    ON drs.replica_id = dbrcs.replica_id AND drs.group_database_id = dbrcs.group_database_id
WHERE ag.name = CAST(SESSION_CONTEXT(N'AGName') AS sysname)
  AND drs.is_local = 1
ORDER BY adc.database_name;
GO

--------------------------------------------------------------------------------
-- 4B. VẬN TỐC GIẢI QUYẾT HÀNG ĐỢI & ETA THỰC ĐO
--------------------------------------------------------------------------------
PRINT '--- 4B. QUEUE DRAIN VELOCITY & ETA (2 mẫu cách nhau ~10s) ---';

IF OBJECT_ID('tempdb..#QueueSample1') IS NOT NULL DROP TABLE #QueueSample1;
IF OBJECT_ID('tempdb..#QueueSample2') IS NOT NULL DROP TABLE #QueueSample2;

SELECT
    adc.database_name AS [Database_Name],
    ISNULL(drs.log_send_queue_size, 0) AS [Send_Queue_KB],
    ISNULL(drs.redo_queue_size, 0) AS [Redo_Queue_KB],
    GETDATE() AS [Sample_Time]
INTO #QueueSample1
FROM sys.availability_groups ag
JOIN sys.dm_hadr_database_replica_states drs ON ag.group_id = drs.group_id
JOIN sys.availability_databases_cluster adc ON drs.group_database_id = adc.group_database_id
WHERE ag.name = CAST(SESSION_CONTEXT(N'AGName') AS sysname) AND drs.is_local = 1;

WAITFOR DELAY '00:00:10';

SELECT
    adc.database_name AS [Database_Name],
    ISNULL(drs.log_send_queue_size, 0) AS [Send_Queue_KB],
    ISNULL(drs.redo_queue_size, 0) AS [Redo_Queue_KB],
    GETDATE() AS [Sample_Time]
INTO #QueueSample2
FROM sys.availability_groups ag
JOIN sys.dm_hadr_database_replica_states drs ON ag.group_id = drs.group_id
JOIN sys.availability_databases_cluster adc ON drs.group_database_id = adc.group_database_id
WHERE ag.name = CAST(SESSION_CONTEXT(N'AGName') AS sysname) AND drs.is_local = 1;

SELECT
    s1.Database_Name,
    CAST(s1.Send_Queue_KB / 1024.0 AS DECIMAL(18,2)) AS [Send_Queue_MB_Now],
    CAST((s2.Send_Queue_KB - s1.Send_Queue_KB) * 1.0 / NULLIF(DATEDIFF(SECOND, s1.Sample_Time, s2.Sample_Time), 0) AS DECIMAL(18,2)) AS [Send_Queue_Velocity_KB_s],
    CASE 
        WHEN s2.Send_Queue_KB < s1.Send_Queue_KB AND (s1.Send_Queue_KB - s2.Send_Queue_KB) > 0
        THEN CAST(s2.Send_Queue_KB * 1.0 / ((s1.Send_Queue_KB - s2.Send_Queue_KB) * 1.0 / NULLIF(DATEDIFF(SECOND, s1.Sample_Time, s2.Sample_Time), 0)) AS DECIMAL(18,1))
        WHEN s2.Send_Queue_KB = 0 THEN 0.0
        ELSE NULL 
    END AS [Send_Queue_ETA_Seconds],
    CAST(s1.Redo_Queue_KB / 1024.0 AS DECIMAL(18,2)) AS [Redo_Queue_MB_Now],
    CAST((s2.Redo_Queue_KB - s1.Redo_Queue_KB) * 1.0 / NULLIF(DATEDIFF(SECOND, s1.Sample_Time, s2.Sample_Time), 0) AS DECIMAL(18,2)) AS [Redo_Queue_Velocity_KB_s],
    CASE 
        WHEN s2.Redo_Queue_KB < s1.Redo_Queue_KB AND (s1.Redo_Queue_KB - s2.Redo_Queue_KB) > 0
        THEN CAST(s2.Redo_Queue_KB * 1.0 / ((s1.Redo_Queue_KB - s2.Redo_Queue_KB) * 1.0 / NULLIF(DATEDIFF(SECOND, s1.Sample_Time, s2.Sample_Time), 0)) AS DECIMAL(18,1))
        WHEN s2.Redo_Queue_KB = 0 THEN 0.0
        ELSE NULL
    END AS [Redo_Queue_ETA_Seconds],
    CASE 
        WHEN s2.Send_Queue_KB = 0 AND s2.Redo_Queue_KB = 0 THEN 'PASS: Hàng đợi đã về 0'
        WHEN s2.Send_Queue_KB > s1.Send_Queue_KB OR s2.Redo_Queue_KB > s1.Redo_Queue_KB
            THEN 'FAIL: Hàng đợi đang TĂNG (Workload ghi cao) - Cân nhắc chờ xả hàng đợi'
        ELSE 'INFO: Hàng đợi đang xả tốt'
    END AS [Velocity_Verdict]
FROM #QueueSample1 s1
JOIN #QueueSample2 s2 ON s1.Database_Name = s2.Database_Name
ORDER BY s1.Database_Name;

DROP TABLE #QueueSample1;
DROP TABLE #QueueSample2;
GO

--------------------------------------------------------------------------------
-- 5. DUNG LƯỢNG Ổ ĐĨA DỮ LIỆU/LOG CỦA AG HIỆN TẠI
--------------------------------------------------------------------------------
PRINT '--- 5. STORAGE VOLUMES FOR AG DATABASES ---';

SELECT DISTINCT
    vs.volume_mount_point AS [Mount_Point],
    CAST(vs.total_bytes / 1073741824.0 AS DECIMAL(18,2)) AS [Total_GB],
    CAST(vs.available_bytes / 1073741824.0 AS DECIMAL(18,2)) AS [Free_GB],
    CAST(vs.available_bytes * 100.0 / NULLIF(vs.total_bytes, 0) AS DECIMAL(8,2)) AS [Free_Percent],
    CASE
        WHEN vs.available_bytes * 100.0 / NULLIF(vs.total_bytes, 0) < 15.0
          OR vs.available_bytes / 1073741824.0 < 20.0
        THEN 'FAIL: Thiếu dung lượng trống an toàn'
        ELSE 'PASS'
    END AS [Volume_Status]
FROM sys.availability_groups ag
JOIN sys.dm_hadr_database_replica_states drs ON ag.group_id = drs.group_id
JOIN sys.availability_databases_cluster adc ON drs.group_database_id = adc.group_database_id
JOIN sys.master_files mf ON drs.database_id = mf.database_id
CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) vs
WHERE ag.name = CAST(SESSION_CONTEXT(N'AGName') AS sysname)
  AND drs.is_local = 1;
GO

--------------------------------------------------------------------------------
-- 6. TỔNG KẾT ĐIỀU KIỆN CHỐT CHẶN (FINAL GATE)
--------------------------------------------------------------------------------
PRINT '--- 6. OVERALL VERDICT ---';

SELECT
    CASE
        WHEN NOT EXISTS (
            SELECT 1 FROM sys.availability_groups ag
            JOIN sys.availability_replicas ar ON ag.group_id = ar.group_id
            JOIN sys.dm_hadr_availability_replica_states ars ON ar.replica_id = ars.replica_id
            WHERE ag.name = CAST(SESSION_CONTEXT(N'AGName') AS sysname) AND ars.is_local = 1
              AND ars.role_desc = 'SECONDARY'
              AND ar.availability_mode_desc = 'SYNCHRONOUS_COMMIT'
              AND ars.connected_state_desc = 'CONNECTED'
              AND ars.operational_state_desc = 'ONLINE'
        ) THEN 'FAIL: Target Replica không phải SECONDARY hợp lệ hoặc mất kết nối'

        WHEN EXISTS (
            SELECT 1 FROM sys.availability_groups ag
            JOIN sys.dm_hadr_availability_replica_states ars ON ag.group_id = ars.group_id
            WHERE ag.name = CAST(SESSION_CONTEXT(N'AGName') AS sysname) AND ars.role_desc = 'PRIMARY'
              AND (ars.connected_state_desc <> 'CONNECTED' OR ars.operational_state_desc <> 'ONLINE')
        ) THEN 'FAIL: Primary hiện tại không ở trạng thái CONNECTED / ONLINE'

        WHEN EXISTS (
            SELECT 1 FROM sys.availability_groups ag
            JOIN sys.dm_hadr_database_replica_states drs ON ag.group_id = drs.group_id
            LEFT JOIN sys.dm_hadr_database_replica_cluster_states dbrcs
                ON drs.replica_id = dbrcs.replica_id AND drs.group_database_id = dbrcs.group_database_id
            WHERE ag.name = CAST(SESSION_CONTEXT(N'AGName') AS sysname) AND drs.is_local = 1
              AND (
                    ISNULL(drs.synchronization_state_desc, '') <> 'SYNCHRONIZED'
                 OR ISNULL(drs.is_suspended, 0) <> 0
                 OR ISNULL(dbrcs.is_failover_ready, 0) <> 1
                 OR ISNULL(dbrcs.is_database_joined, 0) <> 1
                 OR ISNULL(drs.log_send_queue_size, 0) / 1024.0 > CAST(SESSION_CONTEXT(N'MaxAllowedSendQueueMB') AS INT)
              )
        ) THEN 'FAIL: Tồn tại Database chưa SYNCHRONIZED, bị Treo, chưa Joined, hoặc Send Queue cao'

        WHEN (SELECT (osi.max_workers_count - osi.current_workers_count) FROM sys.dm_os_sys_info osi) < CAST(SESSION_CONTEXT(N'MinAvailableWorkers') AS INT)
            THEN 'FAIL: Worker Thread khả dụng thấp hơn ngưỡng an toàn'

        WHEN EXISTS (
            SELECT 1
            FROM sys.dm_tran_active_transactions at
            JOIN sys.dm_tran_database_transactions dt ON at.transaction_id = dt.transaction_id
            WHERE dt.database_id IN (
                    SELECT drs.database_id FROM sys.dm_hadr_database_replica_states drs
                    JOIN sys.availability_groups ag ON drs.group_id = ag.group_id
                    WHERE ag.name = CAST(SESSION_CONTEXT(N'AGName') AS sysname) AND drs.is_local = 1
                  )
              AND DATEDIFF(MINUTE, at.transaction_begin_time, GETDATE()) >= CAST(SESSION_CONTEXT(N'LongTxCriticalMinutes') AS INT)
        ) THEN 'FAIL: Có Transaction chạy quá ' + CAST(SESSION_CONTEXT(N'LongTxCriticalMinutes') AS VARCHAR(10)) + ' phút — nguy cơ Undo kéo dài sau failover'

        ELSE 'PASS - READY FOR MANUAL FAILOVER (đã kiểm tra Role/Sync/Worker/Long-Tx; xem thêm mục 4B để xác nhận hàng đợi đang GIẢM trước khi bấm Failover)'
    END AS [OVERALL_FAILOVER_ELIGIBILITY];
GO
```