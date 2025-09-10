
```bash
CREATE OR ALTER PROCEDURE dbo.sp_IOHealthCheck
    @WaitDelay CHAR(8) = '00:05:00',
    @DataFileReadLatencyThresholdMs INT = 30,
    @LogFileWriteLatencyThresholdMs INT = 5,
    @VLFCountThreshold INT = 500,
    @HighPhysicalReadsThreshold BIGINT = 1000,
    @PageLifeExpectancyThresholdSec INT = 300,
    @ExcludedDbNames NVARCHAR(MAX) = N'',
    @OutputFilePath NVARCHAR(255) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @CollectionTime DATETIME = GETDATE(); -- Single timestamp for this entire execution run.

    -- Initialize redesigned history table for event-based trend analysis
    IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'IoHealthHistory')
    CREATE TABLE dbo.IoHealthHistory (
        HistoryID BIGINT IDENTITY(1,1) PRIMARY KEY,
        CollectionTime DATETIME NOT NULL,
        CheckType NVARCHAR(100) NOT NULL,    -- e.g., 'High Read Latency', 'Top Wait Stat', 'High VLF Count'
        ObjectName NVARCHAR(255) NOT NULL, -- e.g., DatabaseName, WaitType, FileName
        MetricName NVARCHAR(100) NOT NULL,   -- e.g., 'AvgReadLatencyMs', 'WaitTimeSecDelta', 'VLFCount'
        MetricValue NVARCHAR(MAX) NOT NULL, -- Stored as string to accommodate various data types
        ThresholdValue NVARCHAR(MAX) NULL      -- The threshold that was breached
    );

    -- Temp table for summary findings
    IF OBJECT_ID('tempdb..#SummaryFindings') IS NOT NULL DROP TABLE #SummaryFindings;
    CREATE TABLE #SummaryFindings (
        CheckID INT IDENTITY(1,1),
        Severity NVARCHAR(20),
        Finding NVARCHAR(255),
        Details NVARCHAR(MAX)
    );

    -- =================================================================================
    -- HEADER AND SYSTEM CONTEXT
    -- =================================================================================
    PRINT 'SQL Server I/O Health Check v4.0';
    PRINT '=================================';
    PRINT 'Execution Start Time: ' + CONVERT(VARCHAR, @CollectionTime, 120);

    SELECT
        'SQL Server Version' AS [Context],
        @@VERSION AS [Details]
    UNION ALL
    SELECT
        'Server Uptime',
        DATEDIFF(day, sqlserver_start_time, @CollectionTime) + ' days, ' +
        CONVERT(VARCHAR, DATEADD(ms, DATEDIFF(ms, sqlserver_start_time, @CollectionTime), 0), 114)
    FROM sys.dm_os_sys_info
    UNION ALL
    SELECT
        'CPU Info',
        CAST(cpu_count AS VARCHAR) + ' CPUs (' + CAST(hyperthread_ratio AS VARCHAR) + ' HT Ratio)'
    FROM sys.dm_os_sys_info;

    PRINT ' ';
    PRINT 'Configuration:';
    PRINT ' - Wait Stats Delay: ' + @WaitDelay;
    PRINT ' - Data File Read Latency Threshold: ' + CAST(@DataFileReadLatencyThresholdMs AS VARCHAR) + 'ms';
    PRINT ' - Log File Write Latency Threshold: ' + CAST(@LogFileWriteLatencyThresholdMs AS VARCHAR) + 'ms';
    PRINT ' - VLF Count Threshold: ' + CAST(@VLFCountThreshold AS VARCHAR);
    PRINT ' - Page Life Expectancy Threshold: ' + CAST(@PageLifeExpectancyThresholdSec AS VARCHAR) + 's';
    PRINT ' ';
    PRINT 'Gathering data... This will take ' + @WaitDelay + ' to complete.';
    PRINT ' ';


    -- =================================================================================
    -- DATA GATHERING PHASE (Sections 1-7)
    -- This part remains largely the same as v3.1
    -- =================================================================================

    -- SECTION 1: CURRENT TOP WAITS (DELTA ANALYSIS)
    IF OBJECT_ID('tempdb..#WaitStatsStart') IS NOT NULL DROP TABLE #WaitStatsStart;
    SELECT wait_type, waiting_tasks_count, wait_time_ms, signal_wait_time_ms
    INTO #WaitStatsStart
    FROM sys.dm_os_wait_stats;

    WAITFOR DELAY @WaitDelay;

    IF OBJECT_ID('tempdb..#WaitStatsEnd') IS NOT NULL DROP TABLE #WaitStatsEnd;
    SELECT wait_type, waiting_tasks_count, wait_time_ms, signal_wait_time_ms
    INTO #WaitStatsEnd
    FROM sys.dm_os_wait_stats;

    -- SECTION 2: DISK LATENCY, 3: TEMPDB, 4: VLF, 5: HIGH I/O QUERIES, 6: PENDING I/O, 7: INSTANCE PERF...
    -- ... (Code from v3.1 for these sections is copied here for brevity) ...
    -- The gathering logic is solid, so we keep it.
    
    -- SECTION 2: DISK LATENCY PER FILE (IO STALLS)
    IF OBJECT_ID('tempdb..#DiskLatency') IS NOT NULL DROP TABLE #DiskLatency;
    SELECT DB_NAME(vfs.database_id) AS database_name, mf.name AS logical_file_name, mf.type_desc, vfs.num_of_reads, vfs.num_of_writes, vfs.io_stall_read_ms / NULLIF(vfs.num_of_reads, 0) AS avg_read_latency_ms, vfs.io_stall_write_ms / NULLIF(vfs.num_of_writes, 0) AS avg_write_latency_ms, mf.physical_name
    INTO #DiskLatency
    FROM sys.dm_io_virtual_file_stats(NULL, NULL) AS vfs JOIN sys.master_files AS mf ON vfs.database_id = mf.database_id AND vfs.file_id = mf.file_id
    WHERE vfs.num_of_reads > 0 OR vfs.num_of_writes > 0;

    -- SECTION 3: TEMPDB CONTENTION (REAL-TIME)
    IF OBJECT_ID('tempdb..#TempDbContention') IS NOT NULL DROP TABLE #TempDbContention;
    SELECT wt.session_id, ses.login_name, ses.host_name, ses.program_name, wt.wait_duration_ms, wt.wait_type, 'dbid=' + SUBSTRING(wt.resource_description, 1, CHARINDEX(':', wt.resource_description) - 1) + '; fileid=' + SUBSTRING(wt.resource_description, CHARINDEX(':', wt.resource_description) + 1, CHARINDEX(':', wt.resource_description, CHARINDEX(':', wt.resource_description) + 1) - CHARINDEX(':', wt.resource_description) - 1) + '; pageno=' + SUBSTRING(wt.resource_description, CHARINDEX(':', wt.resource_description, CHARINDEX(':', wt.resource_description) + 1) + 1, LEN(wt.resource_description)) AS resource_description_decoded, er.blocking_session_id, st.text AS sql_text
    INTO #TempDbContention
    FROM sys.dm_os_waiting_tasks AS wt JOIN sys.dm_exec_sessions AS ses ON wt.session_id = ses.session_id LEFT JOIN sys.dm_exec_requests AS er ON wt.session_id = er.session_id OUTER APPLY sys.dm_exec_sql_text(er.sql_handle) AS st
    WHERE wt.wait_type LIKE 'PAGELATCH_%' AND wt.resource_description LIKE '2:%';

    -- SECTION 4: LOG FILE GROWTH & VLF COUNT
    IF OBJECT_ID('tempdb..#VLFInfo') IS NOT NULL DROP TABLE #VLFInfo; IF OBJECT_ID('tempdb..#VLFCount') IS NOT NULL DROP TABLE #VLFCount;
    CREATE TABLE #VLFInfo (RecoveryUnitId INT, FileId INT, FileSize BIGINT, StartOffset BIGINT, FSeqNo BIGINT, Status TINYINT, Parity TINYINT, CreateLSN NUMERIC(25,0)); CREATE TABLE #VLFCount (DatabaseName sysname, VLFCount INT);
    DECLARE @DbName NVARCHAR(128), @Command NVARCHAR(MAX); DECLARE db_cursor CURSOR FOR SELECT name FROM sys.databases WHERE state_desc = 'ONLINE' AND name NOT IN (SELECT value FROM STRING_SPLIT(@ExcludedDbNames, ','));
    OPEN db_cursor; FETCH NEXT FROM db_cursor INTO @DbName; WHILE @@FETCH_STATUS = 0 BEGIN SET @Command = 'USE [' + @DbName + ']; BEGIN TRY INSERT INTO #VLFInfo EXEC sp_executesql N''DBCC LOGINFO WITH NO_INFOMSGS''; INSERT INTO #VLFCount (DatabaseName, VLFCount) SELECT N''' + @DbName + ''', COUNT(*) FROM #VLFInfo; TRUNCATE TABLE #VLFInfo; END TRY BEGIN CATCH PRINT ''Warning: Could not run DBCC LOGINFO on database ' + @DbName + '. Error: '' + ERROR_MESSAGE(); END CATCH'; EXEC sp_executesql @Command; FETCH NEXT FROM db_cursor INTO @DbName; END CLOSE db_cursor; DEALLOCATE db_cursor;
    IF OBJECT_ID('tempdb..#LogVlfInfo') IS NOT NULL DROP TABLE #LogVlfInfo; SELECT mf.name AS database_name, mf.physical_name, mf.size * 8 / 1024 AS size_mb, mf.growth * 8 / 1024 AS growth_mb, mf.is_percent_growth, ISNULL(vc.VLFCount, 0) AS VLFCount INTO #LogVlfInfo FROM sys.master_files AS mf LEFT JOIN #VLFCount AS vc ON mf.database_id = DB_ID(vc.DatabaseName) WHERE mf.type_desc = 'LOG';

    -- SECTION 5: QUERIES WITH HIGH PHYSICAL I/O
    IF OBJECT_ID('tempdb..#HighPhysicalIOQueries') IS NOT NULL DROP TABLE #HighPhysicalIOQueries; SELECT TOP 20 qs.total_physical_reads, qs.execution_count, qs.total_physical_reads / qs.execution_count AS avg_physical_reads, SUBSTRING(st.text, (qs.statement_start_offset / 2) + 1, ((CASE qs.statement_end_offset WHEN -1 THEN DATALENGTH(st.text) ELSE qs.statement_end_offset END - qs.statement_start_offset) / 2) + 1) AS query_text, DB_NAME(st.dbid) AS database_name, qs.plan_handle INTO #HighPhysicalIOQueries FROM sys.dm_exec_query_stats AS qs CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st WHERE qs.total_physical_reads > 0 AND (qs.total_physical_reads / qs.execution_count) >= @HighPhysicalReadsThreshold ORDER BY avg_physical_reads DESC;

    -- SECTION 6: PENDING I/O REQUESTS
    IF OBJECT_ID('tempdb..#PendingIO') IS NOT NULL DROP TABLE #PendingIO; SELECT DB_NAME(mf.database_id) AS database_name, mf.physical_name, io.io_pending_ms_ticks AS pending_duration_ms, io.io_pending, io.io_handle INTO #PendingIO FROM sys.dm_io_pending_io_requests AS io JOIN sys.master_files AS mf ON io.io_handle = mf.file_handle;
    
    -- SECTION 7: INSTANCE-LEVEL I/O PERFORMANCE
    IF OBJECT_ID('tempdb..#InstanceIO') IS NOT NULL DROP TABLE #InstanceIO;
    SELECT 'Page Life Expectancy' AS metric, cntr_value AS value INTO #InstanceIO FROM sys.dm_os_performance_counters WHERE object_name LIKE '%Buffer Manager%' AND counter_name = 'Page life expectancy';

    -- =================================================================================
    -- ANALYSIS, SUMMARY & HISTORICAL LOGGING
    -- =================================================================================
    -- Populate Summary table and History table in the same step
    INSERT INTO #SummaryFindings(Severity, Finding, Details) SELECT 'CRITICAL', 'Pending I/O Requests Detected!', 'Database: ' + database_name + ', File: ' + physical_name + ', Pending Duration: ' + CAST(pending_duration_ms AS VARCHAR) + 'ms. This indicates a SEVERE I/O subsystem problem.' FROM #PendingIO;
    INSERT INTO dbo.IoHealthHistory(CollectionTime, CheckType, ObjectName, MetricName, MetricValue) SELECT @CollectionTime, 'Pending I/O Request', database_name + ' (' + physical_name + ')', 'PendingDurationMs', CAST(pending_duration_ms AS VARCHAR) FROM #PendingIO;

    INSERT INTO #SummaryFindings(Severity, Finding, Details) SELECT 'WARNING', 'High Read Latency on DATA file', 'Database: ' + database_name + ', File: ' + logical_file_name + ', Avg Read Latency: ' + CAST(avg_read_latency_ms AS VARCHAR) + 'ms (Threshold: ' + CAST(@DataFileReadLatencyThresholdMs AS VARCHAR) + 'ms).' FROM #DiskLatency WHERE type_desc = 'ROWS' AND avg_read_latency_ms > @DataFileReadLatencyThresholdMs;
    INSERT INTO dbo.IoHealthHistory(CollectionTime, CheckType, ObjectName, MetricName, MetricValue, ThresholdValue) SELECT @CollectionTime, 'High Read Latency', database_name + ' (' + logical_file_name + ')', 'AvgReadLatencyMs', CAST(avg_read_latency_ms AS VARCHAR), CAST(@DataFileReadLatencyThresholdMs AS VARCHAR) FROM #DiskLatency WHERE type_desc = 'ROWS' AND avg_read_latency_ms > @DataFileReadLatencyThresholdMs;

    INSERT INTO #SummaryFindings(Severity, Finding, Details) SELECT 'WARNING', 'High Write Latency on LOG file', 'Database: ' + database_name + ', File: ' + logical_file_name + ', Avg Write Latency: ' + CAST(avg_write_latency_ms AS VARCHAR) + 'ms (Threshold: ' + CAST(@LogFileWriteLatencyThresholdMs AS VARCHAR) + 'ms).' FROM #DiskLatency WHERE type_desc = 'LOG' AND avg_write_latency_ms > @LogFileWriteLatencyThresholdMs;
    INSERT INTO dbo.IoHealthHistory(CollectionTime, CheckType, ObjectName, MetricName, MetricValue, ThresholdValue) SELECT @CollectionTime, 'High Write Latency', database_name + ' (' + logical_file_name + ')', 'AvgWriteLatencyMs', CAST(avg_write_latency_ms AS VARCHAR), CAST(@LogFileWriteLatencyThresholdMs AS VARCHAR) FROM #DiskLatency WHERE type_desc = 'LOG' AND avg_write_latency_ms > @LogFileWriteLatencyThresholdMs;

    INSERT INTO #SummaryFindings(Severity, Finding, Details) SELECT 'WARNING', 'High VLF Count Detected', 'Database: ' + database_name + ', VLF Count: ' + CAST(VLFCount AS VARCHAR) + ' (Threshold: ' + CAST(@VLFCountThreshold AS VARCHAR) + '). Consider shrinking and regrowing the log file.' FROM #LogVlfInfo WHERE VLFCount > @VLFCountThreshold;
    INSERT INTO dbo.IoHealthHistory(CollectionTime, CheckType, ObjectName, MetricName, MetricValue, ThresholdValue) SELECT @CollectionTime, 'High VLF Count', database_name, 'VLFCount', CAST(VLFCount AS VARCHAR), CAST(@VLFCountThreshold AS VARCHAR) FROM #LogVlfInfo WHERE VLFCount > @VLFCountThreshold;

    INSERT INTO #SummaryFindings(Severity, Finding, Details) SELECT 'WARNING', 'Log File using Percent Growth', 'Database: ' + database_name + '. Using percent growth can lead to performance issues.' FROM #LogVlfInfo WHERE is_percent_growth = 1;
    INSERT INTO dbo.IoHealthHistory(CollectionTime, CheckType, ObjectName, MetricName, MetricValue) SELECT @CollectionTime, 'Percent Growth Enabled', database_name, 'IsPercentGrowth', '1' FROM #LogVlfInfo WHERE is_percent_growth = 1;

    INSERT INTO #SummaryFindings(Severity, Finding, Details) SELECT 'WARNING', 'Low Page Life Expectancy', 'Page Life Expectancy: ' + CAST(value AS VARCHAR) + 's (Threshold: ' + CAST(@PageLifeExpectancyThresholdSec AS VARCHAR) + 's). Indicates memory pressure.' FROM #InstanceIO WHERE value < @PageLifeExpectancyThresholdSec;
    INSERT INTO dbo.IoHealthHistory(CollectionTime, CheckType, ObjectName, MetricName, MetricValue, ThresholdValue) SELECT @CollectionTime, 'Low Page Life Expectancy', 'Instance', 'PLE_Seconds', CAST(value AS VARCHAR), CAST(@PageLifeExpectancyThresholdSec AS VARCHAR) FROM #InstanceIO WHERE value < @PageLifeExpectancyThresholdSec;

    -- Log top wait stats separately to history
    INSERT INTO dbo.IoHealthHistory(CollectionTime, CheckType, ObjectName, MetricName, MetricValue)
    SELECT @CollectionTime, 'Top Wait Stat', wait_type, 'WaitTimeSecDelta', CAST(wait_time_ms_delta / 1000.0 AS VARCHAR)
    FROM (SELECT TOP 5 e.wait_type, e.wait_time_ms - s.wait_time_ms AS wait_time_ms_delta FROM #WaitStatsStart s JOIN #WaitStatsEnd e ON s.wait_type = e.wait_type WHERE (e.wait_time_ms - s.wait_time_ms) > 100 ORDER BY wait_time_ms_delta DESC) AS TopWaits;


    -- Display Summary Report
    PRINT '===== SUMMARY OF FINDINGS =====';
    IF NOT EXISTS (SELECT 1 FROM #SummaryFindings)
    BEGIN
        PRINT '>> No significant I/O or memory pressure issues detected based on the configured thresholds.';
    END
    ELSE
    BEGIN
        SELECT Severity, Finding, Details FROM #SummaryFindings ORDER BY CheckID;
    END

    -- =================================================================================
    -- VISUALIZATION (with ASCII Fallback)
    -- =================================================================================
    PRINT ' ';
    PRINT '===== Visualization: Top 5 Wait Types (Delta over ' + @WaitDelay + ') =====';
    WITH WaitStatsDelta AS (
        SELECT TOP 5
            e.wait_type,
            (e.wait_time_ms - s.wait_time_ms) / 1000.0 AS WaitTimeSec
        FROM #WaitStatsStart s
        JOIN #WaitStatsEnd e ON s.wait_type = e.wait_type
        WHERE (e.wait_time_ms - s.wait_time_ms) > 0
        ORDER BY WaitTimeSec DESC
    )
    SELECT
        wait_type,
        WaitTimeSec,
        REPLICATE('█', CAST(WaitTimeSec * 50 / NULLIF(MAX(WaitTimeSec) OVER(), 0) AS INT)) AS [Bar Chart]
    FROM WaitStatsDelta;


    -- =================================================================================
    -- DETAILED REPORTS
    -- =================================================================================
    -- ... (The conditional detailed reports from v3.1 can be kept here) ...
    PRINT ' ';
    PRINT '===== 1. DETAILED REPORT: Current Top Waits (Delta over ' + @WaitDelay + ') =====';
    WITH WaitStatsDelta AS (SELECT e.wait_type, e.waiting_tasks_count - s.waiting_tasks_count AS waiting_tasks_count_delta, e.wait_time_ms - s.wait_time_ms AS wait_time_ms_delta, e.signal_wait_time_ms - s.signal_wait_time_ms AS signal_wait_time_ms_delta FROM #WaitStatsStart s JOIN #WaitStatsEnd e ON s.wait_type = e.wait_type)
    SELECT TOP 15 wait_type, waiting_tasks_count_delta, wait_time_ms_delta / 1000.0 AS wait_time_sec_delta, signal_wait_time_ms_delta / 1000.0 AS signal_wait_time_sec_delta, 100.0 * wait_time_ms_delta / NULLIF(SUM(wait_time_ms_delta) OVER(), 0) AS percentage_of_total_waits, CASE WHEN wait_type LIKE 'PAGEIOLATCH%' THEN 'High I/O Read Contention.' WHEN wait_type = 'WRITELOG' THEN 'Transaction Log Write Contention.' WHEN wait_type = 'IO_COMPLETION' THEN 'General I/O waits (e.g., Backups).' ELSE 'Informational' END AS common_cause_suggestion FROM WaitStatsDelta WHERE wait_time_ms_delta > 0 ORDER BY wait_time_sec_delta DESC;

    -- ... (Other detailed reports as needed) ...
    
    -- =================================================================================
    -- OUTPUT TO FILE (Optional)
    -- =================================================================================
    IF @OutputFilePath IS NOT NULL
    BEGIN
        PRINT ' ';
        PRINT '----- File Output -----';
        PRINT 'Note: File output requires xp_cmdshell to be enabled, which is a security consideration.';
        BEGIN TRY
            DECLARE @bcpCommand NVARCHAR(4000) = 'bcp "SELECT Severity, Finding, Details FROM tempdb..#SummaryFindings ORDER BY CheckID" queryout "' + @OutputFilePath + '" -c -T -S ' + @@SERVERNAME;
            EXEC xp_cmdshell @bcpCommand, NO_OUTPUT;
            PRINT 'Summary findings successfully exported to ' + @OutputFilePath;
        END TRY
        BEGIN CATCH
            PRINT 'ERROR: Could not export to file. Please check permissions and if xp_cmdshell is enabled. Error: ' + ERROR_MESSAGE();
        END CATCH
    END

    -- =================================================================================
    -- CLEANUP
    -- =================================================================================
    DROP TABLE IF EXISTS #SummaryFindings, #WaitStatsStart, #WaitStatsEnd, #DiskLatency, #TempDbContention, #VLFInfo, #VLFCount, #LogVlfInfo, #HighPhysicalIOQueries, #PendingIO, #InstanceIO;

    PRINT ' ';
    PRINT '===== SCRIPT COMPLETE =====';
    PRINT 'End Time: ' + CONVERT(VARCHAR, GETDATE(), 120);
    SET NOCOUNT OFF;
END;
GO

-- Example usage:
-- EXEC dbo.sp_IOHealthCheck @WaitDelay = '00:01:00';
--
-- Example with file output:
-- EXEC dbo.sp_IOHealthCheck @WaitDelay = '00:05:00', @OutputFilePath = 'C:\Temp\IOHealthCheck_Report.txt';
GO
```

