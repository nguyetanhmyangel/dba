### 1. Chạy script này ở primary. Copy kết quả và chạy ở secondary.

backup tất cả login trên SQL Server, bao gồm:

- SQL Login: kèm theo SID, PASSWORD_HASH, DEFAULT_DATABASE, CHECK_POLICY, CHECK_EXPIRATION, DISABLE.

- Windows Login & Windows Group: tạo lại bằng CREATE LOGIN ... FROM WINDOWS.


```bash
SET NOCOUNT ON;

PRINT '/*================================================================================*/';
PRINT '/* Robust Script to Synchronize Logins, Roles, and Permissions             */';
PRINT '/* (No GO statements in generated output)                                  */';
PRINT '/* Generated on: ' + CONVERT(nvarchar(20), GETDATE(), 120) + '                                       */';
PRINT '/*================================================================================*/';
PRINT '';
PRINT 'USE [master];';
-- Lưu ý: Không còn GO ở đây để toàn bộ output là 1 khối

-- 1. SQL Logins (Logic Drop/Create để đảm bảo đồng bộ SID)
PRINT '-- ==== Section 1: SQL Logins (Ensuring SID synchronization) ====';
SELECT
    -- Logic chính: Nếu login tồn tại bằng TÊN...
    'IF EXISTS (SELECT name FROM sys.server_principals WHERE name = N''' + sp.name COLLATE DATABASE_DEFAULT + ''')' + CHAR(13) + CHAR(10) +
    'BEGIN' + CHAR(13) + CHAR(10) +
    -- ... thì kiểm tra xem SID có khớp không.
    '    IF (SELECT sid FROM sys.server_principals WHERE name = N''' + sp.name COLLATE DATABASE_DEFAULT + ''') <> ' + CONVERT(NVARCHAR(MAX), sp.sid, 1) + CHAR(13) + CHAR(10) +
    '    BEGIN' + CHAR(13) + CHAR(10) +
    -- Nếu SID không khớp, tạo lại login.
    '        PRINT ''SID mismatch for [' + sp.name COLLATE DATABASE_DEFAULT + ']. Re-creating login...'';' + CHAR(13) + CHAR(10) +
    '        DROP LOGIN [' + sp.name COLLATE DATABASE_DEFAULT + '];' + CHAR(13) + CHAR(10) +
    '        CREATE LOGIN [' + sp.name COLLATE DATABASE_DEFAULT + '] WITH PASSWORD = ' + CONVERT(NVARCHAR(MAX), sl.password_hash, 1) +
    ' HASHED, SID = ' + CONVERT(NVARCHAR(MAX), sp.sid, 1) + ', DEFAULT_DATABASE = [' + sp.default_database_name COLLATE DATABASE_DEFAULT + ']' +
    CASE WHEN sl.is_policy_checked = 1 THEN ', CHECK_POLICY = ON' ELSE ', CHECK_POLICY = OFF' END +
    CASE WHEN sl.is_expiration_checked = 1 THEN ', CHECK_EXPIRATION = ON' ELSE ', CHECK_EXPIRATION = OFF' END +
    ';' + CHAR(13) + CHAR(10) +
    '    END' + CHAR(13) + CHAR(10) +
    'END' + CHAR(13) + CHAR(10) +
    -- Nếu login không tồn tại bằng TÊN, tạo mới.
    'ELSE' + CHAR(13) + CHAR(10) +
    'BEGIN' + CHAR(13) + CHAR(10) +
    '    PRINT ''Creating new login [' + sp.name COLLATE DATABASE_DEFAULT + ']...'';' + CHAR(13) + CHAR(10) +
    '    CREATE LOGIN [' + sp.name COLLATE DATABASE_DEFAULT + '] WITH PASSWORD = ' + CONVERT(NVARCHAR(MAX), sl.password_hash, 1) +
    ' HASHED, SID = ' + CONVERT(NVARCHAR(MAX), sp.sid, 1) + ', DEFAULT_DATABASE = [' + sp.default_database_name COLLATE DATABASE_DEFAULT + ']' +
    CASE WHEN sl.is_policy_checked = 1 THEN ', CHECK_POLICY = ON' ELSE ', CHECK_POLICY = OFF' END +
    CASE WHEN sl.is_expiration_checked = 1 THEN ', CHECK_EXPIRATION = ON' ELSE ', CHECK_EXPIRATION = OFF' END +
    ';' + CHAR(13) + CHAR(10) +
    'END;' + CHAR(13) + CHAR(10) +
    -- Luôn áp dụng trạng thái disable/enable để đảm bảo đồng bộ
    CASE WHEN sp.is_disabled = 1 THEN 'ALTER LOGIN [' + sp.name COLLATE DATABASE_DEFAULT + '] DISABLE;' ELSE 'ALTER LOGIN [' + sp.name COLLATE DATABASE_DEFAULT + '] ENABLE;' END
FROM sys.sql_logins sl
JOIN sys.server_principals sp ON sl.principal_id = sp.principal_id
WHERE sp.type = 'S' AND sp.name NOT LIKE '##%' AND sp.name <> 'sa';

PRINT '';

-- 2. Windows Logins and Groups (Logic IF NOT EXISTS là đủ)
PRINT '-- ==== Section 2: Windows Logins and Groups ====';
SELECT
    'IF NOT EXISTS (SELECT name FROM sys.server_principals WHERE name = N''' + name COLLATE DATABASE_DEFAULT + ''')' + CHAR(13) + CHAR(10) +
    'BEGIN' + CHAR(13) + CHAR(10) +
    '    CREATE LOGIN [' + name COLLATE DATABASE_DEFAULT + '] FROM WINDOWS;' + CHAR(13) + CHAR(10) +
    'END;'
FROM sys.server_principals
WHERE type IN ('U', 'G') AND name NOT LIKE '##%' AND name NOT LIKE 'NT AUTHORITY\%' AND name NOT LIKE 'NT SERVICE\%' AND name NOT LIKE 'BUILTIN\%';

PRINT '';

-- 3. Server-level Role Members
PRINT '-- ==== Section 3: Server Role Memberships ====';
SELECT
    'IF NOT EXISTS (SELECT 1 FROM sys.server_role_members rm JOIN sys.server_principals rol ON rm.role_principal_id = rol.principal_id JOIN sys.server_principals lgn ON rm.member_principal_id = lgn.principal_id WHERE rol.name = N''' + rol.name COLLATE DATABASE_DEFAULT + ''' AND lgn.name = N''' + lgn.name COLLATE DATABASE_DEFAULT + ''')' + CHAR(13) + CHAR(10) +
    'BEGIN' + CHAR(13) + CHAR(10) +
    '    ALTER SERVER ROLE [' + rol.name COLLATE DATABASE_DEFAULT + '] ADD MEMBER [' + lgn.name COLLATE DATABASE_DEFAULT + '];' + CHAR(13) + CHAR(10) +
    'END;'
FROM sys.server_role_members rm
JOIN sys.server_principals rol ON rm.role_principal_id = rol.principal_id
JOIN sys.server_principals lgn ON rm.member_principal_id = lgn.principal_id
WHERE lgn.type IN ('S', 'U', 'G') AND lgn.name NOT LIKE '##%' AND lgn.name NOT LIKE 'NT AUTHORITY\%' AND lgn.name NOT LIKE 'NT SERVICE\%' AND lgn.name NOT LIKE 'BUILTIN\%' AND lgn.name <> 'sa';

PRINT '';

-- 4. Server-level Permissions
PRINT '-- ==== Section 4: Server-level Permissions ====';
SELECT
    perm.state_desc COLLATE DATABASE_DEFAULT + ' ' + perm.permission_name COLLATE DATABASE_DEFAULT + ' TO [' + prin.name COLLATE DATABASE_DEFAULT + '];'
FROM sys.server_permissions perm
JOIN sys.server_principals prin ON perm.grantee_principal_id = prin.principal_id
WHERE prin.type IN ('S', 'U', 'G') AND prin.name NOT LIKE '##%' AND prin.name NOT LIKE 'NT AUTHORITY\%' AND prin.name NOT LIKE 'NT SERVICE\%' AND prin.name NOT LIKE 'BUILTIN\%' AND prin.name <> 'sa';
```

