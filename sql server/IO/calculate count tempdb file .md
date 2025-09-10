### 1. Script Tối ưu TempDB , dựa trên khuyến nghị chuẩn của Microsoft (theo số core logic).

- Tự động tính toán số lượng file data tempdb dựa trên số core CPU.

- Thêm/Xóa file data để đạt số lượng khuyến nghị.

- Đồng bộ kích thước ban đầu và mức tăng trưởng cho tất cả các file data.

- Cấu hình kích thước và mức tăng trưởng cho file log.

- Kiểm tra các Trace Flag quan trọng (1117, 1118).

- Ghi log chi tiết quá trình thực thi.

Script sử dụng với Sql 2017+, bản cũ hơn thì thay thế STRING_AGG bằng phương thức FOR XML PATH và FORMAT(@i, '00') bằng RIGHT('00' + CAST(@i AS VARCHAR(2)), 2)

```bash
SET NOCOUNT ON;

PRINT '*** BAT DAU QUA TRINH TOI UU HOA TEMPDB (v2.0) ***';
PRINT 'Thoi gian thuc thi: ' + CONVERT(NVARCHAR, GETDATE(), 120);
PRINT '----------------------------------------------------------';

-- =====================================================================================
-- >> PHẦN CẤU HÌNH: Bạn có thể thay đổi các giá trị tại đây cho phù hợp <<
-- =====================================================================================
DECLARE @WorkloadType NVARCHAR(20) = 'Medium'; -- Các tùy chọn: 'Light', 'Medium', 'Heavy'
DECLARE @MaxDataFiles INT = 8;                 -- Giới hạn số file data tối đa. Mặc định là 8.

-- Khai báo các biến kích thước
DECLARE @InitialDataFileSizeMB INT;
DECLARE @AutoGrowthDataFileMB INT;
DECLARE @InitialLogFileSizeMB INT = 1024; -- Kích thước ban đầu cho file log (MB)
DECLARE @AutoGrowthLogFileMB INT = 512;   -- Mức tăng trưởng cho file log (MB)

-- Tự động gán giá trị dựa trên WorkloadType
SELECT @InitialDataFileSizeMB = CASE @WorkloadType
                                   WHEN 'Light' THEN 512
                                   WHEN 'Medium' THEN 1024
                                   WHEN 'Heavy' THEN 2048
                                   ELSE 1024
                               END,
       @AutoGrowthDataFileMB = CASE @WorkloadType
                                 WHEN 'Light' THEN 256
                                 WHEN 'Medium' THEN 512
                                 WHEN 'Heavy' THEN 1024
                                 ELSE 512
                               END;

-- =====================================================================================
-- >> PHẦN THỰC THI: Không cần chỉnh sửa phần dưới đây <<
-- =====================================================================================

-- Tạo bảng tạm để ghi log
IF OBJECT_ID('tempdb..#TempDBLog') IS NOT NULL DROP TABLE #TempDBLog;
CREATE TABLE #TempDBLog (
    LogID INT IDENTITY(1,1) PRIMARY KEY,
    LogTime DATETIME DEFAULT GETDATE(),
    ActionType NVARCHAR(50),
    Details NVARCHAR(MAX)
);

INSERT INTO #TempDBLog (ActionType, Details) VALUES ('Start', 'Start tempdb optimization process.');

-- --- Bước 0: Kiểm tra điều kiện ban đầu ---
PRINT N'--- Buoc 0: Kiem tra dieu kien ban dau ---';

-- Kiểm tra trạng thái tempdb
IF DB_ID('tempdb') IS NULL OR (SELECT state_desc FROM sys.databases WHERE name = 'tempdb') <> 'ONLINE'
BEGIN
    INSERT INTO #TempDBLog (ActionType, Details) VALUES ('Fatal Error', 'Tempdb does not exist or is not ONLINE. Please check the instance!');
    SELECT LogTime, ActionType, Details FROM #TempDBLog ORDER BY LogID;
    RETURN;
END

-- Thu thập thông tin hệ thống
DECLARE @LogicalCPUCount INT;
DECLARE @RecommendedFileCount INT;
DECLARE @CurrentFileCount INT;
DECLARE @TempDBPath NVARCHAR(260);
DECLARE @SQL_Command NVARCHAR(MAX);

SELECT @LogicalCPUCount = cpu_count FROM sys.dm_os_sys_info;

-- Tính toán số file khuyến nghị (không vượt quá @MaxDataFiles)
SET @RecommendedFileCount = CASE WHEN @LogicalCPUCount > @MaxDataFiles THEN @MaxDataFiles ELSE @LogicalCPUCount END;
IF @RecommendedFileCount = 0 SET @RecommendedFileCount = 1; -- Đảm bảo có ít nhất 1 file

-- Lấy số file data hiện tại và đường dẫn
SELECT @CurrentFileCount = COUNT(*) FROM tempdb.sys.database_files WHERE type_desc = 'ROWS';
SELECT TOP 1 @TempDBPath = LEFT(physical_name, LEN(physical_name) - CHARINDEX('\', REVERSE(physical_name)))
FROM tempdb.sys.database_files WHERE type_desc = 'ROWS';

-- Ghi thông tin hệ thống vào log
INSERT INTO #TempDBLog (ActionType, Details)
VALUES ('System Info',
        'Number core CPU logic: ' + CAST(@LogicalCPUCount AS NVARCHAR(10)) +
        ', Number file data recommen: ' + CAST(@RecommendedFileCount AS NVARCHAR(10)) +
        ', Number current file data: ' + CAST(@CurrentFileCount AS NVARCHAR(10)) +
        ', Path TempDB: ' + @TempDBPath);


-- --- Bước 1: Xóa file thừa nếu cần ---
PRINT N'--- Buoc 1: Xoa file data thua (neu co) ---';
IF @CurrentFileCount > @RecommendedFileCount
BEGIN
    -- Tạo câu lệnh xóa file động, không dùng cursor
    SELECT @SQL_Command = STRING_AGG(N'ALTER DATABASE [tempdb] REMOVE FILE ' + QUOTENAME(name) + ';', N' ')
    FROM (
        SELECT name, ROW_NUMBER() OVER (ORDER BY file_id) as rn
        FROM tempdb.sys.database_files
        WHERE type_desc = 'ROWS'
    ) AS files
    WHERE rn > @RecommendedFileCount;

    PRINT N'Thuc thi lenh: ' + @SQL_Command;
    BEGIN TRY
        EXEC sp_executesql @SQL_Command;
        INSERT INTO #TempDBLog (ActionType, Details) VALUES ('Remove Files', N'Delete redundant data files. Please check system log for details.');
    END TRY
    BEGIN CATCH
        INSERT INTO #TempDBLog (ActionType, Details) VALUES ('Error', 'Error delete redundant data file: ' + ERROR_MESSAGE());
    END CATCH
END

-- Cập nhật lại số file hiện tại sau khi xóa
SELECT @CurrentFileCount = COUNT(*) FROM tempdb.sys.database_files WHERE type_desc = 'ROWS';

-- --- Bước 2: Thêm file data nếu cần ---
PRINT N'--- Buoc 2: Them file data moi (neu can) ---';
IF @CurrentFileCount < @RecommendedFileCount
BEGIN
    PRINT N'Number file data (' + STR(@CurrentFileCount) + ') not enough for recommendation (' + STR(@RecommendedFileCount) + '). Begin add new file...';
    DECLARE @i INT = @CurrentFileCount + 1;
    WHILE @i <= @RecommendedFileCount
    BEGIN
        DECLARE @NewFileName NVARCHAR(128) = N'tempdev' + FORMAT(@i, '00');
        -- Kiểm tra file đã tồn tại chưa để tránh lỗi
        IF NOT EXISTS (SELECT 1 FROM tempdb.sys.database_files WHERE name = @NewFileName)
        BEGIN
            DECLARE @NewFilePath NVARCHAR(520) = @TempDBPath + N'\' + @NewFileName + N'.ndf';
            SET @SQL_Command = N'ALTER DATABASE [tempdb] ADD FILE (NAME = ' + QUOTENAME(@NewFileName, '''') + ', FILENAME = N''' + @NewFilePath + ''', SIZE = ' + CAST(@InitialDataFileSizeMB AS NVARCHAR(10)) + N'MB, FILEGROWTH = ' + CAST(@AutoGrowthDataFileMB AS NVARCHAR(10)) + N'MB)';            
            BEGIN TRY
                EXEC sp_executesql @SQL_Command;
                INSERT INTO #TempDBLog (ActionType, Details) VALUES ('Add File', 'Add file [' + @NewFileName + '] is successful.');
            END TRY
            BEGIN CATCH
                INSERT INTO #TempDBLog (ActionType, Details) VALUES ('Error', 'Error add file [' + @NewFileName + ']: ' + ERROR_MESSAGE());
            END CATCH
        END
        SET @i = @i + 1;
    END
END

-- --- Bước 3: Đồng bộ kích thước và autogrowth cho tất cả các file ---
DECLARE @ModifyScript NVARCHAR(MAX) = N'';

-- Tạo script cho DATA files
SELECT @ModifyScript += N'ALTER DATABASE [tempdb] MODIFY FILE (NAME = ' + QUOTENAME(name, '''') + ', SIZE = ' + CAST(@InitialDataFileSizeMB AS NVARCHAR(10)) + 'MB, FILEGROWTH = ' + CAST(@AutoGrowthDataFileMB AS NVARCHAR(10)) + 'MB);' + CHAR(13)
FROM tempdb.sys.database_files
WHERE type_desc = 'ROWS'
  AND ( (size * 8 / 1024) <> @InitialDataFileSizeMB OR is_percent_growth = 1 OR (growth * 8 / 1024) <> @AutoGrowthDataFileMB );

-- Tạo script cho LOG file
SELECT @ModifyScript += N'ALTER DATABASE [tempdb] MODIFY FILE (NAME = ' + QUOTENAME(name, '''') + ', SIZE = ' + CAST(@InitialLogFileSizeMB AS NVARCHAR(10)) + 'MB, FILEGROWTH = ' + CAST(@AutoGrowthLogFileMB AS NVARCHAR(10)) + 'MB);' + CHAR(13)
FROM tempdb.sys.database_files
WHERE type_desc = 'LOG'
  AND ( (size * 8 / 1024) <> @InitialLogFileSizeMB OR is_percent_growth = 1 OR (growth * 8 / 1024) <> @AutoGrowthLogFileMB );

IF LEN(@ModifyScript) > 0
BEGIN
    PRINT @ModifyScript;
    BEGIN TRY
        EXEC sp_executesql @ModifyScript;
        INSERT INTO #TempDBLog (ActionType, Details) VALUES ('Modify Files', 'Synced size and autogrowth for files.');
    END TRY
    BEGIN CATCH
        INSERT INTO #TempDBLog (ActionType, Details) VALUES ('Error', 'Error Synced file: ' + ERROR_MESSAGE());
    END CATCH
END

-- --- Bước 4: Kiểm tra Trace Flags ---
PRINT N'--- Buoc 4: Kiem tra cac Trace Flag khuyen nghi ---';
CREATE TABLE #TraceStatus (TraceFlag INT, Status INT, Global INT, Session INT);
DBCC TRACESTATUS(-1) WITH NO_INFOMSGS;
INSERT INTO #TraceStatus
EXEC ('DBCC TRACESTATUS(-1) WITH NO_INFOMSGS');

IF NOT EXISTS (SELECT 1 FROM #TraceStatus WHERE TraceFlag = 1117 AND Global = 1)
BEGIN
    INSERT INTO #TempDBLog (ActionType, Details) VALUES ('Warning', 'Trace Flag 1117 is not enabled. Use: DBCC TRACEON(1117, -1); or add -T1117 to the startup parameter.');
END

IF NOT EXISTS (SELECT 1 FROM #TraceStatus WHERE TraceFlag = 1118 AND Global = 1)
BEGIN
    INSERT INTO #TempDBLog (ActionType, Details) VALUES ('Warning', 'Trace Flag 1118 is not enabled. Use: DBCC TRACEON(1118, -1); or add -T1117 to the startup parameter.');
END

DROP TABLE #TraceStatus;

-- --- Bước 5: Hoàn tất và hiển thị log ---
INSERT INTO #TempDBLog (ActionType, Details) VALUES ('Complete', 'Complete process.');

SELECT LogTime, ActionType, Details FROM #TempDBLog ORDER BY LogID;

-- Dọn dẹp bảng log
DROP TABLE #TempDBLog;
```


### 2. Add tempdb file

```bash
--- xem cấu hình hiện tại
SELECT name, type_desc, physical_name, size * 8 / 1024 AS size_MB
FROM tempdb.sys.database_files;

--- thêm 1 file mới
ALTER DATABASE tempdb 
ADD FILE (NAME = tempdev1, FILENAME = 'G:\TempDB_3D\tempdb1.ndf',SIZE = 1204MB, FILEGROWTH = 1024MB
);
```