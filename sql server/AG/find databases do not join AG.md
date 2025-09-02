### 1. Script sau chỉ chạy trên PRIMARY replica và có các tính năng sau:

- Kiểm tra Recovery Model (FULL/SIMPLE).

- Kiểm tra sự tồn tại của bản backup FULL gần nhất.

- Phân loại trạng thái db sau đó đưa ra hành động đề xuất chính xác:

* Sẵn sàng tham gia AG: Đã ở chế độ FULL và đã có backup FULL.

* Cần backup: Đã ở chế độ FULL nhưng chưa có backup FULL.

* Cần đổi Recovery Model: Đang ở chế độ SIMPLE.

- Tự động tạo lệnh thêm vào AG cho các DB đã sẵn sàng.


```bash
-- Khai báo biến để lưu tên AG mà instance này là PRIMARY
DECLARE @AGName NVARCHAR(128);

-- Tìm tên của AG mà instance hiện tại là PRIMARY replica
SELECT @AGName = ag.name
FROM sys.dm_hadr_availability_replica_states rs
JOIN sys.availability_groups ag ON rs.group_id = ag.group_id
WHERE rs.role_desc = 'PRIMARY' AND rs.is_local = 1;

-- Nếu instance này là PRIMARY của một AG nào đó
IF @AGName IS NOT NULL
BEGIN
    PRINT N'Instance này là PRIMARY replica cho Availability Group: [' + @AGName + N'].';
    PRINT N'Đang phân loại các database chưa tham gia AG...';
   
    -- Truy vấn và phân loại các database
    SELECT
        d.name AS DatabaseName,
        d.recovery_model_desc AS RecoveryModel,
        -- Sử dụng CASE để phân loại trạng thái và đưa ra khuyến nghị
        CASE
            WHEN d.recovery_model_desc = 'SIMPLE' THEN 'Needs Recovery Model Change'
            WHEN d.recovery_model_desc = 'FULL' AND b.last_full_backup_date IS NULL THEN 'Needs First FULL Backup'
            WHEN d.recovery_model_desc = 'FULL' AND b.last_full_backup_date IS NOT NULL THEN 'Ready to Join AG'
            ELSE 'Unknown Status'
        END AS AvailabilityStatus,
        -- Tạo câu lệnh khuyến nghị tương ứng với từng trạng thái
        CASE
            WHEN d.recovery_model_desc = 'SIMPLE' THEN N'1. ALTER DATABASE [' + d.name + N'] SET RECOVERY FULL; 2. BACKUP DATABASE [' + d.name + N'] TO DISK=...'
            WHEN d.recovery_model_desc = 'FULL' AND b.last_full_backup_date IS NULL THEN N'BACKUP DATABASE [' + d.name + N'] TO DISK = ''path_to_your_backup_file.bak'';'
            WHEN d.recovery_model_desc = 'FULL' AND b.last_full_backup_date IS NOT NULL THEN N'ALTER DATABASE [' + d.name + N'] SET HADR AVAILABILITY GROUP = [' + @AGName + N'];'
            ELSE 'Please investigate manually.'
        END AS Recommended_Action
    FROM
        sys.databases d
    -- Lấy thông tin về lần backup FULL cuối cùng từ MSDB
    LEFT JOIN (
        SELECT
            database_name,
            MAX(backup_finish_date) AS last_full_backup_date
        FROM msdb.dbo.backupset
        WHERE type = 'D' -- 'D' là backup FULL
        GROUP BY database_name
    ) b ON d.name = b.database_name
    WHERE
        -- Điều kiện 1: Database chưa thuộc bất kỳ AG nào
        NOT EXISTS (
            SELECT 1
            FROM sys.dm_hadr_database_replica_states drs
            WHERE d.database_id = drs.database_id
        )
        -- Điều kiện 2: Bỏ qua các database hệ thống và phải đang ONLINE
        AND d.database_id > 4
        AND d.state_desc = 'ONLINE'
    ORDER BY
        AvailabilityStatus, d.name;
END
ELSE
BEGIN
    -- Thông báo nếu instance không phải là PRIMARY replica
    PRINT N'Thông báo: Instance này không phải là PRIMARY replica của bất kỳ Availability Group nào.';
END
GO
```

### 2. Script chạy tự động trên một SQL Server Agent Job để gửi mail cảnh báo tự động

Cách hoạt động:

- Chỉ thực thi trên PRIMARY replica.

- Nếu phát hiện database cần cấu hình, sẽ gửi email cảnh báo với danh sách chi tiết.

- Kiểm tra và gửi mail: Nếu có bất kỳ database nào được tìm thấy (nội dung mail không rỗng), nó sẽ thực thi lệnh msdb.dbo.sp_send_dbmail để gửi cảnh báo. Nếu không tìm thấy database nào, script sẽ không làm gì cả.

