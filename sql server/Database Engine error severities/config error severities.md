### Script 
```sql
USE [master];
GO

-- =============================================================================
-- PHẦN 1: BẬT 'WITH_LOG' CHO CÁC MÃ LỖI QUAN TRỌNG (SEVERITY < 19)
-- Bắt buộc: SQL Agent Alert chỉ bắt sự kiện từ Windows Application Log.
-- =============================================================================
-- Kiểm tra và chỉ bật nếu chưa được log để tránh warning không cần thiết
DECLARE @messages TABLE (msg_id INT);
INSERT INTO @messages (msg_id) 
VALUES (825), (833), (1480), (19406), (35264), (35265);

DECLARE @id INT;
DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT msg_id FROM @messages;

OPEN cur;
FETCH NEXT FROM cur INTO @id;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF EXISTS (
        SELECT 1 FROM sys.messages 
        WHERE message_id = @id AND language_id = 1033 AND is_event_logged = 0
    )
    BEGIN
        EXEC master.dbo.sp_altermessage @message_id = @id, @parameter = 'WITH_LOG', @parameter_value = 'true';
    END
    FETCH NEXT FROM cur INTO @id;
END
CLOSE cur;
DEALLOCATE cur;
GO

USE [msdb];
GO

-- =============================================================================
-- PHẦN 2: KHỞI TẠO HOẶC CẬP NHẬT OPERATOR (IDEMPOTENT)
-- =============================================================================
IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysoperators WHERE name = N'DBA')
BEGIN
    EXEC msdb.dbo.sp_add_operator 
        @name = N'DBA', 
        @enabled = 1, 
        @email_address = N'sqlalert@vietsov.com.vn';
END
ELSE
BEGIN
    EXEC msdb.dbo.sp_update_operator 
        @name = N'DBA', 
        @enabled = 1, 
        @email_address = N'sqlalert@vietsov.com.vn';
END
GO

-- =============================================================================
-- PHẦN 3: STORED PROCEDURE CỤC BỘ ĐỂ QUẢN LÝ ALERT IDEMPOTENT
-- =============================================================================
CREATE OR ALTER PROCEDURE #sp_Upsert_Alert
    @AlertName NVARCHAR(128),
    @MessageID INT = 0,
    @Severity INT = 0,
    @DelaySec INT = 300,
    @OperatorName NVARCHAR(128) = N'DBA'
AS
BEGIN
    SET NOCOUNT ON;

    -- 1. Tạo mới hoặc Cập nhật Alert
    IF EXISTS (SELECT 1 FROM msdb.dbo.sysalerts WHERE name = @AlertName)
    BEGIN
        EXEC msdb.dbo.sp_update_alert 
            @name = @AlertName, 
            @message_id = @MessageID, 
            @severity = @Severity, 
            @enabled = 1, 
            @delay_between_responses = @DelaySec, 
            @include_event_description_in = 1;
    END
    ELSE
    BEGIN
        EXEC msdb.dbo.sp_add_alert 
            @name = @AlertName, 
            @message_id = @MessageID, 
            @severity = @Severity, 
            @enabled = 1, 
            @delay_between_responses = @DelaySec, 
            @include_event_description_in = 1,
            @category_name = N'[Uncategorized]';
    END

    -- 2. Gán Notification (Idempotent)
    IF NOT EXISTS (
        SELECT 1 
        FROM msdb.dbo.sysnotifications n
        JOIN msdb.dbo.sysalerts a ON n.alert_id = a.id
        JOIN msdb.dbo.sysoperators o ON n.operator_id = o.id
        WHERE a.name = @AlertName AND o.name = @OperatorName
    )
    BEGIN
        EXEC msdb.dbo.sp_add_notification 
            @alert_name = @AlertName, 
            @operator_name = @OperatorName, 
            @notification_method = 1; -- 1: Email
    END
END
GO

-- =============================================================================
-- PHẦN 4: KHỞI TẠO CÁC ALERTS
-- =============================================================================

-- NHÓM A: LỖI THEO SEVERITY (17 - 25)
EXEC #sp_Upsert_Alert @AlertName = N'Severity 17: Insufficient Resources',         @Severity = 17, @DelaySec = 300;
EXEC #sp_Upsert_Alert @AlertName = N'Severity 18: Nonfatal Internal Error',        @Severity = 18, @DelaySec = 300;
EXEC #sp_Upsert_Alert @AlertName = N'Severity 19: Fatal Error in Resource',        @Severity = 19, @DelaySec = 300;
EXEC #sp_Upsert_Alert @AlertName = N'Severity 20: Fatal Error in Current Process', @Severity = 20, @DelaySec = 300;
EXEC #sp_Upsert_Alert @AlertName = N'Severity 21: Fatal Error in Database Processes', @Severity = 21, @DelaySec = 300;
EXEC #sp_Upsert_Alert @AlertName = N'Severity 22: Table Integrity Suspect',        @Severity = 22, @DelaySec = 300;
EXEC #sp_Upsert_Alert @AlertName = N'Severity 23: Database Integrity Suspect',     @Severity = 23, @DelaySec = 300;
EXEC #sp_Upsert_Alert @AlertName = N'Severity 24: Hardware/Media Failure',         @Severity = 24, @DelaySec = 300;
EXEC #sp_Upsert_Alert @AlertName = N'Severity 25: Fatal System Error',             @Severity = 25, @DelaySec = 300;

-- NHÓM B: CẢNH BÁO LỖI I/O VÀ Ổ ĐĨA
EXEC #sp_Upsert_Alert @AlertName = N'Error 823: OS Read/Write Failure',            @MessageID = 823, @DelaySec = 300;
EXEC #sp_Upsert_Alert @AlertName = N'Error 824: Logical Checksum/Torn Page Error', @MessageID = 824, @DelaySec = 300;
EXEC #sp_Upsert_Alert @AlertName = N'Error 825: Read-Retry Warning (I/O Hiccup)',  @MessageID = 825, @DelaySec = 300;
EXEC #sp_Upsert_Alert @AlertName = N'Error 833: Long I/O Request > 15s',           @MessageID = 833, @DelaySec = 300;

-- NHÓM C: ALWAYSON AVAILABILITY GROUPS
EXEC #sp_Upsert_Alert @AlertName = N'AlwaysOn 19406: AG Replica State Change',     @MessageID = 19406, @DelaySec = 60;
EXEC #sp_Upsert_Alert @AlertName = N'AlwaysOn 1480: AG Database Role Change',      @MessageID = 1480,  @DelaySec = 60;
EXEC #sp_Upsert_Alert @AlertName = N'AlwaysOn 35264: AG Data Movement Suspended',  @MessageID = 35264, @DelaySec = 300;
EXEC #sp_Upsert_Alert @AlertName = N'AlwaysOn 35265: AG Data Movement Resumed',    @MessageID = 35265, @DelaySec = 300;
GO

-- Dọn dẹp thủ tục tạm
DROP PROCEDURE IF EXISTS #sp_Upsert_Alert;
GO
```

### Lưu ý bắt buộc sau khi chạy Script

- Để email cảnh báo thực sự gửi đi khi sự kiện kích hoạt, hãy đảm bảo cấu hình Agent Alert System đã được kích hoạt:

```sql
-- Kiểm tra Profile có tồn tại
USE msdb;
GO

SELECT
    profile_id,
    name,
    description
FROM dbo.sysmail_profile
WHERE name = N'DBA';

-- Cấu hình SQL Agent sử dụng Database Mail Profile
EXEC msdb.dbo.sp_set_sqlagent_properties 
    @email_save_in_sent_folder = 1,
    @alert_replace_runtime_tokens = 1, 
    @databasemail_profile = N'Your_Mail_Profile_Name', -- Thay bằng Profile Name của bạn
    @use_databasemail = 1;
GO
```

*(Cần restart dịch vụ SQL Server Agent sau khi đổi cấu hình Alert System lần đầu).*