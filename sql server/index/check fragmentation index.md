### Kiểm tra phân mảnh của tất cả các index trong một database:

```bash
SELECT 
    DB_NAME() AS DatabaseName,
    OBJECT_NAME(ips.object_id) AS TableName,
    i.name AS IndexName,
    i.type_desc AS IndexType,
    ips.page_count,
    ips.avg_fragmentation_in_percent,
    CASE 
        WHEN ips.page_count < 1000 THEN 'SKIP: Too small'
        WHEN ips.avg_fragmentation_in_percent > 30 THEN 'REBUILD'
        WHEN ips.avg_fragmentation_in_percent BETWEEN 10 AND 30 THEN 'REORGANIZE'
        ELSE 'OK'
    END AS Recommendation
FROM 
    sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'LIMITED') ips
JOIN 
    sys.indexes i ON ips.object_id = i.object_id AND ips.index_id = i.index_id
WHERE 
    ips.index_id > 0  -- Loại trừ heap
    AND ips.page_count >= 1000
    AND ips.avg_fragmentation_in_percent > 10
ORDER BY 
    ips.avg_fragmentation_in_percent DESC;
```

### kiểm tra phân mảnh index của toàn bộ database trong instance SQL Server

```bash
/*======================================================================
 Enterprise Fragmentation Audit v5
 SQL Server 2016+
 Fixed + Production Safe + Batching
======================================================================*/

SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

------------------------------------------------------------
-- CONFIGURATION
------------------------------------------------------------

DECLARE @TargetDatabases NVARCHAR(MAX) = 'ALL';

DECLARE @MinPageCount BIGINT = 1000;
DECLARE @LargeObjectPageCount BIGINT = 10000;

DECLARE @HeapForwardedRecordThreshold BIGINT = 100;
DECLARE @MinFragmentationPercent DECIMAL(5,2) = 5.0;

DECLARE @BatchSize INT = 250;

------------------------------------------------------------
-- CLEANUP
------------------------------------------------------------

IF OBJECT_ID('tempdb..#FragmentationAudit') IS NOT NULL
    DROP TABLE #FragmentationAudit;

IF OBJECT_ID('tempdb..#CandidateIndexes') IS NOT NULL
    DROP TABLE #CandidateIndexes;

IF OBJECT_ID('tempdb..#TargetDBs') IS NOT NULL
    DROP TABLE #TargetDBs;

------------------------------------------------------------
-- TARGET DATABASE PARSER
------------------------------------------------------------

CREATE TABLE #TargetDBs
(
    DBName SYSNAME
);

IF UPPER(@TargetDatabases) <> 'ALL'
BEGIN

    DECLARE @ParseStr NVARCHAR(MAX);
    DECLARE @CommaPos INT;
    DECLARE @CurrentDB SYSNAME;

    SET @ParseStr = @TargetDatabases + ',';

    WHILE CHARINDEX(',', @ParseStr) > 0
    BEGIN

        SET @CommaPos = CHARINDEX(',', @ParseStr);

        SET @CurrentDB =
            LTRIM(RTRIM(SUBSTRING(@ParseStr,1,@CommaPos - 1)));

        IF @CurrentDB <> ''
        BEGIN
            INSERT INTO #TargetDBs(DBName)
            VALUES(@CurrentDB);
        END

        SET @ParseStr =
            SUBSTRING(@ParseStr,@CommaPos + 1,LEN(@ParseStr));

    END
END

------------------------------------------------------------
-- RESULT TABLE
------------------------------------------------------------

CREATE TABLE #FragmentationAudit
(
    DatabaseName                   SYSNAME,
    SchemaName                     SYSNAME,
    TableName                      SYSNAME,
    ObjectType                     VARCHAR(20),
    IndexName                      SYSNAME NULL,
    IndexType                      NVARCHAR(60),
    PartitionNumber                INT,
    RecordCount                    BIGINT,
    PageCount                      BIGINT,
    FragmentationPercent           DECIMAL(10,2),
    ForwardedRecordCount           BIGINT NULL,
    AvgPageSpaceUsedPercent        DECIMAL(10,2) NULL,
    [FillFactor]                     INT,
    CompressionType                NVARCHAR(60),
    ScanMode                       VARCHAR(20),
    SeverityScore                  DECIMAL(18,2),
    UserSeeks                      BIGINT NULL,
    UserScans                      BIGINT NULL,
    UserLookups                    BIGINT NULL,
    CaptureTime                    DATETIME2(0)
);

------------------------------------------------------------
-- STAGING TABLE
------------------------------------------------------------

CREATE TABLE #CandidateIndexes
(
    RowID           INT IDENTITY(1,1),
    object_id       INT,
    index_id        INT,
    scan_mode       VARCHAR(20)
);

------------------------------------------------------------
-- VARIABLES
------------------------------------------------------------

DECLARE @DBName SYSNAME;
DECLARE @SQL NVARCHAR(MAX);

DECLARE @StartRow INT;
DECLARE @EndRow INT;
DECLARE @MaxRow INT;

------------------------------------------------------------
-- DATABASE CURSOR
------------------------------------------------------------

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD
FOR
SELECT name
FROM sys.databases
WHERE
    database_id > 4
    AND state = 0
    AND is_read_only = 0
    AND source_database_id IS NULL
    AND
    (
        UPPER(@TargetDatabases) = 'ALL'
        OR name IN (SELECT DBName FROM #TargetDBs)
    )
ORDER BY name;

OPEN db_cursor;

FETCH NEXT FROM db_cursor INTO @DBName;

WHILE @@FETCH_STATUS = 0
BEGIN

    PRINT 'Scanning database: ' + @DBName;

    --------------------------------------------------------
    -- RESET STAGING
    --------------------------------------------------------

    TRUNCATE TABLE #CandidateIndexes;

    --------------------------------------------------------
    -- PASS 1
    -- LOW COST DISCOVERY
    --------------------------------------------------------

    SET @SQL = N'

    USE ' + QUOTENAME(@DBName) + N';

    --------------------------------------------------------
    -- SKIP AG SECONDARY
    --------------------------------------------------------

    IF EXISTS
    (
        SELECT 1
        FROM sys.databases
        WHERE name = DB_NAME()
          AND replica_id IS NOT NULL
    )
    AND sys.fn_hadr_is_primary_replica(DB_NAME()) <> 1
    BEGIN
        RETURN;
    END;

    INSERT INTO #CandidateIndexes
    (
        object_id,
        index_id,
        scan_mode
    )

    SELECT DISTINCT
        ips.object_id,
        ips.index_id,

        ----------------------------------------------------
        -- IMPORTANT FIX:
        -- NEVER USE LIMITED IN PASS 2
        ----------------------------------------------------
        CASE
            WHEN ips.page_count >= ' + CAST(@LargeObjectPageCount AS VARCHAR(20)) + '
                THEN ''SAMPLED''
            ELSE ''DETAILED''
        END

    FROM sys.dm_db_index_physical_stats
    (
        DB_ID(),
        NULL,
        NULL,
        NULL,
        ''LIMITED''
    ) ips

    INNER JOIN sys.tables t
        ON ips.object_id = t.object_id

    INNER JOIN sys.indexes i
        ON ips.object_id = i.object_id
        AND ips.index_id = i.index_id

    WHERE
        t.is_ms_shipped = 0

        AND ips.alloc_unit_type_desc = ''IN_ROW_DATA''

        AND ips.page_count >= ' + CAST(@MinPageCount AS VARCHAR(20)) + '

        AND i.is_hypothetical = 0

        AND i.is_disabled = 0;

    ';

    EXEC sp_executesql @SQL;

    --------------------------------------------------------
    -- BATCHING
    --------------------------------------------------------

    SELECT @MaxRow = MAX(RowID)
    FROM #CandidateIndexes;

    SET @StartRow = 1;

    WHILE @StartRow <= ISNULL(@MaxRow,0)
    BEGIN

        SET @EndRow = @StartRow + @BatchSize - 1;

        ----------------------------------------------------
        -- PASS 2
        ----------------------------------------------------

        SET @SQL = N'

        USE ' + QUOTENAME(@DBName) + N';

        INSERT INTO #FragmentationAudit
        (
            DatabaseName,
            SchemaName,
            TableName,
            ObjectType,
            IndexName,
            IndexType,
            PartitionNumber,
            RecordCount,
            PageCount,
            FragmentationPercent,
            ForwardedRecordCount,
            AvgPageSpaceUsedPercent,
            [FillFactor],
            CompressionType,
            ScanMode,
            SeverityScore,
            UserSeeks,
            UserScans,
            UserLookups,
            CaptureTime
        )

        SELECT
            DB_NAME(),

            s.name,

            t.name,

            CASE
                WHEN ips.index_id = 0 THEN ''HEAP''
                ELSE ''INDEX''
            END,

            i.name,

            i.type_desc,

            ips.partition_number,

            ps.row_count,

            ips.page_count,

            CAST
            (
                ips.avg_fragmentation_in_percent
                AS DECIMAL(10,2)
            ),

            ips.forwarded_record_count,

            CAST
            (
                ips.avg_page_space_used_in_percent
                AS DECIMAL(10,2)
            ),

            i.fill_factor,

            p.data_compression_desc,

            c.scan_mode,

            ------------------------------------------------
            -- SEVERITY SCORE
            ------------------------------------------------
            CAST
            (
                CASE

                    ----------------------------------------
                    -- HEAP
                    ----------------------------------------
                    WHEN ips.index_id = 0 THEN
                    (
                        SQRT(NULLIF(ips.page_count,1))
                        *
                        LOG10(ips.forwarded_record_count + 1)
                    )

                    ----------------------------------------
                    -- INDEX
                    ----------------------------------------
                    ELSE
                    (
                        ips.avg_fragmentation_in_percent
                        *
                        SQRT(NULLIF(ips.page_count,1))
                    )

                END

                AS DECIMAL(18,2)
            ),

            us.user_seeks,

            us.user_scans,

            us.user_lookups,

            SYSDATETIME()

        FROM #CandidateIndexes c

        ----------------------------------------------------
        -- IMPORTANT FIX:
        -- REMOVE partition-level invocation
        ----------------------------------------------------
        CROSS APPLY
        sys.dm_db_index_physical_stats
        (
            DB_ID(),
            c.object_id,
            c.index_id,
            NULL,
            c.scan_mode
        ) ips

        INNER JOIN sys.tables t
            ON ips.object_id = t.object_id

        INNER JOIN sys.schemas s
            ON t.schema_id = s.schema_id

        INNER JOIN sys.indexes i
            ON ips.object_id = i.object_id
            AND ips.index_id = i.index_id

        LEFT JOIN sys.partitions p
            ON ips.object_id = p.object_id
            AND ips.index_id = p.index_id
            AND ips.partition_number = p.partition_number

        LEFT JOIN sys.dm_db_partition_stats ps
            ON ips.object_id = ps.object_id
            AND ips.index_id = ps.index_id
            AND ips.partition_number = ps.partition_number

        LEFT JOIN sys.dm_db_index_usage_stats us
            ON us.database_id = DB_ID()
            AND us.object_id = ips.object_id
            AND us.index_id = ips.index_id

        WHERE
            c.RowID BETWEEN ' + CAST(@StartRow AS VARCHAR(20)) + '
            AND ' + CAST(@EndRow AS VARCHAR(20)) + '

            AND ips.page_count >= ' + CAST(@MinPageCount AS VARCHAR(20)) + '

            ------------------------------------------------
            -- IMPORTANT FIX:
            -- HANDLE NULL fragmentation safely
            ------------------------------------------------
            AND
            (
                (
                    ips.index_id = 0
                    AND ips.forwarded_record_count >= ' + CAST(@HeapForwardedRecordThreshold AS VARCHAR(20)) + '
                )

                OR

                (
                    ips.index_id > 0
                    AND ISNULL(ips.avg_fragmentation_in_percent,0)
                        >= ' + CAST(@MinFragmentationPercent AS VARCHAR(20)) + '
                )
            );

        ';

        EXEC sp_executesql @SQL;

        ----------------------------------------------------
        -- THROTTLE
        ----------------------------------------------------

        WAITFOR DELAY '00:00:00.200';

        SET @StartRow = @EndRow + 1;

    END

    FETCH NEXT FROM db_cursor INTO @DBName;

END

CLOSE db_cursor;
DEALLOCATE db_cursor;

------------------------------------------------------------
-- FINAL OUTPUT
------------------------------------------------------------

SELECT
    DatabaseName,
    SchemaName,
    TableName,
    ObjectType,
    IndexName,
    IndexType,
    PartitionNumber,
    RecordCount,
    PageCount,
    FragmentationPercent,
    ForwardedRecordCount,
    AvgPageSpaceUsedPercent,
    [FillFactor],
    CompressionType,
    ScanMode,
    SeverityScore,
    UserSeeks,
    UserScans,
    UserLookups,
    CaptureTime
FROM #FragmentationAudit
ORDER BY
    SeverityScore DESC,
    PageCount DESC,
    FragmentationPercent DESC;
```
	
