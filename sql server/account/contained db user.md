### 1. Kích hoạt Contained Database Authentication

- Chạy lệnh dưới trên mọi replica trong AG để đảm bảo chúng đều sẵn sàng cho contained database

-- Kích hoạt tùy chọn nâng cao
sp_configure 'show advanced options', 1;
GO
RECONFIGURE;
GO

-- Kích hoạt Contained Database Authentication
sp_configure 'contained database authentication', 1;
GO
RECONFIGURE;
GO

-- (Tùy chọn) Tắt lại tùy chọn nâng cao cho gọn gàng
sp_configure 'show advanced options', 0;
GO
RECONFIGURE;
GO

-- kiểm tra lại(giá trị value_in_use phải là 1):
SELECT name, value, value_in_use
FROM sys.configurations
WHERE name = 'contained database authentication';


### 2. Chuyển database sang chế độ contained

-- Thay [YourDatabaseName] bằng tên database thực tế
ALTER DATABASE [YourDatabaseName] SET CONTAINMENT = PARTIAL;
GO

