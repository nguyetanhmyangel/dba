### 1. Script phân tích và đề xuất kích thước và mức tăng trưởng tối ưu cho các file Transaction Log, hỗ trợ nhiều file log, xử lý thiếu lịch sử backup, tối ưu VLF chi tiết, và kiểm tra Availability Group (AG).

```bash
/****************************************************************************
 * Script tối ưu kích thước Transaction Log - Phiên bản cải tiến cho AG
 * Mục đích: Phân tích và đề xuất kích thước và mức tăng trưởng tối ưu
 * cho các file Transaction Log, hỗ trợ nhiều file log, xử lý thiếu lịch sử
 * backup, tối ưu VLF chi tiết, và kiểm tra Availability Group (AG).
 ****************************************************************************/
USE [YourDatabase]; -- << THAY TÊN DATABASE CỦA BẠN VÀO ĐÂY
GO
SET NOCOUNT ON;

-- Bảng tạm để lưu thông tin file log
DECLARE @LogFiles TABLE (
    LogicalName SYSNAME,
    CurrentSizeMB DECIMAL(18,2),
    CurrentUsedMB DECIMAL(18,2),
    PeakUncompressedMB DECIMAL(18,2),
    LargeTransactionMB DECIMAL(18,2),
    TargetMB INT,
    VLFCount INT,
    VLFWarning NVARCHAR(MAX),
    SQL_ShrinkFile NVARCHAR(MAX),
    SQL_ModifyFile NVARCHAR(MAX)
);

DECLARE @DBName SYSNAME = DB_NAME();
DECLARE @DataSizeMB DECIMAL(18,2);
DECLARE @CurrentUsedMB DECIMAL(18,2);
DECLARE @FileGrowthMB INT = 512; -- Mức tăng trưởng mặc định (512 MB)
DECLARE @MinLogSizeMB INT = 1024; -- Kích thước log tối thiểu (1 GB)
DECLARE @MaxVLFPerFile INT = 300; -- Số VLF tối đa đề xuất cho mỗi file
DECLARE @MinVLFPerFile INT = 50;  -- Số VLF tối thiểu đề xuất cho mỗi file
DECLARE @RecoveryModel SYSNAME;
DECLARE @LogReuseWait SYSNAME;
DECLARE @Warning NVARCHAR(MAX) = '';
DECLARE @DiskFreeMB DECIMAL(18,2);
DECLARE @LargeTransactionMB DECIMAL(18,2);
DECLARE @SQL_BackupLog NVARCHAR(MAX) = '';
DECLARE @TotalVLFCount INT = 0;
DECLARE @IsInAG BIT = 0;
-- FIX 2: Khai báo các biến bị thiếu
DECLARE @SQL_ShrinkFile NVARCHAR(MAX);
DECLARE @SQL_ModifyFile NVARCHAR(MAX);

BEGIN TRY
    -- 1. Kiểm tra xem DB có trong AG không
    IF EXISTS (
        SELECT 1
        FROM sys.availability_databases_cluster adc
        JOIN sys.availability_groups ag ON adc.group_id = ag.group_id
        WHERE adc.database_name = @DBName
    )
    BEGIN
        SET @IsInAG = 1;
        SET @Warning = @Warning + N'!!! CẢNH BÁO: Cơ sở dữ liệu nằm trong Availability Group. Không được chuyển sang Simple Recovery vì sẽ phá vỡ AG.' + CHAR(13) + CHAR(10);
    END

    -- 2. Lấy mô hình phục hồi và trạng thái log reuse wait
    SELECT @RecoveryModel = d.recovery_model_desc,
           @LogReuseWait = d.log_reuse_wait_desc
    FROM sys.databases d
    WHERE d.name = @DBName;

    IF @IsInAG = 1 AND @RecoveryModel != 'FULL'
        SET @Warning = @Warning + N'!!! CẢNH BÁO: Cơ sở dữ liệu trong AG nhưng không ở Full Recovery. Cần chuyển sang Full Recovery trước khi tiếp tục.' + CHAR(13) + CHAR(10);

    -- 3. Lấy tổng kích thước file dữ liệu để tham khảo
    SELECT @DataSizeMB = SUM(f.size / 128.0)
    FROM sys.master_files f
    WHERE f.database_id = DB_ID() AND f.type_desc = 'ROWS';

    -- 4. Lấy % sử dụng log hiện tại
    CREATE TABLE #LogSpace (
        DBName SYSNAME,
        LogSizeMB DECIMAL(18,2),
        LogUsedPct DECIMAL(5,2),
        Status INT
    );
    INSERT INTO #LogSpace
    EXEC('DBCC SQLPERF(LOGSPACE)');
    SELECT @CurrentUsedMB = LogSizeMB * (LogUsedPct / 100.0)
    FROM #LogSpace 
    WHERE DBName = @DBName;
    DROP TABLE #LogSpace;

    -- 5. Kiểm tra không gian đĩa trống
    -- FIX 3: Sử dụng cột 'available_bytes' thay vì 'used_bytes' không tồn tại
    SELECT TOP 1 @DiskFreeMB = available_bytes / 1024.0 / 1024.0
    FROM sys.dm_os_volume_stats(DB_ID(), (SELECT TOP 1 file_id FROM sys.master_files WHERE database_id = DB_ID() AND type_desc = 'LOG'));

    -- 6. Ước lượng giao dịch lớn dựa trên bảng/index lớn nhất
    SELECT @LargeTransactionMB = MAX(au.total_pages / 128.0) * 2 -- Nhân 2 để dự phòng
    FROM sys.partitions p
    JOIN sys.allocation_units au ON p.hobt_id = au.container_id
    WHERE p.object_id IN (SELECT object_id FROM sys.indexes WHERE index_id IN (0, 1)) -- Chỉ lấy heap/clustered index
    AND p.index_id IN (0, 1);
    IF @LargeTransactionMB IS NULL
        SET @LargeTransactionMB = @DataSizeMB * 0.1; -- Mặc định 10% kích thước file dữ liệu

    -- 7. Kiểm tra lịch sử backup để tìm giao dịch lớn
    IF @RecoveryModel IN ('FULL', 'BULK_LOGGED')
    BEGIN
        -- FIX 1: Thay thế GREATEST bằng cấu trúc tương thích
        SELECT @LargeTransactionMB =
            (SELECT MAX(v)
             FROM (VALUES
                (@LargeTransactionMB),
                (MAX(CAST(b.backup_size / 1024.0 / 1024.0 AS DECIMAL(18,2))) * 2)
             ) AS value(v)
            )
        FROM msdb.dbo.backupset b
        WHERE b.database_name = @DBName
          AND b.type IN ('L', 'I')
          AND b.backup_finish_date > DATEADD(DAY, -30, GETDATE())
          AND (b.description LIKE '%REBUILD%' OR b.description LIKE '%BULK%');
    END

    -- 8. Xử lý từng file log
    DECLARE @LogicalName SYSNAME, @CurrentSizeMB DECIMAL(18,2), @PeakUncompressedMB DECIMAL(18,2), @TargetMB INT, @VLFCount INT, @VLFWarning NVARCHAR(MAX);
    DECLARE log_cursor CURSOR FOR
        SELECT name, size / 128.0
        FROM sys.master_files
        WHERE database_id = DB_ID() AND type_desc = 'LOG';
    
    OPEN log_cursor;
    FETCH NEXT FROM log_cursor INTO @LogicalName, @CurrentSizeMB;
    
    WHILE @@FETCH_STATUS = 0
    BEGIN
        -- 9. Kiểm tra Peak log backup size (chưa nén)
        SET @PeakUncompressedMB = NULL;
        IF @RecoveryModel IN ('FULL', 'BULK_LOGGED')
        BEGIN
            SELECT @PeakUncompressedMB = MAX(CAST(b.backup_size / 1024.0 / 1024.0 AS DECIMAL(18, 2)))
            FROM msdb.dbo.backupset b
            WHERE b.database_name = @DBName
              AND b.type = 'L'
              AND b.backup_finish_date > DATEADD(DAY, -30, GETDATE());
        END

        -- 10. Tính kích thước mục tiêu
        IF @PeakUncompressedMB IS NULL OR @PeakUncompressedMB = 0
        BEGIN
            -- FIX 1: Thay thế GREATEST bằng cấu trúc tương thích
            SELECT @TargetMB = CEILING(val) FROM (
                SELECT MAX(v) as val FROM (VALUES 
                    (@DataSizeMB * 0.2), 
                    (@CurrentUsedMB * 2), 
                    (CAST(@MinLogSizeMB AS DECIMAL(18,2))), 
                    (@LargeTransactionMB)
                ) AS value(v)
            ) as t;
            SET @Warning = @Warning + N'!!! CẢNH BÁO: Không tìm thấy dữ liệu backup log trong 30 ngày cho file ' + @LogicalName + '. Kích thước đề xuất (' + CAST(@TargetMB AS VARCHAR) + ' MB) dựa trên 20% kích thước file dữ liệu, mức sử dụng hiện tại, và giao dịch lớn.' + CHAR(13) + CHAR(10);
        END
        ELSE
        BEGIN
            -- FIX 1: Thay thế GREATEST bằng cấu trúc tương thích
            SELECT @TargetMB = CEILING(val) FROM (
                SELECT MAX(v) as val FROM (VALUES 
                    (@PeakUncompressedMB * 1.5), 
                    (CAST(@MinLogSizeMB AS DECIMAL(18,2))), 
                    (@LargeTransactionMB)
                ) AS value(v)
            ) as t;
        END

        -- 11. Tối ưu VLF: Điều chỉnh kích thước để số VLF nằm trong khoảng 50-300
        DECLARE @EstimatedVLF INT;
        SET @EstimatedVLF = CASE 
            WHEN @TargetMB < 1 THEN 4
            WHEN @TargetMB < 64 THEN 4
            WHEN @TargetMB < 1024 THEN 8
            ELSE @TargetMB / 64 -- Ước lượng 1 VLF ≈ 64 MB
        END;

        IF @EstimatedVLF < @MinVLFPerFile
        BEGIN
            SET @TargetMB = CEILING(@MinVLFPerFile * 64.0);
            SET @VLFWarning = '!!! CẢNH BÁO: Kích thước log ban đầu quá nhỏ, đã điều chỉnh lên ' + CAST(@TargetMB AS VARCHAR) + ' MB để đạt tối thiểu ' + CAST(@MinVLFPerFile AS VARCHAR) + ' VLF.';
        END
        ELSE IF @EstimatedVLF > @MaxVLFPerFile
        BEGIN
            SET @FileGrowthMB = CEILING(CAST(@TargetMB AS DECIMAL(18,2)) / @MaxVLFPerFile);
            SET @VLFWarning = '!!! CẢNH BÁO: Số VLF ước tính (' + CAST(@EstimatedVLF AS VARCHAR) + ') quá cao. Đã điều chỉnh FileGrowth lên ' + CAST(@FileGrowthMB AS VARCHAR) + ' MB để tối ưu VLF.';
        END
        ELSE
            SET @VLFWarning = '';

        -- 12. Kiểm tra không gian đĩa
        IF @DiskFreeMB < @TargetMB
            SET @Warning = @Warning + N'!!! CẢNH BÁO: Không gian đĩa trống (' + CAST(@DiskFreeMB AS VARCHAR) + ' MB) không đủ để mở rộng log ' + @LogicalName + ' đến ' + CAST(@TargetMB AS VARCHAR) + ' MB.' + CHAR(13) + CHAR(10);

        -- 13. Kiểm tra số lượng VLF
        IF EXISTS (SELECT 1 FROM sys.all_objects WHERE name = 'dm_db_log_info')
            SELECT @VLFCount = COUNT(li.database_id)
            FROM sys.dm_db_log_info(DB_ID()) li
            WHERE li.file_id = (SELECT file_id FROM sys.master_files WHERE database_id = DB_ID() AND name = @LogicalName);
        ELSE
        BEGIN
            CREATE TABLE #VLF (FileId INT, FileSize BIGINT, StartOffset BIGINT, FSeqNo INT, Status INT, Parity INT, CreateLSN NUMERIC(25,0));
            INSERT INTO #VLF EXEC('DBCC LOGINFO');
            SELECT @VLFCount = COUNT(*) FROM #VLF WHERE FileId = (SELECT file_id FROM sys.master_files WHERE database_id = DB_ID() AND name = @LogicalName);
            DROP TABLE #VLF;
        END
        SET @TotalVLFCount = @TotalVLFCount + @VLFCount;

        -- 14. Sinh câu lệnh
        SET @SQL_ShrinkFile = 'DBCC SHRINKFILE (N''' + @LogicalName + ''' , 0, TRUNCATEONLY);';
        SET @SQL_ModifyFile = '
ALTER DATABASE [' + @DBName + ']
MODIFY FILE (NAME = N''' + @LogicalName + ''', SIZE = ' + CAST(@TargetMB AS VARCHAR) + 'MB, FILEGROWTH = ' + CAST(@FileGrowthMB AS VARCHAR) + 'MB);
';

        -- 15. Lưu thông tin vào bảng tạm
        INSERT INTO @LogFiles (LogicalName, CurrentSizeMB, CurrentUsedMB, PeakUncompressedMB, LargeTransactionMB, TargetMB, VLFCount, VLFWarning, SQL_ShrinkFile, SQL_ModifyFile)
        VALUES (@LogicalName, @CurrentSizeMB, @CurrentUsedMB, @PeakUncompressedMB, @LargeTransactionMB, @TargetMB, @VLFCount, @VLFWarning, @SQL_ShrinkFile, @SQL_ModifyFile);

        FETCH NEXT FROM log_cursor INTO @LogicalName, @CurrentSizeMB;
    END
    CLOSE log_cursor;
    DEALLOCATE log_cursor;

    -- 16. Kiểm tra log reuse wait và đề xuất sao lưu log nếu cần
    IF @LogReuseWait NOT IN ('NOTHING', 'CHECKPOINT') AND @RecoveryModel IN ('FULL', 'BULK_LOGGED')
    BEGIN
        SET @SQL_BackupLog = 'BACKUP LOG [' + @DBName + '] TO DISK = N''C:\Backup\' + @DBName + '_Log_' + REPLACE(CONVERT(VARCHAR, GETDATE(), 120), ':', '') + '.trn'';';
        SET @Warning = @Warning + N'!!! CẢNH BÁO: Log không thể thu nhỏ do ' + @LogReuseWait + '. Hãy chạy sao lưu log trước trên primary replica.' + CHAR(13) + CHAR(10);
    END

    -- 17. Kiểm tra tổng số VLF
    IF @TotalVLFCount > 1000
        SET @Warning = @Warning + N'!!! CẢNH BÁO: Tổng số VLF (' + CAST(@TotalVLFCount AS VARCHAR) + ') quá cao. Cân nhắc giảm số lượng file log hoặc tối ưu lại kích thước.' + CHAR(13) + CHAR(10);

    -- 18. In kết quả phân tích và đề xuất
    PRINT '================================================================================';
    PRINT ' PHÂN TÍCH VÀ TỐI ƯU TRANSACTION LOG CHO DATABASE: ' + QUOTENAME(@DBName);
    PRINT '================================================================================';
    PRINT '';
    PRINT '--- THÔNG TIN HIỆN TẠI ---';
    PRINT 'Database trong Availability Group: ' + CASE WHEN @IsInAG = 1 THEN 'Có' ELSE 'Không' END;
    PRINT 'Recovery Model : ' + @RecoveryModel;
    PRINT 'Log Reuse Wait : ' + @LogReuseWait;
    PRINT 'Tổng kích thước Data (MB) : ' + ISNULL(CAST(@DataSizeMB AS VARCHAR(30)), 'N/A');
    PRINT 'Mức sử dụng Log hiện tại (MB): ' + ISNULL(CAST(@CurrentUsedMB AS VARCHAR(30)), 'N/A');
    PRINT 'Không gian đĩa trống (MB) : ' + ISNULL(CAST(@DiskFreeMB AS VARCHAR(30)), 'N/A');
    PRINT 'Ước lượng giao dịch lớn (MB): ' + ISNULL(CAST(@LargeTransactionMB AS VARCHAR(30)), 'N/A');
    PRINT 'Tổng số VLF: ' + CAST(@TotalVLFCount AS VARCHAR(30));
    PRINT '';

    -- In thông tin từng file log
    DECLARE @FileInfo NVARCHAR(MAX);
    SET @FileInfo = '';
    SELECT @FileInfo = @FileInfo + 
        '--- File Log: ' + LogicalName + CHAR(13) + CHAR(10) +
        'Kích thước hiện tại (MB): ' + CAST(CurrentSizeMB AS VARCHAR(30)) + CHAR(13) + CHAR(10) +
        'Mức sử dụng hiện tại (MB): ' + CAST(CurrentUsedMB AS VARCHAR(30)) + CHAR(13) + CHAR(10) +
        'Số lượng VLF hiện tại: ' + CAST(VLFCount AS VARCHAR(30)) + CHAR(13) + CHAR(10) +
        'Peak Log Backup (30 ngày) (MB): ' + ISNULL(CAST(PeakUncompressedMB AS VARCHAR(30)), 'Không có dữ liệu') + CHAR(13) + CHAR(10) +
        'Ước lượng giao dịch lớn (MB): ' + CAST(LargeTransactionMB AS VARCHAR(30)) + CHAR(13) + CHAR(10) +
        'Kích thước đề xuất (MB): ' + CAST(TargetMB AS VARCHAR(30)) + CHAR(13) + CHAR(10) +
        'Mức tăng trưởng đề xuất (MB): ' + CAST(@FileGrowthMB AS VARCHAR(30)) + CHAR(13) + CHAR(10) +
        ISNULL(VLFWarning + CHAR(13) + CHAR(10), '') +
        CHAR(13) + CHAR(10)
    FROM @LogFiles;

    PRINT '--- KẾT QUẢ PHÂN TÍCH ---';
    PRINT @FileInfo;

    PRINT '--- ĐỀ XUẤT TỐI ƯU ---';
    IF @Warning <> ''
        PRINT @Warning;
    PRINT '';

    PRINT '--- HÀNH ĐỘNG ĐỀ XUẤT ---';
    IF @SQL_BackupLog <> ''
    BEGIN
        PRINT '-- Bước 1: Sao lưu log để giải phóng không gian (chạy trên primary replica nếu cần).';
        PRINT @SQL_BackupLog;
        PRINT '';
    END

    PRINT '-- Bước 2: Shrink log để giải phóng không gian không sử dụng (chạy nếu cần).';
    -- Sử dụng STRING_AGG, tương thích với SQL Server 2017+
    SELECT @FileInfo = STRING_AGG(SQL_ShrinkFile, CHAR(13) + CHAR(10)) FROM @LogFiles;
    PRINT @FileInfo;
    PRINT '';

    PRINT '-- Bước 3: Đặt lại kích thước và mức tăng trưởng cho các file log.';
    SELECT @FileInfo = STRING_AGG(SQL_ModifyFile, CHAR(13) + CHAR(10)) FROM @LogFiles;
    PRINT @FileInfo;
    PRINT '================================================================================';
END TRY
BEGIN CATCH
    PRINT '=== LỖI: ' + ERROR_MESSAGE();
END CATCH
GO

```

