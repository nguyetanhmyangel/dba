- Nguyên nhân phổ biến nhất khiến transaction log trong AG bị đầy là do Primary replica không thể tái sử dụng file log vì nó đang chờ một hoặc nhiều Secondary replica xác nhận đã nhận và ghi (harden) các bản ghi log đó. Về cơ bản, Primary đang bị Secondary "kìm hãm".

- Hành động giải quyết tập trung vào việc tìm ra Secondary replica nào đang bị chậm và tại sao, sau đó khắc phục sự cố trên replica đó.

#### Nguyên nhân chính

- Trong một Availability Group, SQL Server sẽ không cho phép giải phóng (truncate) transaction log trên Primary replica cho đến khi các thay đổi đó được gửi và ghi thành công vào file log trên tất cả các Secondary replica. Điều này đảm bảo rằng nếu có sự cố xảy ra, mọi replica đều có đủ thông tin để phục hồi về một trạng thái nhất quán.

    - Các lý do khiến Secondary replica bị tụt lại phía sau bao gồm:

    - Mạng chậm hoặc không ổn định: Kết nối mạng giữa Primary và Secondary bị gián đoạn hoặc có độ trễ cao.

    - Secondary replica bị quá tải: Secondary replica có cấu hình phần cứng (I/O, CPU, RAM) yếu hơn Primary, không xử lý kịp lượng log gửi đến.

    - Data movement bị tạm dừng (Suspended): Một người quản trị đã tạm dừng việc đồng bộ dữ liệu trên database ở Secondary replica.

    - Secondary replica bị tắt hoặc mất kết nối.

    - Một transaction rất lớn đang chạy trên Primary, tạo ra một lượng log khổng lồ trong thời gian ngắn, khiến Secondary không theo kịp.

#### Các bước kiểm tra và chẩn đoán

Cần thực hiện các bước sau trên Primary replica để xác định nguyên nhân gốc rễ.

* Bước 1: Kiểm tra lý do log không thể tái sử dụng, Đây là bước quan trọng nhất. Chạy câu lệnh sau trên Primary replica.

```bash
SELECT name, log_reuse_wait_desc
FROM sys.databases
WHERE name = 'Ten_Database_Check'; -- Thay bằng tên DB cần kiểm tra.
```

- Trong môi trường AG, kết quả cần chú ý nhất ở cột log_reuse_wait_desc là AVAILABILITY_REPLICA. Nếu thấy giá trị này, nó xác nhận 100% rằng log bị đầy là do một Secondary replica nào đó đang làm chậm quá trình. Các giá trị khác có thể gặp:

    - LOG_BACKUP: Chưa backup transaction log.

    - ACTIVE_TRANSACTION: Có một transaction đang chạy rất lâu.

    - NOTHING: Không có gì ngăn cản, có thể chỉ đơn giản là log vừa được sử dụng hết.

* Bước 2: Sử dụng AG Dashboard để xem tổng quan

Trong SQL Server Management Studio (SSMS), vào Always On High Availability > Availability Groups > [Tên AG cần kiểm tra] và chuột phải chọn Show Dashboard.

Trong Dashboard, hãy chú ý đến các cột:

- BSynchronization State: Đảm bảo tất cả đều là Synchronized hoặc Synchronizing.

- BLog Send Queue Size: Cho biết lượng log (KB) đang chờ được gửi từ Primary đến Secondary. Nếu con số này lớn, vấn đề có thể do mạng.

- BRedo Queue Size: Cho biết lượng log (KB) đã đến Secondary nhưng chưa được ghi vào file database. Nếu con số này lớn, vấn đề là do hiệu năng I/O (ổ đĩa) trên Secondary.

Dashboard sẽ chỉ rõ replica nào đang có vấn đề.

* Bước 3: Dùng DMV để kiểm tra chi tiết. Để có thông tin chính xác hơn Dashboard, hãy chạy truy vấn sau trên Primary

