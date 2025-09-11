#### 1. Kiểm tra quyền user và cấp quyền


- Để user có quyền tạo linkser ta cần quyền ALTER ANY LINKED SERVER và SERVER ROLE setupadmin.

- Kiểm tra quyền user: 

```bash
DECLARE @LoginName sysname = 'MyUser';

SELECT
    @LoginName AS [LoginName],
    -- Kiểm tra quyền ALTER ANY LINKED SERVER
    CASE 
        WHEN p.state_desc = 'GRANT' THEN 'Yes'
        ELSE 'No'
    END AS [Has_ALTER_ANY_LINKED_SERVER_Permission],
    
    -- Kiểm tra tư cách thành viên trong vai trò setupadmin
    CASE 
        WHEN IS_SRVROLEMEMBER('setupadmin', @LoginName) = 1 THEN 'Yes'
        ELSE 'No'
    END AS [Is_Member_Of_setupadmin_Role]
FROM
    sys.server_principals sp
LEFT JOIN
    sys.server_permissions p ON sp.principal_id = p.grantee_principal_id
WHERE
    sp.name = @LoginName
    AND (p.permission_name = 'ALTER ANY LINKED SERVER' OR p.permission_name IS NULL);
```
- Cấp quyền:

```bash
-- Cấp quyền quản lý đối tượng linked server
GRANT ALTER ANY LINKED SERVER TO [MyUser];

-- Cấp quyền thực thi các thủ tục cấu hình liên quan
ALTER SERVER ROLE setupadmin ADD MEMBER [MyUser];
```

- Kiểm tra các quyền khác

```bash
SELECT * 
FROM sys.server_permissions
WHERE grantee_principal_id = SUSER_ID('MyUser');
```

hoặc

```bash
DECLARE @UserName SYSNAME = 'MyUser';

SELECT 
    pr.name AS [LoginName],
    sp.permission_name,
    sp.state_desc
FROM sys.server_permissions sp
JOIN sys.server_principals pr ON sp.grantee_principal_id = pr.principal_id
WHERE pr.name = @UserName;
```

| permission\_name            | Ý nghĩa                                                                                            |
| --------------------------- | ---------------------------------------------------------------------------------------------------|
| **ALTER ANY LOGIN**         | Tạo, sửa, xóa mọi login (ngoài sysadmin). Cần thiết khi muốn thêm login mapping cho Linked Server. |
| **ALTER ANY LINKED SERVER** | Tạo, sửa, xóa Linked Server.                                                                       |
| **CONNECT SQL**             | Kết nối vào SQL Server.                                                                            |
| **VIEW SERVER STATE**       | Xem DMV, trạng thái server.                                                                        |
| **CONTROL SERVER**          | Quyền này gần giống sysadmin (toàn quyền trên instance), nhưng vẫn không thể:                      |
|                             | - Thêm user vào sysadmin                                                                           |
|                             | - Thay đổi authentication mode                                                                     |

#### 3. Login mapping cho Linked Server

3.1. Khi tạo Linked Server, SQL Server cần biết dùng tài khoản nào để kết nối sang server từ xa. Đây gọi là login mapping.

- Ở local SQL Server: có các login khác nhau (sa, MyUser, user ứng dụng, …).

- Khi user trong local SQL Server truy vấn qua Linked Server (ví dụ SELECT * FROM [LinkedSrv].Db.dbo.Table), SQL Server phải ánh xạ (map) login local đó sang một login remote trên server đích.

3.2. Các kiểu mapping (khi dùng sp_addlinkedsrvlogin):

- Dùng chính login hiện tại (self mapping)

```bash
EXEC sp_addlinkedsrvlogin 
     @rmtsrvname = N'MY_LINKED_SERVER',
     @useself = 'True';
```

→ Login local nào thì dùng đúng login đó bên remote (nếu tồn tại & mật khẩu trùng).

- Dùng một login chung cho tất cả user

```bash
EXEC sp_addlinkedsrvlogin 
     @rmtsrvname = N'MY_LINKED_SERVER',
     @useself = 'False',
     @locallogin = NULL,  -- tất cả user local
     @rmtuser = N'remote_user',
     @rmtpassword = N'P@ssword123';
```

→ Dù login local nào truy vấn, SQL Server cũng kết nối sang remote bằng remote_user.

- Mapping từng login local sang login remote riêng

```bash
EXEC sp_addlinkedsrvlogin 
     @rmtsrvname = N'MY_LINKED_SERVER',
     @useself = 'False',
     @locallogin = N'MyUser',
     @rmtuser = N'remote_user',
     @rmtpassword = N'P@ssword123';
```

→ Chỉ riêng MyUser khi truy vấn qua Linked Server mới map thành remote_user.

Tóm lại: Login mapping = cách xác định local login nào sẽ dùng remote login nào khi đi qua Linked Server.
Nếu không thiết lập mapping, có thể gặp lỗi “Login failed for user …” khi truy vấn Linked Server.

#### 3. Tạo link server

```bash
/* 1. Tạo Linked Server (ví dụ kết nối đến 192.168.1.100) */
EXEC sp_addlinkedserver
    @server     = N'MY_LINKED_SERVER',
    @srvproduct = N'SQL Server',
    @provider   = N'SQLNCLI',     -- hoặc 'SQLNCLI11', 'MSOLEDBSQL' tùy driver
    @datasrc    = N'192.168.1.100';  -- tên hoặc IP SQL Server đích
GO

/* 2. Thêm login mapping cho Linked Server */
/* Tất cả login local đều map sang 1 login remote */
EXEC sp_addlinkedsrvlogin
    @rmtsrvname = N'MY_LINKED_SERVER',
    @useself    = 'False',
    @locallogin = NULL,   -- NULL = tất cả user local, hoặc một login bất kỳ trên máy chủ cục bộ N'MyUser'
    @rmtuser    = N'remote_user', -- Tài khoản trên máy chủ ở xa
    @rmtpassword= N'RemoteP@ssword123';
GO

/* 3. Test query qua Linked Server */
SELECT TOP 10 * 
FROM [MY_LINKED_SERVER].[RemoteDatabase].[dbo].[SomeTable];
GO
```