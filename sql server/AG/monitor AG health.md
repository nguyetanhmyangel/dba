```bash
-- =================================================================================
-- Script:       AlwaysOn Health Check 
-- Description:  A comprehensive and robust procedure to monitor the health of
--               AlwaysOn Availability Groups and underlying server resources.
--
-- Features:
-- - Accurate, real-time sampling for CPU Usage and Disk I/O Latency.
-- - DRY Principle applied using a CTE for cleaner, maintainable AG queries.
-- - Consolidated and efficient checks for HADR waits.
-- - Set-based, high-performance email validation function.
-- - Flexible control via parameters for sampling and debug mode.
-- - Robust error handling and notification system.
-- =================================================================================

-- Step 1: Create or verify the audit table structure
IF OBJECT_ID('dbo.DBA_Audit_AGHealth', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.DBA_Audit_AGHealth (
        AuditID INT IDENTITY PRIMARY KEY,
        CheckTime DATETIME2(3) DEFAULT SYSUTCDATETIME(),
        ServerName SYSNAME DEFAULT @@SERVERNAME,
        AGName SYSNAME NULL, -- NULL for server-level issues
        DatabaseName SYSNAME NULL,
        ReplicaName SYSNAME,
        RoleDesc NVARCHAR(60) NULL,
        IssueType NVARCHAR(128),
        MetricValue BIGINT,
        ThresholdValue BIGINT,
        Details NVARCHAR(1024)
    );
END
GO

---
-- Step 2: Create the highly efficient, set-based email validation function
CREATE OR ALTER FUNCTION dbo.fn_ValidateEmailRecipients (@Recipients NVARCHAR(4000))
RETURNS BIT
AS
BEGIN
    -- This set-based approach is more efficient than a WHILE loop.
    -- It checks if any of the split email strings do NOT match a basic valid pattern.
    IF EXISTS (
        SELECT 1
        FROM STRING_SPLIT(REPLACE(@Recipients, ' ', ''), ';')
        WHERE LTRIM(RTRIM(value)) != '' -- Ignore empty entries from consecutive semicolons
          AND LTRIM(RTRIM(value)) NOT LIKE '%_@__%.__%' -- A simple but effective pattern check
    )
        RETURN 0; -- Found at least one invalid email string

    RETURN 1; -- All email strings appear valid
END;
GO

---
-- Step 3: Create the final, optimized stored procedure
CREATE OR ALTER PROCEDURE dbo.usp_CheckAGHealth_Pro_v5
    -- AG-specific thresholds
    @LogSendQueueThresholdKB INT = 50000,
    @RedoQueueThresholdKB INT = 50000,
    @RedoRateThresholdKBps INT = 100,
    @HadrWaitThresholdMS INT = 1000,
    -- Server resource thresholds
    @CPUUsageThresholdPercent INT = 80,
    @LowMemoryThresholdMB BIGINT = 500,
    @DiskIOLatencyThresholdMS INT = 50,
    -- Sampling options for performance tuning
    @EnableDiskIOSampling BIT = 1,
    @DiskIOSampleDelaySeconds TINYINT = 5,
    @EnableCPUSampling BIT = 1,
    @CPUSampleDelaySeconds TINYINT = 2,
    -- Execution options
    @LogToTable BIT = 1,
    @SendEmail BIT = 1,
    @EmailRecipients NVARCHAR(4000) = N'dba-team@company.com',
    @DBMailProfileName SYSNAME = N'DBA_Mail_Profile',
    @DebugMode BIT = 0 -- If 1, prints issues to console without logging or emailing
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Issues TABLE (
        AGName SYSNAME NULL, DatabaseName SYSNAME NULL, ReplicaName SYSNAME,
        RoleDesc NVARCHAR(60) NULL, IssueType NVARCHAR(128), MetricValue BIGINT,
        ThresholdValue BIGINT, Details NVARCHAR(1024)
    );
    DECLARE @ServerName SYSNAME = @@SERVERNAME;

    BEGIN TRY
        -- === Input Validation ===
        IF @SendEmail = 1 AND dbo.fn_ValidateEmailRecipients(@EmailRecipients) = 0
        BEGIN
            RAISERROR('Invalid or empty email recipients list provided.', 16, 1); RETURN;
        END

        -- ========================================================================
        -- PART 1: SERVER-LEVEL RESOURCE CHECKS (Run only ONCE)
        -- ========================================================================

        -- === 1. Check CPU Usage (Accurate Sampling Method) ===
        IF @EnableCPUSampling = 1
        BEGIN
            DECLARE @SQLProcessUtilization INT;
            -- Using the ring buffer is a lightweight and effective way to get recent process CPU
            SELECT @SQLProcessUtilization = SQLProcessUtilization
            FROM (
                SELECT
                    record.value('(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]', 'int') AS SQLProcessUtilization,
                    ROW_NUMBER() OVER (ORDER BY record.value('(./Record/@id)[1]', 'bigint') DESC) AS rn
                FROM (SELECT CONVERT(XML, record) AS record FROM sys.dm_os_ring_buffers WHERE ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR') AS x
            ) AS y
            WHERE rn = 1;

            IF @SQLProcessUtilization > @CPUUsageThresholdPercent
            BEGIN
                INSERT INTO @Issues (AGName, ReplicaName, IssueType, MetricValue, ThresholdValue, Details)
                VALUES (NULL, @ServerName, 'High SQL Server CPU Usage', @SQLProcessUtilization, @CPUUsageThresholdPercent,
                        CONCAT('SQL Server process CPU utilization is ', @SQLProcessUtilization, '%. Exceeds threshold of ', @CPUUsageThresholdPercent, '%.'));
            END
        END

        -- === 2. Check Memory Pressure ===
        IF EXISTS (SELECT 1 FROM sys.dm_os_process_memory WHERE process_physical_memory_low = 1)
        BEGIN
            INSERT INTO @Issues (AGName, ReplicaName, IssueType, MetricValue, ThresholdValue, Details)
            VALUES (NULL, @ServerName, 'Memory Pressure Detected', 1, 0, 'SQL Server signaled low physical memory (process_physical_memory_low = 1).');
        END
        
        -- You can also check for available memory if desired
        DECLARE @AvailableMemoryMB BIGINT = (SELECT available_physical_memory_kb / 1024 FROM sys.dm_os_sys_memory);
        IF @AvailableMemoryMB < @LowMemoryThresholdMB
        BEGIN
             INSERT INTO @Issues (AGName, ReplicaName, IssueType, MetricValue, ThresholdValue, Details)
             VALUES (NULL, @ServerName, 'Low Available OS Memory', @AvailableMemoryMB, @LowMemoryThresholdMB,
                     CONCAT('Available OS memory is ', @AvailableMemoryMB, ' MB, below threshold of ', @LowMemoryThresholdMB, ' MB.'));
        END

        -- === 3. Check Disk I/O Latency (Sampling Method) ===
        IF @EnableDiskIOSampling = 1
        BEGIN
            IF OBJECT_ID('tempdb..#VFS_Snapshot1') IS NOT NULL DROP TABLE #VFS_Snapshot1;
            IF OBJECT_ID('tempdb..#VFS_Snapshot2') IS NOT NULL DROP TABLE #VFS_Snapshot2;

            SELECT database_id, file_id, num_of_reads, num_of_writes, io_stall_read_ms, io_stall_write_ms
            INTO #VFS_Snapshot1 FROM sys.dm_io_virtual_file_stats(NULL, NULL);

            WAITFOR DELAY (CONCAT('00:00:', FORMAT(@DiskIOSampleDelaySeconds, '00')));

            SELECT database_id, file_id, num_of_reads, num_of_writes, io_stall_read_ms, io_stall_write_ms
            INTO #VFS_Snapshot2 FROM sys.dm_io_virtual_file_stats(NULL, NULL);

            INSERT INTO @Issues (DatabaseName, ReplicaName, IssueType, MetricValue, ThresholdValue, Details)
            SELECT
                DB_NAME(s2.database_id) AS DatabaseName, @ServerName, 'High Disk I/O Latency',
                CAST(s.avg_latency_ms AS BIGINT) AS MetricValue, @DiskIOLatencyThresholdMS,
                CONCAT('Avg I/O latency for DB [', DB_NAME(s2.database_id), '] on file [', mf.physical_name,
                       '] is ', CAST(s.avg_latency_ms AS INT), ' ms.')
            FROM #VFS_Snapshot2 s2
            JOIN #VFS_Snapshot1 s1 ON s1.database_id = s2.database_id AND s1.file_id = s2.file_id
            JOIN sys.master_files mf ON mf.database_id = s2.database_id AND mf.file_id = s2.file_id
            CROSS APPLY (
                SELECT ((s2.io_stall_read_ms - s1.io_stall_read_ms) + (s2.io_stall_write_ms - s1.io_stall_write_ms)) /
                       NULLIF((s2.num_of_reads - s1.num_of_reads) + (s2.num_of_writes - s1.num_of_writes), 0) AS avg_latency_ms
            ) s
            WHERE s.avg_latency_ms > @DiskIOLatencyThresholdMS;
        END

        -- ========================================================================
        -- PART 2: AVAILABILITY GROUP SPECIFIC CHECKS (using CTE for DRY principle)
        -- ========================================================================
        ;WITH DatabaseReplicaInfo AS (
            -- Define the common join logic once to keep the code DRY and improve readability
            SELECT
                ag.name AS AGName, ar.replica_server_name AS ReplicaName, ars.role_desc AS RoleDesc,
                drs.database_name AS DatabaseName, drs.database_id, drs.is_primary_replica,
                drs.synchronization_state_desc, drs.log_send_queue_size, drs.redo_queue_size,
                drs.redo_rate
            FROM sys.availability_groups ag
            JOIN sys.availability_replicas ar ON ag.group_id = ar.group_id
            JOIN sys.dm_hadr_availability_replica_states ars ON ar.replica_id = ars.replica_id
            JOIN sys.dm_hadr_database_replica_states drs ON ar.replica_id = drs.replica_id AND drs.group_database_id = ars.group_database_id
        )
        -- Insert all AG-related issues in a single, multi-part query for efficiency
        INSERT INTO @Issues (AGName, DatabaseName, ReplicaName, RoleDesc, IssueType, MetricValue, ThresholdValue, Details)
        -- === 4. Check Queues and Rates ===
        SELECT AGName, DatabaseName, ReplicaName, RoleDesc, v.IssueType, v.MetricValue, v.ThresholdValue,
               CONCAT(v.IssueType, ' is ', v.MetricValue, v.Unit, '. Threshold is ', v.ThresholdValue, v.Unit, '.')
        FROM DatabaseReplicaInfo
        CROSS APPLY ( VALUES
            ('Log Send Queue High', log_send_queue_size, @LogSendQueueThresholdKB, ' KB'),
            ('Redo Queue High', redo_queue_size, @RedoQueueThresholdKB, ' KB'),
            ('Redo Rate Low', redo_rate, @RedoRateThresholdKBps, ' KB/s')
        ) AS v(IssueType, MetricValue, ThresholdValue, Unit)
        WHERE
            (is_primary_replica = 1 AND v.IssueType = 'Log Send Queue High' AND v.MetricValue > v.ThresholdValue)
         OR (is_primary_replica = 0 AND v.IssueType = 'Redo Queue High'   AND v.MetricValue > v.ThresholdValue)
         OR (is_primary_replica = 0 AND v.IssueType = 'Redo Rate Low'     AND v.MetricValue < v.ThresholdValue AND v.MetricValue IS NOT NULL)
        UNION ALL
        -- === 5. Check Active HADR Waits (Consolidated) ===
        SELECT
            dri.AGName, dri.DatabaseName, dri.ReplicaName, dri.RoleDesc,
            'High HADR Wait', wt.wait_duration_ms, @HadrWaitThresholdMS,
            CONCAT('Session ', wt.session_id, ' waiting on ', wt.wait_type, ' for ', wt.wait_duration_ms, ' ms.')
        FROM sys.dm_os_waiting_tasks wt
        JOIN DatabaseReplicaInfo dri ON wt.resource_description LIKE CONCAT('%db_id=', dri.database_id, '%')
        WHERE wt.wait_type LIKE 'HADR%' AND wt.wait_duration_ms > @HadrWaitThresholdMS
        UNION ALL
        -- === 6. Check AG Synchronization State ===
        SELECT AGName, DatabaseName, ReplicaName, RoleDesc,
            'AG Not Healthy', 0, 0,
            CONCAT('Database state is ''', synchronization_state_desc, '''. Expected SYNCHRONIZED or SYNCHRONIZING.')
        FROM DatabaseReplicaInfo
        WHERE synchronization_state_desc NOT IN ('SYNCHRONIZED', 'SYNCHRONIZING');

        -- ========================================================================
        -- PART 3: LOGGING AND NOTIFICATION / DEBUG MODE
        -- ========================================================================
        IF @DebugMode = 1
        BEGIN
            SELECT '--- DEBUG MODE: Issues Found ---' AS A; SELECT * FROM @Issues ORDER BY AGName, DatabaseName, IssueType; RETURN;
        END

        IF EXISTS (SELECT 1 FROM @Issues)
        BEGIN
            IF @LogToTable = 1
            BEGIN
                INSERT INTO dbo.DBA_Audit_AGHealth (AGName, DatabaseName, ReplicaName, RoleDesc, IssueType, MetricValue, ThresholdValue, Details)
                SELECT AGName, DatabaseName, ReplicaName, RoleDesc, IssueType, MetricValue, ThresholdValue, Details FROM @Issues;
            END

            IF @SendEmail = 1
            BEGIN
                DECLARE @IssueCount INT = (SELECT COUNT(*) FROM @Issues);
                DECLARE @Body NVARCHAR(MAX) = N'<html><body>' +
                    N'<h2><font color="red">SQL Server Health Alert</font></h2>' +
                    N'<p>Issues detected on server <b>' + @ServerName + N'</b> at ' + CONVERT(NVARCHAR, SYSUTCDATETIME(), 120) + N' (UTC).</p>' +
                    CASE WHEN @IssueCount > 50 THEN N'<p><b>Warning:</b> ' + CAST(@IssueCount AS NVARCHAR) + N' issues found. Showing first 50.</p>' ELSE '' END +
                    N'<table border="1" cellpadding="5" cellspacing="0" style="border-collapse:collapse; font-family: calibri;">' +
                    N'<tr bgcolor="#E6E6FA"><th>AG Name</th><th>Database</th><th>Replica</th><th>Role</th><th>Issue Type</th><th>Metric</th><th>Threshold</th><th>Details</th></tr>' +
                    CAST((
                        SELECT TOP 50
                            td = ISNULL(AGName, 'N/A - Server'), '', td = ISNULL(DatabaseName, 'N/A'), '', td = ReplicaName, '',
                            td = ISNULL(RoleDesc, 'N/A'), '', td = IssueType, '', td = MetricValue, '', td = ThresholdValue, '',
                            td = Details, ''
                        FROM @Issues ORDER BY AGName, DatabaseName, IssueType
                        FOR XML PATH('tr'), TYPE
                    ) AS NVARCHAR(MAX)) + N'</table></body></html>';

                EXEC msdb.dbo.sp_send_dbmail
                    @profile_name = @DBMailProfileName, @recipients = @EmailRecipients,
                    @subject = CONCAT('SQL Health Alert on ', @ServerName),
                    @body = @Body, @body_format = 'HTML';
            END
        END
    END TRY
    BEGIN CATCH
        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE(), @ErrorLine INT = ERROR_LINE();

        IF @LogToTable = 1
        BEGIN
            INSERT INTO dbo.DBA_Audit_AGHealth (AGName, IssueType, Details)
            VALUES (NULL, 'Procedure Error', CONCAT('Error in usp_CheckAGHealth_Pro_v5 at line ', @ErrorLine, ': ', @ErrorMessage));
        END
        THROW; -- Re-throw the error to ensure the SQL Agent job reports failure
    END CATCH
    FINALLY
    BEGIN
        -- Final cleanup of any temporary objects
        IF OBJECT_ID('tempdb..#VFS_Snapshot1') IS NOT NULL DROP TABLE #VFS_Snapshot1;
        IF OBJECT_ID('tempdb..#VFS_Snapshot2') IS NOT NULL DROP TABLE #VFS_Snapshot2;
    END
END
GO
```

