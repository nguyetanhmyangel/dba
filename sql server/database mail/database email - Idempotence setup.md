### /*==============================================================================
###  DATABASE MAIL - PRODUCTION / IDEMPOTENT SETUP
###  Target: SQL Server 2019+
### ==============================================================================*/

```sql 
SET NOCOUNT ON;
GO
```

#### /*==============================================================================
####     STEP 1 - ENABLE DATABASE MAIL XPs
#### ==============================================================================*/
```sql
USE master;
GO

EXEC sys.sp_configure @configname = N'show advanced options', @configvalue = 1;
RECONFIGURE;

EXEC sys.sp_configure @configname = N'Database Mail XPs', @configvalue = 1;
RECONFIGURE;
GO

PRINT '1. Database Mail XPs enabled.';
GO
```
#### /*==============================================================================
####    STEP 2 - CREATE DATABASE MAIL ACCOUNT
#### ==============================================================================*/
```
USE msdb;
GO

DECLARE
    @AccountName   sysname        = N'DBA',
    @EmailAddress  nvarchar(128) = N'sqlalerts@vietsov.com.vn',
    @DisplayName   nvarchar(128) = N'SQL Server DBA Alert',
    @MailServer    nvarchar(128) = N'mail.vietsov.com.vn',
    @MailPort      int            = 25,
    @EnableSSL     bit            = 0;

IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysmail_account WHERE name = @AccountName)
BEGIN
    EXEC msdb.dbo.sysmail_add_account_sp
        @account_name    = @AccountName,
        @description     = N'Mail account for DBA monitoring and SQL Agent alerts',
        @email_address   = @EmailAddress,
        @display_name    = @DisplayName,
        @mailserver_name = @MailServer,
        @port            = @MailPort,
        @enable_ssl      = @EnableSSL;

    PRINT '2. Mail Account created: ' + @AccountName;
END
ELSE
BEGIN
    PRINT '2. Mail Account already exists: ' + @AccountName;
END;
GO
```sql

#### /*==============================================================================
   # STEP 3 - CREATE DATABASE MAIL PROFILE
#### ==============================================================================*/
```sql
DECLARE @ProfileName sysname = N'DBA';

IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysmail_profile WHERE name = @ProfileName)
BEGIN
    EXEC msdb.dbo.sysmail_add_profile_sp
        @profile_name = @ProfileName,
        @description  = N'Primary Database Mail profile for DBA alerts';

    PRINT '3. Mail Profile created: ' + @ProfileName;
END
ELSE
BEGIN
    PRINT '3. Mail Profile already exists: ' + @ProfileName;
END;
GO
```

#### /*==============================================================================
####   STEP 4 - ATTACH ACCOUNT TO PROFILE
#### ==============================================================================*/
```sql
DECLARE
    @ProfileName sysname = N'DBA',
    @AccountName sysname = N'DBA';

IF NOT EXISTS
(
    SELECT 1
    FROM msdb.dbo.sysmail_profileaccount pa
    INNER JOIN msdb.dbo.sysmail_profile p ON p.profile_id = pa.profile_id
    INNER JOIN msdb.dbo.sysmail_account a ON a.account_id = pa.account_id
    WHERE p.name = @ProfileName AND a.name = @AccountName
)
BEGIN
    EXEC msdb.dbo.sysmail_add_profileaccount_sp
        @profile_name    = @ProfileName,
        @account_name    = @AccountName,
        @sequence_number = 1;

    PRINT '4. Mail Account attached to Profile.';
END
ELSE
BEGIN
    PRINT '4. Mail Account already attached to Profile.';
END;
GO
```
#### /*==============================================================================
####    STEP 5 - CREATE / MAP LOGIN INTO MSDB
#### ==============================================================================*/
```
DECLARE @AgentLogin sysname = N'VIETSOV\sqlcluster';

IF SUSER_ID(@AgentLogin) IS NULL
BEGIN
    RAISERROR('Login [%s] does not exist at server level.', 16, 1, @AgentLogin);
END
ELSE IF NOT EXISTS (SELECT 1 FROM msdb.sys.database_principals WHERE name = @AgentLogin)
BEGIN
    DECLARE @SQL nvarchar(max) = N'CREATE USER ' + QUOTENAME(@AgentLogin) + N' FOR LOGIN ' + QUOTENAME(@AgentLogin) + N';';
    EXEC sys.sp_executesql @SQL;
    PRINT '5. msdb user created: ' + @AgentLogin;
END
ELSE
BEGIN
    PRINT '5. msdb user already exists: ' + @AgentLogin;
END;
GO
```
#### /*==============================================================================
####    STEP 6 - ADD USER TO DatabaseMailUserRole
#### ==============================================================================*/
```sql
DECLARE @AgentLogin sysname = N'VIETSOV\sqlcluster';

IF NOT EXISTS
(
    SELECT 1
    FROM msdb.sys.database_role_members drm
    INNER JOIN msdb.sys.database_principals r ON r.principal_id = drm.role_principal_id
    INNER JOIN msdb.sys.database_principals u ON u.principal_id = drm.member_principal_id
    WHERE r.name = N'DatabaseMailUserRole' AND u.name = @AgentLogin
)
BEGIN
    DECLARE @SQL nvarchar(max) = N'ALTER ROLE [DatabaseMailUserRole] ADD MEMBER ' + QUOTENAME(@AgentLogin) + N';';
    EXEC sys.sp_executesql @SQL;
    PRINT '6. User added to DatabaseMailUserRole: ' + @AgentLogin;
END
ELSE
BEGIN
    PRINT '6. User already belongs to DatabaseMailUserRole: ' + @AgentLogin;
END;
GO
```
#### /*==============================================================================
####    STEP 7 - MAKE DBA PROFILE PUBLIC + DEFAULT
#### ==============================================================================*/
```sql
DECLARE @ProfileName sysname = N'DBA';

IF NOT EXISTS
(
    SELECT 1
    FROM msdb.dbo.sysmail_principalprofile pp
    INNER JOIN msdb.dbo.sysmail_profile p ON p.profile_id = pp.profile_id
    WHERE p.name = @ProfileName AND pp.principal_sid = 0x00
)
BEGIN
    EXEC msdb.dbo.sysmail_add_principalprofile_sp
        @profile_name   = @ProfileName,
        @principal_name = N'public',
        @is_default     = 1;

    PRINT '7. Profile granted PUBLIC access and set as default.';
END
ELSE
BEGIN
    EXEC msdb.dbo.sysmail_update_principalprofile_sp
        @profile_name   = @ProfileName,
        @principal_name = N'public',
        @is_default     = 1;

    PRINT '7. PUBLIC profile already exists; default status refreshed.';
END;
GO
```
#### /*==============================================================================
####   STEP 8 - TEST SEND & VERIFY STATUS
#### ==============================================================================*/
```sql
EXEC msdb.dbo.sysmail_help_status_sp;

EXEC msdb.dbo.sp_send_dbmail
    @profile_name = N'DBA',
    @recipients   = N'nghianl.ts@vietsov.com.vn',
    @subject      = N'Test Setup Database Mail Profile',
    @body         = N'Database Mail profile DBA has been configured successfully.';
GO

-- Chờ 3 giây để queue xử lý gửi mail rồi xem log
WAITFOR DELAY '00:00:03';

SELECT TOP (1)
    mailitem_id, send_request_date, sent_status, sent_date
FROM msdb.dbo.sysmail_allitems
ORDER BY mailitem_id DESC;

SELECT TOP (5)
    log_id, log_date, event_type, description
FROM msdb.dbo.sysmail_event_log
ORDER BY log_id DESC;
GO
```