- Database Mail Profile: là cấu hình mà SQL Server dùng để gửi email -> gửi mail bằng cách nào
- Operator đại diện cho người/nhóm sẽ nhận notification từ SQL Server Agen -> gửi notification cho ai
- Profile và Operator kết hợp như thế nào?
                 SQL SERVER
                     │
          ┌──────────┴──────────┐
          │                     │
   Database Mail          SQL Server Agent
          │                     │
     Profile DBA             Operator DBA
          │                     │
     SMTP Account          Email address
          │                     │
          └──────────┬──────────┘
                     │
                  Email
				  
				  
- thông tin về SQL Server Agent Operator.
```sql
SELECT 
    id,
    name AS OperatorName,
    enabled,
    email_address,
    last_email_date,
    last_email_time
FROM msdb.dbo.sysoperators
WHERE name = N'DBA'; -- Hoặc bỏ điều kiện WHERE để xem tất cả
```
- Operator DBA đang nhận Alert nào?
```sql
SELECT 
    o.name AS OperatorName,
    o.email_address,
    a.name AS AlertName,
    a.enabled AS AlertEnabled,
    CASE n.notification_method
        WHEN 1 THEN N'Email'
        WHEN 2 THEN N'Pager'
        WHEN 4 THEN N'NetSend'
        ELSE N'Combined'
    END AS NotificationMethod
FROM msdb.dbo.sysoperators o
JOIN msdb.dbo.sysnotifications n ON o.id = n.operator_id
JOIN msdb.dbo.sysalerts a ON n.alert_id = a.id
WHERE o.name = N'DBA'
ORDER BY a.name;
```
- thông tin về  Database Mail Profile
```sql
SELECT 
    p.profile_id,
    p.name AS profile_name,
    p.description
FROM msdb.dbo.sysmail_profile p;
```

- Update description profile
```sql
EXEC msdb.dbo.sysmail_update_profile_sp
    @profile_name = N'DBA',
    @description = N'Database Mail profile used by SQL Server DBA alerts and notifications';
```

- Principal/user nào được phép sử dụng Database Mail Profile
```sql
SELECT p.name AS ProfileName, pr.name AS PrincipalName, pp.is_default
FROM msdb.dbo.sysmail_principalprofile pp
JOIN msdb.dbo.sysmail_profile p ON pp.profile_id = p.profile_id
JOIN msdb.sys.database_principals pr ON pp.principal_sid = pr.sid
WHERE p.name = 'DBA';
```

- Truy vấn xem Profile và cấu hình SMTP Server
```sql
SELECT 
    p.profile_id,
    p.name AS ProfileName,
    p.description AS ProfileDescription,
    pa.sequence_number AS AccountPriority,
    a.account_id,
    a.name AS AccountName,
    a.email_address AS SenderEmail,
    a.display_name AS DisplayName,
    a.replyto_address AS ReplyTo,
    s.servertype AS ServerType,
    s.servername AS SMTPServer,
    s.port AS SMTPPort,
    s.enable_ssl AS UseSSL,
    c.credential_identity AS MailUserIdentity
FROM msdb.dbo.sysmail_profile p
INNER JOIN msdb.dbo.sysmail_profileaccount pa ON p.profile_id = pa.profile_id
INNER JOIN msdb.dbo.sysmail_account a ON pa.account_id = a.account_id
INNER JOIN msdb.dbo.sysmail_server s ON a.account_id = s.account_id
LEFT JOIN sys.database_scoped_credentials c ON s.credential_id = c.credential_id
ORDER BY p.name, pa.sequence_number;


/*
AssociatedUser trong câu lệnh trên thể hiện Database User (hoặc Role) trong database msdb được phân quyền sử dụng Database Mail Profile đó.
Trong SQL Server, một Mail Profile không tự động mở cho mọi người gửi mail. Profile phải được gán quyền cho một Database User cụ thể 
hoặc gán chung cho toàn hệ thống thông qua msdb.dbo.sysmail_add_principalprofile_sp.
*/

SELECT DISTINCT
    p.profile_id,
    p.name AS ProfileName,
    pp.is_default AS IsDefaultProfile,
    CASE 
        WHEN pp.principal_sid = 0x00 THEN 'Public (All users)'
        ELSE dp.name 
    END AS AssociatedUser
FROM msdb.dbo.sysmail_profile p
INNER JOIN msdb.dbo.sysmail_principalprofile pp ON p.profile_id = pp.profile_id
LEFT JOIN msdb.sys.database_principals dp ON pp.principal_sid = dp.sid
ORDER BY p.name;


---
SELECT 
    p.name AS ProfileName,
    pp.is_default AS IsDefaultProfile,
    CASE 
        WHEN pp.principal_sid = 0x00 THEN 'Public (All users)'
        ELSE dp.name 
    END AS AssociatedUser
FROM msdb.dbo.sysmail_profile p
JOIN msdb.dbo.sysmail_principalprofile pp ON p.profile_id = pp.profile_id
LEFT JOIN sys.database_principals dp ON pp.principal_sid = dp.sid;
```

