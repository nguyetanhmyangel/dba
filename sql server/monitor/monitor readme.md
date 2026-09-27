### PHẦN 1: BÁO CÁO DUNG LƯỢNG & TĂNG TRƯỞNG DATABASE (Dựa trên StorageDatabaseBaseline & StorageVolumeBaseline)
- 1.1. Xem dung lượng tăng (GB) của từng Database qua các tháng (Monthly Growth Pivot)
```SQL
USE DbaMonitor;
GO

-- Tổng hợp dung lượng cuối mỗi tháng và tính Delta so với tháng trước
WITH MonthlySize AS (
    SELECT 
        DatabaseName,
        CONVERT(VARCHAR(7), SnapDate, 120) AS [YearMonth],
        TotalMB,
        ROW_NUMBER() OVER (PARTITION BY DatabaseName, CONVERT(VARCHAR(7), SnapDate, 120) ORDER BY SnapDate DESC) AS rn
    FROM dbo.StorageDatabaseBaseline
),
MonthEnd AS (
    SELECT 
        DatabaseName,
        [YearMonth],
        CAST(TotalMB / 1024.0 AS DECIMAL(18,2)) AS TotalGB
    FROM MonthlySize
    WHERE rn = 1
)
SELECT 
    curr.DatabaseName,
    curr.[YearMonth],
    curr.TotalGB AS CurrentTotalGB,
    prev.TotalGB AS PreviousTotalGB,
    CAST((curr.TotalGB - prev.TotalGB) AS DECIMAL(18,2)) AS GrowthGB,
    CASE 
        WHEN prev.TotalGB > 0 
        THEN CAST(((curr.TotalGB - prev.TotalGB) * 100.0 / prev.TotalGB) AS DECIMAL(5,2))
        ELSE 0 
    END AS GrowthPercent
FROM MonthEnd curr
LEFT JOIN MonthEnd prev 
    ON curr.DatabaseName = prev.DatabaseName 
   AND prev.[YearMonth] = CONVERT(VARCHAR(7), DATEADD(MONTH, -1, CAST(curr.[YearMonth] + '-01' AS DATE)), 120)
ORDER BY curr.[YearMonth] DESC, GrowthGB DESC;
```

- 1.2. Xem dung lượng tăng (GB) của từng Database trong khoảng @from_month đến @to_month
```SQL
USE DbaMonitor;
GO

DECLARE @from_month VARCHAR(7) = '2026-01'; -- Định dạng YYYY-MM
DECLARE @to_month   VARCHAR(7) = '2026-09';

WITH BaselineFrom AS (
    SELECT DatabaseName, TotalMB,
           ROW_NUMBER() OVER (PARTITION BY DatabaseName ORDER BY SnapDate ASC) AS rn
    FROM dbo.StorageDatabaseBaseline
    WHERE CONVERT(VARCHAR(7), SnapDate, 120) = @from_month
),
BaselineTo AS (
    SELECT DatabaseName, TotalMB,
           ROW_NUMBER() OVER (PARTITION BY DatabaseName ORDER BY SnapDate DESC) AS rn
    FROM dbo.StorageDatabaseBaseline
    WHERE CONVERT(VARCHAR(7), SnapDate, 120) = @to_month
)
SELECT 
    t.DatabaseName,
    CAST(f.TotalMB / 1024.0 AS DECIMAL(18,2)) AS [StartGB],
    CAST(t.TotalMB / 1024.0 AS DECIMAL(18,2)) AS [EndGB],
    CAST((t.TotalMB - f.TotalMB) / 1024.0 AS DECIMAL(18,2)) AS [GrowthGB],
    CASE 
        WHEN f.TotalMB > 0 
        THEN CAST(((t.TotalMB - f.TotalMB) * 100.0 / f.TotalMB) AS DECIMAL(6,2))
        ELSE 0 
    END AS [GrowthPct]
FROM BaselineTo t
INNER JOIN BaselineFrom f ON t.DatabaseName = f.DatabaseName AND f.rn = 1 AND t.rn = 1
ORDER BY [GrowthGB] DESC;
```