- Thực thi toàn bộ script trên mỗi Replica (Primary và Secondary) mà muốn giám sát.

- Script sẽ tự động tạo ra 3 đối tượng sau trong database mà chạy nó (thường là master hoặc một database dành riêng cho DBA):

- Bảng dbo.DBA_Audit_AGHealth để lưu trữ lịch sử các vấn đề.

- Function dbo.fn_ValidateEmailRecipients để kiểm tra email.

- Stored Procedure dbo.usp_CheckAGHealth_Pro_v5 là công cụ giám sát chính.

Script sử dụng msdb.dbo.sp_send_dbmail để gửi email. Hãy chắc chắn rằng:

- Database Mail đã được kích hoạt và hoạt động bình thường trên server.

- Tên Profile Mail (@DBMailProfileName) bạn truyền vào procedure phải khớp với một profile đã tồn tại trong cấu hình Database Mail.

-  Lên lịch thực thi với SQL Server Agent. Đây là cách tốt nhất để tự động hóa việc giám sát.

- Mẫu lệnh thực thi:

```bash
EXEC dbo.usp_CheckAGHealth_Pro_v5
    -- Tùy chỉnh các ngưỡng cảnh báo cho phù hợp với môi trường của bạn
    @LogSendQueueThresholdKB    = 100000,  -- 100 MB
    @RedoQueueThresholdKB       = 100000,  -- 100 MB
    @CPUUsageThresholdPercent   = 90,      -- Cảnh báo nếu CPU > 90%
    @DiskIOLatencyThresholdMS   = 50,      -- Cảnh báo nếu độ trễ disk > 50ms

    -- Cấu hình email nhận cảnh báo
    @EmailRecipients    = N'dba-team@company.com;oncall-dba@company.com',
    @DBMailProfileName  = N'DBA Mail Profile', -- Thay bằng tên profile mail của bạn

    -- Bật/tắt các tính năng nâng cao
    @EnableDiskIOSampling = 1, -- Bật để đo độ trễ disk chính xác
    @EnableCPUSampling    = 1; -- Bật để đo CPU chính xác
```

