- Shrink Db with full recovery mode and join AG:

```sql
USE [your-database];
GO

SET NOCOUNT ON;
DECLARE @BkpPath nvarchar(500) = N'D:\Backup\Tranlogs\'; --- Cần đường dẫn chính xác 
DECLARE @DBName sysname = DB_NAME();
DECLARE @LogLogicalName sysname;
DECLARE @RecoveryModel nvarchar(60);
DECLARE @CurrentSizeMB int;
DECLARE @TargetSizeMB int = 256; -- Mục tiêu dung lượng log mong muốn (MB)
DECLARE @Attempt int = 1;
DECLARE @MaxAttempts int = 5;
DECLARE @SqlStmt nvarchar(max);

-- 1. Tự động lấy tên logical của file Log đầu tiên và Recovery Model
SELECT TOP 1 @LogLogicalName = name, 
             @CurrentSizeMB = size * 8 / 1024
FROM sys.database_files 
WHERE type = 1; -- type = 1 là Log file

SELECT @RecoveryModel = recovery_model_desc 
FROM sys.databases 
WHERE name = @DBName;

IF @LogLogicalName IS NULL
BEGIN
    RAISERROR(N'Không tìm thấy file log cho database hiện tại.', 16, 1);
    RETURN;
END;

PRINT N'======================================================';
PRINT N'>> Database: [' + @DBName + N']';
PRINT N'>> Recovery Model: ' + @RecoveryModel;
PRINT N'>> Log File Logical Name: ' + @LogLogicalName;
PRINT N'>> Kích thước hiện tại: ' + CAST(@CurrentSizeMB AS varchar(10)) + N' MB';
PRINT N'>> Kích thước mục tiêu: ' + CAST(@TargetSizeMB AS varchar(10)) + N' MB';
PRINT N'======================================================';

-- 2. Vòng lặp thu gọn
WHILE @CurrentSizeMB > @TargetSizeMB AND @Attempt <= @MaxAttempts
BEGIN
    PRINT N'--- Lần thử ' + CAST(@Attempt AS varchar(5)) + N' ---';

    -- Đối với FULL/BULK_LOGGED: Phải backup log mới giải phóng được VLF
    IF @RecoveryModel IN ('FULL', 'BULK_LOGGED')
    BEGIN
        SET @BkpPath = @BkpPath + @DBName + N'_' 
                       + CONVERT(varchar, GETDATE(), 112) + N'_' 
                       + REPLACE(CONVERT(varchar, GETDATE(), 108), ':', '') + N'.trn';

        SET @SqlStmt = N'BACKUP LOG ' + QUOTENAME(@DBName) + N' TO DISK = @Path WITH COMPRESSION;';
        
        PRINT N'   Đang backup log ra: ' + @BkpPath;
        EXEC sp_executesql @SqlStmt, N'@Path nvarchar(500)', @Path = @BkpPath;
    END;

    -- Checkpoint
    CHECKPOINT;

    -- Shrink file log theo tên logic lấy được
    SET @SqlStmt = N'DBCC SHRINKFILE (' + QUOTENAME(@LogLogicalName, '''') + N', @Target) WITH NO_INFOMSGS;';
    EXEC sp_executesql @SqlStmt, N'@Target int', @Target = @TargetSizeMB;

    -- Kiểm tra lại kích thước sau shrink
    SELECT @CurrentSizeMB = size * 8 / 1024 
    FROM sys.database_files 
    WHERE name = @LogLogicalName;

    PRINT N'>> Kích thước sau lần ' + CAST(@Attempt AS varchar(5)) + N': ' + CAST(@CurrentSizeMB AS varchar(10)) + N' MB';

    IF @CurrentSizeMB <= @TargetSizeMB BREAK;

    SET @Attempt += 1;
    WAITFOR DELAY '00:00:01';
END;

-- 3. Đánh giá kết quả cuối cùng
IF @CurrentSizeMB <= @TargetSizeMB
    PRINT N'>> THÀNH CÔNG: Log file đã về mức ' + CAST(@CurrentSizeMB AS varchar(10)) + N' MB.';
ELSE
BEGIN
    DECLARE @WaitDesc nvarchar(60);
    SELECT @WaitDesc = log_reuse_wait_desc FROM sys.databases WHERE name = @DBName;
    PRINT N'>> CHƯA ĐẠT MỤC TIÊU: Log đang bị giữ lại bởi: ' + @WaitDesc;
END;
GO
```