```bash
-- Chỉ thực thi logic nếu instance hiện tại là PRIMARY replica
IF EXISTS (
    SELECT 1
    FROM sys.dm_hadr_availability_replica_states
    WHERE role_desc = 'PRIMARY' AND is_local = 1
)
BEGIN
    -- Khai báo các biến cần thiết
    DECLARE @emailBody NVARCHAR(MAX);
    DECLARE @emailSubject NVARCHAR(255);
    DECLARE @AGName NVARCHAR(128);
    DECLARE @tableHeader NVARCHAR(MAX);
    DECLARE @tableStyle NVARCHAR(MAX);

    -- Lấy tên AG mà instance này là PRIMARY
    SELECT @AGName = ag.name
    FROM sys.dm_hadr_availability_replica_states rs
    JOIN sys.availability_groups ag ON rs.group_id = ag.group_id
    WHERE rs.role_desc = 'PRIMARY' AND rs.is_local = 1;

    -- Định dạng CSS cho bảng HTML trong email
    SET @tableStyle = N'<style>' +
                      N'table {border-collapse: collapse; width: 100%; font-family: Arial, sans-serif;}' +
                      N'th, td {border: 1px solid #dddddd; text-align: left; padding: 8px;}' +
                      N'th {background-color: #f2f2f2; color: #333; font-weight: bold;}' +
                      N'tr:nth-child(even) {background-color: #f9f9f9;}' +
                      N'</style>';

    -- Tạo phần thân của bảng HTML từ kết quả truy vấn
    SET @emailBody = CAST((
        SELECT
            d.name AS 'td','',
            d.recovery_model_desc AS 'td','',
            CASE
                WHEN d.recovery_model_desc = 'SIMPLE' THEN 'Needs Recovery Model Change'
                WHEN d.recovery_model_desc = 'FULL' AND b.last_full_backup_date IS NULL THEN 'Needs First FULL Backup'
                WHEN d.recovery_model_desc = 'FULL' AND b.last_full_backup_date IS NOT NULL THEN 'Ready to Join AG'
                ELSE 'Unknown Status'
            END AS 'td','',
            CASE
                WHEN d.recovery_model_desc = 'SIMPLE' THEN N'1. ALTER DATABASE [' + d.name + N'] SET RECOVERY FULL; 2. BACKUP DATABASE...'
                WHEN d.recovery_model_desc = 'FULL' AND b.last_full_backup_date IS NULL THEN N'BACKUP DATABASE [' + d.name + N'] TO DISK = ''...'''
                WHEN d.recovery_model_desc = 'FULL' AND b.last_full_backup_date IS NOT NULL THEN N'ALTER DATABASE [' + d.name + N'] SET HADR AVAILABILITY GROUP = [' + @AGName + N'];'
                ELSE 'Please investigate manually.'
            END AS 'td'
        FROM
            sys.databases d
        LEFT JOIN (
            SELECT
                database_name,
                MAX(backup_finish_date) AS last_full_backup_date
            FROM msdb.dbo.backupset
            WHERE type = 'D'
            GROUP BY database_name
        ) b ON d.name = b.database_name
        WHERE
            NOT EXISTS (SELECT 1 FROM sys.dm_hadr_database_replica_states drs WHERE d.database_id = drs.database_id)
            AND d.database_id > 4
            AND d.state_desc = 'ONLINE'
        ORDER BY 3, 1
        FOR XML PATH('tr'), ROOT('table'), TYPE
    ) AS NVARCHAR(MAX));

    -- >> KIỂM TRA NẾU CÓ KẾT QUẢ THÌ MỚI GỬI MAIL <<
    IF @emailBody IS NOT NULL
    BEGIN
        -- Đặt tiêu đề email
        SET @emailSubject = N'Cảnh báo AG (' + @@SERVERNAME + N'): Có Database cần cấu hình để tham gia AG ' + @AGName;

        -- Tạo tiêu đề cho bảng
        SET @tableHeader = N'<html><head>' + @tableStyle + N'</head><body>' +
                         N'<h3>Phát hiện các database trên server [' + @@SERVERNAME + N'] cần được kiểm tra để tham gia Availability Group [' + @AGName + N'].</h3>' +
                         N'<table border="1">' +
                         N'<tr><th>Database Name</th><th>Recovery Model</th><th>Status</th><th>Recommended Action</th></tr>';

        -- Ghép toàn bộ nội dung email
        SET @emailBody = @tableHeader + @emailBody + N'</table></body></html>';

        -- Thực thi gửi mail
        EXEC msdb.dbo.sp_send_dbmail
            @profile_name = 'Your_Database_Mail_Profile', -- ❗ THAY THẾ bằng tên Database Mail Profile của bạn
            @recipients = 'dba_team@yourcompany.com;dev_lead@yourcompany.com', -- ❗ THAY THẾ bằng danh sách email người nhận, cách nhau bởi dấu chấm phẩy
            @subject = @emailSubject,
            @body = @emailBody,
            @body_format = 'HTML';
    END
END
```