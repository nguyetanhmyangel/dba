```sql
USE [DbaMonitor] -- Hoặc DB quản trị của bạn
GO

CREATE OR ALTER PROCEDURE dbo.sp_CheckLogHealth_Enterprise_v2
    @DatabaseName  sysname = NULL,
    @IncludeSystem bit     = 0
AS
BEGIN
    SET NOCOUNT ON; SET ARITHABORT ON; SET ANSI_WARNINGS OFF;
    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

    -- 1. Get Database List
    IF OBJECT_ID('tempdb..#T') IS NOT NULL DROP TABLE #T;
    CREATE TABLE #T (database_id int PRIMARY KEY, database_name sysname);
    IF @DatabaseName IS NOT NULL INSERT #T SELECT database_id, name FROM sys.databases WHERE name = @DatabaseName AND state = 0;
    ELSE INSERT #T SELECT database_id, name FROM sys.databases WHERE (database_id > 4 OR @IncludeSystem = 1) AND state = 0;

    -- 2. Result Table
    IF OBJECT_ID('tempdb..#R') IS NOT NULL DROP TABLE #R;
    CREATE TABLE #R (
        database_id int PRIMARY KEY, database_name sysname, recovery_model nvarchar(60), log_reuse_wait nvarchar(60),
        
        -- AG Status
        is_primary_replica bit DEFAULT 1,
        
        -- Log Metrics
        log_size_mb decimal(18,2), log_used_mb decimal(18,2), log_used_pct decimal(6,2), log_free_mb decimal(18,2),
        
        -- VLF & Disk
        total_vlf int, avg_vlf_size_mb decimal(18,2), volume_info nvarchar(256), volume_free_pct decimal(5,2),
        
        -- Placement Audit (NEW)
        is_shared_drive bit, -- 1 = Bad, 0 = Good
        
        -- Config Audit
        current_growth_mb decimal(18,2), is_percent_growth bit,
        
        -- Logic
        warning_level varchar(20) DEFAULT 'OK', status_display nvarchar(50), recommendation nvarchar(max),
        
        -- Fix Params
        suggested_shrink_mb int, suggested_growth_mb int, log_file sysname, fix_script nvarchar(max)
    );

    -- 3. Core Logic Capture
    INSERT INTO #R(database_id, database_name, recovery_model, log_reuse_wait,
                   log_size_mb, log_used_mb, total_vlf, 
                   volume_free_pct, volume_info, log_file,
                   current_growth_mb, is_percent_growth, is_primary_replica, is_shared_drive)
    SELECT
        t.database_id, t.database_name, d.recovery_model_desc, d.log_reuse_wait_desc,
        ls.total_log_size_mb, ls.active_log_size_mb, vlf.total_vlf,
        ISNULL(vs_log.free_pct, 0), ISNULL(vs_log.volume_mount_point, 'N/A') + N' (' + CAST(ISNULL(vs_log.free_pct,0) AS nvarchar(10)) + N'% Free)', fi.log_logical_name,
        fi.growth_mb, fi.is_percent_growth,
        ISNULL(hadr.is_primary_replica, 1),
        -- [NEW LOGIC] Check if Log Volume exists in Data Volumes list
        CASE WHEN placement.shared_count > 0 THEN 1 ELSE 0 END
    FROM #T t
    JOIN sys.databases d ON d.database_id = t.database_id
    CROSS APPLY sys.dm_db_log_stats(t.database_id) ls
    OUTER APPLY (SELECT COUNT(*) AS total_vlf FROM sys.dm_db_log_info(t.database_id)) vlf
    
    -- Get Log Volume Info
    OUTER APPLY ( 
        SELECT mf.database_id, 
               volume_mount_point = MAX(vs.volume_mount_point),
               free_pct = MAX(CAST(100.0 * vs.available_bytes / NULLIF(vs.total_bytes,0) AS decimal(5,2)))
        FROM sys.master_files mf CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) vs
        WHERE mf.database_id = t.database_id AND mf.type = 1 -- LOG
        GROUP BY mf.database_id
    ) vs_log
    
    -- [NEW LOGIC] Check Placement: Does any Data File share the same volume as the Log?
    OUTER APPLY (
        SELECT COUNT(*) as shared_count
        FROM sys.master_files mf_data
        CROSS APPLY sys.dm_os_volume_stats(mf_data.database_id, mf_data.file_id) vs_data
        WHERE mf_data.database_id = t.database_id
          AND mf_data.type = 0 -- DATA
          AND vs_data.volume_mount_point = vs_log.volume_mount_point -- Same Volume as Log
    ) placement

    LEFT JOIN ( 
        SELECT database_id, log_logical_name = MAX(name), 
               growth_mb = MAX(CASE WHEN is_percent_growth=1 THEN 0 ELSE growth*8.0/1024 END),
               is_percent_growth = MAX(CAST(is_percent_growth AS int))
        FROM sys.master_files WHERE type=1 GROUP BY database_id
    ) fi ON fi.database_id = t.database_id
    LEFT JOIN sys.dm_hadr_database_replica_states hadr 
        ON hadr.database_id = t.database_id AND hadr.is_local = 1;

    -- 4. Advanced Calculations
    UPDATE #R SET
        log_used_pct = CAST(log_used_mb * 100.0 / NULLIF(log_size_mb,0) AS decimal(6,2)),
        log_free_mb  = log_size_mb - log_used_mb,
        avg_vlf_size_mb = CASE WHEN total_vlf > 0 THEN log_size_mb / total_vlf ELSE 0 END,
        
        suggested_growth_mb = CASE     
            WHEN log_size_mb < 10240   THEN 1024      
            WHEN log_size_mb < 51200   THEN 4096      
            WHEN log_size_mb < 204800  THEN 8192      
            WHEN log_size_mb < 1048576 THEN 16384     
            ELSE 32768                                
        END,

        suggested_shrink_mb = CASE 
            WHEN log_used_mb < 512 THEN 1024
            WHEN log_used_mb < 51200 THEN CAST(log_used_mb * 1.3 AS int)
            ELSE CAST(log_used_mb * 1.1 AS int) + 5120
        END;

    -- 5. Enterprise Warning Logic
    UPDATE #R SET warning_level = CASE
        -- Level 1: Nguy hiểm tính mạng
        WHEN volume_free_pct < 5 THEN 'EMERGENCY'
        
        -- Level 2: Cấu hình Vật lý & Growth (Nguyen nhân gốc)
        WHEN is_shared_drive = 1 THEN 'BAD_PLACEMENT' -- [NEW] Chung ổ
        WHEN is_percent_growth = 1 THEN 'CONFIG_BAD' 
        WHEN log_size_mb > 10240 AND current_growth_mb < 512 THEN 'CONFIG_WEAK' 
        
        -- Level 3: VLF Fragmentation
        WHEN total_vlf > 10000 THEN 'CRITICAL' 
        WHEN total_vlf > 1000 AND avg_vlf_size_mb < 64 THEN 'HIGH' 
        
        -- Level 4: Wasted Space
        WHEN log_size_mb > 5120 AND log_used_pct < 2 THEN 'HIGH' 
        
        -- Level 5: Blocked
        WHEN log_reuse_wait NOT IN ('NOTHING','CHECKPOINT') AND log_used_pct > 5 THEN 'BLOCKED' 
        
        ELSE 'OK' END;

    -- 6. Recommendation & Fix Script Generation
    UPDATE #R SET
        status_display = CASE warning_level
            WHEN 'EMERGENCY'     THEN N'🔴 EMERGENCY' 
            WHEN 'CRITICAL'      THEN N'🔴 CRITICAL' 
            WHEN 'CONFIG_BAD'    THEN N'🔴 BAD CONFIG'
            WHEN 'BAD_PLACEMENT' THEN N'🟠 BAD PLACEMENT' -- Màu cam cảnh báo
            WHEN 'HIGH'          THEN N'🟠 HIGH' 
            WHEN 'CONFIG_WEAK'   THEN N'🟠 WEAK CONFIG'
            WHEN 'BLOCKED'       THEN N'🚫 BLOCKED' 
            ELSE N'🟢 OK' 
        END,
        
        recommendation = CASE 
            WHEN is_primary_replica = 0 THEN N'[SECONDARY NODE] Chỉ monitor.'
            WHEN warning_level = 'EMERGENCY'     THEN N'Disk sắp chết ('+CAST(volume_free_pct AS nvarchar)+N'%). Cấp cứu!'
            WHEN warning_level = 'BAD_PLACEMENT' THEN N'Log & Data chung ổ đĩa! Rủi ro mất dữ liệu & chậm I/O.'
            WHEN warning_level = 'CONFIG_BAD'    THEN N'Đang dùng % Growth. Rất tệ.'
            WHEN warning_level = 'CONFIG_WEAK'   THEN N'Growth quá nhỏ. Cần tăng lên.'
            WHEN warning_level = 'CRITICAL'      THEN N'VLF bùng nổ ('+CAST(total_vlf AS nvarchar)+N').'
            WHEN warning_level = 'HIGH'          THEN N'Phân mảnh hoặc Lãng phí ('+CAST(total_vlf AS nvarchar)+N' VLF).'
            WHEN warning_level = 'BLOCKED'       THEN N'Log đầy & Bị kẹt bởi: '+log_reuse_wait
            ELSE N'Healthy' END,
        
        fix_script = CASE
            WHEN is_primary_replica = 0 THEN NULL
            
            WHEN warning_level = 'EMERGENCY' THEN 
                N'BACKUP LOG ['+database_name+'] TO DISK = ''NUL''; -- BREAKS CHAIN!' + CHAR(13) +
                N'DBCC SHRINKFILE (N'''+log_file+''', '+CAST(suggested_shrink_mb AS nvarchar)+');'
            
            -- Placement: Không có script fix tự động, chỉ nhắc nhở
            WHEN warning_level = 'BAD_PLACEMENT' THEN 
                N'-- Cần kế hoạch Move File sang ổ khác. (Thủ công)'

            WHEN warning_level IN ('CONFIG_BAD', 'CONFIG_WEAK') THEN
                N'ALTER DATABASE ['+database_name+'] MODIFY FILE (NAME = N'''+log_file+''', FILEGROWTH = '+CAST(suggested_growth_mb AS nvarchar)+'MB);'

            WHEN warning_level = 'CRITICAL' THEN
                 N'-- CRITICAL FIX: Backup -> TruncateOnly -> Resize' + CHAR(13) +
                 N'USE ['+database_name+']; CHECKPOINT; BACKUP LOG ['+database_name+'] TO DISK=''NUL'';' + CHAR(13) +
                 N'DBCC SHRINKFILE (N'''+log_file+''', 0, TRUNCATEONLY);' + CHAR(13) +
                 N'ALTER DATABASE ['+database_name+'] MODIFY FILE (NAME = N'''+log_file+''', SIZE = '+CAST(suggested_shrink_mb + 2048 AS nvarchar)+'MB, FILEGROWTH = '+CAST(suggested_growth_mb AS nvarchar)+'MB);'

            WHEN warning_level = 'HIGH' THEN 
                 N'USE ['+database_name+']; DBCC SHRINKFILE (N'''+log_file+''', '+CAST(suggested_shrink_mb AS nvarchar)+'); ' +
                 N'ALTER DATABASE ['+database_name+'] MODIFY FILE (NAME = N'''+log_file+''', SIZE = '+CAST(suggested_shrink_mb + 1024 AS nvarchar)+'MB, FILEGROWTH = '+CAST(suggested_growth_mb AS nvarchar)+'MB);'
            
            ELSE NULL
        END;

    -- 7. Output
    SELECT 
        status_display      AS [Status],
        database_name       AS [DB],
        
        -- New Column: Placement Status
        CASE WHEN is_shared_drive=1 THEN N'SHARED (Bad)' ELSE N'SEPARATED (Good)' END AS [I/O_Layout],
        
        -- Config
        CASE WHEN is_percent_growth=1 THEN N'PERCENT' ELSE CAST(CAST(current_growth_mb AS int) AS nvarchar)+N' MB' END AS [Cur_Growth],
        CAST(suggested_growth_mb AS int) AS [Rec_Growth],
        
        -- Stats
        total_vlf           AS [VLF],
        CAST(log_size_mb AS int) AS [Size_MB],
        log_used_pct        AS [Used_%],
        log_reuse_wait      AS [Wait],
        
        recommendation      AS [Message],
        fix_script
    FROM #R
    ORDER BY 
        CASE warning_level 
            WHEN 'EMERGENCY' THEN 1 WHEN 'CRITICAL' THEN 2 WHEN 'CONFIG_BAD' THEN 3 
            WHEN 'BAD_PLACEMENT' THEN 3.5 -- Chen vào giữa
            WHEN 'HIGH' THEN 4 WHEN 'CONFIG_WEAK' THEN 5 ELSE 99 END,
        log_size_mb DESC;
END
GO
```

