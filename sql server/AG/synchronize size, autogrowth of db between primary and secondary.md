- Các data file và log file của các database trong AG có dung lượng, cấu hình và đường dẫn giống hệt nhau trên tất cả các node (replica) Không bắt buộc, nhưng RẤT NÊN và được xem là một best practice.

- Cơ chế hoạt động của AG là gửi các bản ghi trong transaction log từ node Primary (A) sang các node Secondary (B). Node B sẽ liên tục đọc các bản ghi log này và "áp dụng" (redo) lại các thay đổi vào bản sao database của nó.

- Nếu dung lượng hoặc cấu hình file trên node B khác với node A, các vấn đề về hiệu năng và độ trễ có thể xảy ra, đặc biệt là trong các tình huống file cần tự động tăng dung lượng (autogrowth).

- Đối với Log File (.ldf) - Quan trọng nhất. Đây là nơi tác động rõ rệt nhất. Hãy xem xét kịch bản sau:

    - Trên node A (Primary), một giao dịch lớn xảy ra, làm cho file log đầy và phải tự động tăng dung lượng (ví dụ, tăng thêm 512MB).

    - Thao tác "tăng dung lượng file log" này được ghi vào log và gửi đến node B (Secondary).

    - Node B nhận được bản ghi này và cũng phải thực hiện thao tác tăng dung lượng file log của nó để có thể áp dụng giao dịch.

    - Vấn đề là: Thao tác tăng dung lượng file (file growth) là một hoạt động rất tốn tài nguyên I/O. Trong khi file log trên node B đang bận "lớn lên", tiến trình redo (áp dụng log) sẽ bị tạm dừng. Điều này gây ra:

    - Tăng độ trễ đồng bộ (Redo Queue): Dữ liệu trên node B sẽ ngày càng "trễ" so với node A.

    - Tăng RPO (Recovery Point Objective): Nguy cơ mất dữ liệu nếu xảy ra sự cố tăng lên.

    - Failover chậm hơn: Nếu bạn cần chuyển đổi (failover) sang node B, quá trình recovery sẽ mất nhiều thời gian hơn vì nó còn nhiều log chưa áp dụng.

    - Lưu ý: Data file có thể hưởng lợi từ Instant File Initialization (IFI) để tăng tốc độ, nhưng log file thì không. Log file luôn phải được "zero-out" (ghi các số 0 vào vùng dữ liệu mới), khiến cho việc tăng dung lượng log file đặc biệt chậm.

- Đối với Data File (.mdf, .ndf)
Tác động tương tự như log file nhưng thường ít nghiêm trọng hơn. Nếu một thao tác trên node A làm data file phải tự động tăng dung lượng, node B cũng sẽ phải thực hiện điều tương tự. Việc này cũng gây ra I/O contention và làm chậm tiến trình redo, dù không trực tiếp "block" như log file.

- Trong Always On Availability Groups (AG), logical file names (tên logic như 'YourDB_Data') phải giống nhau giữa primary và secondary (đây là yêu cầu bắt buộc để DB join AG).

- Physical paths (đường dẫn vật lý như 'D:\Data\YourDB.mdf') có thể khác nhau giữa các replicas từ SQL Server 2016/2017 trở lên, nhưng Microsoft không khuyến nghị vì có thể gây phức tạp khi add DB mới (cần restore manual với MOVE), automatic seeding thất bại, hoặc quản lý (ví dụ: nếu path khác, autogrowth có thể fail nếu drive hết space).


- Sử dụng câu query sau để lấy thông tin trên node Primary và thực thi các câu lệnh vừa tạo ra trên Secondary:

