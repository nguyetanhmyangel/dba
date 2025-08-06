### 1. Tải và cài đặt script của Ola Hallengren

Truy cập trang chính thức:

🔗 https://ola.hallengren.com

Nhấn vào mục "Download MaintenanceSolution.sql"

Mở SQL Server Management Studio (SSMS) → chạy file MaintenanceSolution.sql trên Database [master]. Sau khi chạy, nó sẽ tạo ra:

- Các stored procedure trong master

- Các job trong SQL Server Agent (nếu chọn cài đặt job)

- Một bảng CommandLog để ghi log chạy job

### 2. Cấu trúc các procedure sau khi cài đặt

| Stored Procedure         | Chức năng                                                               |
| ------------------------ | ----------------------------------------------------------------------- |
| `IndexOptimize`          | Tái cấu trúc hoặc rebuild index (tự động quyết định theo fragmentation) |
| `DatabaseIntegrityCheck` | Kiểm tra tính toàn vẹn dữ liệu                                          |
| `CommandLog`             | Ghi lại lịch sử chạy các command                                        |
| `CommandExecute`         | Thực thi command chính có log                                           |

### 3. Rebuild hoặc Reorganize Index

Chạy câu lệnh dưới đây thủ công để rebuild index cho toàn bộ database:

```bash
EXECUTE dbo.IndexOptimize
    @Databases = 'YourDatabaseName',
    @FragmentationLow = NULL,
    @FragmentationMedium = 'INDEX_REORGANIZE',
    @FragmentationHigh = 'INDEX_REBUILD',
    @FragmentationLevel1 = 5,
    @FragmentationLevel2 = 30,
    @UpdateStatistics = 'ALL'
```

Giải thích các tham số:

- @Databases = 'YourDatabaseName': thay bằng tên database cụ thể hoặc 'ALL_USER_DATABASES'

- @FragmentationLevel1 = 5: nếu fragmentation > 5% → bắt đầu xử lý

- @FragmentationLevel2 = 30: nếu fragmentation > 30% thì rebuild, còn 5–30% thì reorganize

- @UpdateStatistics = 'ALL': cập nhật statistics sau khi xử lý index

- USER_DATABASES: tất cả các database do bạn tạo (không bao gồm master, msdb, tempdb…)

- Phân loại fragment:

    1. Low: bỏ qua

    2. Medium (>5%, <30%): REORGANIZE

    3. High (>30%): REBUILD

### 4. Rebuild hoặc Reorganize Index cho các Db xác định

```bash
EXECUTE dbo.IndexOptimize
    @Databases = 'XYZ,ABC',
    @FragmentationLow = NULL,
    @FragmentationMedium = 'INDEX_REORGANIZE',
    @FragmentationHigh = 'INDEX_REBUILD_ONLINE',
    @FragmentationLevel1 = 5,
    @FragmentationLevel2 = 30,
    @UpdateStatistics = 'ALL'
```

- Nếu muốn rebuild offline sửa dòng @FragmentationHigh = 'INDEX_REBUILD_OFFLINE'

- Nếu muốn xử lý luôn cả các index nhỏ, chỉ cần đặt @MinNumberOfPages = 0 hoặc giá trị nhỏ hơn:

```bash
EXECUTE dbo.IndexOptimize
    @Databases = 'YourDatabaseName',
    @FragmentationLow = NULL,
    @FragmentationMedium = 'INDEX_REORGANIZE',
    @FragmentationHigh = 'INDEX_REBUILD_ONLINE',
    @FragmentationLevel1 = 5,
    @FragmentationLevel2 = 30,
    @MinNumberOfPages = 0, -- Xử lý cả index nhỏ
    @UpdateStatistics = 'ALL';
```

### 5. Kiểm tra toàn vẹn database (CHECKDB)

EXECUTE dbo.DatabaseIntegrityCheck
@Databases = 'USER_DATABASES',
@LogToTable = 'Y';


### 6. Backup FULL

EXECUTE dbo.DatabaseBackup
@Databases = 'USER_DATABASES',
@BackupType = 'FULL',
@BackupDirectory = 'D:\SQLBackups\Full',
@CleanupTime = 168,  -- xóa file cũ sau 7 ngày
@LogToTable = 'Y';


### 7. Backup Differential

EXECUTE dbo.DatabaseBackup
@Databases = 'USER_DATABASES',
@BackupType = 'DIFF',
@BackupDirectory = 'D:\SQLBackups\Diff',
@CleanupTime = 72,
@LogToTable = 'Y';


### 8. Backup LOG

EXECUTE dbo.DatabaseBackup
@Databases = 'USER_DATABASES',
@BackupType = 'LOG',
@BackupDirectory = 'D:\SQLBackups\Log',
@CleanupTime = 48,
@LogToTable = 'Y';

- Chú ý: chỉ chạy backup LOG nếu database ở chế độ FULL hoặc BULK_LOGGED.

