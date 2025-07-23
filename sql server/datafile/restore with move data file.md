# Logical File Name và Đường dẫn gốc từ backup
```bash
RESTORE FILELISTONLY FROM DISK = N'E:\backup\YOUR-DB.bak';
```

# Restore db từ kết quả câu query trên
```bash
RESTORE DATABASE [YOUR-DB]
FROM DISK = N'E:\backup\YOUR-DB.bak'
WITH 
    MOVE 'YOUR-DB' TO 'E:\data\YOUR-DB.mdf',
    MOVE 'YOUR-DB_log' TO 'E:\data\YOUR-DB.ldf',
    REPLACE,
    STATS = 10;
```