### 1.Backup transaction log:

```bash
EXEC dbo.DatabaseBackup
    @Databases = 'USER_DATABASES',
    --- @ExcludeDatabases = ABC,XYZ',
    @Directory = 'D:\SQLBackups\Log',
    @BackupType = 'LOG',
    @Compress = 'Y',
    @Verify = 'Y',
    @CheckSum = 'Y',
    @CleanupTime = 48, -- 2 ngày
    @CleanupMode = 'AFTER_BACKUP';
```

### 2. Backup diff and UpdateStatistics:

```bash
-- step 1:
EXEC dbo.DatabaseBackup
    @Databases = 'USER_DATABASES',
    --- @ExcludeDatabases = ABC,XYZ',
    @Directory = 'D:\SQLBackups\Diff',
    @BackupType = 'DIFF',
    @Compress = 'Y',
    @Verify = 'Y',
    @CheckSum = 'Y',
    @CleanupTime = 168, -- 7 ngày
    @CleanupMode = 'AFTER_BACKUP';

-- step 2:
EXECUTE dbo.IndexOptimize
    @Databases = 'USER_DATABASES',
    ---@ExcludeDatabases = ABC,XYZ',
    @UpdateStatistics = 'ALL',
    @OnlyModifiedStatistics = 'Y',
    @StatisticsSample = NULL,
    @StatisticsResample = 'N'
```

### 3. Backup full:

```bash
EXEC dbo.DatabaseBackup
    @Databases = 'USER_DATABASES',
    @Directory = 'D:\SQLBackups\Full',
    @BackupType = 'FULL',
    @Compress = 'Y',
    @CleanupTime = 336, -- 14 ngày
    @CleanupMode = 'AFTER_BACKUP',
    @Verify = 'Y',
    @CheckSum = 'Y',
    @LogToTable = 'Y';
```