```bash
-- Chạy trên node PRIMARY để tạo script cho node SECONDARY
-- PHIÊN BẢN CUỐI CÙNG: Thông minh, an toàn, và chỉ thay đổi khi cần thiết.
-- LƯU Ý: Chạy script được tạo ra vào thời gian low-traffic.
-- NOTE VỀ FILE PATHS: Script này KHÔNG thay đổi physical file paths (FILENAME). Paths có thể khác giữa replicas (từ SQL 2016+), nhưng khuyến nghị giống nhau để tránh vấn đề khi add DB hoặc automatic seeding. Script sẽ print paths trên secondary để bạn so sánh với primary (chạy SELECT name, physical_name FROM sys.database_files; trên primary).
-- Nếu edition primary và secondary khác (ví dụ Enterprise vs Standard), kiểm tra max_size thủ công.
SET NOCOUNT ON;
DECLARE @sql NVARCHAR(MAX) = N'';
SELECT @sql = @sql + '
-- =====================================================================================
-- Database: ' + QUOTENAME(d.name) + '
-- Generated on: ' + CONVERT(NVARCHAR, GETDATE(), 120) + '
-- =====================================================================================
PRINT N''Processing Database: ' + QUOTENAME(d.name) + ''';
DECLARE @ErrorOccurred BIT = 0;
DECLARE @ForceAlter BIT = 0;  -- Set to 1 để force ALTER dù config đã khớp (cho test)
PRINT N''--> Suspending data movement for ' + QUOTENAME(d.name) + ''';
ALTER DATABASE ' + QUOTENAME(d.name) + ' SET HADR SUSPEND;
GO
WAITFOR DELAY ''00:00:05'';  -- Chờ trạng thái ổn định
PRINT N''--> Checking physical file paths on secondary (compare with primary):'';
SELECT name AS LogicalName, physical_name AS PhysicalPath, type_desc AS FileType
FROM ' + QUOTENAME(d.name) + '.sys.database_files;
PRINT N''--> WARNING: Ensure paths have enough space and are consistent with primary if possible.'';
GO
BEGIN TRY
'
+
-- Bắt đầu vòng lặp tạo lệnh ALTER cho từng file
(
    SELECT
        -- Logic IF để kiểm tra trước khi ALTER, với xử lý size an toàn
        '
    -- Checking file: ' + QUOTENAME(f.name) + '
    DECLARE @NeedAlter BIT = 0;
    IF EXISTS (
        SELECT 1
        FROM ' + QUOTENAME(db.name) + '.sys.database_files sf
        WHERE sf.name = N''' + f.name + ''' AND (
            sf.max_size <> ' + CAST(f.max_size AS NVARCHAR(20)) + ' OR
            sf.growth <> ' + CAST(f.growth AS NVARCHAR(20)) + ' OR
            sf.is_percent_growth <> ' + CAST(f.is_percent_growth AS NVARCHAR(1)) + '
        )
    )
        SET @NeedAlter = 1;
    -- Kiểm tra size riêng: Chỉ grow nếu nhỏ hơn, warning nếu lớn hơn (không shrink tự động)
    IF EXISTS (
        SELECT 1
        FROM ' + QUOTENAME(db.name) + '.sys.database_files sf
        WHERE sf.name = N''' + f.name + ''' AND sf.size < ' + CAST(f.size AS NVARCHAR(20)) + '
    )
        SET @NeedAlter = 1;
    ELSE IF EXISTS (
        SELECT 1
        FROM ' + QUOTENAME(db.name) + '.sys.database_files sf
        WHERE sf.name = N''' + f.name + ''' AND sf.size > ' + CAST(f.size AS NVARCHAR(20)) + '
    )
        PRINT N''--> WARNING: File ' + QUOTENAME(f.name) + ' on secondary is larger than primary (possible autogrow). Skipping size change to avoid shrink error. Use DBCC SHRINKFILE if needed.'';
    
    IF @NeedAlter = 1 OR @ForceAlter = 1
    BEGIN
        PRINT N''--> Applying configuration for file: ' + QUOTENAME(f.name) + ''';
        ALTER DATABASE ' + QUOTENAME(db.name) + ' MODIFY FILE (NAME = N''' + f.name + ''', SIZE = ' +
            CAST(f.size * 8 / 1024 AS NVARCHAR(20)) + 'MB, MAXSIZE = ' +
            CASE
                WHEN f.max_size = -1 THEN
                    CASE
                        WHEN SERVERPROPERTY(''Edition'') LIKE ''%Standard%'' AND f.type = 1 THEN ''2048GB''
                        ELSE ''UNLIMITED''
                    END
                WHEN f.max_size = 0 THEN ''0''
                WHEN f.max_size = 268435456 THEN ''2048GB''
                ELSE
                    CASE
                        WHEN (CAST(f.max_size AS BIGINT) * 8 / 1024) >= 1024 THEN CAST((CAST(f.max_size AS BIGINT) * 8 / 1024 / 1024) AS NVARCHAR(20)) + ''GB''
                        ELSE CAST(CAST(f.max_size AS BIGINT) * 8 / 1024 AS NVARCHAR(20)) + ''MB''
                    END
            END + ', FILEGROWTH = ' +
            CASE
                WHEN f.growth = 0 THEN ''0''
                WHEN f.is_percent_growth = 1 THEN CAST(f.growth AS NVARCHAR(10)) + ''%''
                ELSE CAST(f.growth * 8 / 1024 AS NVARCHAR(20)) + ''MB''
            END + '');
        -- Verify sau ALTER
        PRINT N''--> Verifying updated config for file: ' + QUOTENAME(f.name) + ''';
        SELECT name, size/128.0 AS Size_MB, max_size/128.0 AS MaxSize_MB, growth, is_percent_growth 
        FROM ' + QUOTENAME(db.name) + '.sys.database_files WHERE name = N''' + f.name + ''';
    END
    ELSE
    BEGIN
        PRINT N''--> File ' + QUOTENAME(f.name) + ' is already configured correctly. Skipping.'';
    END;
    GO
'
    FROM sys.master_files f
    INNER JOIN sys.databases db ON f.database_id = db.database_id
    WHERE f.database_id = d.database_id
    FOR XML PATH(''), TYPE
).value('.', 'NVARCHAR(MAX)')
+
'
END TRY
BEGIN CATCH
    PRINT N''!!!!!!!!!! ERROR OCCURRED for database ' + QUOTENAME(d.name) + ' !!!!!!!!!!'';
    PRINT N''Error Number: '' + CAST(ERROR_NUMBER() AS NVARCHAR(20));
    PRINT N''Error Message: '' + ERROR_MESSAGE();
    SET @ErrorOccurred = 1;
END CATCH;
GO
IF @ErrorOccurred = 0
BEGIN
    PRINT N''--> All configurations applied successfully. Resuming data movement for ' + QUOTENAME(d.name) + ''';
    ALTER DATABASE ' + QUOTENAME(d.name) + ' SET HADR RESUME;
END
ELSE
BEGIN
    PRINT N''--> An error occurred. Data movement for ' + QUOTENAME(d.name) + ' remains SUSPENDED. Please review the error message above.'';
END;
GO
'
FROM sys.databases d
JOIN sys.availability_databases_cluster adc ON d.name = adc.database_name
JOIN sys.dm_hadr_availability_group_states ags ON adc.group_id = ags.group_id
WHERE d.database_id > 4 -- Bỏ qua DB hệ thống
  AND d.state = 0 -- DB online
  AND ags.primary_replica = @@SERVERNAME -- Chỉ chạy trên primary replica
ORDER BY d.name;
-- In kết quả ra tab "Messages"
PRINT @sql;

```

