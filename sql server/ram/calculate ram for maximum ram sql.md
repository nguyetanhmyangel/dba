

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
/********************************************************************************
 * CHỈ CẦN CẤU HÌNH CÁC THAM SỐ TRONG PHẦN NÀY
 ********************************************************************************/
DECLARE @TotalRAMGB INT,
        @MaxSqlMemoryMB BIGINT,
        @OsFreeMemoryThresholdMB BIGINT,
        @PleThresholdSeconds INT;

-- Cấu hình cho Server (ví dụ: 512GB RAM)
SET @TotalRAMGB = 512;  -- Tổng RAM server (GB)
SET @MaxSqlMemoryMB = 494 * 1024;  -- 494 GB (đơn vị MB)
SET @OsFreeMemoryThresholdMB = 12 * 1024;  -- 12 GB (đơn vị MB)

SET NOCOUNT ON;

-- Lấy số NUMA node để tính PLE động
DECLARE @NumaNodes INT;
SELECT @NumaNodes = COUNT(DISTINCT parent_node_id)
FROM sys.dm_os_schedulers
WHERE scheduler_id < 255 AND status = 'VISIBLE ONLINE';

-- Tính PLE Threshold động, đây là phương pháp được khuyến nghị
-- Công thức cơ bản: 300 giây cho mỗi 4GB RAM, điều chỉnh theo NUMA
SET @PleThresholdSeconds = (@TotalRAMGB / 4) * 300 / @NumaNodes;
-- Đặt ngưỡng tối thiểu và tối đa để tránh các giá trị quá dị
IF @PleThresholdSeconds < 300 SET @PleThresholdSeconds = 300;
IF @PleThresholdSeconds > 10000 SET @PleThresholdSeconds = 10000;
-- Hoặc bạn có thể dùng ngưỡng cố định nếu muốn:
-- SET @PleThresholdSeconds = 5000;

-- Lấy dữ liệu hiệu suất
;WITH PerfCounters AS (
    SELECT
        MAX(CASE WHEN counter_name LIKE 'Page life expectancy%' THEN cntr_value ELSE NULL END) AS ple_seconds
    FROM sys.dm_os_performance_counters
    WHERE counter_name LIKE 'Page life expectancy%'
        AND object_name LIKE '%Buffer Manager%'
),
CurrentState AS (
    SELECT
        (SELECT available_physical_memory_kb / 1024 FROM sys.dm_os_sys_memory) AS os_available_memory_mb,
        (SELECT physical_memory_in_use_kb / 1024 FROM sys.dm_os_process_memory) AS sql_memory_in_use_mb,
        pc.ple_seconds
    FROM PerfCounters pc
),
TopQueries AS (
    SELECT TOP 3
        session_id,
        granted_memory_kb / 1024 AS granted_memory_mb,
        (SELECT SUBSTRING(text, r.statement_start_offset/2 + 1,
            (CASE WHEN r.statement_end_offset = -1 THEN DATALENGTH(text) ELSE r.statement_end_offset END - r.statement_start_offset)/2 + 1)
         FROM sys.dm_exec_sql_text(r.sql_handle)) AS query_text
    FROM sys.dm_exec_query_memory_grants g
    JOIN sys.dm_exec_requests r ON g.session_id = r.session_id
    WHERE g.granted_memory_kb > 0
    ORDER BY g.granted_memory_kb DESC
)
SELECT
    cs.sql_memory_in_use_mb,
    @MaxSqlMemoryMB * 0.9 AS sql_warning_threshold_mb,
    cs.os_available_memory_mb,
    @OsFreeMemoryThresholdMB AS os_critical_threshold_mb,
    cs.ple_seconds,
    @PleThresholdSeconds AS ple_warning_threshold,
    CASE
        WHEN cs.os_available_memory_mb < @OsFreeMemoryThresholdMB THEN 'CRITICAL'
        WHEN cs.sql_memory_in_use_mb > (@MaxSqlMemoryMB * 0.9) OR cs.ple_seconds < @PleThresholdSeconds THEN 'WARNING'
        ELSE 'OK'
    END AS alert_status,
    TRIM(' | ' FROM CONCAT_WS(' | ',
        CASE WHEN cs.os_available_memory_mb < @OsFreeMemoryThresholdMB
             THEN 'OS Free Memory LOW (' + FORMAT(cs.os_available_memory_mb, 'N1') + ' MB)'
             ELSE '' END,
        CASE WHEN cs.sql_memory_in_use_mb > (@MaxSqlMemoryMB * 0.9)
             THEN 'SQL Memory > 90% (' + FORMAT(cs.sql_memory_in_use_mb, 'N1') + ' MB)'
             ELSE '' END,
        CASE WHEN cs.ple_seconds < @PleThresholdSeconds
             THEN 'PLE LOW (' + CAST(cs.ple_seconds AS VARCHAR(20)) + 's)'
             ELSE '' END
    )) AS alert_message,
    (SELECT STRING_AGG(
        'Session ' + CAST(session_id AS VARCHAR) + ': ' +
        CAST(granted_memory_mb AS VARCHAR) + ' MB - ' +
        LEFT(query_text, 120),
        ' | '
    ) FROM TopQueries) AS top_memory_queries
