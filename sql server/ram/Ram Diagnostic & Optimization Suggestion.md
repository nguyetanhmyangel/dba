

### Bảng Tinh Chỉnh SQL Max RAM và Ngưỡng Cảnh Báo, đã bao gồm phần bộ nhớ trừ hao cho antivirus (như Trellix) và các agent khác.

| **Total RAM**| **RAM OS** | **SQL Max RAM** | **WARNING(>90% SQL Max)** | **OS Free (CRITICAL)**| **Performance WARNING**                        |
|--------------|------------|-----------------|---------------------------|-----------------------|----------------------------------------------|
| 16 GB        | 6 GB       | 10 GB           | > 9.0 GB                  | < 2 GB                | PLE < 300 giây, Pages/sec > 100 (liên tục)   |
| 32 GB        | 8 GB       | 24 GB           | > 21.6 GB                 | < 3 GB                | PLE < 600 giây, Pages/sec > 100 (liên tục)   |
| 64 GB        | 8 GB       | 56 GB           | > 50.4 GB                 | < 4 GB                | PLE < 1200 giây, Pages/sec > 100 (liên tục)  |
| 128 GB       | 10 GB      | 118 GB          | > 106.2 GB                | < 6 GB                | PLE < 2400 giây, ages/sec > 100 (liên tục)   |
| 256 GB       | 10 GB      | 246 GB          | > 221.4 GB                | < 8 GB                | PLE < 4800 giây, Pages/sec > 100 (liên tục)  |
| 512 GB       | 18 GB      | 494 GB          | > 444.6 GB                | < 12 GB               | PLE < 9600 giây, Pages/sec > 100 (liên tục)  |
| 1 TB         | 34 GB      | 990 GB          | > 891.0 GB                | < 16 GB               | PLE < 19200 giây, Pages/sec > 100 (liên tục) |


### Query giám sát dựa vào bảng trên