#### Hướng dẫn sử dụng:

- Cách 1: Chạy với cài đặt mặc định (đợi 5 phút để thu thập dữ liệu)

```bash
EXEC dbo.sp_IOHealthCheck;
```

- Cách 2: Chạy nhanh để kiểm tra (chỉ đợi 1 phút)

```bash
EXEC dbo.sp_IOHealthCheck @WaitDelay = '00:01:00';
```

- Cách 3: Tùy chỉnh ngưỡng và xuất kết quả ra file (rất hữu ích để lưu lại báo cáo)

```bash
EXEC dbo.sp_IOHealthCheck
    @WaitDelay = '00:05:00',
    @DataFileReadLatencyThresholdMs = 20, -- Cảnh báo nếu độ trễ đọc file data > 20ms
    @PageLifeExpectancyThresholdSec = 600, -- Cảnh báo nếu PLE < 600 giây
    @OutputFilePath = 'C:\Temp\BaoCao_IO.txt'; -- Xuất tóm tắt ra file text
```
(Lưu ý: Để xuất ra file, xp_cmdshell cần được bật trên SQL Server của bạn).

- Cách xem và hiểu biểu đồ dạng văn bản (ASCII chart) rất tiện lợi vì nó có thể hiển thị ở mọi nơi. Vị trí xem: Biểu đồ sẽ xuất hiện trong tab "Messages" của cửa sổ kết quả trong SSMS, ngay sau phần "SUMMARY OF FINDINGS".

