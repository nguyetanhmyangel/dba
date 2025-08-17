### TỐI ƯU ORGANIZE,REBUILD INDEX  CHO ALWAYS ON

- Sử dụng OLA HALLENGREN's script
- Chỉ chạy trên PRIMARY replica.
- Chỉ tác động lên các DB ONLINE, không phải DB hệ thống trong AG.
- Chỉ chuyển sang BULK_LOGGED cho các DB thực sự có index cần bảo trì.
- Không có PRINT, output được ghi vào dbo.CommandLog.
- Sẵn sàng để sử dụng trong SQL Agent Job.

```bash
*/
SET NOCOUNT ON;

-- Chỉ chạy nếu server này là PRIMARY replica
IF (SELECT ar.role_desc FROM sys.dm_hadr_availability_replica_states ars JOIN sys.availability_replicas ar ON ars.replica_id = ar.replica_id WHERE ar.replica_server_name = @@SERVERNAME AND ars.is_local = 1) = 'PRIMARY'
BEGIN
    -- Bảng tạm chứa các DB cần được kiểm tra
    CREATE TABLE #EligibleAGDBs (DatabaseName sysname PRIMARY KEY);

    INSERT INTO #EligibleAGDBs (DatabaseName)
    SELECT d.name
    FROM sys.databases d
    INNER JOIN sys.dm_hadr_database_replica_states rs ON d.database_id = rs.database_id
    WHERE d.database_id > 4 AND d.state_desc = 'ONLINE' AND rs.is_local = 1 AND rs.is_primary_replica = 1;

    -- Bảng tạm chỉ chứa các DB thực sự có index cần bảo trì
    CREATE TABLE #DBsToMaintain (DatabaseName sysname PRIMARY KEY);

    DECLARE @dbName sysname;
    DECLARE @sqlCheck NVARCHAR(MAX);

    -- Vòng lặp để kiểm tra và xác định DB nào cần bảo trì
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR SELECT DatabaseName FROM #EligibleAGDBs;
    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @dbName;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @sqlCheck = N'USE [' + @dbName + N']; 
                         IF EXISTS (SELECT 1 
                                    FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, ''SAMPLED'') ips 
                                    WHERE ips.avg_fragmentation_in_percent > 5 AND ips.page_count > 1000 AND ips.index_id > 0)
                         BEGIN
                             INSERT INTO #DBsToMaintain (DatabaseName) VALUES (''' + @dbName + N''');
                         END';
        EXEC sp_executesql @sqlCheck;
        FETCH NEXT FROM db_cursor INTO @dbName;
    END
    CLOSE db_cursor;
    DEALLOCATE db_cursor;

    -- Chỉ thực hiện các bước tiếp theo nếu có DB cần bảo trì
    IF (SELECT COUNT(*) FROM #DBsToMaintain) > 0
    BEGIN
        DECLARE @dbList NVARCHAR(MAX);
        -- Tạo danh sách DB dạng '[DB1],[DB2]' để truyền vào IndexOptimize
        SELECT @dbList = STRING_AGG(QUOTENAME(DatabaseName), ',') FROM #DBsToMaintain;

        BEGIN TRY
            -- Bước 1: Chuyển các DB cần thiết sang BULK_LOGGED
            DECLARE maint_cursor CURSOR LOCAL FAST_FORWARD FOR SELECT DatabaseName FROM #DBsToMaintain;
            OPEN maint_cursor;
            FETCH NEXT FROM maint_cursor INTO @dbName;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                EXEC(N'ALTER DATABASE ' + QUOTENAME(@dbName) + N' SET RECOVERY BULK_LOGGED');
                FETCH NEXT FROM maint_cursor INTO @dbName;
            END
            CLOSE maint_cursor;
            DEALLOCATE maint_cursor;

            -- Bước 2: Chạy IndexOptimize một lần duy nhất cho các DB trong danh sách
            EXECUTE [dbo].[IndexOptimize]
                @Databases = @dbList,
                @FragmentationLow = NULL,
                @FragmentationMedium = 'INDEX_REORGANIZE',
                @FragmentationHigh = 'INDEX_REBUILD_ONLINE,INDEX_REBUILD_OFFLINE',
                @FragmentationLevel1 = 5,
                @FragmentationLevel2 = 30,
                @MinNumberOfPages = 1000,
                @SortInTempdb = 'Y',
                @UpdateStatistics = NULL,
                @LogToTable = 'Y';

            -- Bước 3 & 4: Chuyển về FULL và sao lưu Log
            DECLARE maint_cursor CURSOR LOCAL FAST_FORWARD FOR SELECT DatabaseName FROM #DBsToMaintain;
            OPEN maint_cursor;
            FETCH NEXT FROM maint_cursor INTO @dbName;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                EXEC(N'ALTER DATABASE ' + QUOTENAME(@dbName) + N' SET RECOVERY FULL');
                EXEC(N'BACKUP LOG ' + QUOTENAME(@dbName) + N' TO DISK = N''NUL:''');
                FETCH NEXT FROM maint_cursor INTO @dbName;
            END
            CLOSE maint_cursor;
            DEALLOCATE maint_cursor;
        END TRY
        BEGIN CATCH
            -- Xử lý lỗi: Cố gắng chuyển các DB về lại FULL
            IF CURSOR_STATUS('local', 'maint_cursor') >= 0
            BEGIN
                DEALLOCATE maint_cursor;
            END
            DECLARE error_cursor CURSOR LOCAL FAST_FORWARD FOR SELECT DatabaseName FROM #DBsToMaintain;
            OPEN error_cursor;
            FETCH NEXT FROM error_cursor INTO @dbName;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                IF (SELECT recovery_model_desc FROM sys.databases WHERE name = @dbName) <> 'FULL'
                BEGIN
                    EXEC(N'ALTER DATABASE ' + QUOTENAME(@dbName) + N' SET RECOVERY FULL');
                END
                FETCH NEXT FROM error_cursor INTO @dbName;
            END
            CLOSE error_cursor;
            DEALLOCATE error_cursor;
            -- Ném lỗi ra để Job báo FAILED
            THROW;
        END CATCH
    END

    DROP TABLE #EligibleAGDBs;
    DROP TABLE #DBsToMaintain;
END
```