#### 1.1 Hướng dẫn sử dụng script

- Thay YourDatabase bằng tên cơ sở dữ liệu thực tế hoặc để nguyên để sử dụng cơ sở dữ liệu hiện tại.
- Chạy script trên primary replica (nếu cơ sở dữ liệu trong AG) để xem thông tin phân tích và các câu lệnh đề xuất.
- Nếu có câu lệnh BACKUP LOG, chạy nó trên primary replica để giải phóng log.
- Chạy các lệnh DBCC SHRINKFILE cho từng file log nếu cần thu nhỏ.
- Chạy các lệnh ALTER DATABASE để đặt kích thước và mức tăng trưởng mới cho từng file log.
- Kiểm tra số lượng VLF sau khi thực hiện:

```bash
sqlSELECT file_id, COUNT(*) AS VLFCount
FROM sys.dm_db_log_info(DB_ID())
GROUP BY file_id;
```


#### 1.2 Lưu ý thêm

- Availability Group:

    - Chỉ chạy các lệnh BACKUP LOG và DBCC SHRINKFILE trên primary replica.
    - Không chuyển cơ sở dữ liệu sang Simple Recovery khi trong AG, vì sẽ gây lỗi.

- Không gian đĩa: Đảm bảo ổ đĩa có đủ không gian trước khi chạy ALTER DATABASE.
- Giao dịch lớn: Ước lượng dựa trên bảng/index lớn nhất có thể không chính xác nếu có các giao dịch đặc biệt (như ETL). Theo dõi workload thực tế để điều chỉnh.
- VLF: Nếu tổng số VLF vẫn quá cao (>1000), cân nhắc giảm số lượng file log hoặc lặp lại quá trình shrink/resize với FILEGROWTH lớn hơn.
- Tần suất sao lưu log: Trong AG, thiết lập sao lưu log thường xuyên (ví dụ: mỗi 15-30 phút) để kiểm soát kích thước log.