```bash
SET NOCOUNT ON;

-- =================================================================
-- PHẦN 1: CẤU HÌNH NGƯỠNG (TÙY CHỈNH THEO MÔI TRƯỜNG CỦA BẠN)
-- =================================================================
DECLARE @OsFreeMemoryThresholdMB INT          = 2048;   -- CRITICAL nếu RAM trống của OS < 2GB. Tăng lên cho server lớn.
DECLARE @PleThresholdFactor INT             = 300;    -- Giây PLE cho mỗi 4GB RAM (giá trị tiêu chuẩn).
DECLARE @MinPleThreshold INT                = 300;    -- Ngưỡng PLE tối thiểu. Có thể tăng cho hệ thống Data Warehouse.
DECLARE @MemoryGrantsPendingThreshold INT   = 0;      -- CRITICAL nếu có bất kỳ query nào đang chờ cấp phát bộ nhớ.
DECLARE @SqlMemoryUsageWarningPct DECIMAL(5,2)  = 0.95;   -- WARNING nếu SQL dùng RAM < 95% so với Target (có thể do HĐH thu hồi).

-- =================================================================
-- PHẦN 2: LOGIC CHÍNH VÀ THU THẬP DỮ LIỆU
-- =================================================================
BEGIN TRY
    -- Khai báo các biến lưu trữ
    DECLARE @TotalOSMemoryMB BIGINT, @AvailableOSMemoryMB BIGINT;
    DECLARE @SQLTargetMemoryMB BIGINT, @SQLTotalMemoryMB BIGINT, @PLE_Seconds BIGINT, @MemoryGrantsPending INT, @MaxServerMemoryMB BIGINT;
    DECLARE @TopMemoryConsumers NVARCHAR(MAX), @ActiveWorkloads NVARCHAR(MAX);

    -- Lấy thông tin bộ nhớ OS và cấu hình 'max server memory'
    SELECT @TotalOSMemoryMB = total_physical_memory_kb / 1024, @AvailableOSMemoryMB = available_physical_memory_kb / 1024
    FROM sys.dm_os_sys_memory;

    SELECT @MaxServerMemoryMB = CAST(value_in_use AS BIGINT)
    FROM sys.configurations
    WHERE name = 'max server memory (MB)';

    -- TỐI ƯU: Lấy tất cả performance counters trong MỘT LẦN quét để tăng hiệu suất
    SELECT
        @PLE_Seconds = AVG(CASE WHEN counter_name = 'Page life expectancy' AND object_name LIKE '%Buffer Node%' THEN cntr_value END),
        @SQLTargetMemoryMB = MAX(CASE WHEN counter_name = 'Target Server Memory (KB)' THEN cntr_value END) / 1024,
        @SQLTotalMemoryMB = MAX(CASE WHEN counter_name = 'Total Server Memory (KB)' THEN cntr_value END) / 1024,
        @MemoryGrantsPending = MAX(CASE WHEN counter_name = 'Memory Grants Pending' THEN cntr_value END)
    FROM sys.dm_os_performance_counters
    WHERE
        (counter_name = 'Page life expectancy' AND object_name LIKE '%Buffer Node%') OR
        (counter_name IN ('Target Server Memory (KB)', 'Total Server Memory (KB)', 'Memory Grants Pending') AND object_name LIKE '%Memory Manager%');

    -- BỔ SUNG NGỮ CẢNH: Lấy thông tin về các workload đang chạy
    SELECT @ActiveWorkloads = STRING_AGG(
        'Session ' + CAST(s.session_id AS VARCHAR) + ' (' + LTRIM(RTRIM(s.program_name)) + '): CPU=' + CAST(r.cpu_time AS VARCHAR) + 'ms, Reads=' + CAST(r.reads AS VARCHAR),
        ' | '
    )
    FROM sys.dm_exec_sessions s
    JOIN sys.dm_exec_requests r ON s.session_id = r.session_id
    WHERE s.is_user_process = 1 AND s.status = 'running';

    -- Tính ngưỡng PLE động
    DECLARE @PleActualThreshold INT = (@SQLTotalMemoryMB / 4096) * @PleThresholdFactor;
    IF @PleActualThreshold < @MinPleThreshold SET @PleActualThreshold = @MinPleThreshold;

    -- Lấy top 3 query tiêu tốn bộ nhớ nhất
    SELECT @TopMemoryConsumers = STRING_AGG(
        'Session ' + CAST(session_id AS VARCHAR) + ': ' + CAST(granted_memory_kb / 1024 AS VARCHAR) + ' MB - ' + LEFT(query_text, 150),
        ' | '
    )
    FROM (
        SELECT TOP 3 g.session_id, g.granted_memory_kb,
               (SELECT SUBSTRING(text, r.statement_start_offset/2 + 1,
                    (CASE WHEN r.statement_end_offset = -1 THEN DATALENGTH(text) ELSE r.statement_end_offset END - r.statement_start_offset)/2 + 1)
                FROM sys.dm_exec_sql_text(r.sql_handle)) AS query_text
        FROM sys.dm_exec_query_memory_grants g
        JOIN sys.dm_exec_requests r ON g.session_id = r.session_id
        WHERE g.granted_memory_kb > 1024 ORDER BY g.granted_memory_kb DESC
    ) AS TopQueries;

    -- Tự động tạo bảng log nếu chưa tồn tại
    IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'MemoryMonitoringLog')
    CREATE TABLE MemoryMonitoringLog (
        log_id INT IDENTITY(1,1) PRIMARY KEY,
        check_timestamp DATETIME2(3), alert_status VARCHAR(10), alert_message_json NVARCHAR(MAX),
        ple_seconds BIGINT, ple_threshold_seconds INT, memory_grants_pending INT,
        os_available_mb BIGINT, sql_total_used_mb BIGINT, sql_max_memory_setting_mb BIGINT,
        top_3_memory_consumers NVARCHAR(MAX), active_workloads NVARCHAR(MAX)
    );

    -- Tạo cảnh báo định dạng JSON dễ phân tích
    DECLARE @AlertMessageJSON NVARCHAR(MAX);
    SET @AlertMessageJSON = (
        SELECT
            memory_grants_pending = CASE WHEN @MemoryGrantsPending > @MemoryGrantsPendingThreshold THEN 'CRITICAL: ' + CAST(@MemoryGrantsPending AS VARCHAR) + ' query is waiting for memory!' END,
            os_free_memory = CASE WHEN @AvailableOSMemoryMB < @OsFreeMemoryThresholdMB THEN 'CRITICAL: OS Free Memory LOW (' + FORMAT(@AvailableOSMemoryMB, 'N0') + ' MB)' END,
            ple_status = CASE WHEN @PLE_Seconds < @PleActualThreshold THEN 'WARNING: PLE LOW (' + CAST(@PLE_Seconds AS VARCHAR) + 's / Threshold: ' + CAST(@PleActualThreshold AS VARCHAR) + 's)' END,
            max_memory_setting = CASE WHEN @MaxServerMemoryMB > @TotalOSMemoryMB * 0.95 THEN 'WARNING: Max Server Memory is set too high.' END,
            sql_memory_usage = CASE WHEN @SQLTotalMemoryMB < @SQLTargetMemoryMB * @SqlMemoryUsageWarningPct THEN 'WARNING: SQL is using less memory than its target.' END
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER -- Dùng WITHOUT_ARRAY_WRAPPER để có JSON object đơn giản
    );

    -- Xác định trạng thái cuối cùng
    DECLARE @AlertStatus VARCHAR(10);
    SET @AlertStatus = CASE
        WHEN @MemoryGrantsPending > @MemoryGrantsPendingThreshold OR @AvailableOSMemoryMB < @OsFreeMemoryThresholdMB THEN 'CRITICAL'
        WHEN @AlertMessageJSON LIKE '%WARNING%' OR @AlertMessageJSON LIKE '%CRITICAL%' THEN 'WARNING'
        ELSE 'OK'
    END;

    -- Lưu vào bảng log
    INSERT INTO MemoryMonitoringLog (check_timestamp, alert_status, alert_message_json, ple_seconds, ple_threshold_seconds,
        memory_grants_pending, os_available_mb, sql_total_used_mb, sql_max_memory_setting_mb, top_3_memory_consumers, active_workloads)
    VALUES (GETDATE(), @AlertStatus, @AlertMessageJSON, @PLE_Seconds, @PleActualThreshold,
        @MemoryGrantsPending, @AvailableOSMemoryMB, @SQLTotalMemoryMB, @MaxServerMemoryMB, @TopMemoryConsumers, @ActiveWorkloads);

    -- Trả về kết quả tại thời điểm chạy
    SELECT
        GETDATE() AS check_timestamp, @AlertStatus AS alert_status, @AlertMessageJSON AS alert_message_json,
        @PLE_Seconds AS ple_seconds, @PleActualThreshold AS ple_threshold_seconds, @MemoryGrantsPending AS memory_grants_pending,
        @AvailableOSMemoryMB AS os_available_mb, @SQLTotalMemoryMB AS sql_total_used_mb, @MaxServerMemoryMB AS sql_max_memory_setting_mb,
        @TopMemoryConsumers AS top_3_memory_consumers, @ActiveWorkloads AS active_workloads;

END TRY
BEGIN CATCH
    -- Ghi nhận lỗi nếu script không chạy được
    DECLARE @ErrorMessage NVARCHAR(MAX) = 'Error: ' + ERROR_MESSAGE();
    -- Cân nhắc ghi lỗi này vào một bảng log lỗi riêng hoặc gửi email thông báo
    SELECT
        GETDATE() AS check_timestamp, 'ERROR' AS alert_status, @ErrorMessage AS alert_message_json,
        NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL;
END CATCH;
```

