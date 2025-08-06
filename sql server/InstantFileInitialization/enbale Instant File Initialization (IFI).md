### 1. Tác dụng của Instant File Initialization

| Tác vụ                       | Tăng tốc khi bật IFI                      |
| ---------------------------- | ----------------------------------------- |
| Tạo database mới             | Rất nhanh                                 |
| Tạo tempdb khi khởi động     | Nhanh hơn nhiều                           |
| Tạo thêm data file           | Nhanh                                     |
| Restore database (data file) | Nhanh hơn                                 |
| **Log file**                 | Không ảnh hưởng (log vẫn bị zeroed out)   |

### 2.Xác định tài khoản dịch vụ của SQL Server

SELECT servicename, service_account
FROM sys.dm_server_services
WHERE servicename LIKE 'SQL Server (%';

### 3.Kiểm tra đã bật chưa (SQL Server 2016+)

SELECT
    servicename,
    instant_file_initialization_enabled AS [IFI_enable]
FROM sys.dm_server_services
WHERE servicename LIKE 'SQL Server (%';

### 4. Cấp quyền “Perform volume maintenance tasks”

Để bật Instant File Initialization (IFI) trong SQL Server cần cấp quyền “Perform Volume Maintenance Tasks” cho tài khoản chạy SQL Server service.

- Chạy lệnh secpol.msc (Local Security Policy)

- Vào: Local Policies → User Rights Assignment → Tìm mục: Perform volume maintenance tasks

- Double-click → Add User or Group

- Nhập tài khoản SQL Server (ví dụ: NT SERVICE\MSSQLSERVER hoặc DOMAIN\sqlsvc)

- Bấm OK → Khởi động lại dịch vụ SQL Server để có hiệu lực