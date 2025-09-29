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
# Phân quyền owner cho tất cả các db trong instance:
```bash
DECLARE @db NVARCHAR(128);
DECLARE @sql NVARCHAR(MAX);

DECLARE db_cursor CURSOR FOR
SELECT name
FROM sys.databases
WHERE state_desc = 'ONLINE'
  AND name NOT IN ('master','model','msdb','tempdb');  -- loại trừ các db hệ thống

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @db;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'
USE [' + @db + '];

-- Tạo user nếu chưa có
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N''lacviet_migration'')
    CREATE USER [lacviet_migration] FOR LOGIN [lacviet_migration];

-- Thêm vào db_owner nếu chưa có
IF NOT EXISTS (
    SELECT 1
    FROM sys.database_role_members rm
    JOIN sys.database_principals r ON rm.role_principal_id = r.principal_id
    JOIN sys.database_principals u ON rm.member_principal_id = u.principal_id
    WHERE r.name = N''db_owner''
      AND u.name = N''lacviet_migration''
)
    ALTER ROLE [db_owner] ADD MEMBER [lacviet_migration];
';

    PRINT @sql;           -- chỉ để kiểm tra trước
    EXEC (@sql);          -- bỏ comment nếu muốn thực thi
    FETCH NEXT FROM db_cursor INTO @db;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;
```

# Phân quyền chỉ đọc:
```bash
USE YourDatabase;
GO
GRANT SELECT ON dbo.MyView TO app_user;
```

# Phân quyền read and crud:
```bash
USE YourDatabase;
GO
GRANT SELECT, INSERT, UPDATE, DELETE ON dbo.MyTable TO app_user;
```

# Phân quyền cho 1 schema:
```bash
GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA::dbo TO app_user;
```

# Thu hồi quyền:
```bash
REVOKE SELECT, INSERT, UPDATE, DELETE ON dbo.MyTable FROM app_user;
```