#### 1.3 Nhược điểm của script trên: việc phân tích chỉ dựa trên snapshot hiện tại hoặc lịch sử backup 30 ngày.

### 2. Dưới đây là một script tốt hơn, để tối ưu kích thước Transaction Log bằng cách tạo 2 table dbo.LogPeakUsageHistory và usp_UpdateLogPeakUsage để lưu trữ đỉnh sử dụng log từ sys.dm_db_log_stats. Chạy định kỳ usp_UpdateLogPeakUsage qua SQL Agent Job để cập nhật lịch sử.

```bash
USE [DbaMonitor]; 
GO
SET NOCOUNT ON;

-- Tạo bảng lưu lịch sử đỉnh log
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'LogPeakUsageHistory')
BEGIN
    CREATE TABLE dbo.LogPeakUsageHistory (
        DatabaseName sysname PRIMARY KEY,
        PeakUsedLogMB DECIMAL(18, 2) NOT NULL,
        PeakTotalLogSizeMB DECIMAL(18, 2) NOT NULL,
        PeakTime DATETIME2(0) NOT NULL,
        LastChecked DATETIME2(0) NOT NULL
    );
END
GO

-- Tạo bảng lưu trạng thái batch
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'DatabaseBatchProcessing')
BEGIN
    CREATE TABLE dbo.DatabaseBatchProcessing (
        DatabaseName SYSNAME PRIMARY KEY,
        BatchNumber INT NOT NULL,
        Status NVARCHAR(50) NOT NULL DEFAULT 'Pending',
        LastProcessed DATETIME2(0) NULL,
        ErrorMessage NVARCHAR(MAX) NULL
    );
END
GO

-- Tạo bảng lưu lịch sử audit
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'LogOptimizationAudit')
BEGIN
    CREATE TABLE dbo.LogOptimizationAudit (
        AuditID BIGINT IDENTITY(1,1) PRIMARY KEY,
        BatchNumber INT NOT NULL,
        DatabaseName SYSNAME NOT NULL,
        Action NVARCHAR(100) NOT NULL,
        SQLCommand NVARCHAR(MAX) NULL,
        Status NVARCHAR(50) NOT NULL,
        ExecutionTime DATETIME2(0) NOT NULL,
        ErrorMessage NVARCHAR(MAX) NULL
    );
END
GO

-- Stored procedure để cập nhật lịch sử đỉnh log
IF OBJECT_ID('dbo.usp_UpdateLogPeakUsage', 'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_UpdateLogPeakUsage;
GO

CREATE PROCEDURE dbo.usp_UpdateLogPeakUsage
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @CurrentTime DATETIME2(0) = GETDATE();

    -- Chỉ chạy trên primary replica trong AG
    IF EXISTS (SELECT 1 FROM sys.dm_hadr_availability_replica_states WHERE is_local = 1 AND role_desc <> 'PRIMARY')
        RETURN;

    BEGIN TRY
        MERGE INTO dbo.LogPeakUsageHistory AS Target
        USING (
            SELECT
                d.name AS DatabaseName,
                ls.log_since_last_log_backup_mb AS CurrentUsedLogMB,
                ls.total_log_size_mb AS CurrentTotalLogSizeMB
            FROM sys.databases d
            CROSS APPLY sys.dm_db_log_stats(d.database_id) ls
            WHERE
                d.database_id > 4
                AND d.state_desc = 'ONLINE'
                AND d.recovery_model_desc <> 'SIMPLE'
                AND ls.total_log_size_mb > 0
        ) AS Source
        ON Target.DatabaseName = Source.DatabaseName
        WHEN MATCHED THEN
            UPDATE SET
                PeakUsedLogMB = CASE 
                    WHEN Source.CurrentUsedLogMB > Target.PeakUsedLogMB 
                    THEN Source.CurrentUsedLogMB 
                    ELSE Target.PeakUsedLogMB 
                END,
                PeakTotalLogSizeMB = CASE 
                    WHEN Source.CurrentUsedLogMB > Target.PeakUsedLogMB 
                    THEN Source.CurrentTotalLogSizeMB 
                    ELSE Target.PeakTotalLogSizeMB 
                END,
                PeakTime = CASE 
                    WHEN Source.CurrentUsedLogMB > Target.PeakUsedLogMB 
                    THEN @CurrentTime 
                    ELSE Target.PeakTime 
                END,
                LastChecked = @CurrentTime
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (DatabaseName, PeakUsedLogMB, PeakTotalLogSizeMB, PeakTime, LastChecked)
            VALUES (Source.DatabaseName, Source.CurrentUsedLogMB, Source.CurrentTotalLogSizeMB, @CurrentTime, @CurrentTime);
    END TRY
    BEGIN CATCH
        INSERT INTO dbo.LogOptimizationAudit (BatchNumber, DatabaseName, Action, Status, ExecutionTime, ErrorMessage)
        VALUES (0, 'N/A', 'UpdateLogPeakUsage', 'Failed', GETDATE(), ERROR_MESSAGE());
    END CATCH
END
GO

IF OBJECT_ID('dbo.usp_OptimizeTransactionLog', 'P') IS NOT NULL
DROP PROCEDURE dbo.usp_OptimizeTransactionLog;
GO

CREATE PROCEDURE dbo.usp_OptimizeTransactionLog
    @DatabaseName NVARCHAR(MAX) = NULL, -- Lọc DB, cách nhau bằng dấu phẩy
    @BackupPath NVARCHAR(500) = N'NUL', -- Đường dẫn backup
    @BufferMultiplier DECIMAL(5,2) = 1.25, -- Hệ số buffer
    @VLFThreshold INT = 300, -- Ngưỡng VLF
    @MinLogSizeMB INT = 1024, -- Kích thước log tối thiểu
    @MinLogSizeFilterMB INT = 0, -- Lọc DB theo kích thước log
    @Verbose BIT = 1, -- 1: Hiển thị chi tiết
    @DryRun BIT = 1 -- 1: Chỉ sinh script, 0: Thực thi
AS
BEGIN
    SET NOCOUNT ON;

    -- Bảng tạm lưu kết quả
    DECLARE @LogFiles TABLE (
        DatabaseName SYSNAME PRIMARY KEY,
        LogicalName SYSNAME,
        FileId INT,
        CurrentSizeMB DECIMAL(18,2),
        CurrentUsedMB DECIMAL(18,2),
        PeakUsedLogMB DECIMAL(18,2),
        LargeTransactionMB DECIMAL(18,2),
        DataFileSizeMB DECIMAL(18,2),
        LogToDataRatio DECIMAL(5,2),
        TargetMB INT,
        VLFCount INT,
        LogFileCount INT,
        VLFWarning NVARCHAR(MAX),
        DiskFreeMB DECIMAL(18,2),
        IsInAG BIT,
        RecoveryModel SYSNAME,
        LogReuseWait SYSNAME,
        SQL_BackupLog NVARCHAR(MAX),
        SQL_ShrinkFile NVARCHAR(MAX),
        SQL_ModifyFile NVARCHAR(MAX)
    );

    -- Bảng tạm cho DBCC SQLPERF và DBCC LOGINFO
    CREATE TABLE #LogSpace (
        DBName SYSNAME PRIMARY KEY,
        LogSizeMB DECIMAL(18,2),
        LogUsedPct DECIMAL(5,2),
        Status INT
    );

    CREATE TABLE #VLF_Temp (
        FileId INT,
        FileSize BIGINT,
        StartOffset BIGINT,
        FSeqNo INT,
        Status INT,
        Parity INT,
        CreateLSN NUMERIC(25,0)
    );

    BEGIN TRY
        -- BƯỚC 1: Kiểm tra điều kiện đầu vào
        IF @BackupPath <> N'NUL'
        BEGIN
            DECLARE @PathExists BIT;
            DECLARE @CheckPath TABLE (FileExists BIT, DirectoryExists BIT, ParentDirectoryExists BIT);
            INSERT INTO @CheckPath EXEC master.dbo.xp_fileexist @BackupPath;
            SELECT @PathExists = FileExists FROM @CheckPath;
            IF @PathExists = 0
            BEGIN
                RAISERROR ('Đường dẫn backup %s không tồn tại.', 16, 1, @BackupPath);
                RETURN;
            END
        END

        -- Kiểm tra vai trò Availability Group
        IF EXISTS (SELECT 1 FROM sys.dm_hadr_availability_replica_states WHERE is_local = 1 AND role_desc <> 'PRIMARY')
        BEGIN
            PRINT 'This is a secondary replica in an Availability Group. Script generation is skipped.';
            RETURN;
        END

        -- BƯỚC 2: Thu thập thông tin Log Space
        INSERT INTO #LogSpace
        EXEC('DBCC SQLPERF(LOGSPACE) WITH NO_INFOMSGS');

        -- BƯỚC 3: Thu thập thông tin file log và dữ liệu
        INSERT INTO @LogFiles (
            DatabaseName, LogicalName, FileId, CurrentSizeMB, CurrentUsedMB, PeakUsedLogMB,
            LargeTransactionMB, DataFileSizeMB, LogFileCount, DiskFreeMB, IsInAG, RecoveryModel, LogReuseWait
        )
        SELECT
            d.name,
            mf.name,
            mf.file_id,
            mf.size / 128.0 AS CurrentSizeMB,
            ls.LogSizeMB * (ls.LogUsedPct / 100.0) AS CurrentUsedMB,
            p.PeakUsedLogMB,
            COALESCE((
                SELECT MAX(au.total_pages / 128.0) * 2
                FROM sys.partitions p
                JOIN sys.allocation_units au ON p.hobt_id = au.container_id
                WHERE p.object_id IN (SELECT t.object_id FROM sys.tables t WHERE t.is_ms_shipped = 0)
                AND p.index_id IN (0, 1)
                AND p.object_id IN (SELECT object_id FROM sys.tables WHERE schema_name(schema_id) + '.' + name IN
                    (SELECT table_name FROM information_schema.tables WHERE table_catalog = d.name))
            ), dfs.DataFileSizeMB * 0.1) AS LargeTransactionMB,
            dfs.DataFileSizeMB,
            dfs.LogFileCount,
            vs.available_bytes / 1048576.0 AS DiskFreeMB,
            CASE WHEN d.group_database_id IS NOT NULL THEN 1 ELSE 0 END AS IsInAG,
            d.recovery_model_desc,
            d.log_reuse_wait_desc
        FROM sys.databases d
        JOIN sys.master_files mf ON d.database_id = mf.database_id
        JOIN #LogSpace ls ON d.name = ls.DBName
        LEFT JOIN dbo.LogPeakUsageHistory p ON d.name = p.DatabaseName
        JOIN (
            SELECT db.name,
                   SUM(CASE WHEN mf_inner.type_desc = 'ROWS' THEN mf_inner.size / 128.0 ELSE 0 END) AS DataFileSizeMB,
                   SUM(CASE WHEN mf_inner.type_desc = 'LOG' THEN 1 ELSE 0 END) AS LogFileCount
            FROM sys.databases db
            JOIN sys.master_files mf_inner ON db.database_id = mf_inner.database_id
            GROUP BY db.name
        ) dfs ON d.name = dfs.name
        CROSS APPLY sys.dm_os_volume_stats(d.database_id, mf.file_id) vs
        WHERE mf.type_desc = 'LOG'
        AND d.database_id > 4
        AND d.state_desc = 'ONLINE'
        AND ls.LogSizeMB >= @MinLogSizeFilterMB
        AND (@DatabaseName IS NULL OR d.name IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@DatabaseName, ',')))
        AND d.log_reuse_wait_desc IN ('NOTHING', 'CHECKPOINT', 'LOG_BACKUP');

        -- BƯỚC 4: Tính VLF Count
        DECLARE @CurrentDBName SYSNAME, @CurrentFileId INT;
        DECLARE vlf_cursor CURSOR LOCAL FAST_FORWARD FOR
            SELECT DatabaseName, FileId FROM @LogFiles;
        OPEN vlf_cursor;
        FETCH NEXT FROM vlf_cursor INTO @CurrentDBName, @CurrentFileId;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            DECLARE @VLFCount INT = 0;
            IF EXISTS (SELECT 1 FROM sys.all_objects WHERE name = 'dm_db_log_info')
            BEGIN
                SELECT @VLFCount = COUNT(*)
                FROM sys.dm_db_log_info(DB_ID(@CurrentDBName))
                WHERE file_id = @CurrentFileId;
            END
            ELSE
            BEGIN
                TRUNCATE TABLE #VLF_Temp;
                INSERT INTO #VLF_Temp
                EXEC('DBCC LOGINFO (''' + @CurrentDBName + ''') WITH NO_INFOMSGS');
                SELECT @VLFCount = COUNT(*)
                FROM #VLF_Temp
                WHERE FileId = @CurrentFileId;
            END
            UPDATE @LogFiles
            SET VLFCount = @VLFCount
            WHERE DatabaseName = @CurrentDBName AND FileId = @CurrentFileId;
            FETCH NEXT FROM vlf_cursor INTO @CurrentDBName, @CurrentFileId;
        END
        CLOSE vlf_cursor;
        DEALLOCATE vlf_cursor;

        -- BƯỚC 5: Tính toán các chỉ số và sinh câu lệnh SQL
        UPDATE @LogFiles
        SET
            LogToDataRatio = CASE WHEN DataFileSizeMB > 0 THEN CurrentSizeMB / DataFileSizeMB ELSE 0 END,
            TargetMB = (
                SELECT CEILING(MAX(Val))
                FROM (VALUES
                    (COALESCE(PeakUsedLogMB * @BufferMultiplier, 0)),
                    (COALESCE(CurrentUsedMB * 2, 0)),
                    (COALESCE(LargeTransactionMB, 0)),
                    (COALESCE(@MinLogSizeMB, 0))
                ) AS AllValues(Val)
            ),
            VLFWarning = 
                CASE WHEN LogFileCount > 1 THEN '!!! CẢNH BÁO: Database có ' + CAST(LogFileCount AS VARCHAR) + ' file log. Nên giảm xuống 1 file.' + CHAR(13)+CHAR(10) ELSE '' END +
                CASE WHEN VLFCount > @VLFThreshold THEN '!!! CẢNH BÁO: Số VLF hiện tại (' + CAST(VLFCount AS VARCHAR) + ') quá cao. Cần shrink/resize.' + CHAR(13)+CHAR(10) ELSE '' END +
                CASE WHEN VLFCount < 50 AND VLFCount > 0 THEN '!!! CẢNH BÁO: Số VLF hiện tại (' + CAST(VLFCount AS VARCHAR) + ') quá thấp. Cân nhắc tăng size.' + CHAR(13)+CHAR(10) ELSE '' END +
                CASE WHEN LogToDataRatio > 0.5 THEN '!!! CẢNH BÁO: Tỷ lệ log/data (' + FORMAT(LogToDataRatio, 'P1') + ') > 50%.' + CHAR(13)+CHAR(10) ELSE '' END,
            SQL_BackupLog = CASE 
                WHEN RecoveryModel IN ('FULL', 'BULK_LOGGED') AND LogReuseWait NOT IN ('NOTHING', 'CHECKPOINT') 
                THEN 'BACKUP LOG [' + DatabaseName + '] TO DISK = ' + QUOTENAME(@BackupPath, '''') + ';' 
                ELSE '' END,
            SQL_ShrinkFile = CASE 
                WHEN VLFCount > @VLFThreshold OR CurrentSizeMB > (TargetMB * 1.5) OR LogToDataRatio > 0.5 
                THEN 'DBCC SHRINKFILE (N''' + LogicalName + ''', 0, TRUNCATEONLY);' 
                ELSE '' END,
            SQL_ModifyFile = 'ALTER DATABASE [' + DatabaseName + '] MODIFY FILE (NAME = N''' + LogicalName + ''', SIZE = ' + 
                CAST(TargetMB AS VARCHAR) + 'MB, FILEGROWTH = ' +
                CASE WHEN TargetMB >= 16384 THEN '1024MB' WHEN TargetMB >= 4096 THEN '512MB' ELSE '256MB' END + ');';

        -- Điều chỉnh TargetMB để đảm bảo tối thiểu 50 VLF
        UPDATE @LogFiles
        SET
            TargetMB = CEILING(50 * 64.0),
            VLFWarning = VLFWarning + 'Adjusted TargetMB to ' + CAST(CEILING(50 * 64.0) AS VARCHAR) + ' MB to ensure at least 50 VLF.'
        WHERE TargetMB < @MinLogSizeMB AND VLFCount < 50;

        -- BƯỚC 6: In kết quả phân tích
        IF @Verbose = 1
        BEGIN
            DECLARE @FileInfo NVARCHAR(MAX) = '';
            SELECT @FileInfo = @FileInfo +
                '--- Database: ' + QUOTENAME(DatabaseName) + ', File Log: ' + LogicalName + CHAR(13) + CHAR(10) +
                'Is in AG: ' + CASE WHEN IsInAG = 1 THEN 'Yes' ELSE 'No' END + CHAR(13) + CHAR(10) +
                'Recovery Model: ' + RecoveryModel + CHAR(13) + CHAR(10) +
                'Log Reuse Wait: ' + LogReuseWait + CHAR(13) + CHAR(10) +
                'Current Size (MB): ' + CAST(CurrentSizeMB AS VARCHAR(30)) + CHAR(13) + CHAR(10) +
                'Current Used (MB): ' + CAST(CurrentUsedMB AS VARCHAR(30)) + CHAR(13) + CHAR(10) +
                'Peak Used Log (MB): ' + ISNULL(CAST(PeakUsedLogMB AS VARCHAR(30)), 'N/A') + CHAR(13) + CHAR(10) +
                'Large Transaction (MB): ' + CAST(LargeTransactionMB AS VARCHAR(30)) + CHAR(13) + CHAR(10) +
                'Data File Size (MB): ' + CAST(DataFileSizeMB AS VARCHAR(30)) + CHAR(13) + CHAR(10) +
                'Log/Data Ratio: ' + FORMAT(LogToDataRatio, 'P1') + CHAR(13) + CHAR(10) +
                'Log File Count: ' + CAST(LogFileCount AS VARCHAR(30)) + CHAR(13) + CHAR(10) +
                'VLF Count: ' + CAST(VLFCount AS VARCHAR(30)) + CHAR(13) + CHAR(10) +
                'Disk Free (MB): ' + CAST(DiskFreeMB AS VARCHAR(30)) + CHAR(13) + CHAR(10) +
                'Target Size (MB): ' + CAST(TargetMB AS VARCHAR(30)) + CHAR(13) + CHAR(10) +
                ISNULL(VLFWarning + CHAR(13) + CHAR(10), '') +
                CHAR(13) + CHAR(10)
            FROM @LogFiles;
            PRINT '================================================================================';
            PRINT ' PHÂN TÍCH VÀ TỐI ƯU TRANSACTION LOG';
            PRINT '================================================================================';
            PRINT @FileInfo;
        END

        -- BƯỚC 7: In các hành động đề xuất
        PRINT '--- HÀNH ĐỘNG ĐỀ XUẤT ---';
        IF EXISTS (SELECT 1 FROM @LogFiles WHERE SQL_BackupLog <> '')
        BEGIN
            PRINT '-- Bước 1: Sao lưu log để giải phóng không gian (chạy trên primary replica nếu cần).';
            SELECT DISTINCT SQL_BackupLog FROM @LogFiles WHERE SQL_BackupLog <> '';
        END
        IF EXISTS (SELECT 1 FROM @LogFiles WHERE SQL_ShrinkFile <> '')
        BEGIN
            PRINT '-- Bước 2: Shrink log để giải phóng không gian không sử dụng.';
            SELECT SQL_ShrinkFile FROM @LogFiles WHERE SQL_ShrinkFile <> '';
        END
        PRINT '-- Bước 3: Đặt lại kích thước và mức tăng trưởng cho các file log.';
        SELECT SQL_ModifyFile FROM @LogFiles;

        -- BƯỚC 8: Thực thi nếu DryRun = 0
        IF @DryRun = 0
        BEGIN
            DECLARE @SQL NVARCHAR(MAX), @DBNameExec SYSNAME, @Action NVARCHAR(100);
            DECLARE script_cursor CURSOR LOCAL FAST_FORWARD FOR
                SELECT
                    DatabaseName,
                    CASE
                        WHEN SQL_BackupLog <> '' THEN 'BackupLog'
                        WHEN SQL_ShrinkFile <> '' THEN 'ShrinkFile'
                        ELSE 'ModifyFile'
                    END AS Action,
                    SQL_BackupLog + CHAR(13) + CHAR(10) + SQL_ShrinkFile + CHAR(13) + CHAR(10) + SQL_ModifyFile
                FROM @LogFiles
                WHERE SQL_BackupLog <> '' OR SQL_ShrinkFile <> '' OR SQL_ModifyFile <> '';
            OPEN script_cursor;
            FETCH NEXT FROM script_cursor INTO @DBNameExec, @Action, @SQL;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                BEGIN TRY
                    EXEC sp_executesql @SQL;
                    INSERT INTO dbo.LogOptimizationAudit (BatchNumber, DatabaseName, Action, SQLCommand, Status, ExecutionTime)
                    VALUES (0, @DBNameExec, @Action, @SQL, 'Completed', GETDATE());
                END TRY
                BEGIN CATCH
                    INSERT INTO dbo.LogOptimizationAudit (BatchNumber, DatabaseName, Action, SQLCommand, Status, ExecutionTime, ErrorMessage)
                    VALUES (0, @DBNameExec, @Action, @SQL, 'Failed', GETDATE(), 
                           'Error: ' + ERROR_MESSAGE() + ' (Line: ' + CAST(ERROR_LINE() AS VARCHAR) + ')');
                END CATCH
                FETCH NEXT FROM script_cursor INTO @DBNameExec, @Action, @SQL;
            END
            CLOSE script_cursor;
            DEALLOCATE script_cursor;
        END
    END TRY
    BEGIN CATCH
        INSERT INTO dbo.LogOptimizationAudit (BatchNumber, DatabaseName, Action, Status, ExecutionTime, ErrorMessage)
        VALUES (0, 'N/A', 'OptimizeTransactionLog', 'Failed', GETDATE(), 
               'Error: ' + ERROR_MESSAGE() + ' (Line: ' + CAST(ERROR_LINE() AS VARCHAR) + ')');
    END CATCH

    -- BƯỚC 9: Dọn dẹp bảng tạm
    IF OBJECT_ID('tempdb..#LogSpace') IS NOT NULL DROP TABLE #LogSpace;
    IF OBJECT_ID('tempdb..#VLF_Temp') IS NOT NULL DROP TABLE #VLF_Temp;
END
GO


IF OBJECT_ID('dbo.usp_ProcessLogOptimizationInBatches', 'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_ProcessLogOptimizationInBatches;
GO

CREATE PROCEDURE dbo.usp_ProcessLogOptimizationInBatches
    @BatchSize INT = 20, -- Số DB mỗi batch
    @BackupPath NVARCHAR(500) = N'NUL', -- Đường dẫn backup
    @BufferMultiplier DECIMAL(5,2) = 1.25, -- Hệ số buffer
    @VLFThreshold INT = 300, -- Ngưỡng VLF
    @MinLogSizeMB INT = 1024, -- Kích thước log tối thiểu
    @MinLogSizeFilterMB INT = 1000, -- Lọc DB theo kích thước log
    @MaxBatchesPerRun INT = 10, -- Số batch tối đa mỗi lần chạy
    @Verbose BIT = 0, -- 0 để giảm đầu ra
    @DryRun BIT = 1, -- 1: Chỉ sinh script, 0: Thực thi
    @DelaySeconds INT = 10, -- Độ trễ giữa các batch
    @MailProfile NVARCHAR(128) = NULL, -- Tên profile email
    @MailRecipients NVARCHAR(MAX) = NULL -- Danh sách email nhận thông báo
AS
BEGIN
    SET NOCOUNT ON;

    -- Bảng tạm cho DBCC SQLPERF
    CREATE TABLE #LogSpace (
        DBName SYSNAME PRIMARY KEY,
        LogSizeMB DECIMAL(18,2),
        LogUsedPct DECIMAL(5,2),
        Status INT
    );

    BEGIN TRY
        -- BƯỚC 1: Kiểm tra điều kiện đầu vào
        IF @BatchSize <= 0
        BEGIN
            RAISERROR ('@BatchSize phải lớn hơn 0.', 16, 1);
            RETURN;
        END
        IF @BackupPath <> N'NUL'
        BEGIN
            DECLARE @PathExists BIT;
            DECLARE @CheckPath TABLE (FileExists BIT, DirectoryExists BIT, ParentDirectoryExists BIT);
            INSERT INTO @CheckPath EXEC master.dbo.xp_fileexist @BackupPath;
            SELECT @PathExists = FileExists FROM @CheckPath;
            IF @PathExists = 0
            BEGIN
                RAISERROR ('Đường dẫn backup %s không tồn tại.', 16, 1, @BackupPath);
                RETURN;
            END
        END
        IF (@MailProfile IS NOT NULL OR @MailRecipients IS NOT NULL) AND NOT EXISTS (SELECT 1 FROM msdb.dbo.sysmail_profile WHERE name = @MailProfile)
        BEGIN
            RAISERROR ('Mail profile %s không tồn tại.', 16, 1, @MailProfile);
            RETURN;
        END

        -- BƯỚC 2: Thu thập thông tin Log Space
        INSERT INTO #LogSpace
        EXEC('DBCC SQLPERF(LOGSPACE) WITH NO_INFOMSGS');

        -- BƯỚC 3: Xóa bảng trạng thái cũ
        TRUNCATE TABLE dbo.DatabaseBatchProcessing;

        -- BƯỚC 4: Tạo danh sách cơ sở dữ liệu và gán batch
        INSERT INTO dbo.DatabaseBatchProcessing (DatabaseName, BatchNumber)
        SELECT
            d.name,
            (ROW_NUMBER() OVER (ORDER BY ls.LogSizeMB DESC) - 1) / @BatchSize + 1 AS BatchNumber
        FROM sys.databases d
        JOIN #LogSpace ls ON d.name = ls.DBName
        WHERE d.database_id > 4
        AND d.state_desc = 'ONLINE'
        AND ls.LogSizeMB >= @MinLogSizeFilterMB
        AND d.log_reuse_wait_desc IN ('NOTHING', 'CHECKPOINT', 'LOG_BACKUP');

        -- Ghi log các DB bị bỏ qua do log_reuse_wait
        INSERT INTO dbo.LogOptimizationAudit (BatchNumber, DatabaseName, Action, Status, ExecutionTime, ErrorMessage)
        SELECT
            0,
            d.name,
            'SkipDatabase',
            'Skipped',
            GETDATE(),
            'Skipped due to log_reuse_wait_desc = ' + d.log_reuse_wait_desc
        FROM sys.databases d
        WHERE d.database_id > 4
        AND d.state_desc = 'ONLINE'
        AND d.log_reuse_wait_desc NOT IN ('NOTHING', 'CHECKPOINT', 'LOG_BACKUP');

        -- BƯỚC 5: Xử lý từng batch
        DECLARE @BatchNumber INT = 1;
        DECLARE @MaxBatch INT;
        SELECT @MaxBatch = CASE 
            WHEN MAX(BatchNumber) > @MaxBatchesPerRun THEN @MaxBatchesPerRun 
            ELSE MAX(BatchNumber) 
        END FROM dbo.DatabaseBatchProcessing;

        WHILE @BatchNumber <= @MaxBatch
        BEGIN
            DECLARE @DatabaseList NVARCHAR(MAX);
            SELECT @DatabaseList = STRING_AGG(QUOTENAME(DatabaseName), ',')
            FROM dbo.DatabaseBatchProcessing
            WHERE BatchNumber = @BatchNumber AND Status = 'Pending';

            IF @DatabaseList IS NOT NULL
            BEGIN
                -- Cập nhật trạng thái thành Processing
                UPDATE dbo.DatabaseBatchProcessing
                SET Status = 'Processing', LastProcessed = GETDATE()
                WHERE BatchNumber = @BatchNumber AND Status = 'Pending';

                -- Ghi log bắt đầu batch
                INSERT INTO dbo.LogOptimizationAudit (BatchNumber, DatabaseName, Action, Status, ExecutionTime)
                VALUES (@BatchNumber, @DatabaseList, 'StartBatch', 'Started', GETDATE());

                -- Gọi usp_OptimizeTransactionLog
                BEGIN TRY
                    EXEC dbo.usp_OptimizeTransactionLog
                        @DatabaseName = @DatabaseList,
                        @BackupPath = @BackupPath,
                        @BufferMultiplier = @BufferMultiplier,
                        @VLFThreshold = @VLFThreshold,
                        @MinLogSizeMB = @MinLogSizeMB,
                        @MinLogSizeFilterMB = @MinLogSizeFilterMB,
                        @Verbose = @Verbose,
                        @DryRun = @DryRun;

                    -- Cập nhật trạng thái thành Completed
                    UPDATE dbo.DatabaseBatchProcessing
                    SET Status = 'Completed', LastProcessed = GETDATE(), ErrorMessage = NULL
                    WHERE BatchNumber = @BatchNumber AND Status = 'Processing';

                    INSERT INTO dbo.LogOptimizationAudit (BatchNumber, DatabaseName, Action, Status, ExecutionTime)
                    VALUES (@BatchNumber, @DatabaseList, 'CompleteBatch', 'Completed', GETDATE());
                END TRY
                BEGIN CATCH
                    -- Ghi lỗi và cập nhật trạng thái thành Failed
                    DECLARE @ErrorMessage NVARCHAR(MAX) = 'Error: ' + ERROR_MESSAGE() + ' (Line: ' + CAST(ERROR_LINE() AS VARCHAR) + ')';
                    UPDATE dbo.DatabaseBatchProcessing
                    SET Status = 'Failed', LastProcessed = GETDATE(), ErrorMessage = @ErrorMessage
                    WHERE BatchNumber = @BatchNumber AND Status = 'Processing';

                    INSERT INTO dbo.LogOptimizationAudit (BatchNumber, DatabaseName, Action, Status, ExecutionTime, ErrorMessage)
                    VALUES (@BatchNumber, @DatabaseList, 'CompleteBatch', 'Failed', GETDATE(), @ErrorMessage);
                END CATCH

                -- Gửi email thông báo
                IF @MailProfile IS NOT NULL AND @MailRecipients IS NOT NULL
                BEGIN
                    DECLARE @MailBody NVARCHAR(MAX) =
                        'Batch ' + CAST(@BatchNumber AS VARCHAR) + ' completed.' + CHAR(13) + CHAR(10) +
                        'Databases: ' + @DatabaseList + CHAR(13) + CHAR(10) +
                        'Status: ' + (SELECT TOP 1 Status FROM dbo.DatabaseBatchProcessing WHERE BatchNumber = @BatchNumber) + CHAR(13) + CHAR(10) +
                        'Errors: ' + ISNULL((SELECT TOP 1 ErrorMessage FROM dbo.DatabaseBatchProcessing WHERE BatchNumber = @BatchNumber AND ErrorMessage IS NOT NULL), 'None');
                    EXEC msdb.dbo.sp_send_dbmail
                        @profile_name = @MailProfile,
                        @recipients = @MailRecipients,
                        @subject = 'Log Optimization Batch Report',
                        @body = @MailBody;
                END

                -- Độ trễ giữa các batch
                IF @DelaySeconds > 0
                BEGIN
                    DECLARE @DelayTime NVARCHAR(8) = '00:00:' + RIGHT('0' + CAST(@DelaySeconds AS VARCHAR(2)), 2);
                    WAITFOR DELAY @DelayTime;
                END
            END
            SET @BatchNumber = @BatchNumber + 1;
        END

        -- BƯỚC 6: In báo cáo trạng thái
        BEGIN
            IF @Verbose = 1
            BEGIN
                PRINT '================================================================================';
                PRINT ' BÁO CÁO XỬ LÝ BATCH';
                PRINT '================================================================================';
                SELECT
                    BatchNumber,
                    COUNT(*) AS TotalDatabases,
                    SUM(CASE WHEN Status = 'Completed' THEN 1 ELSE 0 END) AS Completed,
                    SUM(CASE WHEN Status = 'Failed' THEN 1 ELSE 0 END) AS Failed,
                    STRING_AGG(CASE WHEN Status = 'Failed' THEN DatabaseName + ': ' + ErrorMessage ELSE NULL END, CHAR(13) + CHAR(10)) AS ErrorDetails
                FROM dbo.DatabaseBatchProcessing
                GROUP BY BatchNumber
                ORDER BY BatchNumber;
            END
        END

        -- BƯỚC 7: Gửi email báo cáo cuối cùng
        IF @MailProfile IS NOT NULL AND @MailRecipients IS NOT NULL
        BEGIN
            DECLARE @FinalReport NVARCHAR(MAX) =
                'Log Optimization Completed.' + CHAR(13) + CHAR(10) +
                'Total Batches: ' + CAST(@MaxBatch AS VARCHAR) + CHAR(13) + CHAR(10) +
                'Total Databases: ' + CAST((SELECT COUNT(*) FROM dbo.DatabaseBatchProcessing) AS VARCHAR) + CHAR(13) + CHAR(10) +
                'Completed: ' + CAST((SELECT COUNT(*) FROM dbo.DatabaseBatchProcessing WHERE Status = 'Completed') AS VARCHAR) + CHAR(13) + CHAR(10) +
                'Failed: ' + CAST((SELECT COUNT(*) FROM dbo.DatabaseBatchProcessing WHERE Status = 'Failed') AS VARCHAR) + CHAR(13) + CHAR(10) +
                'Errors: ' + ISNULL((SELECT STRING_AGG(DatabaseName + ': ' + ErrorMessage, CHAR(13) + CHAR(10)) FROM dbo.DatabaseBatchProcessing WHERE Status = 'Failed'), 'None');
            EXEC msdb.dbo.sp_send_dbmail
                @profile_name = @MailProfile,
                @recipients = @MailRecipients,
                @subject = 'Log Optimization Final Report',
                @body = @FinalReport;
        END
    END TRY
    BEGIN CATCH
        -- Ghi lỗi vào bảng audit
        DECLARE @GlobalError NVARCHAR(MAX) = 'Error: ' + ERROR_MESSAGE() + ' (Line: ' + CAST(ERROR_LINE() AS VARCHAR) + ')';
        INSERT INTO dbo.LogOptimizationAudit (BatchNumber, DatabaseName, Action, Status, ExecutionTime, ErrorMessage)
        VALUES (0, 'N/A', 'ProcessLogOptimizationInBatches', 'Failed', GETDATE(), @GlobalError);
    END CATCH

    -- BƯỚC 8: Dọn dẹp bảng tạm
    IF OBJECT_ID('tempdb..#LogSpace') IS NOT NULL
        DROP TABLE #LogSpace;
END
GO

```

