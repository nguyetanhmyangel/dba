
### 1. Kiểm tra toàn bộ database trong instance có cấu hình autogrowth tồi

```bash
SELECT
    d.name AS DatabaseName,
    mf.name AS LogicalFileName,
    mf.type_desc AS FileType,
    CAST(mf.size * 8.0 / 1024 AS DECIMAL(10,2)) AS InitialSizeMB,
    CASE
        WHEN mf.is_percent_growth = 1 THEN 'Yes'
        ELSE 'No'
    END AS IsPercentGrowth,
    CASE
        WHEN mf.is_percent_growth = 1 THEN CAST(mf.growth AS VARCHAR(10)) + '%'
        ELSE CAST(mf.growth * 8.0 / 1024 AS VARCHAR(20)) + ' MB'
    END AS AutoGrowthValue,
    CASE
        WHEN mf.is_percent_growth = 1 THEN 'BAD PRACTICE: Use a fixed size in MB.'
        WHEN mf.type_desc = 'ROWS' AND mf.growth * 8.0 / 1024 < 64 THEN 'WARNING: Data file growth is too small.'
        WHEN mf.type_desc = 'LOG' AND mf.growth * 8.0 / 1024 < 64 THEN 'WARNING: Log file growth is too small.'
        ELSE 'OK'
    END AS Recommendation
FROM
    sys.master_files AS mf
JOIN
    sys.databases AS d ON mf.database_id = d.database_id
WHERE
    d.database_id > 4 -- Bỏ qua các database hệ thống
ORDER BY
    DatabaseName, FileType;
```

### 2. Kiểm tra và Fix 

- Script sẽ đề xuất và thực thi (set @DryRun = 1 để chay thử, set @DryRun = 0 để thực thi) việc thay đổi giá trị FILEGROWTH sang một giá trị MB cố định, hợp lý dựa trên kích thước hiện tại của file.