- 1.3. Xem dung lượng tăng (GB) của từng Database trong NĂM được chọn
```SQL
USE DbaMonitor;
GO

DECLARE @SelectedYear INT = 2026;

WITH YearBounds AS (
    SELECT 
        DatabaseName,
        TotalMB,
        SnapDate,
        ROW_NUMBER() OVER (PARTITION BY DatabaseName ORDER BY SnapDate ASC) AS rn_start,
        ROW_NUMBER() OVER (PARTITION BY DatabaseName ORDER BY SnapDate DESC) AS rn_end
    FROM dbo.StorageDatabaseBaseline
    WHERE YEAR(SnapDate) = @SelectedYear
)
SELECT 
    e.DatabaseName,
    @SelectedYear AS [ReportYear],
    CAST(s.TotalMB / 1024.0 AS DECIMAL(18,2)) AS StartYearGB,
    CAST(e.TotalMB / 1024.0 AS DECIMAL(18,2)) AS EndYearGB,
    CAST((e.TotalMB - s.TotalMB) / 1024.0 AS DECIMAL(18,2)) AS NetGrowthGB,
    CASE 
        WHEN s.TotalMB > 0 
        THEN CAST(((e.TotalMB - s.TotalMB) * 100.0 / s.TotalMB) AS DECIMAL(6,2))
        ELSE 0 
    END AS GrowthPct
FROM YearBounds e
INNER JOIN YearBounds s ON e.DatabaseName = s.DatabaseName AND s.rn_start = 1 AND e.rn_end = 1
ORDER BY NetGrowthGB DESC;
```

- 1.4. Dự báo Disk Runway (Tốc độ tiêu hao & Số tháng còn lại của từng ổ đĩa)
```SQL
USE DbaMonitor;
GO

WITH VolumeTrend AS (
    SELECT 
        curr.VolumeMountPoint,
        curr.TotalSpaceGB,
        curr.AvailableSpaceGB AS CurrentFreeGB,
        past.AvailableSpaceGB AS PastFreeGB,
        DATEDIFF(DAY, past.SnapDate, curr.SnapDate) AS DaysSpan
    FROM dbo.StorageVolumeBaseline curr
    INNER JOIN dbo.StorageVolumeBaseline past ON curr.VolumeMountPoint = past.VolumeMountPoint
    WHERE curr.SnapDate = (SELECT MAX(SnapDate) FROM dbo.StorageVolumeBaseline)
      AND past.SnapDate = (
          SELECT MAX(SnapDate) FROM dbo.StorageVolumeBaseline 
          WHERE SnapDate <= DATEADD(DAY, -30, (SELECT MAX(SnapDate) FROM dbo.StorageVolumeBaseline))
      )
)
SELECT 
    VolumeMountPoint,
    TotalSpaceGB,
    CurrentFreeGB,
    CAST((CurrentFreeGB * 100.0 / NULLIF(TotalSpaceGB, 0)) AS DECIMAL(5,2)) AS FreeSpacePct,
    CAST((PastFreeGB - CurrentFreeGB) * 1.0 / NULLIF(DaysSpan, 0) * 30.4375 AS DECIMAL(18,2)) AS EstBurnRateGB_Month,
    CASE 
        WHEN (PastFreeGB - CurrentFreeGB) > 0 
        THEN CAST(CurrentFreeGB / NULLIF((PastFreeGB - CurrentFreeGB) * 1.0 / DaysSpan * 30.4375, 0) AS DECIMAL(5,1))
        ELSE 999.0 
    END AS RunwayMonths,
    CASE 
        WHEN (PastFreeGB - CurrentFreeGB) > 0 AND (CurrentFreeGB / NULLIF((PastFreeGB - CurrentFreeGB) * 1.0 / DaysSpan * 30.4375, 0)) <= 2.0 THEN 'CRITICAL'
        WHEN (PastFreeGB - CurrentFreeGB) > 0 AND (CurrentFreeGB / NULLIF((PastFreeGB - CurrentFreeGB) * 1.0 / DaysSpan * 30.4375, 0)) <= 4.0 THEN 'WARN'
        ELSE 'SAFE'
    END AS RiskLevel
FROM VolumeTrend
ORDER BY RunwayMonths ASC;
```
### PHẦN 2: ĐIỀU TRA HIỆU NĂNG, DEADLOCK & WAIT STATS

