### 1.1 Create a LogPeakUsageHistory table

```bash
CREATE TABLE dbo.LogPeakUsageHistory (
    DatabaseName sysname PRIMARY KEY,
    PeakUsedLogMB DECIMAL(18, 2) NOT NULL,
    PeakTotalLogSizeMB DECIMAL(18, 2) NOT NULL,
    PeakTime DATETIME2(0) NOT NULL,
    LastChecked DATETIME2(0) NOT NULL
);
GO
CREATE INDEX IX_LogPeakUsageHistory_LastChecked ON dbo.LogPeakUsageHistory (LastChecked);
GO
```

### 1.2 Create store procedure to add new or update when a new peak is observed records into the table above

- Tạo 1 job chạy usp_UpdateLogPeakUsage với khoảng 30 phút 1 lần.

- Tăng tần suất (ví dụ: 10-15 phút/lần):

Hệ thống có tải đột biến cao và ngắn: Nếu bạn có các tác vụ cực lớn (như rebuild index toàn bộ, import dữ liệu lớn) chạy trong thời gian ngắn hơn 30 phút và không theo lịch cố định. Việc chạy job thường xuyên hơn sẽ chắc chắn bắt được các "peak" này.

Cơ sở dữ liệu cực kỳ quan trọng: Đối với các hệ thống OLTP (Online Transaction Processing) quan trọng hàng đầu, việc theo dõi sát sao hơn giúp phát hiện các vấn đề bất thường nhanh hơn.

- Giảm tần suất (ví dụ: 1-2 giờ/lần):

Hệ thống ổn định, tải thấp: Nếu cơ sở dữ liệu của bạn có mô hình sử dụng rất dễ đoán, không có nhiều biến động lớn (ví dụ: một trang web nội bộ ít người dùng, một kho dữ liệu chỉ cập nhật vào ban đêm).

Tối ưu hóa tài nguyên tuyệt đối: Trên các máy chủ có tài nguyên rất hạn chế, việc giảm tần suất sẽ giảm thiểu mọi tác động, dù là nhỏ nhất.

- Hãy để Job này chạy ít nhất 1-2 tuần, hoặc qua một chu kỳ kinh doanh đầy đủ (ví dụ: một kỳ báo cáo cuối tháng). Điều này đảm bảo bảng LogPeakUsageHistory có đủ dữ liệu đáng tin cậy về các đỉnh sử dụng thực tế. 

```bash
IF OBJECT_ID('dbo.usp_UpdateLogPeakUsage', 'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_UpdateLogPeakUsage;
GO

CREATE PROCEDURE dbo.usp_UpdateLogPeakUsage
AS
BEGIN
    SET NOCOUNT ON;

    -- Check if primary in AG (skip if not)
    IF EXISTS (SELECT 1 FROM sys.dm_hadr_availability_replica_states WHERE is_local = 1 AND role_desc <> 'PRIMARY')
        RETURN;

    DECLARE @CurrentTime DATETIME2(0) = GETDATE();

    -- Use sys.dm_db_log_stats for more accurate peak usage tracking between log backups
    MERGE INTO dbo.LogPeakUsageHistory AS Target
    USING (
        SELECT
            d.name AS DatabaseName,
            ls.log_since_last_backup_mb AS CurrentUsedLogMB, -- More accurate peak metric
            CAST(total_log_size_in_bytes / 1048576.0 AS DECIMAL(18, 2)) AS CurrentTotalLogSizeMB
        FROM sys.databases d
        CROSS APPLY sys.dm_db_log_stats(d.database_id) ls
        WHERE 
            d.database_id > 4
            AND d.state_desc = 'ONLINE'
            AND d.recovery_model_desc <> 'SIMPLE' -- log_since_last_backup_mb is only relevant for FULL/BULK_LOGGED
            AND total_log_size_in_bytes > 0
    ) AS Source
    ON Target.DatabaseName = Source.DatabaseName

    -- Update when a new peak is observed
    WHEN MATCHED AND Source.CurrentUsedLogMB > Target.PeakUsedLogMB THEN
        UPDATE SET
            Target.PeakUsedLogMB = Source.CurrentUsedLogMB,
            Target.PeakTotalLogSizeMB = Source.CurrentTotalLogSizeMB,
            Target.PeakTime = @CurrentTime,
            Target.LastChecked = @CurrentTime

    -- Update LastChecked time even if no new peak
    WHEN MATCHED THEN
        UPDATE SET
            Target.LastChecked = @CurrentTime

    WHEN NOT MATCHED BY TARGET THEN
        INSERT (DatabaseName, PeakUsedLogMB, PeakTotalLogSizeMB, PeakTime, LastChecked)
        VALUES (Source.DatabaseName, Source.CurrentUsedLogMB, Source.CurrentTotalLogSizeMB, @CurrentTime, @CurrentTime);
END
GO
```