- Xem danh sách Profiles
EXEC msdb.dbo.sysmail_help_profile_sp;

- Xem danh sách Accounts (kèm thông tin server, port, ssl)
EXEC msdb.dbo.sysmail_help_account_sp;

- Xem mối quan hệ gán giữa Profile và Account
EXEC msdb.dbo.sysmail_help_profileaccount_sp;

#### Database Mail Health Check

```SQL
USE [msdb];
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE
    @ProfileName        sysname = N'DBA',
    @ExpectedPrincipal  sysname = N'VIETSOV\sqlcluster',
    @OperatorName       sysname = N'DBA'; -- Đổi thành N'DBAs' nếu bạn đặt tên có 's'

------------------------------------------------------------
-- 0. HEADER
------------------------------------------------------------
PRINT '============================================================';
PRINT ' DBA - DATABASE MAIL HEALTH CHECK';
PRINT ' Server   : ' + @@SERVERNAME;
PRINT ' Database : ' + DB_NAME();
PRINT ' Time     : ' + CONVERT(varchar(19), GETDATE(), 120);
PRINT ' Profile  : ' + @ProfileName;
PRINT ' Principal: ' + @ExpectedPrincipal;
PRINT ' Operator : ' + @OperatorName;
PRINT '============================================================';


------------------------------------------------------------
-- 1. DATABASE MAIL PROFILE
------------------------------------------------------------
PRINT '';
PRINT '1. DATABASE MAIL PROFILE';
PRINT '------------------------------------------------------------';

IF EXISTS (SELECT 1 FROM msdb.dbo.sysmail_profile WHERE name = @ProfileName)
BEGIN
    SELECT
        N'PASS' AS Status,
        profile_id,
        name AS ProfileName,
        description
    FROM msdb.dbo.sysmail_profile
    WHERE name = @ProfileName;
END
ELSE
BEGIN
    SELECT
        N'FAIL' AS Status,
        @ProfileName AS ProfileName,
        N'Profile does not exist' AS Message;
END;


------------------------------------------------------------
-- 2. DATABASE MAIL ACCOUNTS
------------------------------------------------------------
PRINT '';
PRINT '2. DATABASE MAIL ACCOUNTS';
PRINT '------------------------------------------------------------';

SELECT
    CASE WHEN a.account_id IS NULL THEN N'FAIL' ELSE N'PASS' END AS Status,
    p.name AS ProfileName,
    a.account_id,
    a.name AS AccountName,
    a.email_address AS EmailAddress,
    a.display_name AS DisplayName,
    a.replyto_address AS ReplyToAddress,
    s.servername AS SMTPServer,
    s.port AS SMTPPort,
    s.enable_ssl AS EnableSSL,
    a.description AS AccountDescription
FROM msdb.dbo.sysmail_profile p
LEFT JOIN msdb.dbo.sysmail_profileaccount pa ON p.profile_id = pa.profile_id
LEFT JOIN msdb.dbo.sysmail_account a ON pa.account_id = a.account_id
LEFT JOIN msdb.dbo.sysmail_server s ON a.account_id = s.account_id
WHERE p.name = @ProfileName
ORDER BY a.account_id;


------------------------------------------------------------
-- 3. PROFILE -> ACCOUNT MAPPING
------------------------------------------------------------
PRINT '';
PRINT '3. PROFILE -> ACCOUNT MAPPING';
PRINT '------------------------------------------------------------';

IF EXISTS (
    SELECT 1 
    FROM msdb.dbo.sysmail_profile p
    JOIN msdb.dbo.sysmail_profileaccount pa ON p.profile_id = pa.profile_id
    WHERE p.name = @ProfileName
)
BEGIN
    SELECT
        N'PASS' AS Status,
        p.name AS ProfileName,
        a.name AS AccountName,
        pa.sequence_number AS SequenceNumber
    FROM msdb.dbo.sysmail_profile p
    JOIN msdb.dbo.sysmail_profileaccount pa ON p.profile_id = pa.profile_id
    JOIN msdb.dbo.sysmail_account a ON pa.account_id = a.account_id
    WHERE p.name = @ProfileName
    ORDER BY pa.sequence_number;
END
ELSE
BEGIN
    SELECT
        N'FAIL' AS Status,
        @ProfileName AS ProfileName,
        N'No Database Mail account is mapped to this profile' AS Message;
END;


------------------------------------------------------------
-- 4. EXPECTED PRINCIPAL EXISTS IN MSDB
------------------------------------------------------------
PRINT '';
PRINT '4. DATABASE USER / PRINCIPAL';
PRINT '------------------------------------------------------------';

SELECT
    CASE WHEN dp.name IS NULL THEN N'FAIL' ELSE N'PASS' END AS Status,
    @ExpectedPrincipal AS ExpectedPrincipal,
    dp.name AS ActualPrincipalName,
    dp.type_desc AS PrincipalType,
    dp.authentication_type_desc AS AuthenticationType
FROM (SELECT 1 AS Dummy) x
LEFT JOIN msdb.sys.database_principals dp ON dp.name = @ExpectedPrincipal;


------------------------------------------------------------
-- 5. DATABASEMAILUSERROLE (Kiểm tra trực tiếp qua Sys tables)
------------------------------------------------------------
PRINT '';
PRINT '5. DATABASEMAILUSERROLE';
PRINT '------------------------------------------------------------';

SELECT 
    CASE 
        WHEN rm.role_principal_id IS NOT NULL THEN N'PASS'
        ELSE N'FAIL'
    END AS Status,
    @ExpectedPrincipal AS PrincipalName,
    N'DatabaseMailUserRole' AS RequiredRole,
    CASE WHEN rm.role_principal_id IS NOT NULL THEN 1 ELSE 0 END AS IsMember
FROM (SELECT 1 AS Dummy) x
LEFT JOIN msdb.sys.database_principals dp ON dp.name = @ExpectedPrincipal
LEFT JOIN msdb.sys.database_role_members rm 
    ON rm.member_principal_id = dp.principal_id
   AND rm.role_principal_id = (SELECT principal_id FROM msdb.sys.database_principals WHERE name = N'DatabaseMailUserRole');


------------------------------------------------------------
-- 6. PROFILE PRINCIPAL MAPPING
------------------------------------------------------------
PRINT '';
PRINT '6. PROFILE -> PRINCIPAL';
PRINT '------------------------------------------------------------';

SELECT
    CASE WHEN pp.is_default = 1 THEN N'PASS' ELSE N'WARN' END AS Status,
    p.name AS ProfileName,
    pr.name AS PrincipalName,
    pr.type_desc AS PrincipalType,
    pp.is_default AS IsDefault
FROM msdb.dbo.sysmail_principalprofile pp
JOIN msdb.dbo.sysmail_profile p ON pp.profile_id = p.profile_id
JOIN msdb.sys.database_principals pr ON pp.principal_sid = pr.sid
WHERE p.name = @ProfileName
ORDER BY
    CASE WHEN pr.name = @ExpectedPrincipal THEN 0 ELSE 1 END,
    pr.name;


------------------------------------------------------------
-- 7. EXPECTED PRINCIPAL + PROFILE
------------------------------------------------------------
PRINT '';
PRINT '7. EXPECTED PRINCIPAL -> PROFILE';
PRINT '------------------------------------------------------------';

IF EXISTS (
    SELECT 1
    FROM msdb.dbo.sysmail_principalprofile pp
    JOIN msdb.dbo.sysmail_profile p ON pp.profile_id = p.profile_id
    JOIN msdb.sys.database_principals pr ON pp.principal_sid = pr.sid
    WHERE p.name = @ProfileName
      AND pr.name = @ExpectedPrincipal
      AND pp.is_default = 1
)
BEGIN
    SELECT
        N'PASS' AS Status,
        @ExpectedPrincipal AS PrincipalName,
        @ProfileName AS ProfileName,
        N'Private profile exists and is default' AS Message;
END
ELSE
BEGIN
    SELECT
        N'FAIL' AS Status,
        @ExpectedPrincipal AS PrincipalName,
        @ProfileName AS ProfileName,
        N'Private default profile is missing' AS Message;
END;


------------------------------------------------------------
-- 8. PUBLIC PROFILE
------------------------------------------------------------
PRINT '';
PRINT '8. PUBLIC PROFILE';
PRINT '------------------------------------------------------------';

SELECT
    CASE WHEN pp.is_default = 1 THEN N'PASS' ELSE N'WARN' END AS Status,
    p.name AS ProfileName,
    pr.name AS PrincipalName,
    pp.is_default AS IsDefault
FROM msdb.dbo.sysmail_principalprofile pp
JOIN msdb.dbo.sysmail_profile p ON pp.profile_id = p.profile_id
JOIN msdb.sys.database_principals pr ON pp.principal_sid = pr.sid
WHERE p.name = @ProfileName
  AND pr.name = N'public';


------------------------------------------------------------
-- 9 & 10. ALL PROFILES & ACCOUNTS
------------------------------------------------------------
PRINT '';
PRINT '9. ALL PROFILES & 10. ALL ACCOUNTS';
PRINT '------------------------------------------------------------';

SELECT
    p.profile_id,
    p.name AS ProfileName,
    p.description,
    COUNT(pa.account_id) AS AccountCount
FROM msdb.dbo.sysmail_profile p
LEFT JOIN msdb.dbo.sysmail_profileaccount pa ON p.profile_id = pa.profile_id
GROUP BY p.profile_id, p.name, p.description
ORDER BY p.name;

SELECT
    a.account_id,
    a.name AS AccountName,
    a.email_address,
    a.display_name,
    s.servername AS SMTPServer,
    s.port AS SMTPPort,
    s.enable_ssl AS EnableSSL,
    a.description
FROM msdb.dbo.sysmail_account a
LEFT JOIN msdb.dbo.sysmail_server s ON a.account_id = s.account_id
ORDER BY a.account_id;


------------------------------------------------------------
-- 11 & 12. FAILURES & EVENT LOGS (24 HOURS)
------------------------------------------------------------
PRINT '';
PRINT '11 & 12. MAIL FAILURES & EVENT LOGS (LAST 24 HOURS)';
PRINT '------------------------------------------------------------';

SELECT
    sent_status,
    send_request_date,
    sent_date,
    profile_id,
    recipients,
    subject,
    last_mod_date
FROM msdb.dbo.sysmail_allitems
WHERE send_request_date >= DATEADD(HOUR, -24, GETDATE())
  AND sent_status <> 'sent'
ORDER BY send_request_date DESC;

SELECT
    log_date,
    process_id,
    mailitem_id,
    event_type,
    description
FROM msdb.dbo.sysmail_event_log
WHERE log_date >= DATEADD(HOUR, -24, GETDATE())
ORDER BY log_date DESC;


------------------------------------------------------------
-- 15. SQL AGENT OPERATOR
------------------------------------------------------------
PRINT '';
PRINT '15. SQL SERVER AGENT OPERATOR';
PRINT '------------------------------------------------------------';

SELECT
    CASE 
        WHEN enabled = 1 AND NULLIF(email_address, '') IS NOT NULL THEN N'PASS'
        ELSE N'FAIL'
    END AS Status,
    id,
    name AS OperatorName,
    enabled,
    email_address,
    last_email_date,
    last_email_time
FROM msdb.dbo.sysoperators
WHERE name = @OperatorName;


------------------------------------------------------------
-- 16 & 17. OPERATOR ALERTS
------------------------------------------------------------
PRINT '';
PRINT '16. OPERATOR -> ALERT MAPPING';
PRINT '------------------------------------------------------------';

SELECT
    o.name AS OperatorName,
    o.email_address,
    a.name AS AlertName,
    a.enabled AS AlertEnabled,
    CASE n.notification_method
        WHEN 1 THEN N'Email'
        WHEN 2 THEN N'Pager'
        WHEN 4 THEN N'NetSend'
        ELSE N'Combined'
    END AS NotificationMethod
FROM msdb.dbo.sysoperators o
JOIN msdb.dbo.sysnotifications n ON o.id = n.operator_id
JOIN msdb.dbo.sysalerts a ON n.alert_id = a.id
WHERE o.name = @OperatorName
ORDER BY a.name;

PRINT '';
PRINT '17. ENABLED ALERTS WITHOUT THIS OPERATOR';
PRINT '------------------------------------------------------------';

SELECT
    a.id,
    a.name AS AlertName,
    a.enabled
FROM msdb.dbo.sysalerts a
WHERE a.enabled = 1
  AND NOT EXISTS (
      SELECT 1
      FROM msdb.dbo.sysnotifications n
      JOIN msdb.dbo.sysoperators o ON n.operator_id = o.id
      WHERE n.alert_id = a.id
        AND o.name = @OperatorName
  )
ORDER BY a.name;


------------------------------------------------------------
-- 18 & 19. CONFIGURATION & QUEUE STATUS
------------------------------------------------------------
PRINT '';
PRINT '18. SQL SERVER AGENT MAIL CONFIGURATION';
PRINT '------------------------------------------------------------';
EXEC msdb.dbo.sp_get_sqlagent_properties;

PRINT '';
PRINT '19. DATABASE MAIL QUEUE';
PRINT '------------------------------------------------------------';
EXEC msdb.dbo.sysmail_help_queue_sp @queue_type = 'Mail';


------------------------------------------------------------
-- 20. FINAL CHECK SUMMARY
------------------------------------------------------------
PRINT '';
PRINT '============================================================';
PRINT '20. FINAL EXPECTED CONFIGURATION CHECK';
PRINT '============================================================';

DECLARE
    @ProfileExists bit = 0,
    @AccountExists bit = 0,
    @PrincipalExists bit = 0,
    @RoleOK bit = 0,
    @PrincipalProfileOK bit = 0,
    @OperatorOK bit = 0;

IF EXISTS (SELECT 1 FROM msdb.dbo.sysmail_profile WHERE name = @ProfileName)
    SET @ProfileExists = 1;

IF EXISTS (
    SELECT 1 FROM msdb.dbo.sysmail_profile p
    JOIN msdb.dbo.sysmail_profileaccount pa ON p.profile_id = pa.profile_id
    JOIN msdb.dbo.sysmail_account a ON pa.account_id = a.account_id
    WHERE p.name = @ProfileName
)
    SET @AccountExists = 1;

IF EXISTS (SELECT 1 FROM msdb.sys.database_principals WHERE name = @ExpectedPrincipal)
    SET @PrincipalExists = 1;

IF EXISTS (
    SELECT 1 
    FROM msdb.sys.database_principals dp
    JOIN msdb.sys.database_role_members rm ON rm.member_principal_id = dp.principal_id
    WHERE dp.name = @ExpectedPrincipal
      AND rm.role_principal_id = (SELECT principal_id FROM msdb.sys.database_principals WHERE name = N'DatabaseMailUserRole')
)
    SET @RoleOK = 1;

IF EXISTS (
    SELECT 1 FROM msdb.dbo.sysmail_principalprofile pp
    JOIN msdb.dbo.sysmail_profile p ON pp.profile_id = p.profile_id
    JOIN msdb.sys.database_principals pr ON pp.principal_sid = pr.sid
    WHERE p.name = @ProfileName
      AND pr.name = @ExpectedPrincipal
      AND pp.is_default = 1
)
    SET @PrincipalProfileOK = 1;

IF EXISTS (
    SELECT 1 FROM msdb.dbo.sysoperators
    WHERE name = @OperatorName
      AND enabled = 1
      AND NULLIF(email_address, '') IS NOT NULL
)
    SET @OperatorOK = 1;

SELECT
    CheckItem,
    Status,
    Details
FROM (
    SELECT N'Profile exists' AS CheckItem, CASE WHEN @ProfileExists = 1 THEN N'PASS' ELSE N'FAIL' END AS Status, @ProfileName AS Details
    UNION ALL
    SELECT N'Profile has Mail Account', CASE WHEN @AccountExists = 1 THEN N'PASS' ELSE N'FAIL' END, @ProfileName
    UNION ALL
    SELECT N'Principal exists in msdb', CASE WHEN @PrincipalExists = 1 THEN N'PASS' ELSE N'FAIL' END, @ExpectedPrincipal
    UNION ALL
    SELECT N'DatabaseMailUserRole', CASE WHEN @RoleOK = 1 THEN N'PASS' ELSE N'FAIL' END, @ExpectedPrincipal
    UNION ALL
    SELECT N'Principal has default Profile', CASE WHEN @PrincipalProfileOK = 1 THEN N'PASS' ELSE N'FAIL' END, @ExpectedPrincipal + N' -> ' + @ProfileName
    UNION ALL
    SELECT N'SQL Agent Operator exists & valid', CASE WHEN @OperatorOK = 1 THEN N'PASS' ELSE N'FAIL' END, @OperatorName
) AS FinalCheck
ORDER BY
    CASE Status
        WHEN N'FAIL' THEN 1
        WHEN N'WARN' THEN 2
        WHEN N'PASS' THEN 3
        ELSE 4
    END,
    CheckItem;

PRINT '';
PRINT '============================================================';
PRINT ' HEALTH CHECK COMPLETED';
PRINT '============================================================';
GO
```