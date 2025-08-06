### 1.Tính toán và đề xuất số lượng file data (ROWS) cho TempDB , dựa trên khuyến nghị chuẩn của Microsoft (theo số core logic).

 * QUY TẮC ÁP DỤNG:

    - Nếu số core logic <= 8: Số file khuyến nghị = Số core logic.

    - Nếu số core logic > 8: Số file khuyến nghị = 8.


```bash
SET NOCOUNT ON;

-- Khai báo các biến cần thiết
DECLARE @LogicalCPUCount INT;
DECLARE @CurrentTempDBFileCount INT;
DECLARE @RecommendedFileCount INT;
DECLARE @RecommendationNote NVARCHAR(1000);

-- 1. Lấy thông tin cấu hình từ hệ thống
SELECT @LogicalCPUCount = cpu_count FROM sys.dm_os_sys_info;

-- Đếm số file data (ROWS) hiện có của TempDB
SELECT @CurrentTempDBFileCount = COUNT(*) FROM tempdb.sys.database_files WHERE type_desc = 'ROWS';

-- 2. Áp dụng logic khuyến nghị
IF @LogicalCPUCount <= 8
BEGIN
    SET @RecommendedFileCount = @LogicalCPUCount;
    SET @RecommendationNote = N'Server có ' + CAST(@LogicalCPUCount AS NVARCHAR(3)) + N' core (<= 8), khuyến nghị cấu hình 1 file data cho mỗi core.';
END
ELSE -- @LogicalCPUCount > 8
BEGIN
    SET @RecommendedFileCount = 8;
    SET @RecommendationNote = N'Server có ' + CAST(@LogicalCPUCount AS NVARCHAR(3)) + N' core (> 8), khuyến nghị bắt đầu với 8 file data. Nếu vẫn còn contention, bạn có thể tăng thêm theo bội số của 4.';
END

-- 3. Đưa ra kết luận và hướng dẫn
SELECT
    @LogicalCPUCount AS [So_Core_Logic_Phat_Hien],
    @CurrentTempDBFileCount AS [So_File_TempDB_Hien_Tai],
    @RecommendedFileCount AS [==> So_File_Khuyen_Nghi <==],
    @RecommendationNote AS [Ghi_Chu];

-- Hướng dẫn thêm về cách áp dụng thay đổi
IF @CurrentTempDBFileCount <> @RecommendedFileCount
BEGIN
    PRINT N'-------------------------------------------------------------------------------------------------';
    PRINT N'HƯỚNG DẪN THAY ĐỔI:';
    PRINT N'Cấu hình hiện tại của bạn (' + CAST(@CurrentTempDBFileCount AS NVARCHAR(3)) + N' file) chưa tối ưu. Bạn cần thay đổi thành ' + CAST(@RecommendedFileCount AS NVARCHAR(3)) + N' file.';
    PRINT N'LƯU Ý QUAN TRỌNG: Tất cả các file data của TempDB phải có CÙNG KÍCH THƯỚC BAN ĐẦU và CÙNG MỨC AUTOGROWTH.';
    PRINT N'Ví dụ: Để thêm 1 file mới tên tempdev2 với kích thước 1024MB, dùng lệnh sau:';
    PRINT N'
USE [master];
GO
ALTER DATABASE [tempdb]
ADD FILE (NAME = N''tempdev2'', FILENAME = N''D:\SQLData\tempdev2.ndf'', SIZE = 1024MB, FILEGROWTH = 512MB);
GO
';
    PRINT N'(Hãy thay đổi ĐƯỜNG DẪN và KÍCH THƯỚC cho phù hợp với hệ thống của bạn).';
    PRINT N'-------------------------------------------------------------------------------------------------';
END
ELSE
BEGIN
    PRINT N'-------------------------------------------------------------------------------------------------';
    PRINT N'XIN CHÚC MỪNG! Cấu hình số lượng file TempDB của bạn đã tối ưu theo khuyến nghị.';
    PRINT N'-------------------------------------------------------------------------------------------------';
END
GO

```

### 2. Add tempdb file

```bash
--- xem cấu hình hiện tại
SELECT name, type_desc, physical_name, size * 8 / 1024 AS size_MB
FROM tempdb.sys.database_files;

--- thêm 1 file mới
ALTER DATABASE tempdb 
ADD FILE (NAME = tempdev1, FILENAME = 'G:\TempDB_3D\tempdb1.ndf',SIZE = 1204MB, FILEGROWTH = 1024MB
);
```