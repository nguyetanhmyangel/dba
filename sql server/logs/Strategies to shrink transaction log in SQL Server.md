- Việc shrink transaction log file (.ldf) trong SQL Server nên được thực hiện một cách cẩn thận, vì log file cần không gian để hoạt động hiệu quả và tránh fragmentation. 

- Không nên shrink thường xuyên trừ khi file log quá lớn và gây vấn đề về dung lượng đĩa. Dưới đây là chiến lược hiệu quả cho hai trường hợp bạn đề cập, dựa trên các thực hành tốt nhất (best practices) từ Microsoft SQL Server.

### 1. Database với recovery model là SIMPLE

- Trong recovery model SIMPLE, transaction log được tự động truncate (giải phóng không gian) sau mỗi checkpoint, nên log thường không phát triển quá lớn trừ khi có giao dịch lớn kéo dài. Chiến lược shrink như sau:

#### Bước 1: Kiểm tra kích thước log hiện tại và không gian trống.

- Sử dụng lệnh:

```bash
DBCC SQLPERF(LOGSPACE);

-- or
SELECT name, size/128.0 AS Size_MB, used_pages/128.0 AS Used_MB 
FROM sys.database_files 
WHERE type_desc = 'LOG';
```

- Nếu không gian trống (unused space) lớn, mới cần shrink.

#### Bước 2: Thực hiện checkpoint để truncate log.

- Chạy lệnh sau giúp giải phóng không gian log trước khi shrink.:

```bash
CHECKPOINT;
```

#### Bước 3: Shrink log file.

- Sử dụng lệnh DBCC SHRINKFILE với kích thước mục tiêu hợp lý (ví dụ: shrink xuống còn 1 MB, nhưng nên để lớn hơn để tránh phát triển lại nhanh chóng):

```bash
USE [YourDatabaseName];
DBCC SHRINKFILE ('YourLogFileName', 1);  -- Shrink xuống 1 MB, điều chỉnh theo nhu cầu
```

- Lưu ý: Không shrink xuống 0, và chỉ shrink khi database không có giao dịch đang chạy để tránh lock.

- Mẹo hiệu quả:

    - Theo dõi và lập lịch checkpoint định kỳ nếu cần.
    - Nếu log vẫn lớn, kiểm tra nguyên nhân như index rebuild hoặc bulk insert, và tối ưu hóa query để giảm giao dịch lớn.
    - Sau shrink, theo dõi performance vì shrink có thể gây fragmentation trên đĩa.

### 2. Database với recovery model là FULL và tham gia Always On Availability Groups (AG)

- Trong FULL recovery model, log không tự động truncate mà cần backup transaction log để giải phóng không gian. Với AG, database phải ở FULL model, và shrink cần đảm bảo không ảnh hưởng đến replication giữa primary và secondary replicas (log phải được gửi và áp dụng đầy đủ).

#### Bước 1: Backup transaction log để truncate.

Backup log thường xuyên để giải phóng không gian (log chỉ truncate sau backup thành công):

```bash
BACKUP LOG [YourDatabaseName] TO DISK = 'C:\Backup\YourLogBackup.trn' WITH NOFORMAT, NOINIT;
```

- Trong AG, backup log nên thực hiện trên primary replica để tránh vấn đề đồng bộ.
- Nếu AG có secondary readable, có thể backup trên secondary để giảm tải primary (sử dụng BACKUP PREFERENCE).


#### Bước 2: Kiểm tra trạng thái AG và log.

- Kiểm tra kích thước log:

```bash
DBCC SQLPERF(LOGSPACE);
```

- Kiểm tra đồng bộ AG:

```bash
SELECT ag.name AS AG_Name, ar.replica_server_name, db.name AS Database_Name, rs.synchronization_health_desc 
FROM sys.dm_hadr_availability_replica_states rs
INNER JOIN sys.availability_groups ag ON rs.group_id = ag.group_id
INNER JOIN sys.availability_replicas ar ON rs.replica_id = ar.replica_id
INNER JOIN sys.databases db ON rs.database_id = db.database_id;
```

- Đảm bảo tất cả replicas đều HEALTHY trước khi shrink.

#### Bước 3: Shrink log file trên primary replica.

- Sau backup log, shrink:

```bash
USE [YourDatabaseName];
DBCC SHRINKFILE ('YourLogFileName', 1);  -- Shrink xuống kích thước hợp lý
```

#### Bước 4: Đặt kích thước log mong muốn(tốt nhất trong 1 lần):

* Tại sao cần phát triển log trong một lần duy nhất?

    - Tránh autogrow lặp lại: Autogrow (tự động mở rộng) thường xuyên với kích thước tăng nhỏ (ví dụ: 1 MB hoặc 10%) có thể tạo ra nhiều VLF, làm giảm hiệu suất.

    - Kiểm soát VLF: Mỗi lần log tăng kích thước, SQL Server tạo thêm VLF. Phát triển log trong một lần duy nhất giúp kiểm soát số lượng VLF hợp lý.

    - Tối ưu hiệu suất: Một kích thước log được cấu hình đúng giúp giảm thiểu sự gián đoạn do mở rộng file log trong quá trình hoạt động.