```bash
/***************************************************************************************************
 * SCRIPT TỰ ĐỘNG TỐI ƯU HÓA AUTOGROWTH CHO TẤT CẢ DATABASE (PHIÊN BẢN HOÀN CHỈNH)
 *
 * Tác giả: Dựa trên thảo luận và các khuyến nghị tốt nhất (Best Practices)
 * Chức năng:
 * 1. Tự động tìm các file database (data & log) có cấu hình Autogrowth không tốt.
 * 2. Đề xuất giá trị FILEGROWTH mới một cách thông minh dựa trên kích thước file hiện tại.
 * 3. Hỗ trợ chế độ chạy thử (Dry Run) để xem trước các thay đổi một cách an toàn.
 * 4. Thực thi các thay đổi và ghi lại trạng thái (thành công/lỗi).
 * 5. Hiển thị một báo cáo tổng kết dạng bảng duy nhất, dễ đọc.
 ***************************************************************************************************/

SET NOCOUNT ON;

-- =====================================================================================
-- >> PHẦN 1: CẤU HÌNH - Vui lòng chỉnh sửa các thông số dưới đây cho phù hợp <<
-- =====================================================================================

-- Chế độ chạy: 1 = Chạy thử (chỉ in lệnh, không thực thi), 0 = Chạy thật
DECLARE @DryRun BIT = 1;

-- Ngưỡng phát hiện: Bất kỳ file nào có growth theo MB nhỏ hơn giá trị này sẽ được xem xét
DECLARE @MinGrowthMB INT = 128;


-- =====================================================================================
-- >> PHẦN 2: KHỞI TẠO BẢNG TẠM - Không cần chỉnh sửa phần này
-- =====================================================================================

-- Tạo bảng để định nghĩa các mức growth mới "thông minh"
IF OBJECT_ID('tempdb..#GrowthSettings') IS NOT NULL DROP TABLE #GrowthSettings;
CREATE TABLE #GrowthSettings (
    FileType NVARCHAR(60),
    SizeThresholdMB INT,
    NewGrowthMB INT
);

-- Cấu hình cho DATA files (ROWS)
INSERT INTO #GrowthSettings (FileType, SizeThresholdMB, NewGrowthMB) VALUES
('ROWS', 1024, 128),    -- < 1GB -> growth 128MB
('ROWS', 10240, 256),   -- < 10GB -> growth 256MB
('ROWS', 102400, 512),  -- < 100GB -> growth 512MB
('ROWS', 2147483647, 1024); -- > 100GB -> growth 1GB

-- Cấu hình cho LOG file
INSERT INTO #GrowthSettings (FileType, SizeThresholdMB, NewGrowthMB) VALUES
('LOG', 2048, 256),    -- < 2GB -> growth 256MB
('LOG', 20480, 512),   -- < 20GB -> growth 512MB
('LOG', 2147483647, 1024); -- > 20GB -> growth 1GB


-- Tạo bảng để lưu kết quả báo cáo
IF OBJECT_ID('tempdb..#Report') IS NOT NULL DROP TABLE #Report;
CREATE TABLE #Report (
    DatabaseName NVARCHAR(128),
    FileName NVARCHAR(128),
    FileTypeDesc NVARCHAR(60),
    CurrentSizeMB DECIMAL(18, 2),
    CurrentGrowthDesc NVARCHAR(50),
    MaxSizeMB DECIMAL(18, 2) NULL,
    Reason NVARCHAR(500),
    ProposedGrowthMB INT,
    FinalSQLCommand NVARCHAR(MAX),
    Status NVARCHAR(255),
    Notes NVARCHAR(500)
);

PRINT '*** KHOI TAO MOI TRUONG HOAN TAT ***';


-- =====================================================================================
-- >> PHẦN 3: PHÂN TÍCH, THU THẬP DỮ LIỆU VÀ LƯU VÀO BẢNG #Report
-- =====================================================================================
PRINT '*** DANG PHAN TICH VA THU THAP DU LIEU... ***';

DECLARE @DBName NVARCHAR(128), @FileName NVARCHAR(128), @FileTypeDesc NVARCHAR(60);
DECLARE @CurrentSizeMB DECIMAL(18, 2), @IsPercentGrowth BIT, @CurrentGrowthRaw INT;
DECLARE @CurrentGrowthDesc NVARCHAR(50), @NewGrowthMB INT, @Reason NVARCHAR(500);
DECLARE @SQL_Command NVARCHAR(MAX), @MaxSizeMB DECIMAL(18, 2), @Notes NVARCHAR(500);

-- Sử dụng CURSOR để lặp qua từng file cần kiểm tra
DECLARE db_cursor CURSOR FOR
SELECT
    d.name AS DatabaseName, mf.name AS LogicalFileName, mf.type_desc,
    CAST(mf.size * 8.0 / 1024 AS DECIMAL(18, 2)) AS CurrentSizeMB,
    mf.is_percent_growth, mf.growth,
    CASE
        WHEN mf.is_percent_growth = 1 THEN CAST(mf.growth AS VARCHAR(10)) + '%'
        ELSE CAST(mf.growth * 8.0 / 1024 AS VARCHAR(20)) + ' MB'
    END AS CurrentGrowthDesc,
    CASE
        WHEN mf.max_size IN (-1, 0, 268435456) THEN NULL
        ELSE CAST(mf.max_size * 8.0 / 1024 AS DECIMAL(18, 2))
    END AS MaxSizeMB
FROM
    sys.master_files AS mf
JOIN
    sys.databases AS d ON mf.database_id = d.database_id
WHERE
    d.database_id > 4 AND d.state_desc = 'ONLINE' AND d.is_read_only = 0
    AND (
        mf.is_percent_growth = 1 OR mf.growth = 0 OR (mf.is_percent_growth = 0 AND mf.growth * 8.0 / 1024 < @MinGrowthMB)
    )
    ;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DBName, @FileName, @FileTypeDesc, @CurrentSizeMB, @IsPercentGrowth, @CurrentGrowthRaw, @CurrentGrowthDesc, @MaxSizeMB;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @SQL_Command = NULL; SET @Reason = N''; SET @Notes = N'';

    IF @IsPercentGrowth = 1 SET @Reason = N'Autogrowth by Percentage (' + @CurrentGrowthDesc + N').';
    ELSE IF @CurrentGrowthRaw = 0 SET @Reason = N'Autogrowth is disabled.';
    ELSE SET @Reason = N'Autogrowth has too small value (' + @CurrentGrowthDesc + N').';

    SELECT TOP 1 @NewGrowthMB = NewGrowthMB FROM #GrowthSettings WHERE FileType = @FileTypeDesc AND @CurrentSizeMB <= SizeThresholdMB ORDER BY SizeThresholdMB ASC;

    IF @MaxSizeMB IS NOT NULL
    BEGIN
        DECLARE @RemainingSpaceMB DECIMAL(18, 2) = @MaxSizeMB - @CurrentSizeMB;
        IF @RemainingSpaceMB <= 0
        BEGIN
            SET @NewGrowthMB = 0; SET @Notes = N'WARNING: File has reached MAXSIZE. Cannot grow.';
        END
        ELSE IF @NewGrowthMB > @RemainingSpaceMB
        BEGIN
            SET @Notes = N'NOTE: Proposed growth (' + CAST(@NewGrowthMB AS NVARCHAR(10)) + N'MB) > remaining space. Adjusting to ' + CAST(FLOOR(@RemainingSpaceMB) AS NVARCHAR(20)) + N'MB.';
            SET @NewGrowthMB = FLOOR(@RemainingSpaceMB);
        END
    END

    IF @NewGrowthMB > 0
        SET @SQL_Command = N'ALTER DATABASE ' + QUOTENAME(@DBName) + N' MODIFY FILE (NAME = N''' + REPLACE(@FileName, '''', '''''') + ''', FILEGROWTH = ' + CAST(@NewGrowthMB AS NVARCHAR(10)) + N'MB);';
    ELSE
        SET @SQL_Command = N'-- No action taken due to MAXSIZE constraint or other reason --';

    INSERT INTO #Report VALUES (@DBName, @FileName, @FileTypeDesc, @CurrentSizeMB, @CurrentGrowthDesc, @MaxSizeMB, @Reason, ISNULL(@NewGrowthMB,0), @SQL_Command, 'Pending', @Notes);

    FETCH NEXT FROM db_cursor INTO @DBName, @FileName, @FileTypeDesc, @CurrentSizeMB, @IsPercentGrowth, @CurrentGrowthRaw, @CurrentGrowthDesc, @MaxSizeMB;
END;

CLOSE db_cursor;
DEALLOCATE db_cursor;

PRINT '*** PHAN TICH HOAN TAT. DA LUU ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' FILE CAN XEM XET VAO BANG TAM. ***';

-- =====================================================================================
-- >> PHẦN 4: THỰC THI LỆNH VÀ CẬP NHẬT TRẠNG THÁI
-- =====================================================================================
PRINT N'';
PRINT N'==================== EXECUTING COMMANDS ====================';
PRINT N'Execution mode: ' + IIF(@DryRun = 1, 'Dry Run (commands will not be executed)', 'Live Execution');
PRINT N'------------------------------------------------------------';

IF NOT EXISTS (SELECT 1 FROM #Report)
BEGIN
    PRINT N'-> No file found with Autogrowth configuration that needs improvement.';
END
ELSE
BEGIN
    DECLARE report_cursor CURSOR FOR
    SELECT DatabaseName, FileName, FinalSQLCommand, ProposedGrowthMB FROM #Report ORDER BY DatabaseName, FileName;

    OPEN report_cursor;
    FETCH NEXT FROM report_cursor INTO @DBName, @FileName, @SQL_Command, @NewGrowthMB;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        PRINT N'Processing: [' + @DBName + '].[' + @FileName + ']...';

        IF @DryRun = 1
        BEGIN
            UPDATE #Report SET Status = 'DryRun - Not Executed' WHERE DatabaseName = @DBName AND FileName = @FileName;
        END
        ELSE
        BEGIN
            IF @SQL_Command NOT LIKE '-- No action taken%' AND @NewGrowthMB > 0
            BEGIN
                BEGIN TRY
                    EXEC sp_executesql @SQL_Command;
                    UPDATE #Report SET Status = 'Success' WHERE DatabaseName = @DBName AND FileName = @FileName;
                END TRY
                BEGIN CATCH
                    UPDATE #Report SET Status = 'Error: ' + ERROR_MESSAGE() WHERE DatabaseName = @DBName AND FileName = @FileName;
                END CATCH
            END
            ELSE
            BEGIN
                UPDATE #Report SET Status = 'Skipped' WHERE DatabaseName = @DBName AND FileName = @FileName;
            END
        END
        FETCH NEXT FROM report_cursor INTO @DBName, @FileName, @SQL_Command, @NewGrowthMB;
    END

    CLOSE report_cursor;
    DEALLOCATE report_cursor;

    PRINT N'-> Execution process complete. See the final report in the Results tab.';
END

-- =====================================================================================
-- >> PHẦN 5: HIỂN THỊ BÁO CÁO TỔNG HỢP DẠNG BẢNG
-- =====================================================================================
PRINT N'';
PRINT N'==================== FINAL SUMMARY REPORT ====================';

SELECT
    DatabaseName AS [Ten_DB],
    FileName AS [Ten_File_Logic],
    FileTypeDesc AS [Loai_File],
    CurrentSizeMB AS [Kich_Thuoc_Hien_Tai_MB],
    CurrentGrowthDesc AS [Growth_Hien_Tai],
    ISNULL(CAST(MaxSizeMB AS VARCHAR(20)) + ' MB', 'Unlimited') AS [Gioi_Han_MaxSize],
    Reason AS [Ly_Do_Thay_Doi],
    CASE WHEN ProposedGrowthMB > 0 THEN CAST(ProposedGrowthMB AS VARCHAR(10)) + 'MB' ELSE '--' END AS [Growth_De_Xuat],
    Status AS [Trang_Thai_Thuc_Thi],
    ISNULL(NULLIF(Notes, ''), '--') AS [Ghi_Chu_Them]
    --,FinalSQLCommand AS [Lenh_SQL_Da_Chay] -- Bỏ comment dòng này nếu muốn xem cả câu lệnh SQL trong báo cáo
FROM
    #Report
ORDER BY
    DatabaseName, FileName;


-- =====================================================================================
-- >> PHẦN 6: DỌN DẸP
-- =====================================================================================
DROP TABLE #GrowthSettings;
DROP TABLE #Report;

SET NOCOUNT OFF;
PRINT N'*** PROCESS IS COMPLETE ***';
GO
```