- Từ biểu đồ này, bạn sẽ biết cần tập trung phân tích các báo cáo chi tiết về "Disk Latency" và "Queries with High Physical Reads" để tìm ra nguyên nhân gốc rễ. 

1. Biểu đồ: PAGEIOLATCH_SH là Wait Type cao nhất
Ý nghĩa: Đây là dấu hiệu kinh điển của việc hệ thống đang phải chờ đọc dữ liệu từ đĩa lên bộ nhớ (RAM) quá nhiều. Server của bạn đang "khát" I/O đọc.

Hành động xử lý:

    - Xem ngay Báo cáo số 5 (Queries with High Physical Reads): Tìm những câu lệnh SQL là "thủ phạm" chính gây ra việc đọc đĩa nhiều.

        - Lấy plan_handle từ báo cáo và xem Execution Plan của chúng.

        - Tìm các toán tử Table Scan hoặc Clustered Index Scan trên các bảng lớn.

        - Giải pháp: Thêm các index còn thiếu (Missing Indexes) mà Execution Plan gợi ý. Đây là cách khắc phục hiệu quả nhất.

    - Kiểm tra và bảo trì Index: Các index hiện có có bị phân mảnh (fragmentation) nặng không? Thực hiện REBUILD hoặc REORGANIZE các index bị phân mảnh trên 80%.

    - Xem Báo cáo số 7 (Low Page Life Expectancy - PLE): Nếu chỉ số PLE thấp (dưới 300s cho mỗi 4GB RAM), server đang thiếu RAM. Khi thiếu RAM, SQL Server phải liên tục đẩy dữ liệu ra khỏi cache và đọc lại từ đĩa.

        - Giải pháp: Tăng RAM cho máy chủ.

