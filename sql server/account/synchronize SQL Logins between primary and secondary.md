### 1. Chạy script này ở primary. Copy kết quả và chạy ở secondary.

- Chạy script trên primary node dưới để backup tất cả login trên SQL Server, bao gồm:

	- SQL Login: kèm theo SID, PASSWORD_HASH, DEFAULT_DATABASE, CHECK_POLICY, CHECK_EXPIRATION, DISABLE.

	- Windows Login & Windows Group: tạo lại bằng CREATE LOGIN ... FROM WINDOWS.

- Sau đó copy kết quả của script trên rồi chạy trên ở secondary node để đồng bộ

```sql
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

### 2. Câu lệnh kiểm tra Orphan User trong tất cả Db(Nên chạy ở cả hai node)

- Chạy ở Primary: Để đảm bảo bản thân node gốc không có User nào bị mồ côi (do trước đó restore database từ server khác về chẳng hạn).

- Chạy ở Secondary: Đây là nơi quan trọng nhất cần kiểm tra. Lỗi "User mồ côi" thường chỉ xuất hiện ở Secondary sau khi đồng bộ database qua AG nhưng chưa đồng bộ Login ở cấp Instance.

```sql
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

- Nếu có Orphaned Users 

- Nếu có user xuất hiện ở nhiều Db. Hãy đảm bảo bạn có một Login tên là admin ở cấp Server. 
Nếu Login ở Server tên là sa hoặc một tên khác, Script 3 sẽ không tự sửa được vì nó đang tìm tên trùng khớp.

- Trường hợp tên Login khác tên User: ví dụ nếu Login trên server tên là your_account nhưng User trong DB tên là db_your_account, phải sửa thủ công cho từng database:

```sql
USE [yourDb];
ALTER USER [db_your_account] WITH LOGIN = [your_account];
```

### 3. Tự động Fix Orphan User(ChỈ chạy ở node Primary)

- Trong AG, các database ở node Secondary thường ở chế độ Read-Only hoặc Redoing, không thể thực thi lệnh sửa đổi trực tiếp tại đó.

- Cơ chế: Khi chạy Script 3 trên Primary, lệnh sửa User sẽ được ghi vào Transaction Log và tự động đẩy xuống node Secondary. Khi đó, User ở Secondary sẽ được "khớp" lại với Login mà đã tạo bằng Script 1.

```sql
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

### 4. Tạo job đồng bộ user giữa các node trong AG với dbatool:


- Cài đặt dbatool:

```sql
# 1. Config TLS 1.2 to load module from PSGallery(Importal for older window servers)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# 2. Update PackageProvider to bester module management.
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force

# 3. Trust the PSGallery storge to avoid being asked confirmtion during installtion.
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted

# 4. Install dbtools for all user
Install-Module dbatools -Repository PSGallery -Force -Scope AllUsers
```

- Tạo file .ps đồng bộ:

```powershell
#Requires -Modules dbatools

# ============================================================
# CONFIGURATION
# ============================================================
$DryRun      = $true        # Set to $false to apply changes
$MaxThreads  = 3            # Maximum parallel threads
$CustomPort  = 1433         # Change if using non-standard port
$LogPath     = "D:\AsyncAccount\Logs\SQL_Sync"
$KeepDays    = 30

# INITIALIZATION
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$CurrentDate = Get-Date -Format "yyyyMMdd_HHmm"
$LogFile     = "$LogPath\SQL_Sync_Log_$CurrentDate.txt"

if (!(Test-Path $LogPath)) { 
    New-Item -ItemType Directory -Path $LogPath -Force | Out-Null 
}

# ============================================================
# MAIN SCRIPT
# ============================================================
Start-Transcript -Path $LogFile -Append