```bash
ALTER DATABASE YourDatabaseName
MODIFY FILE (NAME = N'YourLogFileName', SIZE = 4096MB, FILEGROWTH = 512MB);
```

* Xác định kích thước log hợp lý ,không có kích thước cụ thể cố định cho mọi cơ sở dữ liệu, nhưng có thể dựa vào các yếu tố sau để xác định kích thước hợp lý:

- Kích thước log tối thiểu: Log nên có kích thước từ 10-25% kích thước file dữ liệu (.mdf + .ndf) trong các cơ sở dữ liệu có mức giao dịch trung bình.

Ví dụ: Nếu file dữ liệu là 10 GB, log nên khoảng 1-2.5 GB (1024-2560 MB).

- Tính đến giao dịch lớn nhất: Log cần đủ lớn để chứa giao dịch lớn nhất (như rebuild index, bulk insert). Một cách ước lượng: Log size ≥ 2 × kích thước của giao dịch lớn nhất.

Ví dụ: Nếu rebuild index cho bảng 2 GB, log nên ít nhất 4 GB.

- Tăng trưởng tương lai: Cộng thêm khoảng 20-50% kích thước dự kiến để đáp ứng tăng trưởng trong tương lai (trong 6-12 tháng). Để  kiểm tra kích thước file dữ liệu và log hiện tại:

```bash
SELECT name, size/128.0 AS Size_MB
FROM sys.master_files
WHERE database_id = DB_ID('YourDatabaseName');
```
- Dự đoán dựa trên workload:

    - Cơ sở dữ liệu giao dịch cao (OLTP): Log có thể cần lớn hơn, khoảng 25-50% kích thước file dữ liệu hoặc hơn, tùy thuộc vào tần suất và khối lượng giao dịch.

    - Cơ sở dữ liệu báo cáo/warehouse (OLAP): Log thường nhỏ hơn, khoảng 10-20% kích thước file dữ liệu, do ít giao dịch ghi hơn.
    Hoạt động đặc biệt: Nếu có các tác vụ như rebuild index, ETL (Extract, Transform, Load), hoặc bulk insert, hãy ước lượng log dựa trên giao dịch lớn nhất.

* Quản lý số lượng VLF, khi đặt kích thước log, cần đảm bảo số lượng VLF hợp lý (không quá nhiều, không quá ít):

SQL Server tạo VLF dựa trên kích thước log theo các quy tắc:

    - Log < 1 MB: 4 VLF.
    - Log từ 1 MB đến < 64 MB: 4 VLF.
    - Log từ 64 MB đến < 1 GB: 8 VLF.
    - Log ≥ 1 GB: 16 VLF.

- Công thức gần đúng: Số VLF ≈ Kích thước log (MB) / (kích thước trung bình của mỗi VLF).

- Kích thước trung bình VLF thường là 1/4 đến 1/8 kích thước tăng trưởng (growth increment).

- Ngưỡng VLF hợp lý:

    - 50-100 VLF cho cơ sở dữ liệu nhỏ/trung bình.

    - 100-300 VLF cho cơ sở dữ liệu lớn.

    - Tránh > 1000 VLF để đảm bảo hiệu suất sao lưu/khôi phục.

- Cách tối ưu VLF:

    - Sau khi shrink log, sử dụng DBCC LOGINFO để kiểm tra số lượng VLF.

    - Đặt kích thước log mới với mức tăng trưởng hợp lý:

```bash
sqlALTER DATABASE YourDatabaseName
MODIFY FILE (NAME = N'YourLogFileName', SIZE = 4096MB, FILEGROWTH = 512MB);
```

- Kiểm tra lại VLF sau khi đặt kích thước:

```bash
sqlDBCC LOGINFO;

-- Hoặc, nếu dùng SQL Server 2017 trở lên
SELECT file_id, COUNT(*) AS VLFCount
FROM sys.dm_db_log_info(DB_ID('YourDatabaseName'))
GROUP BY file_id;
```
Ví dụ: Nếu đặt log thành 4 GB (4096 MB) với FILEGROWTH = 512 MB, mỗi lần tăng trưởng tạo khoảng 8-16 VLF. Tổng số VLF ban đầu có thể khoảng 64-128, phù hợp cho hầu hết các cơ sở dữ liệu.

- Khuyến nghị cụ thể

`- Size:

    - Cơ sở dữ liệu nhỏ (<10 GB dữ liệu): 512 MB - 2 GB.

    - Cơ sở dữ liệu trung bình (10-100 GB): 2-10 GB.

    - Cơ sở dữ liệu lớn (>100 GB): 10-50 GB hoặc hơn, tùy workload.


- FILEGROWTH đề xuất:

    - 512 MB hoặc 1 GB cho hầu hết các trường hợp.
    - Tránh mức tăng trưởng nhỏ như 1 MB hoặc 10%, vì sẽ tạo quá nhiều VLF.