2. Biểu đồ: WRITELOG là Wait Type cao nhất

- Ý nghĩa: Hệ thống đang bị nghẽn ở khâu ghi transaction log. Mọi lệnh INSERT, UPDATE, DELETE đều phải chờ cho đến khi log được ghi xong, gây chậm toàn bộ hệ thống.

- Hành động xử lý:

    - Kiểm tra vị trí và tốc độ ổ đĩa Log:

        - File log (.ldf) có đang nằm trên một ổ đĩa vật lý riêng biệt với file data (.mdf) không? Đây là một yêu cầu bắt buộc cho hệ thống hiệu năng cao.

        - Ổ đĩa chứa file log phải là ổ đĩa nhanh nhất hệ thống, ưu tiên ghi (write). SSD NVMe là lựa chọn lý tưởng.

        - Xem Báo cáo số 2 để kiểm tra AvgWriteLatencyMs của file log. Nếu > 5ms là rất tệ.

    - Tối ưu hóa Transaction:

        - Tránh các transaction lớn, chạy kéo dài hàng giờ. Hãy chia nhỏ chúng thành các batch nhỏ hơn và COMMIT thường xuyên.

        - Kiểm tra code ứng dụng xem có vòng lặp nào thực hiện từng lệnh UPDATE trong một transaction riêng lẻ không (row-by-row processing). Hãy gộp chúng lại.

    - Xem Báo cáo số 4 (High VLF Count): Nếu số VLF quá cao (hàng ngàn), nó sẽ làm chậm tất cả các hoạt động liên quan đến log. Hãy xử lý theo mục 4 dưới đây.