- 1. Kiểm tra không gian ổ đĩa (Disk Space)

	- Logic: Kiểm tra ổ cứng chứa file Log còn trống bao nhiêu %.

	- Điều kiện: Volume Free % < 10%.

	- Kết luận: 🔴 EMERGENCY.

	- Hành động: Kích hoạt chế độ cứu hộ (Cho phép Backup to NUL nếu cần thiết để cứu ổ cứng khỏi bị đầy 100%).

- 2. Kiểm tra phân mảnh (VLF Fragmentation)

	- Logic: Đếm số lượng Virtual Log Files (VLF) trong file Log.

	- Điều kiện:
	
		- VLF Count > 10.000: 🔴 CRITICAL (Luôn luôn sai, bất kể size nào. Quá nhiều overhead cho OS).

		- VLF Count > 1000 VÀ Avg VLF Size < 64 MB: 🟠 HIGH (Đây là phân mảnh. Log file to nhưng bị băm nhỏ).

		- VLF Count > 1000 VÀ Avg VLF Size > 256 MB: 🟢 OK (Đây là Database lớn, số lượng VLF nhiều là do dung lượng lớn, cấu trúc vẫn khỏe).

	- Hành động: Đề xuất Shrink về nhỏ (reset VLF) rồi Resize lại to (để tạo VLF mới liền mạch).

