Việc shrink transaction log file (.ldf) trong SQL Server nên được thực hiện một cách cẩn thận, vì log file cần không gian để hoạt động hiệu quả và tránh fragmentation. Không nên shrink thường xuyên trừ khi file log quá lớn và gây vấn đề về dung lượng đĩa. Dưới đây là chiến lược hiệu quả cho hai trường hợp bạn đề cập, dựa trên các thực hành tốt nhất (best practices) từ Microsoft SQL Server.

### 1. Database với recovery model là SIMPLE

Trong recovery model SIMPLE, transaction log được tự động truncate (giải phóng không gian) sau mỗi checkpoint, nên log thường không phát triển quá lớn trừ khi có giao dịch lớn kéo dài. Chiến lược shrink như sau:

#### Bước 1: Kiểm tra kích thước log hiện tại và không gian trống.

Sử dụng lệnh:

```bash
DBCC SQLPERF(LOGSPACE);
```
Hoặc:

```bash
SELECT name, size/128.0 AS Size_MB, used_pages/128.0 AS Used_MB 
FROM sys.database_files 
WHERE type_desc = 'LOG';
```

Nếu không gian trống (unused space) lớn, mới cần shrink.

#### Bước 2: Thực hiện checkpoint để truncate log.

Chạy lệnh:

```bash
CHECKPOINT;
```

Điều này giúp giải phóng không gian log trước khi shrink.

#### Bước 3: Shrink log file.

Sử dụng lệnh DBCC SHRINKFILE với kích thước mục tiêu hợp lý (ví dụ: shrink xuống còn 1 MB, nhưng nên để lớn hơn để tránh phát triển lại nhanh chóng):

```bash
USE [YourDatabaseName];
DBCC SHRINKFILE ('YourLogFileName', 1);  -- Shrink xuống 1 MB, điều chỉnh theo nhu cầu
```

Lưu ý: Không shrink xuống 0, và chỉ shrink khi database không có giao dịch đang chạy để tránh lock.

Mẹo hiệu quả:

- Theo dõi và lập lịch checkpoint định kỳ nếu cần.
- Nếu log vẫn lớn, kiểm tra nguyên nhân như index rebuild hoặc bulk insert, và tối ưu hóa query để giảm giao dịch lớn.
- Sau shrink, theo dõi performance vì shrink có thể gây fragmentation trên đĩa.

### 2. Database với recovery model là FULL và tham gia Always On Availability Groups (AG)

Trong FULL recovery model, log không tự động truncate mà cần backup transaction log để giải phóng không gian. Với AG, database phải ở FULL model, và shrink cần đảm bảo không ảnh hưởng đến replication giữa primary và secondary replicas (log phải được gửi và áp dụng đầy đủ).

#### Bước 1: Backup transaction log để truncate.

Backup log thường xuyên để giải phóng không gian (log chỉ truncate sau backup thành công):

```bash
BACKUP LOG [YourDatabaseName] TO DISK = 'C:\Backup\YourLogBackup.trn' WITH NOFORMAT, NOINIT;
```

- Trong AG, backup log nên thực hiện trên primary replica để tránh vấn đề đồng bộ.
- Nếu AG có secondary readable, có thể backup trên secondary để giảm tải primary (sử dụng BACKUP PREFERENCE).


#### Bước 2: Kiểm tra trạng thái AG và log.

Kiểm tra kích thước log:

DBCC SQLPERF(LOGSPACE);

Kiểm tra đồng bộ AG:

SELECT ag.name AS AG_Name, ar.replica_server_name, db.name AS Database_Name, rs.synchronization_health_desc 
FROM sys.dm_hadr_availability_replica_states rs
INNER JOIN sys.availability_groups ag ON rs.group_id = ag.group_id
INNER JOIN sys.availability_replicas ar ON rs.replica_id = ar.replica_id
INNER JOIN sys.databases db ON rs.database_id = db.database_id;

Đảm bảo tất cả replicas đều HEALTHY trước khi shrink.

#### Bước 3: Shrink log file trên primary replica.

Sau backup log, shrink:

USE [YourDatabaseName];
DBCC SHRINKFILE ('YourLogFileName', 1);  -- Shrink xuống kích thước hợp lý

Shrink chỉ trên primary; AG sẽ tự đồng bộ thay đổi file size.
Tránh shrink trong giờ cao điểm vì có thể gây delay replication.

Mẹo hiệu quả:

Lập lịch backup log định kỳ (ví dụ: mỗi 15-30 phút) để giữ log nhỏ, tránh cần shrink thường xuyên.
Sử dụng alert để theo dõi kích thước log (qua SQL Agent hoặc sys.dm_os_performance_counters).
Nếu log phát triển nhanh, kiểm tra nguyên nhân như thiếu backup, giao dịch dài, hoặc vấn đề đồng bộ AG (ví dụ: network latency giữa replicas).
Không shrink xuống quá nhỏ; giữ ít nhất 10-20% kích thước database để tránh auto-growth thường xuyên, gây performance hit.
Trong AG, nếu secondary có vấn đề, khắc phục trước khi shrink để tránh log buildup trên primary.

Lưu ý chung:

Shrink log không phải giải pháp lâu dài; hãy tối ưu hóa database (index, query, storage) để log không phát triển bất thường.
Sử dụng công cụ như SQL Server Management Studio (SSMS) để thực hiện các lệnh trên một cách trực quan.
Nếu gặp lỗi, kiểm tra error log SQL Server để debug.