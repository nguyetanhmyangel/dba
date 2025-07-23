##  Xử lí lỗi: Login 'old-user' owns one or more database(s). Change the owner of the database(s) before dropping the login. (Microsoft SQL Server, Error: 15174)

### 1. Kiểm tra các Availability Group mà user 'old-user' đang là chủ sở hữu trên replica hiện tại

```bash
SELECT ag.name AS AvailabilityGroupName,ar.replica_server_name,sp.name AS OwnerName
FROM sys.availability_replicas AS ar
JOIN sys.availability_groups AS ag ON ar.group_id = ag.group_id
JOIN sys.server_principals AS sp ON ar.owner_sid = sp.sid
WHERE sp.name = 'old-user';
```

### 2. Đổi quyền sở hữu trên Availability Group 

```bash
ALTER AUTHORIZATION ON AVAILABILITY GROUP::[sqlform] TO [new-user];
```

### 3. Kiểm tra các database mà VIETSOV\cuongpc.ts là chủ sở hữu:

```bash
SELECT name AS DatabaseName, SUSER_SNAME(owner_sid) AS CurrentOwner
FROM sys.databases
WHERE owner_sid = SUSER_SID('old-user') ;
```

### 4. Đổi chủ sở hữu của các database 

```bash
--- ALTER AUTHORIZATION ON DATABASE::[VSP_House_RU_Temp] TO [new-user];

DECLARE @OldOwner1 NVARCHAR(128) = 'old-user';
DECLARE @NewOwner  NVARCHAR(128) = 'new-user';

DECLARE @sql NVARCHAR(MAX) = N'';

SELECT @sql += '
ALTER AUTHORIZATION ON DATABASE::[' + name + '] TO [' + @NewOwner + '];'
FROM sys.databases
WHERE owner_sid = SUSER_SID(@OldOwner1);

-- Kiểm tra lệnh trước khi chạy:
PRINT @sql;
```

### 5. Kiểm tra các job mà 'old-user' là chủ sở hữu:

```bash
SELECT
    j.name AS JobName,
    SUSER_SNAME(j.owner_sid) AS CurrentOwner
FROM
    msdb.dbo.sysjobs AS j
WHERE
    j.owner_sid = SUSER_SID('old-user');
```

### 6. Đổi chủ sở hữu của các job

```bash
DECLARE @job_name SYSNAME;
DECLARE @current_owner_sid VARBINARY(85) = SUSER_SID('old-user');
DECLARE @new_owner_name SYSNAME = N'new-user'; -- 

-- Đảm bảo login mới tồn tại
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = @new_owner_name AND type IN ('S', 'U', 'G'))
BEGIN
    PRINT 'ERROR: The new owner login ' + QUOTENAME(@new_owner_name) + ' does not exist. Please create it first.';
    RETURN;
END;

DECLARE job_cursor CURSOR FOR
SELECT name
FROM msdb.dbo.sysjobs
WHERE owner_sid = @current_owner_sid;

OPEN job_cursor;
FETCH NEXT FROM job_cursor INTO @job_name;

WHILE @@FETCH_STATUS = 0
BEGIN
    PRINT 'Attempting to change owner for job: ' + @job_name;
    BEGIN TRY
        EXEC msdb.dbo.sp_update_job
            @job_name = @job_name,
            @owner_login_name = @new_owner_name; 
        PRINT 'Successfully changed owner for job: ' + @job_name;
    END TRY
    BEGIN CATCH
        PRINT 'Failed to change owner for job: ' + @job_name + '. Error: ' + ERROR_MESSAGE();
    END CATCH;
    FETCH NEXT FROM job_cursor INTO @job_name;
END;

CLOSE job_cursor;
DEALLOCATE job_cursor;

PRINT 'Finished attempting to update job owners.';
```

### 7. Drop user:

```bash
DROP USER [old-user];
```