- 2.1. Danh sách Deadlock từ 1 đến 7 ngày gần nhất (Kèm T-SQL nạn nhân & Deadlock Graph)
```SQL
USE DbaMonitor;
GO

DECLARE @DaysBack INT = 7; -- Tuỳ chỉnh: 1, 3 hoặc 7 ngày

-- Truy vấn chi tiết từ bảng output thực tế của sp_BlitzLock
SELECT 
    event_date AS DeadlockTime,
    database_name AS DatabaseName,
    deadlock_group AS DeadlockGroup,
    -- Trích xuất cờ Victim từ text của deadlock_group
    CASE 
        WHEN deadlock_group LIKE '%VICTIM%' THEN 'YES (Victim)' 
        ELSE 'NO' 
    END AS IsVictim,
    object_names AS ImpactedObjects,
    isolation_level AS IsolationLevel,
    owner_mode AS LockOwnerMode,
    waiter_mode AS LockWaiterMode,
    transaction_count AS TransactionCount,
    -- Cột query là kiểu XML, có thể click trực tiếp trong SSMS để xem SQL statement
    query AS StatementXML
FROM dbo.BlitzLockHistory
WHERE event_date >= DATEADD(DAY, -@DaysBack, SYSDATETIME())
ORDER BY event_date DESC, deadlock_group ASC;

-- Nếu muốn mở đồ thị XML Deadlock Graph nguyên bản:
SELECT 
    DeadlockID,
    CaptureTime,
    DeadlockGraph
FROM dbo.DeadlockHistory
WHERE CaptureTime >= DATEADD(DAY, -@DaysBack, SYSDATETIME())
ORDER BY CaptureTime DESC;
```

- 2.2. Top 5 Wait Stats gây chậm hệ thống trong 24 giờ qua 
(Sử dụng chính xác view BlitzFirst_WaitStats_Deltas và cột Ignorable có sẵn của FRK)

```SQL
USE DbaMonitor;
GO

SELECT TOP 5
    wait_type,
    WaitCategory,
    CAST(SUM(wait_time_ms_delta) / 1000.0 AS DECIMAL(18,2)) AS TotalWaitSec,
    CAST(SUM(signal_wait_time_ms_delta) / 1000.0 AS DECIMAL(18,2)) AS TotalCpuSignalWaitSec,
    CAST(SUM(waiting_tasks_count_delta) AS BIGINT) AS TotalWaitingTasks,
    CAST(SUM(wait_time_ms_delta) * 100.0 / NULLIF(SUM(SUM(wait_time_ms_delta)) OVER(), 0) AS DECIMAL(5,2)) AS PctOfTotal
FROM dbo.BlitzFirst_WaitStats_Deltas
WHERE CheckDate >= DATEADD(HOUR, -24, SYSDATETIME())
  AND Ignorable = 0 -- Lọc toàn bộ wait hệ thống/idle
GROUP BY wait_type, WaitCategory
HAVING SUM(wait_time_ms_delta) > 0
ORDER BY SUM(wait_time_ms_delta) DESC;
```

- 2.3. Top File có Độ trễ Đọc/Ghi (Latency) cao nhất trong 24 giờ qua

