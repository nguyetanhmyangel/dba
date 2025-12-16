- Nguyên nhân phổ biến nhất khiến transaction log trong AG bị đầy là do Primary replica không thể tái sử dụng file log vì nó đang chờ một hoặc nhiều Secondary replica xác nhận đã nhận và ghi (harden) các bản ghi log đó. Về cơ bản, Primary đang bị Secondary "kìm hãm".

- Hành động giải quyết tập trung vào việc tìm ra Secondary replica nào đang bị chậm và tại sao, sau đó khắc phục sự cố trên replica đó.

#### Nguyên nhân chính

- Trong một Availability Group, SQL Server sẽ không cho phép giải phóng (truncate) transaction log trên Primary replica cho đến khi các thay đổi đó được gửi và ghi thành công vào file log trên tất cả các Secondary replica. Điều này đảm bảo rằng nếu có sự cố xảy ra, mọi replica đều có đủ thông tin để phục hồi về một trạng thái nhất quán.

    - Các lý do khiến Secondary replica bị tụt lại phía sau bao gồm:

    - Mạng chậm hoặc không ổn định: Kết nối mạng giữa Primary và Secondary bị gián đoạn hoặc có độ trễ cao.

    - Secondary replica bị quá tải: Secondary replica có cấu hình phần cứng (I/O, CPU, RAM) yếu hơn Primary, không xử lý kịp lượng log gửi đến.

    - Data movement bị tạm dừng (Suspended): Một người quản trị đã tạm dừng việc đồng bộ dữ liệu trên database ở Secondary replica.

    - Secondary replica bị tắt hoặc mất kết nối.

    - Một transaction rất lớn đang chạy trên Primary, tạo ra một lượng log khổng lồ trong thời gian ngắn, khiến Secondary không theo kịp.

#### Các bước kiểm tra và chẩn đoán

Cần thực hiện các bước sau trên Primary replica để xác định nguyên nhân gốc rễ.

* Bước 1: Kiểm tra lý do log không thể tái sử dụng, Đây là bước quan trọng nhất. Chạy câu lệnh sau trên Primary replica.

```bash
SELECT name, log_reuse_wait_desc
FROM sys.databases
WHERE name = 'Ten_Database_Check'; -- Thay bằng tên DB cần kiểm tra.
```

- Trong môi trường AG, kết quả cần chú ý nhất ở cột log_reuse_wait_desc là AVAILABILITY_REPLICA. Nếu thấy giá trị này, nó xác nhận 100% rằng log bị đầy là do một Secondary replica nào đó đang làm chậm quá trình. Các giá trị khác có thể gặp:

    - LOG_BACKUP: Chưa backup transaction log.

    - ACTIVE_TRANSACTION: Có một transaction đang chạy rất lâu.

    - NOTHING: Không có gì ngăn cản, có thể chỉ đơn giản là log vừa được sử dụng hết.

* Bước 2: Sử dụng AG Dashboard để xem tổng quan

Trong SQL Server Management Studio (SSMS), vào Always On High Availability > Availability Groups > [Tên AG cần kiểm tra] và chuột phải chọn Show Dashboard.

Trong Dashboard, hãy chú ý đến các cột:

- BSynchronization State: Đảm bảo tất cả đều là Synchronized hoặc Synchronizing.

- BLog Send Queue Size: Cho biết lượng log (KB) đang chờ được gửi từ Primary đến Secondary. Nếu con số này lớn, vấn đề có thể do mạng.

- BRedo Queue Size: Cho biết lượng log (KB) đã đến Secondary nhưng chưa được ghi vào file database. Nếu con số này lớn, vấn đề là do hiệu năng I/O (ổ đĩa) trên Secondary.

Dashboard sẽ chỉ rõ replica nào đang có vấn đề.

* Bước 3: Dùng DMV để kiểm tra chi tiết. Để có thông tin chính xác hơn Dashboard, hãy chạy truy vấn sau trên Primary