#### Cách triển khai

1. Tạo cơ sở dữ liệu DbaMonitor

```bash
IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = 'DbaMonitor')
BEGIN
    CREATE DATABASE DbaMonitor;
    ALTER DATABASE DbaMonitor SET RECOVERY SIMPLE;
END
GO
```

2. Tạo các bảng và stored procedure: Chạy script trong và đảm bảo DbaMonitor có đủ không gian đĩa và được sao lưu định kỳ.

3. Cấu hình email (nếu cần)

```bash
EXEC msdb.dbo.sp_configure 'show advanced options', 1;
RECONFIGURE;
EXEC msdb.dbo.sp_configure 'Database Mail XPs', 1;
RECONFIGURE;
```

4. Chạy xử lý batch

- Gọi usp_ProcessLogOptimizationInBatches:

```bash
USE DBA_Tools;
EXEC dbo.usp_ProcessLogOptimizationInBatches
    @BatchSize = 20,
    @BackupPath = 'C:\Backup',
    @MinLogSizeFilterMB = 1000, -- Chỉ xử lý DB có log ≥ 1 GB
    @MaxBatchesPerRun = 10,
    @Verbose = 0,
    @DryRun = 1,
    @DelaySeconds = 10,
    @MailProfile = 'YourMailProfile',
    @MailRecipients = 'admin@yourcompany.com';
```

