#### Page Verification TORN_PAGE_DETECTION: 
- Cơ chế cũ để phát hiện page bị ghi dở dang/corruption nên đổi sang CHECKSUM để kiểm tra tính toàn vẹn page tốt hơn.

```sql
ALTER DATABASE [thluong]
SET PAGE_VERIFY CHECKSUM
WITH NO_WAIT;
GO
```

```sql
USE [master];
GO

SET NOCOUNT ON;

DECLARE 
    @DatabaseName sysname,
    @SQL          nvarchar(MAX);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name
FROM sys.databases
WHERE page_verify_option_desc = N'TORN_PAGE_DETECTION'
  AND state_desc = N'ONLINE'
  AND is_read_only = 0
  AND name <> N'tempdb';

OPEN db_cursor;

FETCH NEXT FROM db_cursor INTO @DatabaseName;

WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY

        SET @SQL =
            N'ALTER DATABASE ' + QUOTENAME(@DatabaseName) +
            N' SET PAGE_VERIFY CHECKSUM WITH NO_WAIT;';

        PRINT N'Đang xử lý: ' + QUOTENAME(@DatabaseName);

        EXEC sys.sp_executesql @SQL;

        PRINT N'  -> OK: ' + QUOTENAME(@DatabaseName);

    END TRY
    BEGIN CATCH

        PRINT N'  -> FAILED: ' + QUOTENAME(@DatabaseName);
        PRINT N'  -> Error ' 
            + CONVERT(nvarchar(20), ERROR_NUMBER())
            + N': ' + ERROR_MESSAGE();

    END CATCH;

    FETCH NEXT FROM db_cursor INTO @DatabaseName;
END;

CLOSE db_cursor;
DEALLOCATE db_cursor;
GO
```

#### Recovery Interval TARGET_RECOVERY_TIME = 0: Đang dùng cơ chế recovery legacy. 
Nên đặt 60 seconds để SQL Server kiểm soát checkpoint/recovery theo mục tiêu hiện đại hơn.

```sql
ALTER DATABASE [YourDb] 
SET TARGET_RECOVERY_TIME = 60 SECONDS;
GO
```

```SQL
USE [master];
GO

DECLARE
    @DatabaseName sysname,
    @SQL nvarchar(MAX);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name
FROM sys.databases
WHERE target_recovery_time_in_seconds = 0
  AND state_desc = N'ONLINE'
  AND is_read_only = 0
  AND database_id > 4; -- Chỉ user database

OPEN db_cursor;

FETCH NEXT FROM db_cursor INTO @DatabaseName;

WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY

        SET @SQL =
            N'ALTER DATABASE ' + QUOTENAME(@DatabaseName) +
            N' SET TARGET_RECOVERY_TIME = 60 SECONDS;';

        PRINT N'Đang xử lý: ' + QUOTENAME(@DatabaseName);

        EXEC sys.sp_executesql @SQL;

        PRINT N'  -> OK';

    END TRY
    BEGIN CATCH

        PRINT N'  -> FAILED: '
            + CONVERT(nvarchar(20), ERROR_NUMBER())
            + N' - '
            + ERROR_MESSAGE();

    END CATCH;

    FETCH NEXT FROM db_cursor INTO @DatabaseName;
END;

CLOSE db_cursor;
DEALLOCATE db_cursor;
GO
```