### 2. Suggest shrink and set FileGrowth appropriately after shrink 


```bash
IF OBJECT_ID('dbo.usp_GenerateLogResizeScript', 'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_GenerateLogResizeScript;
GO

CREATE PROCEDURE dbo.usp_GenerateLogResizeScript(
    @DatabaseName NVARCHAR(MAX) = NULL,      -- >> Lọc cho các DB cụ thể, cách nhau bằng dấu phẩy
    @BackupPath NVARCHAR(500) = N'NUL',   -- >> Tùy chỉnh đường dẫn backup, mặc định là NUL
    @BufferMultiplier DECIMAL(5,2) = 1.25,
    @VLFThreshold INT = 500,
    @ShrinkTargetMB INT = 1,
    @DryRun BIT = 1
)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        IF EXISTS (SELECT 1 FROM sys.dm_hadr_availability_replica_states WHERE is_local = 1 AND role_desc <> 'PRIMARY')
        BEGIN
            PRINT 'This is a secondary replica in an Availability Group. Script generation is skipped.';
            RETURN;
        END

        ;WITH LogFileInfo AS (
            SELECT 
                d.name AS DatabaseName, d.recovery_model_desc, mf.name AS LogicalFileName,
                mf.size * 8.0 / 1024 AS CurrentSizeMB, vlf.total_vlf_count AS CurrentVLFCount
            FROM sys.databases d
            JOIN sys.master_files mf ON d.database_id = mf.database_id
            CROSS APPLY (SELECT COUNT(li.database_id) AS total_vlf_count FROM sys.dm_db_log_info(d.database_id) li) AS vlf
            WHERE mf.type_desc = 'LOG' AND d.database_id > 4 AND d.state_desc = 'ONLINE'
            AND (@DatabaseName IS NULL OR d.name IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@DatabaseName, ',')))
        ),
        PeakHistory AS (
            SELECT DatabaseName, PeakUsedLogMB FROM dbo.LogPeakUsageHistory
        ),
        DataFileSize AS (
            SELECT d.name AS DatabaseName, SUM(mf.size * 8.0 / 1024) AS DataFileSizeMB
            FROM sys.master_files mf
            JOIN sys.databases d ON mf.database_id = d.database_id
            WHERE mf.type_desc = 'ROWS' AND d.state_desc = 'ONLINE' GROUP BY d.name
        ),
        Recommendations AS (
            SELECT 
                l.DatabaseName, l.recovery_model_desc, l.LogicalFileName, l.CurrentSizeMB, l.CurrentVLFCount,
                COALESCE(p.PeakUsedLogMB, ds.DataFileSizeMB * 0.25, 1024) AS BaseSizeForCalcMB,
                CASE WHEN p.PeakUsedLogMB IS NOT NULL THEN 'Peak History' ELSE 'Fallback: 25% of Data Size' END AS SizingSource,
                CASE 
                    WHEN (CEILING(COALESCE(p.PeakUsedLogMB, ds.DataFileSizeMB * 0.25, 1024) * @BufferMultiplier / 512.0) * 512) < 1024 
                    THEN 1024
                    ELSE (CEILING(COALESCE(p.PeakUsedLogMB, ds.DataFileSizeMB * 0.25, 1024) * @BufferMultiplier / 512.0) * 512)
                END AS RecommendedSizeMB,
                CEILING((CEILING(COALESCE(p.PeakUsedLogMB, ds.DataFileSizeMB * 0.25, 1024) * @BufferMultiplier / 512.0) * 512) / 8192) * 16 AS EstimatedVLFCountAfterResize -- More precise VLF calc
        )
        SELECT 
            r.DatabaseName, r.CurrentSizeMB, r.RecommendedSizeMB, r.CurrentVLFCount, r.SizingSource,
            CASE WHEN r.CurrentVLFCount > @VLFThreshold THEN 'High VLF Count' WHEN r.RecommendedSizeMB > r.CurrentSizeMB THEN 'Proactive Resize' ELSE 'OK' END AS RecommendationReason,
            CASE
                WHEN r.CurrentVLFCount > @VLFThreshold THEN
                '/*
                --------------------------------------------------------------------------------
                Database                 : ' + QUOTENAME(r.DatabaseName) + '
                ACTION                   : FULL LOG RESIZE (CHECKPOINT -> BACKUP -> SHRINK -> GROW)
                Reason for action        : High VLF count detected (' + ISNULL(CAST(r.CurrentVLFCount AS VARCHAR(10)),'N/A') + ' > ' + CAST(@VLFThreshold AS VARCHAR(10)) + ').
                --------------------------------------------------------------------------------
                */' + CHAR(13)+CHAR(10) +
                'USE ' + QUOTENAME(r.DatabaseName) + '; GO' + CHAR(13)+CHAR(10) +

                '-- Step 0a: Force a checkpoint to write dirty pages to disk, marking log records as inactive.
                CHECKPOINT; GO' + CHAR(13)+CHAR(10) + CHAR(13)+CHAR(10) +

                (CASE WHEN r.recovery_model_desc <> 'SIMPLE' THEN 
                '-- Step 0b: Backup the log to truncate inactive VLFs. If this fails, check log_reuse_wait_desc.
                BACKUP LOG ' + QUOTENAME(r.DatabaseName) + ' TO DISK = ' + QUOTENAME(@BackupPath, '''') + '; GO' + CHAR(13)+CHAR(10) + CHAR(13)+CHAR(10) ELSE '-- Step 0b: Backup Skipped (SIMPLE recovery model).' + CHAR(13)+CHAR(10) END) +

                '-- Step 1: Clear any remaining inactive VLFs from the end of the file.
                DBCC SHRINKFILE (N''' + r.LogicalFileName + ''', 0, TRUNCATEONLY); GO' + CHAR(13)+CHAR(10) + CHAR(13)+CHAR(10) +

                '-- Step 2: Shrink the file to the target to reset VLF structure.
                -- WARNING: This can be an I/O intensive operation.
                DBCC SHRINKFILE (N''' + r.LogicalFileName + ''' , ' + CAST(@ShrinkTargetMB AS VARCHAR(10)) + '); GO' + CHAR(13)+CHAR(10) + CHAR(13)+CHAR(10) +

                '-- Step 3 & 4: Grow to recommended size and set future autogrowth.
                ALTER DATABASE ' + QUOTENAME(r.DatabaseName) + ' MODIFY FILE ( NAME = N''' + r.LogicalFileName + ''', SIZE = ' + CAST(CAST(r.RecommendedSizeMB AS INT) AS VARCHAR(20)) + 'MB ); GO' + CHAR(13)+CHAR(10) +
                'ALTER DATABASE ' + QUOTENAME(r.DatabaseName) + ' MODIFY FILE ( NAME = N''' + r.LogicalFileName + ''', FILEGROWTH = ' + CASE WHEN r.RecommendedSizeMB >= 16384 THEN '1024MB' WHEN r.RecommendedSizeMB >= 4096 THEN '512MB' ELSE '256MB' END + ' ); GO'

                WHEN r.RecommendedSizeMB > r.CurrentSizeMB THEN
                '/*
                --------------------------------------------------------------------------------
                Database                 : ' + QUOTENAME(r.DatabaseName) + '
                ACTION                   : SIMPLE LOG RESIZE (GROW ONLY)
                Reason for action        : Proactive resize needed. VLF count is healthy (' + ISNULL(CAST(r.CurrentVLFCount AS VARCHAR(10)),'N/A') + ').
                Sizing Source            : ' + r.SizingSource + '
                --------------------------------------------------------------------------------
                */' + CHAR(13)+CHAR(10) +
                'USE ' + QUOTENAME(r.DatabaseName) + '; GO' + CHAR(13)+CHAR(10) +
                'ALTER DATABASE ' + QUOTENAME(r.DatabaseName) + ' MODIFY FILE ( NAME = N''' + r.LogicalFileName + ''', SIZE = ' + CAST(CAST(r.RecommendedSizeMB AS INT) AS VARCHAR(20)) + 'MB ); GO'
            END AS GeneratedScript
        INTO #Result
        FROM Recommendations r
        WHERE r.RecommendedSizeMB > r.CurrentSizeMB OR r.CurrentVLFCount > @VLFThreshold OR r.EstimatedVLFCountAfterResize > 10000; 

        IF @DryRun = 1
        BEGIN
            SELECT * FROM #Result ORDER BY DatabaseName;
        END
        ELSE
        BEGIN
            DECLARE @ScriptToPrint NVARCHAR(MAX);
            DECLARE script_cursor CURSOR FOR SELECT GeneratedScript FROM #Result ORDER BY DatabaseName;
            OPEN script_cursor;
            FETCH NEXT FROM script_cursor INTO @ScriptToPrint;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                PRINT @ScriptToPrint;
                FETCH NEXT FROM script_cursor INTO @ScriptToPrint;
            END
            CLOSE script_cursor;
            DEALLOCATE script_cursor;
        END

        DROP TABLE #Result;

    END TRY
    BEGIN CATCH
        PRINT 'An error occurred while generating the script:';
        PRINT ERROR_MESSAGE();
        RETURN;
    END CATCH
END
GO
```

 
Thực thi stored procedure chính ở chế độ xem trước (mặc định).