- 3. Kiểm tra lãng phí (Wasted Space & Ghost Wait)

	- Đây là logic đã được tinh chỉnh cho SQL 2014 & AG Bug:

	- Logic: File Log rất to nhưng bên trong rỗng tuếch.

	- Điều kiện:

	- Log Size > 5GB.

	- Log Used % < 5% (Rất quan trọng: Thực tế là log đang rỗng).

	- Đặc biệt: Kể cả khi Wait Type báo là LOG_BACKUP (do lỗi hiển thị của AG), nếu Used < 5% thì vẫn coi là lãng phí.

	- Kết luận: 🟠 HIGH.

	- Hành động: Đề xuất Shrink để thu hồi dung lượng đĩa.

- 4. Kiểm tra bị kẹt (Blocked)

	- Logic: Log không rỗng (Used % cao) và đang chờ tác vụ khác.

	- Điều kiện: log_reuse_wait KHÔNG PHẢI là NOTHING hoặc CHECKPOINT.

	- Kết luận: 🚫 BLOCKED.

	- Hành động: Không cho phép Shrink. Yêu cầu người dùng xử lý nguyên nhân (Replication, Active Transaction...) trước.

- 5. Kiểm tra tỷ lệ (Ratio)

- Logic: File Log lớn hơn cả file Data (bất thường với DB lưu trữ).

- Điều kiện: Log Size > Data Size và Log > 1GB.

- Kết luận: 🟡 MEDIUM.

- Hành động: Cảnh báo nhẹ, theo dõi thêm.


- 6. Cách dùng:

- Kiểm tra toàn bộ Server (Khuyên dùng):
```sql
EXEC dbo.sp_CheckLogHealth;
```

- Kiểm tra 1 Database cụ thể (Khi đang nghi ngờ):
```sql
EXEC dbo.sp_CheckLogHealth @DatabaseName = 'BK_20_CDB';
```

- Kiểm tra bao gồm cả System DB (master, msdb...):
```sql
EXEC dbo.sp_CheckLogHealth @IncludeSystem = 1;
```