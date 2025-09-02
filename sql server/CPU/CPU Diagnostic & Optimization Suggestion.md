/*
    Procedure: dbo.usp_CheckServerPerformance
    Purpose: Monitors SQL Server performance, including CPU usage, configuration, top queries, index fragmentation, and parameter sniffing.
             Provides robust logging, error handling, and detailed email reporting.

    Parameters:
        @CpuThreshold TINYINT - CPU usage threshold for alerts (default: 80%).
        @TargetDatabase SYSNAME - Specific database to check (NULL = all user databases).
        @MinPageCountForFrag INT - Minimum page count for index fragmentation check (default: 1000).
        @TopQueries INT - Number of top CPU-consuming queries to return (default: 10).
        @SniffingReadSkewFactor INT - Factor by which max_reads must exceed avg_reads to be flagged (default: 100).
        @SniffingMinExecutionCount INT - Minimum execution count for a query to be checked for sniffing (default: 50).
        @SendEmail BIT - Whether to send an email report (default: 0).
        @EmailProfile SYSNAME - Database mail profile name (default: 'DBA_Mail_Profile').
        @Recipients NVARCHAR(MAX) - Email recipients (default: 'dba_team@example.com').
*/


```bash
IF OBJECT_ID('dbo.usp_CheckServerPerformance') IS NOT NULL
    DROP PROCEDURE dbo.usp_CheckServerPerformance;
GO

CREATE PROCEDURE dbo.usp_CheckServerPerformance
    @CpuThreshold TINYINT = 80,
    @TargetDatabase SYSNAME = NULL,
    @MinPageCountForFrag INT = 1000,
    @TopQueries INT = 10,
    @SniffingReadSkewFactor INT = 100,      -- CẢI TIẾN: Tham số hóa ngưỡng sniffing
    @SniffingMinExecutionCount INT = 50,    -- CẢI TIẾN: Tham số hóa ngưỡng sniffing
    @SendEmail BIT = 0,
    @EmailProfile SYSNAME = 'DBA_Mail_Profile',
    @Recipients NVARCHAR(MAX) = 'dba_team@example.com'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Warnings NVARCHAR(MAX) = N'';
    DECLARE @BodyHTML NVARCHAR(MAX) = N'';
    DECLARE @Subject NVARCHAR(255) = N'SQL Server Performance Report - ' + @@SERVERNAME + N' (' + CONVERT(NVARCHAR(20), GETDATE(), 120) + N')';

    BEGIN TRY
        -- Validate parameters
        IF @CpuThreshold > 100 OR @CpuThreshold < 0
            RAISERROR('Invalid @CpuThreshold value. Must be between 0 and 100.', 16, 1);
        IF @TopQueries < 1 OR @TopQueries > 100
            RAISERROR('Invalid @TopQueries value. Must be between 1 and 100.', 16, 1);
        IF @SendEmail = 1 AND NOT EXISTS (SELECT 1 FROM msdb.dbo.sysmail_profile WHERE name = @EmailProfile)
            SET @Warnings += N'<li>⚠ Email profile "' + @EmailProfile + N'" does not exist. Email will not be sent.</li>';

        -- [1] CPU Usage Check
        DECLARE @SQLServerCPU DECIMAL(5, 2);
        SELECT TOP(1) @SQLServerCPU = SQLProcessUtilization
        FROM (
            SELECT
                record.value('(./Record/@id)[1]', 'int') AS record_id,
                record.value('(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]', 'int') AS SQLProcessUtilization
            FROM (
                SELECT CONVERT(XML, record) AS record
                FROM sys.dm_os_ring_buffers
                WHERE ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR' AND record LIKE '%<SystemHealth>%'
            ) AS x
        ) AS y
        ORDER BY record_id DESC;
        
        IF @SQLServerCPU IS NULL
            SET @Warnings += N'<li>⚠ Unable to retrieve current CPU usage data from ring buffers.</li>';
        ELSE IF @SQLServerCPU > @CpuThreshold
            SET @Warnings += N'<li>🔥 High CPU Usage Detected: ' + CAST(@SQLServerCPU AS NVARCHAR(10)) + N'% (Threshold: ' + CAST(@CpuThreshold AS NVARCHAR(10)) + N'%)</li>';

        -- [2] Configuration Check
        DECLARE @MaxDOP INT, @CostThreshold INT, @cpu_count INT;
        SELECT @cpu_count = cpu_count FROM sys.dm_os_sys_info;
        SELECT @MaxDOP = CAST(value_in_use AS INT) FROM sys.configurations WHERE name = 'max degree of parallelism';
        SELECT @CostThreshold = CAST(value_in_use AS INT) FROM sys.configurations WHERE name = 'cost threshold for parallelism';

        IF @MaxDOP = 0 OR @MaxDOP > @cpu_count
            SET @Warnings += N'<li>⚠ Misconfigured MAXDOP. Current: ' + CAST(@MaxDOP AS NVARCHAR(10)) + N'. Recommended for this server ('+ CAST(@cpu_count AS NVARCHAR(5)) +' cores): ' + CAST(CASE WHEN @cpu_count <= 8 THEN @cpu_count ELSE 8 END AS NVARCHAR(10)) + N'.</li>';
        IF @CostThreshold < 25
            SET @Warnings += N'<li>⚠ Low "Cost Threshold for Parallelism". Current: ' + CAST(@CostThreshold AS NVARCHAR(10)) + N'. Recommended: 30-50 for OLTP workloads.</li>';

        -- [3] Top Queries
        CREATE TABLE #TopQueries (
            TotalCPU_ms BIGINT, execution_count BIGINT, AvgCPU_ms DECIMAL(18,2),
            QueryText NVARCHAR(MAX), QueryPlan XML, DbName SYSNAME
        );
        INSERT INTO #TopQueries
        SELECT TOP (@TopQueries)
            qs.total_worker_time / 1000 AS TotalCPU_ms,
            qs.execution_count,
            (qs.total_worker_time * 1.0 / qs.execution_count) / 1000 AS AvgCPU_ms,
            SUBSTRING(qt.text, (qs.statement_start_offset/2)+1,
                ((CASE qs.statement_end_offset WHEN -1 THEN DATALENGTH(qt.text) ELSE qs.statement_end_offset END - qs.statement_start_offset)/2)+1) AS QueryText,
            qp.query_plan,
            DB_NAME(qt.dbid)
        FROM sys.dm_exec_query_stats AS qs
        CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS qt
        CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
        WHERE qs.execution_count > 1
        ORDER BY qs.total_worker_time DESC;

        -- [4] Index Fragmentation
        CREATE TABLE #FragInfo (
            DatabaseName SYSNAME, SchemaName SYSNAME, TableName SYSNAME, IndexName SYSNAME,
            avg_fragmentation_in_percent DECIMAL(5,2), page_count BIGINT, ActionRecommended VARCHAR(20)
        );
        
        DECLARE @db_name SYSNAME, @sql_command NVARCHAR(MAX);
        DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
            SELECT name FROM sys.databases 
            WHERE state_desc = 'ONLINE' 
              AND is_read_only = 0
              AND database_id > 4 -- Chỉ user databases
              AND (@TargetDatabase IS NULL OR name = @TargetDatabase);
        
        OPEN db_cursor;
        FETCH NEXT FROM db_cursor INTO @db_name;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @sql_command = N'USE ' + QUOTENAME(@db_name) + N';
                INSERT INTO #FragInfo
                SELECT TOP 50 DB_NAME(), sc.name, o.name, i.name, ps.avg_fragmentation_in_percent, ps.page_count,
                       CASE WHEN ps.avg_fragmentation_in_percent > 30 THEN ''REBUILD''
                            WHEN ps.avg_fragmentation_in_percent BETWEEN 10 AND 30 THEN ''REORGANIZE''
                            ELSE ''OK'' END
                FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, ''LIMITED'') ps
                JOIN sys.indexes i ON ps.object_id = i.object_id AND ps.index_id = i.index_id
                JOIN sys.objects o ON i.object_id = o.object_id
                JOIN sys.schemas sc ON o.schema_id = sc.schema_id
                WHERE ps.page_count > @MinPageCountForFrag AND ps.index_id > 0 AND ps.avg_fragmentation_in_percent >= 10
                ORDER BY ps.avg_fragmentation_in_percent DESC;';
            EXEC sp_executesql @sql_command, N'@MinPageCountForFrag INT', @MinPageCountForFrag;
            FETCH NEXT FROM db_cursor INTO @db_name;
        END
        CLOSE db_cursor;
        DEALLOCATE db_cursor;
        IF @TargetDatabase IS NOT NULL AND NOT EXISTS (SELECT 1 FROM #FragInfo) AND NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = @TargetDatabase)
            SET @Warnings += N'<li>⚠ Target database "' + @TargetDatabase + N'" does not exist or is inaccessible.</li>';


        -- [5] Parameter Sniffing
        CREATE TABLE #SniffingIssues (
            AvgLogicalReads BIGINT, MinLogicalReads BIGINT, MaxLogicalReads BIGINT,
            ReadSkew BIGINT, ExecutionCount BIGINT, QueryText NVARCHAR(MAX), QueryPlan XML
        );
        INSERT INTO #SniffingIssues
        SELECT TOP 10
            total_logical_reads / execution_count AS avg_logical_reads,
            min_logical_reads,
            max_logical_reads,
            (max_logical_reads - min_logical_reads) AS read_skew,
            execution_count,
            SUBSTRING(qt.text, (qs.statement_start_offset/2)+1,
                ((CASE qs.statement_end_offset WHEN -1 THEN DATALENGTH(qt.text) ELSE qs.statement_end_offset END - qs.statement_start_offset)/2)+1),
            qp.query_plan
        FROM sys.dm_exec_query_stats AS qs
        CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS qt
        CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
        WHERE execution_count > @SniffingMinExecutionCount
          AND total_logical_reads > 0 AND execution_count > 0 -- Tránh lỗi chia cho 0
          AND (max_logical_reads * 1.0 / (total_logical_reads / execution_count)) > @SniffingReadSkewFactor
        ORDER BY read_skew DESC;

        -- [6] Email Report Generation
        IF @SendEmail = 1
        BEGIN
            DECLARE @ServerConfigHTML NVARCHAR(MAX) = N'<h3>Server Configuration</h3><ul>'
                + N'<li><b>CPU Cores:</b> ' + CAST(@cpu_count AS NVARCHAR(10)) + N'</li>'
                + N'<li><b>MAXDOP Setting:</b> ' + CAST(@MaxDOP AS NVARCHAR(10)) + N'</li>'
                + N'<li><b>Cost Threshold Setting:</b> ' + CAST(@CostThreshold AS NVARCHAR(10)) + N'</li>'
                + N'</ul><hr>';

            SET @BodyHTML = N'<html><head><style>'
                + N'body {font-family: Arial, sans-serif; font-size: 14px;} table {border-collapse: collapse; width: 95%;} th, td {border: 1px solid #dddddd; text-align: left; padding: 8px;} th {background-color: #f2f2f2;} h2, h3 {color: #333366;} ul {color: #990000;} pre {white-space: pre-wrap; word-wrap: break-word; font-family: Consolas, monospace; font-size: 12px;}</style></head><body>'
                + N'<h2>SQL Server Performance Report for ' + @@SERVERNAME + N'</h2>'
                + @ServerConfigHTML -- CẢI TIẾN: Thêm thông tin cấu hình vào email
                + N'<h3><font color="red">Alerts & Warnings:</font></h3><ul>' + CASE WHEN @Warnings = N'' THEN N'<li>✅ No new warnings detected.</li>' ELSE @Warnings END + N'</ul><hr>';

            IF EXISTS (SELECT 1 FROM #TopQueries)
            BEGIN
                SET @BodyHTML += N'<h3>Top ' + CAST(@TopQueries AS NVARCHAR(10)) + N' CPU Consuming Queries</h3><table border="1"><tr><th>Database</th><th>Total CPU (ms)</th><th>Exec Count</th><th>Avg CPU (ms)</th><th>Query Text</th></tr>';
                SELECT @BodyHTML += N'<tr><td>' + ISNULL(DbName, 'N/A') + N'</td><td>' + FORMAT(TotalCPU_ms, 'N0') + N'</td><td>' + FORMAT(execution_count, 'N0') + N'</td><td>' + CAST(AvgCPU_ms AS NVARCHAR(20)) + N'</td><td><pre>' + REPLACE(REPLACE(LEFT(QueryText, 500), '<', '&lt;'), '>', '&gt;') + N'</pre></td></tr>' FROM #TopQueries ORDER BY TotalCPU_ms DESC;
                SET @BodyHTML += N'</table><hr>';
            END

            IF EXISTS (SELECT 1 FROM #FragInfo)
            BEGIN
                SET @BodyHTML += N'<h3>Indexes with High Fragmentation</h3><table border="1"><tr><th>Database</th><th>Table</th><th>Index</th><th>Fragmentation (%)</th><th>Page Count</th><th>Recommendation</th></tr>';
                SELECT @BodyHTML += N'<tr><td>' + DatabaseName + N'</td><td>' + SchemaName + '.' + TableName + N'</td><td>' + IndexName + N'</td><td>' + CAST(avg_fragmentation_in_percent AS NVARCHAR(10)) + N'</td><td>' + FORMAT(page_count, 'N0') + N'</td><td>' + ActionRecommended + N'</td></tr>' FROM #FragInfo ORDER BY avg_fragmentation_in_percent DESC;
                SET @BodyHTML += N'</table><hr>';
            END

            IF EXISTS (SELECT 1 FROM #SniffingIssues)
            BEGIN
                SET @BodyHTML += N'<h3>Potential Parameter Sniffing Issues</h3><table border="1"><tr><th>Avg Reads</th><th>Min Reads</th><th>Max Reads</th><th>Read Skew</th><th>Exec Count</th><th>Query Text</th></tr>';
                SELECT @BodyHTML += N'<tr><td>' + FORMAT(AvgLogicalReads, 'N0') + N'</td><td>' + FORMAT(MinLogicalReads, 'N0') + N'</td><td>' + FORMAT(MaxLogicalReads, 'N0') + N'</td><td>' + FORMAT(ReadSkew, 'N0') + N'</td><td>' + FORMAT(ExecutionCount, 'N0') + N'</td><td><pre>' + REPLACE(REPLACE(LEFT(QueryText, 500), '<', '&lt;'), '>', '&gt;') + N'</pre></td></tr>' FROM #SniffingIssues ORDER BY ReadSkew DESC;
                SET @BodyHTML += N'</table><hr>';
            END

            SET @BodyHTML += N'</body></html>';
            
            IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysmail_profile WHERE name = @EmailProfile)
            BEGIN
                RAISERROR('Email profile "%s" does not exist. Cannot send report.', 10, 1, @EmailProfile) WITH NOWAIT;
            END
            ELSE
            BEGIN
                 EXEC msdb.dbo.sp_send_dbmail @profile_name = @EmailProfile, @recipients = @Recipients, @subject = @Subject, @body = @BodyHTML, @body_format = 'HTML';
            END
        END

        -- [7] Log Results
        IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'ServerPerformanceLog' AND type = 'U')
        BEGIN
            CREATE TABLE dbo.ServerPerformanceLog (
                LogID BIGINT IDENTITY(1,1) PRIMARY KEY,
                LogDate DATETIME2(3) DEFAULT GETDATE(),
                ServerName SYSNAME,
                CPUUtilization DECIMAL(5,2),
                Status VARCHAR(10) NOT NULL, -- CẢI TIẾN: Thêm cột Status
                Warnings NVARCHAR(MAX),
                TopQueries XML,
                FragmentationInfo XML,
                ParameterSniffingInfo XML
            );
        END
        INSERT INTO dbo.ServerPerformanceLog (ServerName, CPUUtilization, Status, Warnings, TopQueries, FragmentationInfo, ParameterSniffingInfo)
        SELECT 
            @@SERVERNAME, 
            @SQLServerCPU, 
            CASE WHEN @Warnings <> N'' THEN 'ALERT' ELSE 'OK' END, -- CẢI TIẾN: Gán giá trị cho Status
            @Warnings,
            (SELECT * FROM #TopQueries FOR XML RAW('Query'), ROOT('TopQueries')),
            (SELECT * FROM #FragInfo FOR XML RAW('Index'), ROOT('Fragmentation')),
            (SELECT * FROM #SniffingIssues FOR XML RAW('Sniff'), ROOT('SniffingIssues'));

    END TRY
    BEGIN CATCH
        DECLARE @ErrorMessage NVARCHAR(MAX) = ERROR_MESSAGE();
        DECLARE @ErrorSeverity INT = ERROR_SEVERITY();
        DECLARE @ErrorState INT = ERROR_STATE();

        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

        RAISERROR(@ErrorMessage, @ErrorSeverity, @ErrorState) WITH NOWAIT;

        -- Attempt to send an error email
        IF @SendEmail = 1 AND EXISTS (SELECT 1 FROM msdb.dbo.sysmail_profile WHERE name = @EmailProfile)
        BEGIN
            DECLARE @ErrorBody NVARCHAR(MAX) = N'An error occurred while running usp_CheckServerPerformance on ' + @@SERVERNAME + N'.<br><br><b>Error:</b> ' + @ErrorMessage;
            EXEC msdb.dbo.sp_send_dbmail
                 @profile_name = @EmailProfile,
                 @recipients = @Recipients,
                 @subject = @Subject + N' (SCRIPT FAILED)',
                 @body = @ErrorBody,
                 @body_format = 'HTML';
        END
    END CATCH

    -- Final Cleanup
    DROP TABLE IF EXISTS #TopQueries;
    DROP TABLE IF EXISTS #FragInfo;
    DROP TABLE IF EXISTS #SniffingIssues;
END
GO
```