``` SQL
USE DbaMonitor;
GO

;WITH Snaps AS (
    SELECT DatabaseID, FileID, DatabaseName, LogicalFileName, PhysicalName,
           NumOfReads, IoStallReadMs, NumOfWrites, IoStallWriteMs, SnapTime,
           ROW_NUMBER() OVER (PARTITION BY DatabaseID, FileID ORDER BY SnapTime ASC) AS rn_first,
           ROW_NUMBER() OVER (PARTITION BY DatabaseID, FileID ORDER BY SnapTime DESC) AS rn_last
    FROM dbo.FileIOStatsSnapshot
    WHERE SnapTime >= DATEADD(HOUR, -24, SYSDATETIME())
),
Deltas AS (
    SELECT 
        l.DatabaseName, l.LogicalFileName, l.PhysicalName,
        (l.NumOfReads - e.NumOfReads) AS DeltaReads,
        (l.IoStallReadMs - e.IoStallReadMs) AS DeltaReadStall,
        (l.NumOfWrites - e.NumOfWrites) AS DeltaWrites,
        (l.IoStallWriteMs - e.IoStallWriteMs) AS DeltaWriteStall
    FROM Snaps l
    INNER JOIN Snaps e ON l.DatabaseID = e.DatabaseID AND l.FileID = e.FileID AND e.rn_first = 1 AND l.rn_last = 1
    WHERE l.NumOfReads >= e.NumOfReads AND l.NumOfWrites >= e.NumOfWrites
)
SELECT TOP 10
    DatabaseName,
    LogicalFileName,
    PhysicalName,
    DeltaReads,
    CAST(DeltaReadStall * 1.0 / NULLIF(DeltaReads, 0) AS DECIMAL(10,2)) AS AvgReadLatencyMs,
    DeltaWrites,
    CAST(DeltaWriteStall * 1.0 / NULLIF(DeltaWrites, 0) AS DECIMAL(10,2)) AS AvgWriteLatencyMs
FROM Deltas
WHERE DeltaReads > 0 OR DeltaWrites > 0
ORDER BY AvgReadLatencyMs DESC;
```
### PHẦN 3: KIỂM TRA SỨC KHỎE VẬN HÀNH & HỆ THỐNG (OPERATIONS & ALWAYSON)

- 3.1. Xem các hạng mục bị WARN hoặc CRITICAL trong lần chạy mới nhất
```SQL
USE DbaMonitor;
GO

-- 1. Xem từ kết quả Audit Log của Daily Health Check
SELECT 
    CheckDate,
    CheckCategory,
    SeverityLevel,
    CheckDetails
FROM dbo.DailyCheckAuditLog
WHERE CheckDate = (SELECT MAX(CheckDate) FROM dbo.DailyCheckAuditLog)
ORDER BY CASE WHEN SeverityLevel = 'CRITICAL' THEN 1 ELSE 2 END;

-- 2. Xem các finding mới nhất từ bảng FRK BlitzResults
SELECT 
    CheckDate,
    Priority,
    FindingsGroup,
    Finding,
    DatabaseName,
    Details,
    URL
FROM dbo.BlitzResults
WHERE CheckDate = (SELECT MAX(CheckDate) FROM dbo.BlitzResults)
  AND Priority <= 50
ORDER BY Priority ASC;
```

- 3.2. Kiểm tra chi tiết trạng thái AlwaysOn (Lag Send/Redo Queue & Đồng bộ)

```SQL
SELECT 
    ag.name AS AGName,
    ar.replica_server_name AS ReplicaNode,
    DB_NAME(drs.database_id) AS DatabaseName,
    drs.is_local AS IsLocal,
    drs.is_primary_replica AS IsPrimary,
    drs.synchronization_state_desc AS SyncState,
    drs.synchronization_health_desc AS SyncHealth,
    drs.log_send_queue_size AS LogSendQueue_KB,
    drs.log_send_rate AS LogSendRate_KB_sec,
    drs.redo_queue_size AS RedoQueue_KB,
    drs.redo_rate AS RedoRate_KB_sec,
    -- Ước tính thời gian xả sạch redo queue (giây)
    CASE 
        WHEN drs.redo_rate > 0 
        THEN CAST((drs.redo_queue_size * 1.0 / drs.redo_rate) AS DECIMAL(10,1))
        ELSE 0 
    END AS RedoEstimatedCatchupSec
FROM sys.dm_hadr_database_replica_states drs
INNER JOIN sys.availability_groups ag ON ag.group_id = drs.group_id
INNER JOIN sys.availability_replicas ar ON ar.replica_id = drs.replica_id
ORDER BY ag.name, drs.database_id, drs.is_primary_replica DESC;
```

- 3.3. Xem Log lỗi nội bộ giám sát (Chống Silent Failure)