### Cách sử dụng tốt nhất (Quy trình 4 bước)

#### Bước 1: Tùy chỉnh ngưỡng

- Mở script và điều chỉnh các giá trị trong PHẦN 1: CẤU HÌNH NGƯỠNG.

- @OsFreeMemoryThresholdMB: Phụ thuộc vào tổng RAM của bạn. Một quy tắc chung là giữ lại 5-10% RAM cho hệ điều hành. Ví dụ: Server 128GB RAM có thể đặt ngưỡng là 8192 (8GB).

- @MinPleThreshold: Đối với hệ thống OLTP (nhiều giao dịch nhỏ, nhanh), 300 là ổn. Đối với hệ thống Data Warehouse/OLAP (xử lý dữ liệu lớn), bạn có thể cần tăng lên 1000 hoặc cao hơn.

#### Bước 2: Tự động hóa bằng SQL Server Agent Job 

- Đây là cách triển khai phổ biến và hiệu quả nhất.

- Mở SQL Server Management Studio (SSMS), kết nối tới instance của bạn.

- Trong Object Explorer, mở rộng SQL Server Agent, chuột phải vào Jobs -> New Job....

- Đặt tên cho Job, ví dụ: [Admin] - Monitor Memory Health.

- Chuyển qua tab Steps, nhấn New....

