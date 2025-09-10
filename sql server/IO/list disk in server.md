### Câu query này sẽ liệt kê tất cả các ổ đĩa đang chứa file database của SQL Server.

```bash
SELECT DISTINCT
    vs.volume_mount_point AS [DiskName],
    -- Chuyển đổi từ Bytes sang Gigabytes cho dễ đọc
    CONVERT(DECIMAL(18, 0), vs.total_bytes / 1073741824.0) AS [TotalSize(GB)],
    CONVERT(DECIMAL(18, 0), vs.available_bytes / 1073741824.0) AS [FreeSize(GB)],
    -- Tính toán phần trăm dung lượng trống
    CAST(vs.available_bytes * 100.0 / vs.total_bytes AS DECIMAL(5, 2)) AS [FreePercent]
FROM
    sys.master_files AS mf
CROSS APPLY
    sys.dm_os_volume_stats(mf.database_id, mf.file_id) AS vs
ORDER BY
    vs.volume_mount_point;
```