```SQL
USE DbaMonitor;
GO

SELECT TOP 50
    ErrorTime,
    ProcedureName,
    ErrorStep,
    ErrorMessage,
    ErrorLine
FROM dbo.DbaMonitorErrorLog
ORDER BY ErrorTime DESC;
```

### PHẦN 4: INDEX PHÂN MẢNH, LOG & VLF (KẾT HỢP FRK)

- 4.1. Xem Index phân mảnh (Index Fragmentation & Missing Index): Sử dụng FRK sp_BlitzIndex là cách tối ưu nhất để tránh quét toàn bộ bảng làm chậm I/O:

	- 1. Xem tổng quan vấn đề khẩn cấp nhất của Index (Mode 0: Diagnose - Mặc định)
	```sql
	EXEC dbo.sp_BlitzIndex @DatabaseName = 'TenDatabaseCuaBan', @Mode = 0;
	```
	- 2. Chẩn đoán chuyên sâu toàn diện các vấn đề Index (Mode 4: Diagnose Details) ,
	bao gồm cảnh báo phân mảnh nặng, index trùng lặp/dư thừa, chi phí bảo trì cao)
	```sql
	EXEC dbo.sp_BlitzIndex @DatabaseName = 'TenDatabaseCuaBan', @Mode = 4;
	```
	```sql
	- 3. Đào sâu riêng về các Index còn thiếu cần bổ sung (Mode 3: Missing Index Detail)
	EXEC dbo.sp_BlitzIndex @DatabaseName = 'TenDatabaseCuaBan', @Mode = 3;
	```
	- 4. Bảng kê mức độ sử dụng Đọc/Ghi thực tế của Index (Mode 2: Index Usage Detail)
	```sql
	EXEC dbo.sp_BlitzIndex @DatabaseName = 'TenDatabaseCuaBan', @Mode = 2;
	```
	- 5. Query DMV trực tiếp xem Top 20 Index phân mảnh > 30% trên Database hiện tại (bỏ qua table nhỏ < 8MB)
	```sql
	SELECT TOP 20
		DB_NAME() AS DatabaseName,
		OBJECT_SCHEMA_NAME(ps.object_id) AS SchemaName,
		OBJECT_NAME(ps.object_id) AS TableName,
		i.name AS IndexName,
		ps.index_type_desc,
		CAST(ps.avg_fragmentation_in_percent AS DECIMAL(5,2)) AS FragmentationPercent,
		ps.page_count,
		CAST((ps.page_count * 8.0 / 1024.0) AS DECIMAL(10,2)) AS SizeMB
	FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'LIMITED') ps
	INNER JOIN sys.indexes i ON ps.object_id = i.object_id AND ps.index_id = i.index_id
	WHERE ps.avg_fragmentation_in_percent > 30.0 
	  AND ps.page_count > 1000 -- Bỏ qua index < 8MB vì phân mảnh không gây ảnh hưởng I/O thực tế
	ORDER BY ps.avg_fragmentation_in_percent DESC;
	```

- 4.2. Xem Log File & Số lượng VLF (Virtual Log Files): VLF quá nhiều (> 1,000 VLFs) sẽ làm chậm quá trình khởi động SQL Server, failover AlwaysOn và giảm tốc độ ghi transaction log:

	- Kiểm tra kích thước Log, % Trống và Lý do Log không thể truncate (log_reuse_wait_desc)
	```SQL
	SELECT 
		d.name AS DatabaseName,
		d.recovery_model_desc AS RecoveryModel,
		d.log_reuse_wait_desc AS LogReuseWait,
		ls.total_log_size_in_bytes / 1048576.0 AS TotalLogMB,
		ls.used_log_space_in_bytes / 1048576.0 AS UsedLogMB,
		CAST(ls.used_log_space_in_percent AS DECIMAL(5,2)) AS UsedLogPercent,
		vlf.VLFCount,
		CASE 
			WHEN vlf.VLFCount > 1000 THEN 'CRITICAL (Cần Shrink & Pre-grow Log)'
			WHEN vlf.VLFCount > 500  THEN 'WARN'
			ELSE 'NORMAL'
		END AS VLFStatus
	FROM sys.databases d
	CROSS APPLY sys.dm_db_log_space_usage ls
	CROSS APPLY (
		SELECT COUNT(*) AS VLFCount 
		FROM sys.dm_db_log_info(d.database_id)
	) vlf
	WHERE d.database_id = ls.database_id
	ORDER BY vlf.VLFCount DESC;
	```
	
