-- =============================================
-- Ngày tạo:  2025-07-30

-- Mô tả:     Chuyển Recovery Model sang FULL và Backup Full cho danh sách DB cụ thể.

-- LƯU Ý:      Chạy kịch bản này bằng tài khoản có quyền sysadmin.

--             Tài khoản dịch vụ SQL Server phải có quyền ghi (Write) trên thư mục mạng.

-- =============================================

```bash
SET NOCOUNT ON;

-- Khai báo các biến cần thiết
DECLARE @dbName NVARCHAR(128);          -- Tên Database
DECLARE @backupPath NVARCHAR(500);      -- Đường dẫn thư mục backup
DECLARE @backupFile NVARCHAR(1000);     -- Đường dẫn đầy đủ của file backup
DECLARE @dateTime NVARCHAR(20);         -- Chuỗi thời gian để đặt tên file
DECLARE @sqlCommand NVARCHAR(MAX);      -- Chuỗi lệnh SQL động

-- 1. THIẾT LẬP ĐƯỜNG DẪN BACKUP
SET @backupPath = N'\\sharedisk\QLSX\Backup\S3DNIPI\backup\';

-- 2. TẠO BẢNG TẠM CHỨA DANH SÁCH DATABASE CẦN XỬ LÝ
DECLARE @DatabasesToProcess TABLE (name NVARCHAR(128) PRIMARY KEY);
INSERT INTO @DatabasesToProcess (name) VALUES
('BK10A_CDB'),
('BK10A_CDB_SCHEMA'),
('BK10A_MDB'),
('BK10A_RDB'),
('BK10A_RDB_SCHEMA'),
('DHN_CDB'),
('DHN_CDB_SCHEMA'),
('DHN_MDB'),
('DHN_RDB'),
('DHN_RDB_SCHEMA'),
('TNHA_TEST_MDB'),
('TNHA_TEST_RDB'),
('TNHA_TEST_RDB_SCHEMA'),
('ZZSUPPORT_TEST_CDB'),
('ZZSUPPORT_TEST_CDB_SCHEMA'),
('ZZSUPPORT_TEST_MDB'),
('ZZSUPPORT_TEST_RDB'),
('ZZSUPPORT_TEST_RDB_SCHEMA'),
('ZZTRAINING_CDB'),
('ZZTRAINING_CDB_SCHEMA'),
('ZZTRAINING_MDB'),
('ZZTRAINING_RDB'),
('ZZTRAINING_RDB_SCHEMA');

-- 3. SỬ DỤNG CURSOR ĐỂ LẶP QUA TỪNG DATABASE
PRINT N'Bắt đầu quá trình...';
PRINT N'---------------------------------';

DECLARE db_cursor CURSOR FOR
SELECT name
FROM @DatabasesToProcess
WHERE DB_ID(name) IS NOT NULL; -- Chỉ xử lý những DB thực sự tồn tại trên server

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @dbName;

WHILE @@FETCH_STATUS = 0
BEGIN
    PRINT N'Đang xử lý Database: [' + @dbName + ']';

    -- 3.1. Chuyển Recovery Model sang FULL
    BEGIN TRY
        SET @sqlCommand = N'ALTER DATABASE [' + @dbName + '] SET RECOVERY FULL WITH NO_WAIT;';
        PRINT N'  -> Đang chuyển Recovery Model sang FULL...';
        EXEC sp_executesql @sqlCommand;
        PRINT N'  -> Chuyển Recovery Model thành công.';
    END TRY
    BEGIN CATCH
        PRINT N'  -> LỖI khi chuyển Recovery Model: ' + ERROR_MESSAGE();
    END CATCH

    -- 3.2. Thực hiện Backup Full
    BEGIN TRY
        -- Tạo chuỗi ngày giờ để tên file backup không bị trùng
        SET @dateTime = FORMAT(GETDATE(), 'yyyyMMdd_HHmmss');
        SET @backupFile = @backupPath + @dbName + '_FullBackup_' + @dateTime + '.bak';

        -- Tạo lệnh backup
        SET @sqlCommand = N'BACKUP DATABASE [' + @dbName + '] TO DISK = N''' + @backupFile + ''' WITH COMPRESSION, STATS = 10, CHECKSUM;';
        PRINT N'  -> Đang backup ra file: ' + @backupFile;
        EXEC sp_executesql @sqlCommand;
        PRINT N'  -> Backup thành công.';
    END TRY
    BEGIN CATCH
        PRINT N'  -> LỖI khi backup: ' + ERROR_MESSAGE();
    END CATCH

    PRINT N'---------------------------------';
    FETCH NEXT FROM db_cursor INTO @dbName;
END;

CLOSE db_cursor;
DEALLOCATE db_cursor;

PRINT N'Hoàn tất quá trình!';
SET NOCOUNT OFF;
```