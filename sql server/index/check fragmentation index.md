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
-- Kiểm tra phân mảnh index toàn bộ instance (tất cả database)
SET NOCOUNT ON;

-- Bảng tạm để lưu kết quả
IF OBJECT_ID('tempdb..#IndexFragmentation') IS NOT NULL
    DROP TABLE #IndexFragmentation;

CREATE TABLE #IndexFragmentation (
    DatabaseName SYSNAME,
    SchemaName SYSNAME,
    TableName SYSNAME,
    IndexName SYSNAME NULL,
    IndexType NVARCHAR(60),
    IndexID INT,
    PageCount BIGINT,
    AvgFragmentationPercent FLOAT,
    FragmentCount BIGINT,
    Recommendation NVARCHAR(20)
);

-- Duyệt qua tất cả database (chỉ online, loại trừ tempdb nếu cần)
DECLARE @SQL NVARCHAR(MAX) = '';

SELECT @SQL = @SQL + 
    'USE [' + name + ']; ' +
    'INSERT INTO #IndexFragmentation
     SELECT 
        DB_NAME() AS DatabaseName,
        SCHEMA_NAME(o.schema_id) AS SchemaName,
        OBJECT_NAME(ips.object_id) AS TableName,
        i.name AS IndexName,
        i.type_desc AS IndexType,
        ips.index_id AS IndexID,
        ips.page_count AS PageCount,
        ips.avg_fragmentation_in_percent AS AvgFragmentationPercent,
        ips.fragment_count AS FragmentCount,
        CASE 
            WHEN ips.page_count < 1000 THEN ''SKIP''
            WHEN ips.avg_fragmentation_in_percent > 30 THEN ''REBUILD''
            WHEN ips.avg_fragmentation_in_percent BETWEEN 10 AND 30 THEN ''REORGANIZE''
            ELSE ''OK''
        END AS Recommendation
     FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, ''LIMITED'') ips
     JOIN sys.indexes i ON ips.object_id = i.object_id AND ips.index_id = i.index_id
     JOIN sys.objects o ON ips.object_id = o.object_id
     WHERE ips.index_id > 0 -- Loại trừ HEAP
       AND o.is_ms_shipped = 0 -- Loại trừ object hệ thống
     ;'
FROM sys.databases
WHERE state = 0 -- Chỉ database ONLINE
  AND name NOT IN ('tempdb'); -- Loại tempdb (tùy chọn)

-- Thực thi
EXEC sp_executesql @SQL;

-- Kết quả: Chỉ hiển thị các index cần xử lý
SELECT 
    DatabaseName,
    SchemaName + '.' + TableName AS FullTableName,
    IndexName,
    IndexType,
    PageCount,
    CAST(AvgFragmentationPercent AS DECIMAL(5,2)) AS AvgFragmentationPercent,
    Recommendation
FROM #IndexFragmentation
WHERE Recommendation IN ('REBUILD', 'REORGANIZE')
ORDER BY 
    DatabaseName,
    AvgFragmentationPercent DESC,
    PageCount DESC;

-- Dọn dẹp
DROP TABLE #IndexFragmentation;
```
	
- Ý nghĩa các cột:
	- avg_fragmentation_in_percent: % phân mảnh logic (cao → cần rebuild/reorganize)
	- fragment_count: Số fragment của index
	- page_count: Số trang dữ liệu của index
	- avg_page_space_used_in_percent: % không gian trang được sử dụng

- Khuyến cáo thực tế (Best Practice): Theo khuyến cáo chính thức từ Microsoft và các chuyên gia SQL Server (bao gồm Paul Randal, Brent Ozar, Kimberly Tripp...), không có ngưỡng cố định về page_count để quyết định rebuild index.
Thay vào đó, quyết định rebuild/reorganize dựa chủ yếu vào avg_fragmentation_in_percent, nhưng page_count đóng vai trò quan trọng để tránh hành động không cần thiết trên các index nhỏ.

	- page_count < 1000, avg_fragmentation_in_percent: Bất kỳ -> Không rebuild/reorganize
	- page_count ≥ 1000, avg_fragmentation_in_percent > 30% -> REBUILD
	- page_count ≥ 1000, avg_fragmentation_in_percent trong khoảng 10% - 30% -> REORGANIZE
	- page_count ≥ 1000, avg_fragmentation_in_percent < 10% ->Không cần
	
- Loại trừ heap có nghĩa là: Chỉ lấy các index thực sự (clustered / non-clustered), bỏ qua bảng dạng HEAP. Trong SQL Server, mỗi bảng có thể thuộc một trong hai loại cấu trúc lưu trữ:

| Loại               | index_id | Mô tả                                                                        |    
|--------------------|-----------|-----------------------------------------------------------------------------|
| HEAP               | 0         | Bảng không có clustered index. Dữ liệu được lưu lộn xộn, không theo thứ tự. |
| Clustered Index    | 1         | Bảng có clustered index → dữ liệu được sắp xếp vật lý theo key.             |
| Non-clustered Index| > 1       | Các index phụ, không ảnh hưởng cấu trúc bảng.                               |

- Tại sao cần loại trừ index_id = 0 (HEAP)?

	- sys.dm_db_index_physical_stats trả về thông tin phân mảnh cho cả HEAP và index.
	- HEAP không phải là index → không thể REBUILD hay REORGANIZE như index.
	- Nếu bạn cố chạy:sqlALTER INDEX ... ON HeapTable REBUILD → Sẽ lỗi, vì không có index để rebuild!

- Cách xử lý HEAP (nếu cần):

	- Không rebuild được → chỉ có thể:
	- Tạo clustered index → tự động rebuild toàn bộ bảng.
	- Hoặc dùng ALTER TABLE YourTable REBUILD (chỉ rebuild heap, không giảm phân mảnh logic).