### PHẦN 5: DASHBOARD BÁO CÁO TỔNG HỢP (EXECUTIVE OVERVIEW TABLE)

- Query này tổng hợp toàn bộ các lát cắt quan trọng (CPU, Memory, Wait, Disk, Job, Deadlock) thành một bảng Dashboard duy nhất để DBA kiểm tra ngay lập tức:

```SQL
USE DbaMonitor;
GO

SELECT 
    '1. CPU & Memory (Lát cắt 1h gần nhất)' AS MetricGroup,
    'SQL Server CPU Avg' AS Indicator,
    CAST(AVG(CAST(CpuSqlPercent AS INT)) AS VARCHAR) + '%' AS CurrentStatus,
    'Bình thường nếu < 70%' AS Benchmark
FROM dbo.PerformanceSnapHistory 
WHERE SnapTime >= DATEADD(HOUR, -1, SYSDATETIME())

UNION ALL

SELECT 
    '1. CPU & Memory (Lát cắt 1h gần nhất)',
    'Page Life Expectancy (PLE)',
    CAST(AVG(PageLifeExpectancy) AS VARCHAR) + ' s',
    'Cảnh báo nếu < 300 s'
FROM dbo.PerformanceSnapHistory 
WHERE SnapTime >= DATEADD(HOUR, -1, SYSDATETIME())

UNION ALL

SELECT 
    '1. CPU & Memory (Lát cắt 1h gần nhất)',
    'Memory Grants Pending',
    CAST(MAX(MemoryGrantsPending) AS VARCHAR),
    'Phải bằng 0 (nghiêm trọng nếu > 0)'
FROM dbo.PerformanceSnapHistory 
WHERE SnapTime >= DATEADD(HOUR, -1, SYSDATETIME())

UNION ALL

SELECT 
    '2. Vận hành & Cảnh báo',
    'Số Deadlock (24h qua)',
    -- Đã sửa: Sử dụng bảng BlitzLockHistory và đếm distinct event_date (hoặc deadlock_group)
    CAST(COUNT(DISTINCT event_date) AS VARCHAR),
    'Cần tối ưu câu lệnh/Transaction'
FROM dbo.BlitzLockHistory 
WHERE event_date >= DATEADD(HOUR, -24, SYSDATETIME())

UNION ALL

SELECT 
    '2. Vận hành & Cảnh báo',
    'Lỗi hệ thống giám sát nội bộ (24h qua)',
    CAST(COUNT(*) AS VARCHAR),
    'Phải bằng 0 (kiểm tra DbaMonitorErrorLog)'
FROM dbo.DbaMonitorErrorLog 
WHERE ErrorTime >= DATEADD(HOUR, -24, SYSDATETIME())

UNION ALL

SELECT 
    '2. Vận hành & Cảnh báo',
    'Cảnh báo Daily Health Check (Hôm nay)',
    CAST(COUNT(*) AS VARCHAR),
    'Kiểm tra DailyCheckAuditLog'
FROM dbo.DailyCheckAuditLog 
WHERE CheckDate = CAST(SYSDATETIME() AS DATE)

UNION ALL

SELECT 
    '3. Lưu trữ Ổ đĩa',
    'Ổ đĩa có mức trống thấp nhất',
    VolumeMountPoint + ': ' + CAST(FreeSpacePercent AS VARCHAR) + '% free',
    'Cảnh báo nếu < 15%'
FROM (
    SELECT TOP 1 VolumeMountPoint, FreeSpacePercent 
    FROM dbo.StorageVolumeBaseline 
    WHERE SnapDate = (SELECT MAX(SnapDate) FROM dbo.StorageVolumeBaseline)
    ORDER BY FreeSpacePercent ASC
) d;
```