### Hướng dẫn cách sử dụng:

* Bước 1: Tạo Stored Procedure

- Trước tiên, cần chạy toàn-bộ script đã cung-cấp một-lần trên SQL Server của mình. Thao-tác này sẽ tạo ra stored procedure có tên dbo.usp_CheckServerPerformance trong database master

* Bước 2: Các cách chạy (thực thi)

- Có thể chạy stored procedure này theo nhiều cách khác-nhau tùy-thuộc vào nhu-cầu của mình. Dưới đây là các ví-dụ phổ-biến.

1. Chạy kiểm-tra nhanh: Cách đơn-giản nhất là chạy mà không cần tham-số nào, nó sẽ sử-dụng các giá-trị mặc-định.

```bash
EXEC dbo.usp_CheckServerPerformance
```

- Kết-quả: Script sẽ in ra các kết-quả kiểm-tra ngay trong cửa-sổ Messages và Results của SQL Server Management Studio (SSMS). Dữ-liệu cũng sẽ được lưu vào bảng dbo.ServerPerformanceLog.

2. Kiểm-tra và gửi email cảnh-báo. Đây là kịch-bản phổ-biến nhất khi muốn tự-động-hóa.

```bash
EXEC dbo.usp_CheckServerPerformance
    @SendEmail = 1,
        @Recipients = 'your_email@company.com; another_dba@company.com',
        @CpuThreshold = 75;
```
- @SendEmail = 1: Kích-hoạt tính-năng gửi email.