1. IssueType: High SQL Server CPU Usage

- Ý nghĩa: Tiến trình SQL Server đang chiếm dụng quá nhiều CPU, làm chậm mọi thứ.

- Nguyên nhân phổ biến: Các truy vấn nặng, thiếu index, thống kê (statistics) cũ, blocking.

- Hành động:

    - Chạy ngay sp_whoisactive hoặc SELECT * FROM sys.dm_exec_requests để xem các session nào đang hoạt động và chiếm nhiều CPU.

    - Kiểm tra các truy vấn có CPU time cao nhất trong sys.dm_exec_query_stats.

    - Xem execution plan của các truy vấn đó để tìm cơ hội tối ưu (thêm index, viết lại logic).

2. IssueType: Memory Pressure Detected / Low Available OS Memory

- Ý nghĩa: SQL Server hoặc hệ điều hành đang thiếu bộ nhớ (RAM). Điều này dẫn đến việc dữ liệu bị đẩy ra khỏi cache và phải đọc lại từ đĩa, gây chậm.

- Nguyên nhân phổ biến: Cấu hình max server memory quá cao, có ứng dụng khác trên server chiếm RAM, không đủ RAM vật lý.

- Hành động:

    - Kiểm tra cấu hình max server memory của SQL Server. Đảm bảo nó chừa lại đủ RAM cho hệ điều hành (thường là 1-4 GB hoặc 10% tổng RAM).

    - Dùng Task Manager hoặc Resource Monitor để xem có tiến trình nào khác ngoài sqlservr.exe đang chiếm nhiều RAM không.

    - Cân nhắc nâng cấp RAM cho server.

