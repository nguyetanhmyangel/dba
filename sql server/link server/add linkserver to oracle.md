### Để kết nối được từ Linked Server như câu hỏi trước, nội dung cần có một entry (bí danh) như sau trong tnsnames.ora:

# Tên Alias (dùng để điền vào @datasrc của Linked Server)

```
ORACLE_DB_ALIAS =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = 172.18.15.56)(PORT = 1521))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = ORCL) # Hỏi DBA để lấy Service Name đúng
    )
  )
```
 
### Tạo link server:

```sql
/* 1. Tạo Linked Server */
EXEC sp_addlinkedserver
    @server     = N'ORACLE_DB_ALIAS',          -- Tên Linked Server trong SQL Server
    @srvproduct = N'Oracle',
    @provider   = N'OraOLEDB.Oracle',  -- Provider chuẩn
    @datasrc    = N'ORACLE_DB_ALIAS';          -- Trùng với tên trong tnsnames.ora
GO

/* 2. Cấu hình bảo mật (Security) */
EXEC sp_addlinkedsrvlogin
    @rmtsrvname = N'ORACLE_DB_ALIAS',
    @useself    = 'False',
    @locallogin = NULL,                -- Map tất cả user SQL
    @rmtuser    = N'user_name_remote',             -- User Oracle
    @rmtpassword= N'user_password_remote';         -- Pass Oracle
GO

/* 3. Cấu hình RPC (Khuyên dùng để gọi được Store Procedure hoặc lệnh phức tạp) */
EXEC sp_serveroption @server=N'ORACLE_DB_ALIAS', @optname=N'rpc', @optvalue=N'true'
EXEC sp_serveroption @server=N'ORACLE_DB_ALIAS', @optname=N'rpc out', @optvalue=N'true'
GO 
```

### Select example:

```sql
SELECT * FROM OPENQUERY(ORACLE_DB_ALIAS, 'SELECT * FROM APPLSYS.FND_USER');

SELECT * INTO dbo.FND_USER
FROM OPENQUERY(ERP_PROD, 'SELECT * FROM APPLSYS.FND_USER');
```