FROM CurrentState cs;
```

- sql_memory_in_use_mb: Dung lượng RAM (tính bằng MB) mà tiến trình SQL Server (sqlservr.exe) đang thực sự sử dụng. --> Cho biết SQL Server đang "ăn" bao nhiêu bộ nhớ.

- os_available_memory_mb: Dung lượng RAM (MB) còn trống trên toàn bộ hệ điều hành --> Đây là chỉ số quan trọng nhất về sức khỏe bộ nhớ tổng thể. Con số này càng cao càng tốt.

- ple_second: "Tuổi thọ trang" (Page Life Expectancy) tính bằng giây. --> Là thời gian trung bình (tính bằng giây) mà một trang dữ liệu (8KB) có thể tồn tại trong bộ nhớ cache của SQL Server mà không cần phải đọc lại từ đĩa cứng.

    - Con số cao và ổn định: Rất tốt! Cho thấy server không chịu áp lực bộ nhớ.

    - Con số thấp hoặc giảm đột ngột: Dấu hiệu xấu, cho thấy SQL Server đang thiếu RAM và phải liên tục đọc/ghi dữ liệu từ đĩa.

- sql_warning_threshold_mb: Ngưỡng cảnh báo WARNING, được tính bằng 90% của bộ nhớ tối đa cấp cho SQL (@MaxSqlMemoryMB).

- os_critical_threshold_mb: Ngưỡng cảnh báo CRITICAL.

- ple_warning_threshold: Ngưỡng cảnh báo WARNING cho PLE.

- alert_status: Trạng thái sức khỏe tổng hợp của server. Cột này sẽ trả về một trong ba giá trị:

    - OK: Mọi thứ đều ổn.

    - WARNING: Có một vấn đề tiềm ẩn cần chú ý (ví dụ: PLE thấp hoặc SQL dùng >90% RAM).

    - CRITICAL: Có một vấn đề nghiêm trọng cần hành động ngay lập tức (RAM của OS sắp cạn).

alert_message: Tin nhắn mô tả chi tiết nguyên nhân gây ra cảnh báo. Thay vì chỉ thấy trạng thái "WARNING", cột này sẽ cho biết chính xác tại sao nó lại cảnh báo (ví dụ: PLE LOW (2500s) hoặc SQL Memory > 90% (110000.5 MB)). Nếu có nhiều vấn đề cùng lúc, nó sẽ kết hợp chúng lại.

- top_memory_queries: Danh sách 3 truy vấn đang yêu cầu cấp phát bộ nhớ nhiều nhất. Đây là cột cực kỳ giá trị khi có sự cố. Nếu nhận được cảnh báo liên quan đến bộ nhớ, cột này sẽ chỉ ra ngay "danh sách tình nghi" gồm các câu lệnh SQL có thể là nguyên nhân. Nó giúp tiết kiệm rất nhiều thời gian chẩn đoán sự cố. Cột này hiển thị: Session ID, Lượng RAM được cấp, và Nội dung câu lệnh.