- Để thực thi trực tiếp: @DryRun = 0.

5. Tích hợp với SQL Agent Job

- Tạo job để chạy định kỳ:

```bash
USE msdb;
EXEC sp_add_job @job_name = 'LogOptimizationJob';
EXEC sp_add_jobstep @job_name = 'LogOptimizationJob', @step_name = 'RunBatchOptimization',
    @subsystem = 'TSQL',
    @command = 'USE DBA_Tools; EXEC dbo.usp_ProcessLogOptimizationInBatches @BatchSize=20, @MinLogSizeFilterMB=1000, @MaxBatchesPerRun=10, @Verbose=0, @DryRun=0, @MailProfile=''YourMailProfile'', @MailRecipients=''admin@yourcompany.com'';',
    @database_name = 'DBA_Tools';
EXEC sp_add_jobschedule @job_name = 'LogOptimizationJob', @name = 'DailySchedule',
    @freq_type = 4, -- Hàng ngày
    @freq_interval = 1,
    @active_start_time = 10000; -- 1:00 AM
EXEC sp_add_jobserver @job_name = 'LogOptimizationJob';
```

6. Kiểm tra trạng thái và audit

- Kiểm tra trạng thái batch:

```bash
USE DBA_Tools;
SELECT * FROM dbo.DatabaseBatchProcessing ORDER BY BatchNumber, DatabaseName;
```
- Kiểm tra lịch sử audit:

```bash
SELECT * FROM dbo.LogOptimizationAudit ORDER BY ExecutionTime DESC;
```

- Kiểm tra VLF:

```bash
SELECT DB_NAME(database_id) AS DatabaseName, file_id, COUNT(*) AS VLFCount
FROM sys.dm_db_log_info(DB_ID())
GROUP BY database_id, file_id;
```

7. Tích hợp giám sát

- Zabbix/Nagios:

    - Tạo query để kiểm tra lỗi:

    ```bash
    USE DBA_Tools;
    SELECT COUNT(*) AS FailedCount FROM dbo.  WHERE Status = 'Failed' AND ExecutionTime > DATEADD(HOUR, -24, GETDATE());
    ```

    - Xuất sang CSV hoặc API bằng SSIS nếu cần.

- Email: Đảm bảo @MailProfile và @MailRecipients được cấu hình.