- Cột 1: PageCount (Kích thước vật lý của Index)
	- Ý nghĩa: Cho biết index đó đang chiếm bao nhiêu trang dữ liệu (mỗi page = 8KB).
	- Cách đọc quyết định: * PageCount < 1000: Bạn bỏ qua, không cần Rebuild hay Reorganize, dù % phân mảnh có lên tới 90%. Ở kích thước này (nhỏ hơn 8MB), index nằm gọn trong bộ nhớ RAM (Buffer Pool) và thuật toán quét của SQL Server không bị ảnh hưởng. Bảo trì các index này chỉ làm tốn CPU vô ích.
	- PageCount >= 1000: Đây mới là các đối tượng "vào tầm ngắm" để xử lý.

- Cột 2: FragmentationPercent (Tỷ lệ phân mảnh)
	- Ý nghĩa: Cho biết tỷ lệ phần trăm các trang dữ liệu bị sắp xếp sai thứ tự logic so với thứ tự vật lý trên ổ đĩa.
	- Cách đọc quyết định (Theo chuẩn Microsoft dựa trên điều kiện PageCount >= 1000):
	- Từ 5% đến 30%: Quyết định REORGANIZATION (ALTER INDEX ... REORGANIZE).
	- Lớn hơn 30%: Quyết định REBUILD (ALTER INDEX ... REBUILD).

