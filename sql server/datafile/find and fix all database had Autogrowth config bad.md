
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

### 2. Chạy đoạn script dưới để fix, trong đó script sẽ đề xuất một giá trị FILEGROWTH mới dựa trên kích thước hiện tại của file. File lớn sẽ có mức tăng trưởng lớn hơn và ngược lại.

```bash
SET NOCOUNT ON;

PRINT '*** BAT DAU QUA TRINH CAI TIEN AUTOGROWTH (v2.0) ***';
PRINT 'Thoi gian thuc thi: ' + CONVERT(NVARCHAR, GETDATE(), 120);
PRINT '----------------------------------------------------------';

-- =====================================================================================
-- >> PHẦN CẤU HÌNH: Bạn có thể thay đổi các giá trị ngưỡng tại đây <<
-- =====================================================================================
DECLARE @MinGrowthMB INT = 64; -- Bất kỳ file nào có growth < 64MB sẽ được coi là "tồi"


-- =====================================================================================
-- >> PHẦN THỰC THI: Không cần chỉnh sửa phần dưới đây <<
-- =====================================================================================

-- Khai báo các biến cần thiết
DECLARE @DBName NVARCHAR(128);
DECLARE @FileName NVARCHAR(128);
DECLARE @FileTypeDesc NVARCHAR(60);
DECLARE @CurrentSizeMB DECIMAL(18,2);
DECLARE @IsPercentGrowth BIT;
DECLARE @CurrentGrowthDesc NVARCHAR(50);
DECLARE @NewGrowthMB INT;
DECLARE @Reason NVARCHAR(500);
DECLARE @SQL_Command NVARCHAR(MAX);

-- Khai báo CURSOR để duyệt qua tất cả các file có cấu hình autogrowth tồi
DECLARE db_cursor CURSOR FOR
SELECT
    d.name AS DatabaseName,
    mf.name AS LogicalFileName,
    mf.type_desc,
    CAST(mf.size * 8.0 / 1024 AS DECIMAL(18,2)) AS CurrentSizeMB,
    mf.is_percent_growth,
    CASE
        WHEN mf.is_percent_growth = 1 THEN CAST(mf.growth AS VARCHAR(10)) + '%'
        ELSE CAST(mf.growth * 8.0 / 1024 AS VARCHAR(20)) + ' MB'
    END AS CurrentGrowth
FROM
    sys.master_files AS mf
JOIN
    sys.databases AS d ON mf.database_id = d.database_id
WHERE
    d.database_id > 4 -- Chỉ lấy các database của người dùng
    AND d.state_desc = 'ONLINE' -- Chỉ xử lý các DB đang online
    AND d.is_read_only = 0 -- Bỏ qua các DB chỉ đọc
    AND (
        mf.is_percent_growth = 1 -- Điều kiện 1: Autogrowth theo % (luôn là tồi)
        OR
        (mf.is_percent_growth = 0 AND mf.growth * 8.0 / 1024 < @MinGrowthMB) -- Điều kiện 2: Autogrowth theo MB nhưng quá nhỏ
    );

-- Mở CURSOR
OPEN db_cursor;

-- Bắt đầu vòng lặp
FETCH NEXT FROM db_cursor INTO @DBName, @FileName, @FileTypeDesc, @CurrentSizeMB, @IsPercentGrowth, @CurrentGrowthDesc;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @SQL_Command = NULL; -- Reset biến command
    SET @Reason = N''; -- Reset biến lý do

    -- Xác định lý do cần sửa
    IF @IsPercentGrowth = 1
        SET @Reason = N'Phat hien Autogrowth theo phan tram (' + @CurrentGrowthDesc + N'), day la thuc hanh toi.';
    ELSE
        SET @Reason = N'Phat hien Autogrowth co gia tri qua nho (' + @CurrentGrowthDesc + N').';


    -- Logic tính toán giá trị growth mới một cách "thông minh"
    IF @FileTypeDesc = 'ROWS' -- Logic cho Data File
    BEGIN
        SET @NewGrowthMB =
            CASE
                WHEN @CurrentSizeMB < 1024 THEN 128     -- < 1GB  -> growth 128MB
                WHEN @CurrentSizeMB < 10240 THEN 256    -- < 10GB -> growth 256MB
                WHEN @CurrentSizeMB < 102400 THEN 512   -- < 100GB-> growth 512MB
                ELSE 1024                               -- > 100GB-> growth 1GB
            END;
    END
    ELSE IF @FileTypeDesc = 'LOG' -- Logic cho Log File
    BEGIN
        SET @NewGrowthMB =
            CASE
                WHEN @CurrentSizeMB < 2048 THEN 256     -- < 2GB  -> growth 256MB
                WHEN @CurrentSizeMB < 20480 THEN 512    -- < 20GB -> growth 512MB
                ELSE 1024                               -- > 20GB -> growth 1GB
            END;
    END

    -- Xây dựng câu lệnh ALTER
    SET @SQL_Command = N'ALTER DATABASE ' + QUOTENAME(@DBName) +
                       N' MODIFY FILE (NAME = N''' + @FileName + ''', FILEGROWTH = ' + CAST(@NewGrowthMB AS NVARCHAR(10)) + N'MB);';

    -- In log và thực thi
    PRINT N'';
    PRINT N'Kiem tra file: [' + @DBName + N'].[' + @FileName + N'] (Kich thuoc hien tai: ' + CAST(@CurrentSizeMB AS NVARCHAR(20)) + N' MB)';
    PRINT N'--> Ly do: ' + @Reason;
    PRINT N'--> De xuat gia tri moi: ' + CAST(@NewGrowthMB AS NVARCHAR(10)) + 'MB.';
    PRINT N'   Thuc thi lenh: ' + @SQL_Command;

    BEGIN TRY
        EXEC sp_executesql @SQL_Command;
        PRINT N'   -> THAY DOI THANH CONG.';
    END TRY
    BEGIN CATCH
        PRINT N'   -> *** LOI: Khong the thay doi file. Loi chi tiet: ' + ERROR_MESSAGE() + ' ***';
    END CATCH

    -- Lấy dòng tiếp theo
    FETCH NEXT FROM db_cursor INTO @DBName, @FileName, @FileTypeDesc, @CurrentSizeMB, @IsPercentGrowth, @CurrentGrowthDesc;
END;

-- Đóng và giải phóng CURSOR
CLOSE db_cursor;
DEALLOCATE db_cursor;

PRINT N'';
PRINT '----------------------------------------------------------';
PRINT '*** QUA TRINH KIEM TRA VA CAI TIEN AUTOGROWTH DA HOAN TAT ***';
```