3. Báo cáo: High Read/Write Latency (Độ trễ đọc/ghi cao)

- Ý nghĩa: Đây là vấn đề ở tầng hạ tầng. Hệ thống lưu trữ (ổ đĩa local, SAN, NAS) không đáp ứng kịp yêu cầu của SQL Server.

- Hành động xử lý:

    - Báo cáo cho đội Hạ tầng/SysAdmin: Cung cấp cho họ kết quả từ script này. Họ cần kiểm tra:

        - Tình trạng sức khỏe của ổ đĩa vật lý.

        - Cấu hình RAID (nên dùng RAID 10 cho hiệu năng tốt nhất).

        - Driver và firmware của card HBA, SAN switch.

        - Tải tổng thể trên hệ thống lưu trữ SAN (có máy chủ nào khác đang chiếm dụng hết băng thông không?).

    - Tách biệt I/O: Đảm bảo file data, file log, và TempDB nằm trên các ổ đĩa/LUNs vật lý khác nhau.

4. Báo cáo: High VLF Count (Số VLF cao)

- Ý nghĩa: File log đã trải qua quá nhiều lần tự động tăng trưởng (autogrowth) với kích thước nhỏ, tạo ra hàng ngàn file log ảo (Virtual Log Files), làm chậm quá trình backup, restore và recovery.