- Cột 3: ObjectType (Loại đối tượng: INDEX hay HEAP)
	- Ý nghĩa: Phân biệt giữa bảng có khóa chính/clustered index (INDEX) và bảng trần không có clustered index (HEAP).
	- Cách đọc quyết định:
	- Nếu là INDEX: Áp dụng quy tắc 5% và 30% ở trên.
	- Nếu là HEAP: không thể chạy lệnh ALTER INDEX REORGANIZE vì nó không có cấu trúc cây để sắp xếp. Nếu cột ForwardedRecordCount cao (ví dụ > 100), bạn bắt buộc phải REBUILD BẢNG bằng lệnh: ALTER TABLE [Tên_Bảng] REBUILD; để dọn dẹp các con trỏ rác.

- Các chỉ số bổ trợ để "Tinh chỉnh chiến thuật" (Advanced DBA)
	- Cột AvgPageSpaceUsedPercent (Độ đặc của trang)
	- Ý nghĩa: Các page dữ liệu đang đầy bao nhiêu % (ví dụ: 60% nghĩa là mỗi page đang trống 40%).
	- Cách đọc quyết định: * Nếu một index có % phân mảnh thấp (ví dụ 8%) nhưng AvgPageSpaceUsedPercent lại quá thấp (ví dụ 50%), điều này nghĩa là dữ liệu bị rải rác, gây lãng phí RAM và làm chậm câu lệnh SELECT.
	- Giải pháp: Trường hợp này vẫn nên REBUILD lại index để SQL Server gom dữ liệu lại cho khít, giải phóng các page trống về cho hệ điều hành.