```bash
SELECT
    ar.replica_server_name,
    drs.database_id,
    db_name(drs.database_id) AS database_name,
    drs.synchronization_state_desc,
    drs.log_send_queue_size, -- Đang chờ gửi đi (vấn đề mạng)
    drs.log_send_rate,
    drs.redo_queue_size, -- Đã nhận, chờ ghi (vấn đề I/O trên secondary)
    drs.redo_rate,
    drs.last_commit_time
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar ON drs.replica_id = ar.replica_id
WHERE db_name(drs.database_id) = 'Ten_Database_Check'; -- Thay bằng tên DB cần kiểm tra
```

Query này sẽ cho con số chính xác về log_send_queue_size và redo_queue_size cho từng replica, giúp khoanh vùng vấn đề là do mạng hay do hiệu năng của máy Secondary.

#### Hành động giải quyết

Sau khi đã xác định được nguyên nhân, hãy thực hiện các hành động tương ứng.

1. Nếu vấn đề do Mạng (Log Send Queue cao):

- Kiểm tra kết nối mạng: Dùng ping hoặc các công cụ khác để kiểm tra độ trễ và tình trạng mất gói tin giữa Primary và Secondary.

- Kiểm tra băng thông: Đảm bảo băng thông mạng không bị nghẽn bởi các ứng dụng khác.

- Kiểm tra Firewall/Thiết bị mạng: Đảm bảo không có thiết bị nào đang chặn hoặc làm chậm traffic trên cổng của SQL Server.

2. Nếu vấn đề do hiệu năng Secondary (Redo Queue cao):

- Kiểm tra I/O trên Secondary: Dùng Performance Monitor để theo dõi các chỉ số về disk I/O trên Secondary. Có thể ổ đĩa đang bị quá tải.

- Kiểm tra tài nguyên khác: CPU và RAM trên Secondary có đang bị sử dụng quá mức bởi các tiến trình khác không?

- Xem xét nâng cấp phần cứng: Nếu Secondary luôn bị chậm, có thể nó có cấu hình yếu hơn Primary và cần được nâng cấp.

3. Nếu Data Movement đang bị Suspended:

- Resume lại việc đồng bộ: Chuột phải vào database bị suspended trong SSMS (trên Primary) và chọn Resume Data Movement. Hoặc dùng lệnh T-SQL

```bash
ALTER DATABASE [Ten_Database_Check] SET HADR RESUME;
```

4. Sau khi đã giải quyết vấn đề trên Secondary, Secondary đã bắt kịp Primary (Log Send Queue và Redo Queue đã về gần 0), log trên Primary sẽ có thể được giải phóng. Lúc này hãy:

Backup Transaction Log: Đây là hành động cho phép SQL Server đánh dấu các phần không còn hoạt động trong log là có thể tái sử dụng.

```bash
BACKUP LOG [Ten_Database_Check] TO DISK = 'NUL:'; -- Backup nhanh vào "thiết bị rỗng"
-- Hoặc backup ra file như bình thường
BACKUP LOG [Ten_Database_Check] TO DISK = 'D:\Backups\Ten_Database_Check.trn';
```

#### Giải pháp khẩn cấp (Khi ổ đĩa sắp đầy)

Nếu ổ đĩa chứa file log sắp đầy và không thể giải quyết vấn đề trên Secondary ngay lập tức, có thể thêm một file log mới: Thêm một file log thứ hai trên một ổ đĩa khác còn trống. SQL Server sẽ bắt đầu ghi vào file mới này, cho thêm thời gian để xử lý sự cố.

```bash
ALTER DATABASE [Ten_Database_Cua_Ban]
ADD LOG FILE
(
    NAME = N'Ten_Database_Cua_Ban_log2',
    FILENAME = N'E:\SQL_Logs\Ten_Database_Cua_Ban_log2.ldf', -- Đường dẫn đến ổ đĩa mới
    SIZE = 10240MB, -- Kích thước ban đầu
    FILEGROWTH = 1024MB
);
```
Hành động này không giải quyết gốc rễ vấn đề nhưng sẽ giúp hệ thống không bị dừng hoạt động. Sau khi khắc phục được sự cố đồng bộ, có thể shrink và xóa file log tạm thời này đi.