3. IssueType: High Disk I/O Latency

- Ý nghĩa: Hệ thống lưu trữ (Disk/SAN) phản hồi rất chậm. Đây là "kẻ thù" số một của hiệu năng database.

- Nguyên nhân phổ biến: Đĩa vật lý chậm, cấu hình SAN sai, backup/restore/DBCC chạy cùng lúc, các truy vấn gây scan dữ liệu lớn.

- Hành động:

    - Xác định database và file nào đang có độ trễ cao từ nội dung cảnh báo.

    - Dùng sp_whoisactive để tìm các session đang có physical_reads hoặc writes cao.

    - Phân tích các truy vấn đó để giảm I/O (ví dụ: thêm index để tránh table scan).

    - Làm việc với đội ngũ Storage/System Admin để kiểm tra sức khỏe của hệ thống đĩa.

4. IssueType: Log Send Queue High (trên Primary)

- Ý nghĩa: Replica Primary đang tạo ra log nhanh hơn tốc độ gửi nó qua Secondary. Dữ liệu đang bị "tắc nghẽn" trên Primary.

- Nguyên nhân phổ biến: Vấn đề về mạng (network) giữa Primary và Secondary (phổ biến nhất), hoặc do Secondary quá tải và phản hồi chậm (flow control).

- Hành động:

    - Kiểm tra ngay cảnh báo Redo Queue High trên Secondary.

    - Nếu Redo Queue cũng cao, vấn đề nằm ở Secondary.

    - Nếu Redo Queue thấp, vấn đề 100% là do network.

    - Sử dụng lệnh ping -t <Secondary_IP> để kiểm tra độ trễ (latency) và tình trạng mất gói (packet loss).

    - Liên hệ đội ngũ Network để kiểm tra đường truyền giữa hai server.