- @Recipients: Danh-sách người nhận, cách-nhau bởi dấu chấm-phẩy.

- @CpuThreshold = 75: Gửi cảnh-báo nếu CPU vượt-quá 75%.

3. Chỉ kiểm-tra một database cụ-thể: Nếu chỉ muốn kiểm-tra phân-mảnh (fragmentation ) cho một database nhất-định.

```bash
EXEC dbo.usp_CheckServerPerformance @TargetDatabase = 'AdventureWorks2019';
```
- @TargetDatabase: Chỉ-định tên database muốn phân-tích.

4. Tùy-chỉnh các ngưỡng kiểm-tra, có thể tùy-chỉnh các ngưỡng để phù-hợp với môi-trường của mình.

```bash
EXEC dbo.usp_CheckServerPerformance
    @TopQueries = 5,
    @SniffingReadSkewFactor = 150,
    @SniffingMinExecutionCount = 100;
```

- @TopQueries = 5: Chỉ lấy 5 câu truy-vấn tốn CPU nhất.

- @SniffingReadSkewFactor = 150: Tăng độ-nhạy của việc phát-hiện "parameter sniffing" (chỉ cảnh-báo khi max_reads lớn hơn 150 lần avg_reads).

- @SniffingMinExecutionCount = 100: Chỉ kiểm-tra các query đã chạy ít-nhất 100 lần.