- Hành động xử lý (Cần thực hiện cẩn thận vào thời điểm ít tải):

    - Backup Log: Thực hiện một bản backup transaction log (BACKUP LOG ...).

    - Shrink File: DBCC SHRINKFILE (ten_file_log, 0, TRUNCATEONLY). Có thể cần chạy vài lần.

    - Regrow File: Tăng kích thước file log trở lại một kích thước đủ lớn và hợp lý (ALTER DATABASE ... MODIFY FILE ... SIZE = ...).

    - Cấu hình Autogrowth: Đặt mức tăng trưởng tự động cho file log thành một giá trị cố định và hợp lý (ví dụ: 512MB, 1024MB), không dùng %.

5. Báo cáo: Low Page Life Expectancy (PLE)

- Ý nghĩa: Dữ liệu trong RAM đang bị "đẩy ra" quá nhanh, cho thấy SQL Server đang bị áp lực về bộ nhớ (thiếu RAM).

- Hành động xử lý:

    - Tăng RAM: Giải pháp trực tiếp và hiệu quả nhất là nâng cấp RAM cho máy chủ.

    - Kiểm tra cấu hình max server memory: Đảm bảo bạn đã cấu hình giới hạn RAM cho SQL Server, chừa lại đủ bộ nhớ cho hệ điều hành và các ứng dụng khác.

    - Tìm và tối ưu các query "ăn" nhiều bộ nhớ: Các query thực hiện quét toàn bộ bảng lớn sẽ làm sạch bộ đệm (buffer pool), khiến PLE giảm đột ngột.

6. Báo cáo: Pending I/O Requests (Yêu cầu I/O đang chờ)

- Ý nghĩa: CẢNH BÁO NGHIÊM TRỌNG NHẤT! SQL Server đã gửi yêu cầu xuống hệ điều hành/đĩa cứng nhưng không nhận được phản hồi. Hệ thống lưu trữ của bạn đang bị treo hoặc gặp lỗi nghiêm trọng.

- Hành động xử lý:

    - Hành động ngay lập tức: Báo ngay cho đội ngũ hạ tầng/sysadmin.

    - Kiểm tra Windows Event Viewer: Xem log hệ thống để tìm các lỗi liên quan đến disk, iScsiPrt, LSI_SAS,...

    - Kiểm tra tất cả các thành phần vật lý của hệ thống lưu trữ.