```bash
SELECT
    ar.replica_server_name,
    drs.database_id,
    db_name(drs.database_id) AS database_name,
    drs.synchronization_state_desc,
    drs.log_send_queue_size, -- Đang chờ gửi đi (vấn đề mạng)
    drs.log_send_rate,
    drs.redo_queue_size, -- Đã nhận, chờ ghi (vấn đề I/O trên secondary)
    drs.redo_rate,
    drs.last_commit_time
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar ON drs.replica_id = ar.replica_id
WHERE db_name(drs.database_id) = 'Ten_Database_Check'; -- Thay bằng tên DB cần kiểm tra
```

Query này sẽ cho con số chính xác về log_send_queue_size và redo_queue_size cho từng replica, giúp khoanh vùng vấn đề là do mạng hay do hiệu năng của máy Secondary.

#### Hành động giải quyết

Sau khi đã xác định được nguyên nhân, hãy thực hiện các hành động tương ứng.

1. Nếu vấn đề do Mạng (Log Send Queue cao):

- Kiểm tra kết nối mạng: Dùng ping hoặc các công cụ khác để kiểm tra độ trễ và tình trạng mất gói tin giữa Primary và Secondary.

- Kiểm tra băng thông: Đảm bảo băng thông mạng không bị nghẽn bởi các ứng dụng khác.

- Kiểm tra Firewall/Thiết bị mạng: Đảm bảo không có thiết bị nào đang chặn hoặc làm chậm traffic trên cổng của SQL Server.

2. Nếu vấn đề do hiệu năng Secondary (Redo Queue cao):

- Kiểm tra I/O trên Secondary: Dùng Performance Monitor để theo dõi các chỉ số về disk I/O trên Secondary. Có thể ổ đĩa đang bị quá tải.

- Kiểm tra tài nguyên khác: CPU và RAM trên Secondary có đang bị sử dụng quá mức bởi các tiến trình khác không?

- Xem xét nâng cấp phần cứng: Nếu Secondary luôn bị chậm, có thể nó có cấu hình yếu hơn Primary và cần được nâng cấp.

3. Nếu Data Movement đang bị Suspended:

- Resume lại việc đồng bộ: Chuột phải vào database bị suspended trong SSMS (trên Primary) và chọn Resume Data Movement. Hoặc dùng lệnh T-SQL

```bash
ALTER DATABASE [Ten_Database_Check] SET HADR RESUME;
```

4. Sau khi đã giải quyết vấn đề trên Secondary, Secondary đã bắt kịp Primary (Log Send Queue và Redo Queue đã về gần 0), log trên Primary sẽ có thể được giải phóng. Lúc này hãy:

Backup Transaction Log: Đây là hành động cho phép SQL Server đánh dấu các phần không còn hoạt động trong log là có thể tái sử dụng.

```bash
BACKUP LOG [Ten_Database_Check] TO DISK = 'NUL:'; -- Backup nhanh vào "thiết bị rỗng"
-- Hoặc backup ra file như bình thường
BACKUP LOG [Ten_Database_Check] TO DISK = 'D:\Backups\Ten_Database_Check.trn';
```

#### Giải pháp khẩn cấp (Khi ổ đĩa sắp đầy)

Nếu ổ đĩa chứa file log sắp đầy và không thể giải quyết vấn đề trên Secondary ngay lập tức, có thể thêm một file log mới: Thêm một file log thứ hai trên một ổ đĩa khác còn trống. SQL Server sẽ bắt đầu ghi vào file mới này, cho thêm thời gian để xử lý sự cố.

```bash
ALTER DATABASE [Ten_Database_Cua_Ban]
ADD LOG FILE
(
    NAME = N'Ten_Database_Cua_Ban_log2',
    FILENAME = N'E:\SQL_Logs\Ten_Database_Cua_Ban_log2.ldf', -- Đường dẫn đến ổ đĩa mới
    SIZE = 10240MB, -- Kích thước ban đầu
    FILEGROWTH = 1024MB
);
```
Hành động này không giải quyết gốc rễ vấn đề nhưng sẽ giúp hệ thống không bị dừng hoạt động. Sau khi khắc phục được sự cố đồng bộ, có thể shrink và xóa file log tạm thời này đi.

