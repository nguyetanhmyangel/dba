# 1. Kiểm tra file
```bash
SELECT name, physical_name 
FROM sys.master_files 
WHERE database_id = DB_ID('YOUR-DB');
```

# 2. Ngắt kết nối tạm thời
```bash
ALTER DATABASE YOUR-DB SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
```

# 3. Tách DB
```bash
EXEC sp_detach_db 'YOUR-DB';
```

# 4. (Thực hiện thủ công: Di chuyển file .mdf và .ldf sang D:\data)

# 5. Gắn lại DB
```bash
CREATE DATABASE YOUR-DB
ON 
( FILENAME = 'D:\data\YOUR-DB.mdf' ),
( FILENAME = 'D:\data\YOUR-DB_log.ldf' )
FOR ATTACH;
```

# 6. Khôi phục chế độ multi-user
```bash
ALTER DATABASE YOUR-DB SET MULTI_USER;
```