```bash
EXEC dbo.usp_GenerateLogResizeScript @DryRun = 1;
```

Xem xét kết quả:

- RecommendationReason: Cột này cho bạn biết tại sao một database được đề xuất thay đổi. "High VLF Count" cần ưu tiên xử lý hơn "Proactive Resize".

- SizingSource: Kiểm tra xem đề xuất dựa trên "Peak History" (tốt) hay "Fallback" (cần xem xét kỹ hơn).

- GeneratedScript: Đọc qua kịch bản được tạo ra. Nó sẽ cho bạn biết chính xác hành động được đề xuất là "FULL LOG RESIZE" (gồm cả shrink) hay chỉ là "SIMPLE LOG RESIZE" (chỉ grow).


Không bao giờ chạy các script thay đổi cấu trúc file trực tiếp trên hệ thống production đang hoạt động vào giờ cao điểm.

Chuẩn bị kịch bản cuối cùng:

Nếu cần lưu log backup vào một đường dẫn cụ thể (để không phá vỡ chuỗi log), hãy chạy lại script với tham số @BackupPath.

```bash
-- Ví dụ chạy cho DB cụ thể và có đường dẫn backup
EXEC dbo.usp_GenerateLogResizeScript 
    @DatabaseName = 'YourDatabaseName', 
    @BackupPath = 'D:\Backup\TempLogBackup.trn', 
    @DryRun = 0;
```

Xem xét thủ công lần cuối: Output từ lệnh trên (@DryRun = 0) sẽ là các kịch bản T-SQL hoàn chỉnh. Hãy copy, dán vào một cửa sổ query mới và đọc lại một lần nữa để chắc chắn mọi thứ đều đúng.

Thực thi: Chạy kịch bản đã được duyệt trong cửa sổ bảo trì đã lên kế hoạch.

Kiểm tra sau khi thực thi:

Chạy lại EXEC dbo.usp_GenerateLogResizeScript @DryRun = 1; để đảm bảo database vừa sửa không còn xuất hiện trong danh sách đề xuất.

Cũng có thể dùng DBCC LOGINFO('YourDatabaseName'); để kiểm tra số lượng VLF đã giảm đáng kể.

Lặp lại quy trình: Lặp lại Bước 2 và 3 theo định kỳ (ví dụ: hàng tháng) để giữ cho hệ thống của luôn ở trạng thái tối ưu.