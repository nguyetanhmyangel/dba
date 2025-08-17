### 1. VLF là gì?

Định nghĩa:

- VLF là các phân đoạn logic nhỏ hơn trong transaction log file (.ldf).

- Mỗi log file được chia thành nhiều VLF, SQL Server sử dụng VLF để quản lý ghi log.

- Khi bạn tạo hoặc mở rộng log file, SQL Server sẽ chia phần không gian mới thành nhiều VLF.

### 2. Tại sao phải quan tâm đến VLF?

- Hậu quả khi VLF quá nhiều:

- Làm chậm quá trình recovery (khởi động DB, restore, backup log).

- Làm chậm log truncation → log file không thu nhỏ được.

- Gây ảnh hưởng hiệu suất khi giao dịch lớn hoặc backup/restore/log shipping.

### 3. SQL Server tạo VLF như thế nào?

Quy tắc chia VLF khi mở rộng log:

| Kích thước mở rộng | Số lượng VLF được tạo |
| ------------------ | --------------------- |
| <= 64 MB           | 4 VLF                 |
| 64 MB < x <= 1 GB  | 8 VLF                 |
| > 1 GB             | 16 VLF                |

### 4. Giám sát VLF như thế nào?

Query kiểm tra số lượng và trạng thái VLF:

```bash
DBCC LOGINFO;
-- hoặc với SQL Server 2012 trở lên:
DBCC LOGINFO('TênDatabase');
```

SQL Server 2016+:

```bash
SELECT * FROM sys.dm_db_log_info(DB_ID('TênDatabase'));
```

### 5. Số  lượng VLF

| Số lượng VLF | Đánh giá       |
| ------------ | -------------- |
| < 50         | Tốt            |
| 50 – 200     | Chấp nhận được |
| > 1000       | Quá nhiều      |

### 6. Thay đổi số lượng VLF(giảm fragmentation)

- Shrink file log để giảm kích thước file vật lý (cẩn thận với việc ảnh hưởng hiệu suất).

- Tăng lại log với kích thước lớn hơn để chia VLF hợp lý.

Giả sử database là MyDB:

```bash
-- 1. Đảm bảo backup log nếu ở chế độ full
BACKUP LOG MyDB TO DISK = 'NUL:' -- hoặc đến file thực

-- 2. Thu nhỏ log
USE MyDB;
DBCC SHRINKFILE (MyDB_log, 1);  -- 1MB

-- 3. Tăng lại log file với kích thước lớn (v.d. 512MB)
ALTER DATABASE MyDB 
MODIFY FILE (NAME = MyDB_log, SIZE = 512MB);
```

### 7. Dưới đây là bản mở rộng script để:

- Kiểm tra toàn bộ database trong SQL Server

- Đếm số lượng VLF trên mỗi database

- Cảnh báo nếu số lượng VLF quá cao (ví dụ: > 1000)

```bash
SET NOCOUNT ON;

-- Bảng tạm để lưu kết quả
CREATE TABLE #VLFInfo
(
    DatabaseName SYSNAME,
    VLFCount INT
);

-- Biến xử lý vòng lặp
DECLARE @dbName SYSNAME;
DECLARE db_cursor CURSOR FOR
SELECT name 
FROM sys.databases 
WHERE state_desc = 'ONLINE' AND name NOT IN ('tempdb'); -- tempdb luôn có VLF cao, bỏ qua

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @dbName;

WHILE @@FETCH_STATUS = 0
BEGIN
    -- Bảng tạm trong mỗi vòng lặp
    DECLARE @logInfo TABLE (
        RecoveryUnitId BIGINT NOT NULL,
        FileId TINYINT NOT NULL,
        FileSize BIGINT NOT NULL,
        StartOffset BIGINT NOT NULL,
        FSeqNo INTEGER NOT NULL,
        Status TINYINT NOT NULL,
        Parity TINYINT NOT NULL,
        CreateLSN NUMERIC(38, 0) NOT NULL
    );

    -- Dynamic SQL để chạy DBCC LOGINFO cho từng database
    DECLARE @sql NVARCHAR(MAX);
    SET @sql = N'USE [' + QUOTENAME(@dbName) + N']; INSERT INTO @logInfo EXEC(''DBCC LOGINFO WITH NO_INFOMSGS'');';
    
    -- Thực thi dynamic SQL (để chèn vào bảng tạm @logInfo)
    EXEC sp_executesql @sql, N'@logInfo TABLE (
        RecoveryUnitId BIGINT,
        FileId TINYINT,
        FileSize BIGINT,
        StartOffset BIGINT,
        FSeqNo INTEGER,
        Status TINYINT,
        Parity TINYINT,
        CreateLSN NUMERIC(38, 0)
    ) READONLY', @logInfo = @logInfo;

    -- Chèn kết quả đếm số VLF vào bảng chính
    INSERT INTO #VLFInfo(DatabaseName, VLFCount)
    SELECT @dbName, COUNT(*) FROM @logInfo;

    FETCH NEXT FROM db_cursor INTO @dbName;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;

-- Hiển thị kết quả
SELECT 
    DatabaseName, 
    VLFCount,
    CASE 
        WHEN VLFCount > 1000 THEN N'Too many VLFs – cần shrink + grow lại log'
        WHEN VLFCount > 200 THEN N'Nên theo dõi'
        ELSE N'Bình thường'
    END AS Status
FROM #VLFInfo
ORDER BY VLFCount DESC;

-- Xóa bảng tạm
DROP TABLE #VLFInfo;
```