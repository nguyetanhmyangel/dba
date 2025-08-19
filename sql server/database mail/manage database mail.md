#### 1. Bật Database Mail XPs

Trước tiên cần bật tính năng Database Mail trong SQL Server:

```bash
-- Bật Database Mail XPs
EXEC sp_configure 'show advanced options', 1;
RECONFIGURE;

EXEC sp_configure 'Database Mail XPs', 1;
RECONFIGURE;
```

### 2. Add

#### 2.1 Tạo account (SMTP)

```bash
EXEC msdb.dbo.sysmail_add_account_sp
    @account_name = 'MyMailAccount',
    @description  = 'Mail account for notifications',
    @email_address= 'your_email@domain.com',
    @display_name = 'SQL Server Notification',
    @mailserver_name = 'smtp.domain.com',
    @port = 587,   -- thường 25, 465 hoặc 587
    @enable_ssl = 1,
    @username = 'your_email@domain.com',
    @password = 'your_password';
```

#### 2.2 Tạo profile

```bash
EXEC msdb.dbo.sysmail_add_profile_sp
    @profile_name = 'MyMailProfile',
    @description = 'Profile for SQL Server Database Mail';
```

#### 2.3 Gán account vào profile

```bash
EXEC msdb.dbo.sysmail_add_profileaccount_sp
    @profile_name = 'MyMailProfile',
    @account_name = 'MyMailAccount',
    @sequence_number = 1;
```

#### 2.4 Gán quyền cho public role (tất cả user được dùng profile này)

Principal Profile: quyền gán một Database Mail profile cho một login/user cụ thể, giúp họ được phép gửi mail thông qua profile đó.

Mỗi profile có thể được gán ở 2 mức:

- Public profile: bất kỳ user nào trong SQL Server cũng có thể sử dụng để gửi mail.

- Private profile: chỉ một số login/user được phép sử dụng.

```bash
EXEC msdb.dbo.sysmail_add_principalprofile_sp
    @profile_name = 'MyMailProfile',
    @principal_id = 0,
    @is_default = 1;
```

### 3. Gửi mail thử

```bash
EXEC msdb.dbo.sp_send_dbmail
    @profile_name = 'MyMailProfile',
    @recipients = 'recipient@domain.com',
    @subject = 'Test mail from SQL Server',
    @body = 'This is a test email sent from SQL Server Database Mail';
```

### 4. Update

#### 4.1 1. Update Account

```bash
EXEC msdb.dbo.sysmail_update_account_sp
    @account_name    = 'MyMailAccount',      -- tên account đã tạo
    @description     = 'Updated mail account',
    @email_address   = 'new_email@domain.com',
    @display_name    = 'SQL Server Notification Updated',
    @mailserver_name = 'smtp.newdomain.com',
    @port            = 587,
    @enable_ssl      = 1,
    @username        = 'new_email@domain.com',
    @password        = 'new_password';
```

#### 4.2 Update Profile

```bash
EXEC msdb.dbo.sysmail_update_profile_sp
    @profile_name = 'MyMailProfile',
    @description  = 'Updated profile for SQL notifications';
```

#### 4.3 Update Profile Account

Có thể remove account cũ rồi add account mới vào profile:

```bash
-- Xóa account khỏi profile
EXEC msdb.dbo.sysmail_delete_profileaccount_sp
    @profile_name = 'MyMailProfile',
    @account_name = 'MyMailAccount';

-- Thêm account khác vào profile
EXEC msdb.dbo.sysmail_add_profileaccount_sp
    @profile_name    = 'MyMailProfile',
    @account_name    = 'NewMailAccount',
    @sequence_number = 1;
```

#### 4.4 Update Principal Profile

```bash
EXEC msdb.dbo.sysmail_update_principalprofile_sp
    @profile_name = 'MyMailProfile',
    @principal_name = 'public',
    @is_default = 1;
```

#### 4.5 Check

```bash
-- Kiểm tra account
SELECT * FROM msdb.dbo.sysmail_account;

-- Kiểm tra profile
SELECT * FROM msdb.dbo.sysmail_profile;

-- Kiểm tra account thuộc profile nào
SELECT p.name AS ProfileName, a.name AS AccountName
FROM msdb.dbo.sysmail_profileaccount pa
JOIN msdb.dbo.sysmail_profile p ON pa.profile_id = p.profile_id
JOIN msdb.dbo.sysmail_account a ON pa.account_id = a.account_id;
```

### 5. Delete

Qui trình: Xóa account ra khỏi profile (sysmail_delete_profileaccount_sp) -> Xóa account (sysmail_delete_account_sp) -> Xóa profile nếu muốn (sysmail_delete_profile_sp).

#### 5.1 Xóa account khỏi profile trước

```bash
EXEC msdb.dbo.sysmail_delete_profileaccount_sp
    @profile_name = 'MyMailProfile',
    @account_name = 'MyMailAccount';
```

#### 5.2 Xóa account

```bash
EXEC msdb.dbo.sysmail_delete_account_sp
    @account_name = 'MyMailAccount';
```

#### 5.3 Xóa profile

```bash
EXEC msdb.dbo.sysmail_delete_profile_sp
    @profile_name = 'MyMailProfile';
```

#### 5.4 Check

```bash
-- Danh sách account còn lại
SELECT * FROM msdb.dbo.sysmail_account;

-- Danh sách profile còn lại
SELECT * FROM msdb.dbo.sysmail_profile;

-- Quan hệ profile - account
SELECT p.name AS ProfileName, a.name AS AccountName
FROM msdb.dbo.sysmail_profileaccount pa
JOIN msdb.dbo.sysmail_profile p ON pa.profile_id = p.profile_id
JOIN msdb.dbo.sysmail_account a ON pa.account_id = a.account_id;
```

### 6. Kiểm tra trạng thái gửi mail

#### 6.1 Xem danh sách mail đã gửi

```bash
SELECT * 
FROM msdb.dbo.sysmail_allitems
ORDER BY send_request_date DESC;
```

#### 6.2 Xem mail thành công/thất bại

```bash
SELECT mailitem_id, recipients, subject, send_request_date, sent_status
FROM msdb.dbo.sysmail_allitems
ORDER BY mailitem_id DESC;
```

- sent_status = sent → gửi thành công
- sent_status = failed → lỗi

#### 6.3 Xem log lỗi chi tiết

```bash
SELECT * 
FROM msdb.dbo.sysmail_event_log
ORDER BY log_date DESC;
```

#### 6.4 Kiểm tra mail đang trong hàng chờ

```bash
SELECT * 
FROM msdb.dbo.sysmail_unsentitems;
```