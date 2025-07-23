# Bước 1: Tạo login (nếu chưa có):
```bash
CREATE LOGIN [sqluser2] WITH PASSWORD = 'YourStrongPassword123!';
```
# Bước 2: Tạo user trong database:
```bash
USE [YourDatabaseName];
CREATE USER [sqluser2] FOR LOGIN [sqluser2];
```

# Bước 3: Thêm vào role db_owner:
```bash
ALTER ROLE db_owner ADD MEMBER [sqluser2];
```