### 2. Câu lệnh kiểm tra Orphan User trong tất cả DB

```bash
-- Tạo một bảng tạm để lưu kết quả
IF OBJECT_ID('tempdb..#OrphanedUsers') IS NOT NULL
    DROP TABLE #OrphanedUsers;
CREATE TABLE #OrphanedUsers (
    DatabaseName sysname,
    UserName sysname,
    UserSID VARBINARY(85)
);

-- Dùng sp_MSforeachdb để chạy lệnh trong mỗi database
EXEC sp_MSforeachdb '
USE [?];
INSERT INTO #OrphanedUsers (DatabaseName, UserName, UserSID)
SELECT
    DB_NAME() AS DatabaseName,
    dp.name AS UserName,
    dp.sid AS UserSID
FROM
    sys.database_principals AS dp
LEFT JOIN
    sys.server_principals AS sp ON dp.sid = sp.sid
WHERE
    sp.sid IS NULL -- Điều kiện chính: không tìm thấy login tương ứng ở cấp server
    AND dp.authentication_type_desc = ''INSTANCE'' -- Chỉ áp dụng cho user SQL, không phải Windows
    AND dp.principal_id > 4; -- Bỏ qua các user hệ thống
';

-- Hiển thị kết quả
SELECT * FROM #OrphanedUsers;
```

### 3. Tự động Fix Orphan User

```bash
-- Script này sẽ tạo và thực thi các lệnh "ALTER USER" để sửa lỗi
EXEC sp_MSforeachdb '
USE [?];
DECLARE @UserName sysname;
DECLARE OrphanUserCursor CURSOR FOR
SELECT
    dp.name
FROM
    sys.database_principals AS dp
LEFT JOIN
    sys.server_principals AS sp ON dp.sid = sp.sid
WHERE
    sp.sid IS NULL
    AND dp.authentication_type_desc = ''INSTANCE''
    AND dp.principal_id > 4
    AND EXISTS ( -- Chỉ lấy những user có login cùng tên tồn tại ở cấp server
        SELECT 1 FROM sys.server_principals WHERE name = dp.name
    );

OPEN OrphanUserCursor;
FETCH NEXT FROM OrphanUserCursor INTO @UserName;

WHILE @@FETCH_STATUS = 0
BEGIN
    DECLARE @Command NVARCHAR(500);
    SET @Command = N''ALTER USER ['' + @UserName + ''] WITH LOGIN = ['' + @UserName + '']'';
    
    PRINT ''Fixing user ['' + @UserName + ''] in database ['' + DB_NAME() + '']...'';
    PRINT @Command;
    
    EXEC sp_executesql @Command;
    
    FETCH NEXT FROM OrphanUserCursor INTO @UserName;
END;

CLOSE OrphanUserCursor;
DEALLOCATE OrphanUserCursor;
';

PRINT 'Finished fixing orphaned users.';
```