5. IssueType: Redo Queue High (trên Secondary)

- Ý nghĩa: Secondary đã nhận được log nhưng không thể ghi (redo) vào file database đủ nhanh. Dữ liệu đang bị "tắc nghẽn" trên Secondary.

- Nguyên nhân phổ biến: Hệ thống I/O trên Secondary chậm (phổ biến nhất), CPU trên Secondary bị quá tải, hoặc có blocking trên Secondary (một truy vấn read-only đang khóa một đối tượng mà redo thread cần).

- Hành động:

    - Đối chiếu ngay với các cảnh báo khác trên chính server Secondary này! Rất có thể bạn sẽ thấy cảnh báo High Disk I/O Latency hoặc High CPU Usage đi kèm.

    - Kiểm tra xem phần cứng (Disk, CPU) của Secondary có tương đương với Primary không.

    - Chạy sp_whoisactive trên Secondary để kiểm tra xem có session nào đang block session của redo thread không (thường có session_id < 0).

6. IssueType: AG Not Healthy

- Ý nghĩa: Cảnh báo nghiêm trọng! Một database không còn ở trạng thái SYNCHRONIZED hoặc SYNCHRONIZING. Dữ liệu đang không được bảo vệ.

- Nguyên nhân phổ biến: Data movement bị tạm dừng thủ công, lỗi kết nối, hết dung lượng đĩa chứa file log trên Secondary, lỗi phân quyền.

- Hành động:

    - Ngay lập tức mở SSMS, kết nối tới AG và mở Availability Group Dashboard. Dashboard sẽ cho bạn thấy chính xác lỗi là gì.

    - Kiểm tra SQL Server Error Log trên cả Primary và Secondary. Sẽ có thông báo lỗi rất chi tiết về nguyên nhân.

    - Xử lý gốc rễ vấn đề (thêm dung lượng đĩa, sửa lỗi phân quyền...).

    - Sau khi đã sửa lỗi, dùng Dashboard hoặc lệnh T-SQL để Resume Data Movement.