try {
    Write-Output "========================================================="
    Write-Output "SQL AG LOGIN SYNC - v6.1 PARALLEL"
    $DryModeStatus = if($DryRun){ "ENABLED (No changes)" } else { "DISABLED (Live Sync)" }
    Write-Output "DRY RUN MODE: $DryModeStatus"
    Write-Output "========================================================="

    # 1. Connect Local (Force TCP Loopback)
    $LocalInstance = "tcp:127.0.0.1,$CustomPort"
    Write-Output "Connecting to local: $LocalInstance"
    
    $serverConn = Connect-DbaInstance -SqlInstance $LocalInstance -TrustServerCertificate -ErrorAction Stop
    
    # 2. Role Check
    $localReplica = Get-DbaAgReplica -SqlInstance $serverConn | Where-Object { $_.IsLocal -eq $true }
    $currentRole = $localReplica.Role
    
    if ($currentRole -ne "Primary") {
        Write-Output "Current Node is $currentRole. Sync only runs on PRIMARY. Exiting."
    }
    else {
        Write-Output "Role confirmed: PRIMARY. Searching for healthy secondaries..."

        # 3. Discover Healthy Secondary Nodes
        $healthySecondaries = Get-DbaAgReplica -SqlInstance $serverConn | Where-Object { 
            $_.IsLocal -eq $false -and 
            $_.ConnectionState -eq 'Connected' -and 
            $_.SynchronizationHealth -eq 'Healthy' 
        }

        if ($null -eq $healthySecondaries) {
            Write-Output "No healthy connected secondary nodes found."
        }
        else {
            # 4. Setup Runspace Pool
            $RunspacePool = [RunspaceFactory]::CreateRunspacePool(1, $MaxThreads)
            $RunspacePool.Open()
            $Jobs = @()

            foreach ($secNode in $healthySecondaries) {
                $targetName = $secNode.Name
                # Handle instance name and port
                $targetInstance = "tcp:$targetName"
                if ($targetInstance -notlike "*,*") { $targetInstance = "$targetInstance,$CustomPort" }

                $ScriptBlock = {
                    param($Source, $Dest, $IsDryRun)
                    Import-Module dbatools -ErrorAction SilentlyContinue
                    try {
                        $copyParams = @{
                            Source = $Source
                            Destination = $Dest
                            ExcludeSystemLogins = $true
                            ExcludeLogin = "sa"
                            SyncOnly = $true
                            Force = $true
                            IncludePermission = $true
                            IncludeUserRoleMember = $true
                            TrustServerCertificate = $true
                            WhatIf = $IsDryRun
                        }
                        $syncResult = Copy-DbaLogin @copyParams
                        $count = if($syncResult){$syncResult.Count}else{0}
                        return @{ Node = $Dest; Success = $true; Count = $count }
                    } catch {
                        $err = $_.Exception.Message
                        return @{ Node = $Dest; Success = $false; Error = $err }
                    }
                }

                $PowerShell = [PowerShell]::Create().AddScript($ScriptBlock).AddArgument($LocalInstance).AddArgument($targetInstance).AddArgument($DryRun)
                $PowerShell.RunspacePool = $RunspacePool
                $Jobs += @{ PS = $PowerShell; Handle = $PowerShell.BeginInvoke() }
            }

            # 5. Wait and Collect Results
            while ($Jobs.Handle.IsCompleted -contains $false) { Start-Sleep -Milliseconds 200 }

            Write-Output "---------------------------------------------------------"
            foreach ($Job in $Jobs) {
                $FinalResult = $Job.PS.EndInvoke($Job.Handle)
                $nodeLabel = $FinalResult.Node
                if ($FinalResult.Success) {
                    $logCount = $FinalResult.Count
                    Write-Output "SUCCESS - Node: $nodeLabel | Logins: $logCount"
                } else {
                    $errText = $FinalResult.Error
                    Write-Output "FAILED  - Node: $nodeLabel | Error: $errText"
                }
                $Job.PS.Dispose()
            }
        }
    }
} 
catch {
    $critErr = $_.Exception.Message
    Write-Output "CRITICAL ERROR: $critErr"
} 
finally {
    if ($RunspacePool) { $RunspacePool.Close(); $RunspacePool.Dispose() }
    
    # Log Cleanup
    Write-Output "---------------------------------------------------------"
    $LimitDate = (Get-Date).AddDays(-$KeepDays)
    Get-ChildItem -Path $LogPath -Filter "SQL_Sync_Log_*.txt" | 
        Where-Object { $_.LastWriteTime -lt $LimitDate } | 
        Remove-Item -Force
        
    Write-Output "PROCESS COMPLETED."
    Stop-Transcript
}
```

- kiểm tra sau khi cài

```powershell
Get-Module dbatools -ListAvailable
```

- Tạo job sql để chạy script theo lịch (Action: Start a program. Program/script: powershell.exe. Add arguments: -ExecutionPolicy Bypass -File "your path/script.ps1"

```SQL
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& 'E:\AsyncAccount\asynaccount.ps1'"
```