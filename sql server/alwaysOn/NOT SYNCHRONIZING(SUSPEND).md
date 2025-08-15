#### 2.tìm ra các database đang bị tạm dừng (SUSPENDED) trong Availability Group.


```bash
SELECT
    ag.name AS AG_Name,
    ar.replica_server_name,
    DB_NAME(drs.database_id) AS database_name, -- Sử dụng hàm DB_NAME()
    drs.synchronization_state_desc,
    drs.synchronization_health_desc,
    drs.is_suspended,
    drs.suspend_reason_desc
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar
    ON drs.replica_id = ar.replica_id
JOIN sys.availability_groups ag
    ON ar.group_id = ag.group_id
-- Không cần JOIN với sys.availability_databases_cluster nữa
WHERE drs.is_suspended = 1;

```

### 2. SUSPEND_FROM_APPLY

Nếu column suspend_reason_desc trả về  lý do SUSPEND_FROM_APPLY có nghĩa là quá trình đồng bộ dữ liệu đã bị tạm dừng một cách tự động bởi chính SQL Server trên node Secondary. Đây là một cơ chế tự bảo vệ.

Điều này xảy ra khi node Secondary đã nhận được dữ liệu log từ Primary, nhưng lại gặp lỗi nghiêm trọng khi cố gắng "áp dụng" (apply/redo) những thay đổi đó vào file dữ liệu (.mdf) hoặc file log (.ldf). Do không thể ghi lại giao dịch một cách an toàn, SQL Server quyết định tạm dừng database đó để tránh các sự cố nghiêm trọng hơn.

Các bước chẩn đoán và khắc phục (Bắt buộc),p hải thực hiện các bước này trên node Secondary nơi database bị tạm dừng.

- Bước 1: Kiểm tra SQL Server Error Log (Quan trọng nhất)

Đây là nơi đầu tiên và quan trọng nhất cần xem. Nó sẽ ghi lại chính xác lỗi đã gây ra việc tạm dừng.

Kết nối đến node Secondary bằng SQL Server Management Studio (SSMS).

Mở SQL Server Logs trong mục Management.

Tìm các bản ghi lỗi xảy ra vào khoảng thời gian database bị tạm dừng. Hãy tìm các từ khóa như:

"I/O error", "operating system error": Cho thấy có vấn đề với ổ đĩa.

"Disk is full": Ổ đĩa chứa file data hoặc log đã hết dung lượng.

"Access is denied": Tài khoản dịch vụ SQL Server không có quyền ghi lên file/thư mục.

Lỗi liên quan đến không thể mở rộng file log (log file could not be grown).

-Bước 2: Kiểm tra Windows Event Viewer

Trên node Secondary, mở Event Viewer và kiểm tra trong mục Windows Logs > System và Application để tìm các lỗi liên quan đến ổ đĩa (Disk) hoặc NTFS xảy ra cùng thời điểm.

- Bước 3: Kiểm tra các nguyên nhân phổ biến khác

Dung lượng ổ đĩa: Đảm bảo các ổ đĩa chứa file .mdf và .ldf của database đó trên secondary còn đủ dung lượng trống.

Quyền thư mục: Đảm bảo tài khoản dịch vụ SQL Server có quyền "Full Control" trên các thư mục chứa file database.

Lệnh để tiếp tục đồng bộ (Chỉ chạy sau khi đã sửa lỗi gốc). Sau khi đã xác định và khắc phục được nguyên nhân gốc rễ (ví dụ: giải phóng dung lượng đĩa, sửa lỗi ổ cứng, cấp lại quyền...), Hãy kết nối đến node Secondary và chạy lệnh sau để tiếp tục quá trình đồng bộ:


```bash
ALTER DATABASE [TênDatabase] SET HADR RESUME;
```

- Kiểm tra lại trạng thái sau khi RESUME

```bash
SELECT 
    drs.database_id,
    db_name(drs.database_id) AS database_name,
    drs.synchronization_state_desc,
    drs.suspend_reason_desc,
    drs.is_suspended
FROM sys.dm_hadr_database_replica_states drs
WHERE db_name(drs.database_id) = 'BK22_RDB_SCHEMA';

```