- Nhóm cột UserSeeks, UserScans, UserLookups (Tần suất sử dụng)
	- Ý nghĩa: Ứng dụng có dùng đến index này không kể từ lần restart server gần nhất.
	- Cách đọc quyết định:
	- Nếu một index bị phân mảnh > 50% nhưng cả 3 cột này đều bằng 0 hoặc rất nhỏ (vài ba lần), nghĩa là đây là một Index "Chết" (Unused Index). Do ứng dụng thay đổi logic nên không còn ai truy vấn vào nó nữa.
	- Giải pháp: KHÔNG Rebuild nó. Thay vào đó, hãy lên kế hoạch DROP (Xóa) hẳn index này đi. Vì để lại nó vừa làm chậm lệnh INSERT/UPDATE/DELETE (do SQL Server vẫn phải cập nhật index khi bảng thay đổi dữ liệu) vừa tốn tài nguyên bảo trì.


- Có thể đối chiếu nhanh kết quả quét được với bảng quy chuẩn dưới đây:

| Object Type | Page Count| Fragmentation Percent | Forwarded Record Count | Hành động                           | Lệnh T-SQL mẫu                                                       |
| ----------- | ----------| --------------------- | ---------------------- | ----------------------------------- | -------------------------------------------------------------------- |
| INDEX       | < 1000    | Bất kỳ                | Không áp dụng          | Bỏ qua                              | Không làm gì cả                                                      |
| INDEX       | >= 1000   | 5% - 30%              | Không áp dụng          | Reorganize (Online, nhẹ nhàng)      | `ALTER INDEX [Index_Name] ON [Table_Name] REORGANIZE;`               |
| INDEX       | >= 1000   | > 30%                 | Không áp dụng          | Rebuild (Nên dùng kèm ONLINE=ON)    | `ALTER INDEX [Index_Name] ON [Table_Name] REBUILD WITH (ONLINE=ON);` |
| HEAP        | >= 1000   | Bất kỳ                | Cao (> 100)            | Rebuild Table (Gom dọn con trỏ rác) | `ALTER TABLE [Table_Name] REBUILD;`                                  |