* Bước 3: Tự-động-hóa với SQL Server Agent

- Để script này thực-sự phát-huy sức-mạnh, nên tạo một Job trong SQL Server Agent để nó tự-động chạy theo lịch.

- Mở SQL Server Agent trong SSMS, chuột-phải vào Jobs và chọn New Job....

- General: Đặt tên cho Job, ví-dụ: DBA - Daily Performance Check.

- Steps:

- Nhấn New....

- Đặt tên cho Step, ví-dụ: Run Performance Stored Procedure.

- Trong ô Command, nhập lệnh muốn chạy. Ví-dụ để chạy kiểm-tra hàng-ngày và gửi email:

```bash
EXEC dbo.usp_CheckServerPerformance
    @SendEmail = 1,
    @Recipients = 'dba_team@company.com',
    @CpuThreshold = 80;
```

Schedules:

- Nhấn New....

- Thiết-lập lịch chạy, ví-dụ: Chạy hàng-ngày (Daily) vào lúc 7:00 AM.

- Nhấn OK để lưu Job. Giờ đây, Job sẽ tự-động chạy theo lịch đã đặt.

* Bước 4: Xem lại lịch-sử

-Bất-cứ lúc nào cũng có thể xem lại kết-quả của các lần chạy trước bằng cách truy-vấn bảng log.

```bash
-- Xem 100 bản ghi gần nhất
SELECT TOP 100 *
FROM master.dbo.ServerPerformanceLog
ORDER BY LogDate DESC;
```

```bash
-- Chỉ xem những lần chạy có cảnh-báo (ALERT)
SELECT *
FROM master.dbo.ServerPerformanceLog
WHERE Status = 'ALERT'
ORDER BY LogDate DESC;
```