### Đoạn script thu gọn để tạo job

```bash
SET NOCOUNT ON;

-- Bảng cấu hình ngưỡng autogrowth mới
CREATE TABLE #GrowthSettings (
    FileType NVARCHAR(60),
    SizeThresholdMB DECIMAL(18, 2),
    NewGrowthMB INT
);

-- Cấu hình cho DATA files (ROWS)
INSERT INTO #GrowthSettings (FileType, SizeThresholdMB, NewGrowthMB) VALUES
    ('ROWS', 1024, 128),
    ('ROWS', 10240, 256),
    ('ROWS', 102400, 512),
    ('ROWS', 2048000, 1024);

-- Cấu hình cho LOG files (LOG)
INSERT INTO #GrowthSettings (FileType, SizeThresholdMB, NewGrowthMB) VALUES
    ('LOG', 2048, 256),
    ('LOG', 20480, 512),
    ('LOG', 2048000, 1024);

-- Khai báo các biến cần thiết
DECLARE @DBName NVARCHAR(128);
DECLARE @FileName NVARCHAR(128);
DECLARE @FileTypeDesc NVARCHAR(60);
DECLARE @CurrentSizeMB DECIMAL(18, 2);
DECLARE @NewGrowthMB INT;
DECLARE @SQL_Command NVARCHAR(MAX);
DECLARE @MaxSizeMB DECIMAL(18, 2);
DECLARE @MinGrowthMB INT = 64;

-- Dùng CURSOR để lặp qua từng file cần thay đổi cấu hình
DECLARE db_cursor CURSOR FOR
SELECT
    d.name AS DatabaseName,
    mf.name AS LogicalFileName,
    mf.type_desc,
    CAST(mf.size * 8.0 / 1024 AS DECIMAL(18, 2)) AS CurrentSizeMB,
    CASE
        WHEN mf.max_size = -1 THEN NULL
        WHEN mf.max_size = 0 THEN NULL
        WHEN mf.max_size = 268435456 THEN NULL
        ELSE CAST(mf.max_size * 8.0 / 1024 AS DECIMAL(18, 2))
    END AS MaxSizeMB
FROM
    sys.master_files AS mf
JOIN
    sys.databases AS d ON mf.database_id = d.database_id
WHERE
    d.database_id > 4         -- Bỏ qua database hệ thống
    AND d.state_desc = 'ONLINE'
    AND d.is_read_only = 0
    AND (
        mf.is_percent_growth = 1
        OR mf.growth = 0
        OR (mf.is_percent_growth = 0 AND mf.growth * 8.0 / 1024 < @MinGrowthMB)
    );

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DBName, @FileName, @FileTypeDesc, @CurrentSizeMB, @MaxSizeMB;

WHILE @@FETCH_STATUS = 0
BEGIN
    -- Tính giá trị growth mới dựa trên cấu hình
    SELECT TOP 1 @NewGrowthMB = NewGrowthMB
    FROM #GrowthSettings
    WHERE FileType = @FileTypeDesc AND @CurrentSizeMB <= SizeThresholdMB
    ORDER BY SizeThresholdMB ASC;

    -- Kiểm tra logic với MAXSIZE
    IF @MaxSizeMB IS NOT NULL
    BEGIN
        DECLARE @RemainingSpaceMB DECIMAL(18, 2) = @MaxSizeMB - @CurrentSizeMB;
        IF @RemainingSpaceMB <= 0
        BEGIN
            SET @NewGrowthMB = 0; -- Đã đạt MAXSIZE, không thể growth
        END
        ELSE IF @NewGrowthMB > @RemainingSpaceMB
        BEGIN
            SET @NewGrowthMB = FLOOR(@RemainingSpaceMB); -- Điều chỉnh growth mới bằng không gian còn lại
        END
    END

    -- Xây dựng và thực thi câu lệnh ALTER nếu có giá trị growth mới hợp lệ
    IF @NewGrowthMB > 0
    BEGIN
        SET @SQL_Command = N'ALTER DATABASE ' + QUOTENAME(@DBName) +
                           N' MODIFY FILE (NAME = N''' + @FileName + ''', FILEGROWTH = ' + CAST(@NewGrowthMB AS NVARCHAR(10)) + N'MB);';
        
        BEGIN TRY
            EXEC sp_executesql @SQL_Command;
            PRINT N'SUCCESS: Da thay doi file [' + @DBName + '].[' + @FileName + '] thanh ' + CAST(@NewGrowthMB AS NVARCHAR(10)) + 'MB.';
        END TRY
        BEGIN CATCH
            PRINT N'*** ERROR: Khong the thay doi file [' + @DBName + '].[' + @FileName + ']. Chi tiet: ' + ERROR_MESSAGE() + ' ***';
        END CATCH
    END

    FETCH NEXT FROM db_cursor INTO @DBName, @FileName, @FileTypeDesc, @CurrentSizeMB, @MaxSizeMB;
END;

CLOSE db_cursor;
DEALLOCATE db_cursor;

-- Dọn dẹp
DROP TABLE #GrowthSettings;

SET NOCOUNT OFF;
```