- Đặt tên Step: Run Memory Check.

- Trong ô Command, dán toàn bộ script ở trên.

- Nhấn OK.

- Chuyển qua tab Schedules, nhấn New....

- Đặt tên Schedule: Every 5 Minutes.

- Cấu hình cho Job chạy định kỳ. Tần suất 5 đến 15 phút là hợp lý cho hầu hết các hệ thống.

- Nhấn OK hai lần để lưu Job.

#### Bước 3: Cấu hình cảnh báo (Alerting) 

- Mục tiêu là nhận được thông báo khi có sự cố.

- Chỉnh sửa Step của Agent Job đã tạo ở Bước 2.

- Chuyển qua tab Advanced.

- Trong phần On success action, chọn "Quit the job reporting success".

- Trong phần On failure action, chọn "Quit the job reporting failure" và cấu hình Notifications để gửi email cho bạn khi Job bị lỗi (lỗi trong khối CATCH).

- Để cảnh báo khi trạng thái là WARNING/CRITICAL:

- Sửa lại code trong Step của Job, thêm đoạn logic T-SQL sau vào cuối script:


```bash
-- Thêm vào cuối khối TRY
IF @AlertStatus IN ('CRITICAL', 'WARNING')
BEGIN
    DECLARE @MailBody NVARCHAR(MAX);
    SET @MailBody = N'SQL Server Memory Alert: ' + @AlertStatus + CHAR(13) + CHAR(10) +
                    N'Details (JSON): ' + @AlertMessageJSON + CHAR(13) + CHAR(10) +
                    N'Top Consumers: ' + ISNULL(@TopMemoryConsumers, 'N/A');

    EXEC msdb.dbo.sp_send_dbmail
        @profile_name = 'Your_Mail_Profile', -- << THAY TÊN PROFILE CỦA BẠN
        @recipients = 'your_dba_email@company.com', -- << THAY EMAIL CỦA BẠN
        @subject = 'SQL Server Memory Alert',
        @body = @MailBody;
END
```

#### Bước 4: Phân tích và hành động 

- Khi nhận được cảnh báo hoặc khi cần kiểm tra định kỳ, hãy sử dụng bảng log.

- Kiểm tra lịch sử:
```bash
-- Xem lại tất cả các cảnh báo trong 24 giờ qua
SELECT * FROM MemoryMonitoringLog
WHERE alert_status <> 'OK' AND check_timestamp >= DATEADD(hour, -24, GETDATE())
ORDER BY log_id DESC;
```
- Phân tích xu hướng PLE:
```bash
-- Xem xu hướng PLE trong 7 ngày qua để tìm quy luật
SELECT CAST(check_timestamp AS DATE) AS log_date, AVG(ple_seconds) AS average_ple
FROM MemoryMonitoringLog
WHERE check_timestamp >= DATEADD(day, -7, GETDATE())
GROUP BY CAST(check_timestamp AS DATE)
ORDER BY log_date;
```
- Hành động:

    - Nếu có cảnh báo, hãy xem cột alert_message_json để biết nguyên nhân gốc.

    - Nhìn vào cột top_3_memory_consumers để xác định "thủ phạm".

    - Kiểm tra cột active_workloads để hiểu bối cảnh: "À, lỗi xảy ra khi job ETL đang chạy!".