#### Script shrink log, tối ưu VLF:

- Kiểm tra xem file log thuộc database nào:

```sql
DECLARE @PhysicalPath NVARCHAR(512) = N'F:\Log\EDMS_TKNIPI'; -- <--- INPUT


-- 1. TÌM DB TỪ FILE PATH
SELECT TOP 1 
     DB_NAME(database_id) as DbName,
    name  as LogFileName 
FROM sys.master_files
WHERE type_desc = 'LOG' 
  AND physical_name LIKE '%' + RIGHT(@PhysicalPath, CHARINDEX('\', REVERSE(@PhysicalPath))-1) + '%';
```

-- Kiểm tra log của db và xử lí

```sql



/* =================================================================================
   SQL SERVER LOG MANAGER (REPORT & EXECUTE MODE)
   Tính năng:
     1. Mode 'REPORT': Xem tình trạng VLF, Size, Dự đoán Target (An toàn)
     2. Mode 'EXECUTE': Chạy quy trình Backup Append -> Shrink Loop -> Resize
   ================================================================================= */
SET NOCOUNT ON;

-- =============================================================
-- [1] CẤU HÌNH (USER INPUT)
-- =============================================================
DECLARE @DBName      sysname       = N'EDMS_TKNIPI';   -- <--- TÊN DATABASE
DECLARE @BackupPath  nvarchar(256) = N'F:\Log\'; -- <--- FOLDER BACKUP
DECLARE @Mode        varchar(10)   = 'REPORT';             -- <--- CHỌN: 'REPORT' hoặc 'EXECUTE'

-- =============================================================
-- [2] KHAI BÁO BIẾN & TÍNH TOÁN
-- =============================================================
DECLARE @LogFile sysname, @LogSizeMB int, @LogUsedPct decimal(5,2);
DECLARE @DataMB bigint, @TargetSizeMB int, @GrowthMB int;
DECLARE @VLFCount int, @AvgVLFSize decimal(10,2);
DECLARE @IsPrimary bit = 1, @HadrStatus varchar(50) = 'STANDALONE';
DECLARE @Msg nvarchar(max);

-- 2.1 Kiểm tra DB tồn tại
IF DB_ID(@DBName) IS NULL BEGIN RAISERROR(N'Database [%s] not exist.',16,1,@DBName); RETURN; END

-- 2.2 Lấy thông tin File Log
SELECT TOP 1 @LogFile = name, @LogSizeMB = (size*8)/1024 
FROM sys.master_files WHERE database_id = DB_ID(@DBName) AND type = 1;

-- 2.3 Kiểm tra AG Role (Dùng function chuẩn 2019)
IF SERVERPROPERTY('IsHadrEnabled') = 1 
BEGIN
    SET @IsPrimary = sys.fn_hadr_is_primary_replica(@DBName);
    IF @IsPrimary = 0 SET @HadrStatus = 'SECONDARY (READ-ONLY)';
    ELSE IF @IsPrimary = 1 SET @HadrStatus = 'PRIMARY';
    ELSE SET @HadrStatus = 'NOT_JOINED';
END

-- 2.4 Tính toán Target Size (Kimberly Tripp Logic)
SELECT @DataMB = SUM(CAST(size AS bigint)*8/1024) 
FROM sys.master_files WHERE database_id = DB_ID(@DBName) AND type = 0;

SET @TargetSizeMB = CASE 
    WHEN @DataMB <= 10000   THEN 2048   -- Data < 10GB  -> Log 2GB
    WHEN @DataMB <= 50000   THEN 4096   -- Data < 50GB  -> Log 4GB
    WHEN @DataMB <= 200000  THEN 8192   -- Data < 200GB -> Log 8GB
    ELSE 16384 END;                     -- Data to      -> Log 16GB

SET @GrowthMB = CASE WHEN @DataMB <= 200000 THEN 2048 ELSE 8192 END;

-- 2.5 Lấy thông tin VLF (SQL 2019 Native)
-- Lưu ý: Phải dùng Dynamic SQL để chuyển context sang DB đích mới lấy được dm_db_log_info chính xác
DECLARE @VLF_SQL nvarchar(max) = N'SELECT @Cnt = COUNT(*), @Avg = AVG(vlf_size_mb) FROM ' + QUOTENAME(@DBName) + N'.sys.dm_db_log_info(DB_ID('''+@DBName+N'''))';
EXEC sp_executesql @VLF_SQL, N'@Cnt int OUTPUT, @Avg decimal(10,2) OUTPUT', @Cnt=@VLFCount OUTPUT, @Avg=@AvgVLFSize OUTPUT;

-- =============================================================
-- [3] CHẾ ĐỘ BÁO CÁO (REPORT MODE)
-- =============================================================
IF @Mode = 'REPORT'
BEGIN
    PRINT '================================================================';
    PRINT '                   LOG HEALTH REPORT                            ';
    PRINT '================================================================';
    PRINT 'Database:       ' + @DBName;
    PRINT 'AG Role:        ' + @HadrStatus;
    PRINT 'Data Size:      ' + FORMAT(@DataMB, 'N0') + ' MB';
    PRINT '----------------------------------------------------------------';
    PRINT 'CURRENT STATUS:';
    PRINT '   Log File:    ' + @LogFile;
    PRINT '   Size:        ' + FORMAT(@LogSizeMB, 'N0') + ' MB';
    
    -- Đánh giá VLF
    DECLARE @VLFStatus varchar(50);
    IF @VLFCount > 10000 SET @VLFStatus = '(CRITICAL - Startup slow)'
    ELSE IF @VLFCount > 1000 AND @AvgVLFSize < 64 SET @VLFStatus = '(WARNING - Fragmented)'
    ELSE IF @VLFCount > 1000 SET @VLFStatus = '(OK - Large DB)'
    ELSE SET @VLFStatus = '(EXCELLENT)';

    PRINT '   VLF Count:   ' + CAST(@VLFCount AS varchar) + '   ' + @VLFStatus;
    PRINT '   Avg VLF:     ' + FORMAT(@AvgVLFSize, 'N2') + ' MB';
    PRINT '----------------------------------------------------------------';
    PRINT 'TARGET CALCULATION (Based on Data Size):';
    PRINT '   Target Size:    ' + FORMAT(@TargetSizeMB, 'N0') + ' MB';
    PRINT '   Growth Rate:    ' + FORMAT(@GrowthMB, 'N0') + ' MB';
    PRINT '----------------------------------------------------------------';
    
    PRINT 'FINAL RECOMMENDATION:';
    
    -- Logic 1: Không chạy được do là Secondary
    IF @IsPrimary = 0 
        PRINT '   [STOP] CANNOT BE EXECUTED (This is a Secondary Replica).';
    
    -- Logic 2: VLF quá xấu -> BẮT BUỘC CHẠY
    ELSE IF @VLFCount > 1000 AND @AvgVLFSize < 64
        PRINT '   [URGENT] RUN IT IMMEDIATELY. The log file is heavily fragmented (High VLF)..';

    -- Logic 3: VLF tốt, nhưng Size quá lớn (gấp 1.5 lần target) -> TÙY CHỌN
    ELSE IF @LogSizeMB > (@TargetSizeMB * 1.5)
    BEGIN
        PRINT '   [OPTIONAL] CAN BE RUNNING TO SAVE SPACE.';
        PRINT '   Reason: The current log (' + CAST(@LogSizeMB AS varchar) + 'MB) is much larger than the estimated requirement. (' + CAST(@TargetSizeMB AS varchar) + 'MB).';
        PRINT '   Note: Only run this if you are certain the database will not require such large log volumes frequently.';
    END

    -- Logic 4: Mọi thứ đều ổn
    ELSE
        PRINT '   [OK] HEALTHY. No action is required.';
        
    PRINT '================================================================';
END

-- =============================================================
-- [4] CHẾ ĐỘ THỰC THI (EXECUTE MODE)
-- =============================================================
ELSE IF @Mode = 'EXECUTE'
BEGIN
    -- Safety Check
    IF @IsPrimary = 0 
    BEGIN 
        RAISERROR(N'STOP: The database is currently a Secondary Replica. Please switch to Primary Replica..', 16, 1); 
        RETURN; 
    END

    DECLARE @BackupFile nvarchar(512) = @BackupPath + N'LOG_' + @DBName + N'_' + FORMAT(GETDATE(), 'yyyyMMdd_HHmmss') + N'.trn';
    
    DECLARE @ExecSQL nvarchar(max) = N'
    USE ' + QUOTENAME(@DBName) + N';
    SET NOCOUNT ON;
    
    PRINT ''>>> STARTING EXECUTION FOR: ' + @DBName + N''';
    PRINT ''    Target: ' + CAST(@TargetSizeMB AS varchar) + N' MB | Backup: ' + @BackupFile + N''';

    -- VÒNG LẶP THỬ SHRINK (5 LẦN)
    DECLARE @i int = 0, @curr int;
    WHILE @i < 5
    BEGIN
        SET @i += 1;
        SELECT @curr = size*8/1024 FROM sys.database_files WHERE name = ''' + @LogFile + N''';
        
        IF @curr <= 1200 
        BEGIN
            PRINT ''    [Loop '' + CAST(@i AS varchar) + ''] Size OK ('' + CAST(@curr AS varchar) + '' MB). Breaking loop.'';
            BREAK;
        END

        PRINT ''    [Loop '' + CAST(@i AS varchar) + ''] Current: '' + CAST(@curr AS varchar) + '' MB. Backup Append & Shrink...'';
        
        BACKUP LOG ' + QUOTENAME(@DBName) + N' TO DISK = ''' + @BackupFile + N''' WITH COMPRESSION, NOINIT;
        CHECKPOINT;
        DBCC SHRINKFILE(N''' + @LogFile + N''', 1024) WITH NO_INFOMSGS;
        WAITFOR DELAY ''00:00:01'';
    END

    -- RESIZE & REGROW
    PRINT ''>>> Resizing & Setting Growth...'';
    ALTER DATABASE ' + QUOTENAME(@DBName) + N' MODIFY FILE (NAME = N''' + @LogFile + N''', FILEGROWTH = ' + CAST(@GrowthMB AS varchar) + N'MB);
    ALTER DATABASE ' + QUOTENAME(@DBName) + N' MODIFY FILE (NAME = N''' + @LogFile + N''', SIZE = ' + CAST(@TargetSizeMB AS varchar) + N'MB);

    PRINT ''>>> DONE. Status After:'';
    ';

    -- Thực thi lệnh Shrink
    EXEC sp_executesql @ExecSQL;

    -- In báo cáo sau khi chạy xong
    SELECT @VLF_SQL = N'SELECT @Cnt = COUNT(*) FROM ' + QUOTENAME(@DBName) + N'.sys.dm_db_log_info(DB_ID('''+@DBName+N'''))';
    DECLARE @NewVLF int;
    EXEC sp_executesql @VLF_SQL, N'@Cnt int OUTPUT', @Cnt=@NewVLF OUTPUT;
    
    PRINT '    Old VLF: ' + CAST(@VLFCount AS varchar) + ' -> New VLF: ' + CAST(@NewVLF AS varchar);
    PRINT '    PLEASE RUN FULL BACKUP NOW!';
END
ELSE
BEGIN
    PRINT 'Invalid mode. Please select ''REPORT'' or ''EXECUTE''.';
END
```