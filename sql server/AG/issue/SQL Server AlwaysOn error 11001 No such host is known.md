## 1. Hiện tượng & Thông báo lỗi

* **Triệu chứng:** Database trên node Secondary rơi vào trạng thái `NOT SYNCHRONIZING`.
* **Trạng thái Replica:** `connected_state_desc = 'DISCONNECTED'`.
* **Mã lỗi ghi nhận:** `last_connect_error_number = 11001`.
* **Thông báo chi tiết:**
`Connection attempt failed with error: '11001(No such host is known.)'.`

## 2. Phân tích nguyên nhân gốc rễ (Root Cause)

1. **Lỗi phân giải tên miền (DNS / IPv6 Link-Local override):**
* Khi thực hiện `ping` hostname, hệ thống tự động ưu tiên phân giải ra dải IPv6 Link-Local (`fe80::...%6`).
* SQL Server Database Mirroring Endpoint không hỗ trợ tốt hoặc fail khi bắt tay TCP qua dải địa chỉ IPv6 Link-Local (do dính scope ID của interface mạng), dẫn tới mã lỗi WinSock `11001: WSAHOST_NOT_FOUND`.


2. **Sai lệch cấu hình chéo cổng (Port Mismatch):**
* Endpoint thực tế của Primary (`sql-intergrated`) đang lắng nghe ở cổng `5023`, nhưng AG metadata cấu hình `endpoint_url` lại trỏ tới `5022`.
* Endpoint thực tế của Secondary (`sql-web03\INTERGRATED`) đang lắng nghe ở cổng `5022`, nhưng AG metadata cấu hình `endpoint_url` lại trỏ tới `5023`.
* Hậu quả: Dù thông mạng, 2 node vẫn bắt tay trượt do kết nối sai port của nhau.

## 3. Các truy vấn chẩn đoán & Kiểm tra lỗi

### A. Truy vấn SQL DMV kiểm tra trạng thái kết nối & Port

Chạy trên cả hai node (Primary và Secondary):

```sql
-- 1. Kiểm tra port và trạng thái Database Mirroring Endpoint thực tế trên Instance
SELECT 
    name AS endpoint_name, 
    protocol_desc, 
    port, 
    state_desc 
FROM sys.tcp_endpoints 
WHERE type_desc = 'DATABASE_MIRRORING';

-- 2. Kiểm tra trạng thái kết nối AG và chi tiết lỗi handshake gần nhất
SELECT 
    ar.replica_server_name, 
    ar.endpoint_url, 
    ars.connected_state_desc, 
    ars.last_connect_error_number,
    ars.last_connect_error_description,
    ars.last_connect_error_timestamp
FROM sys.dm_hadr_availability_replica_states ars
JOIN sys.availability_replicas ar 
    ON ars.replica_id = ar.replica_id;

-- 3. Kiểm tra trạng thái data movement của từng database
SELECT 
    ar.replica_server_name, 
    adc.database_name, 
    drs.synchronization_state_desc, 
    drs.synchronization_health_desc,
    drs.suspend_reason_desc
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar ON drs.replica_id = ar.replica_id
JOIN sys.availability_databases_cluster adc ON drs.group_database_id = adc.group_database_id;
```

### B. Lệnh kiểm tra mạng & Port bằng PowerShell

Chạy trên cả hai máy chủ Windows:

```powershell
# 1. Kiểm tra phân giải tên miền (xem có bị trôi về fe80:: IPv6 hay không)
ping sql-intergrated.vietsov.com.vn
ping sql-web03.vietsov.com.vn

# Ép kiểm tra cụ thể với IPv4
ping -4 sql-intergrated.vietsov.com.vn
ping -4 sql-web03.vietsov.com.vn

# 2. Kiểm tra thông cổng Endpoint (đúng port mà instance đối tác đang LISTEN)
# Từ Secondary test sang Primary (Port 5023):
Test-NetConnection -ComputerName sql-intergrated.vietsov.com.vn -Port 5023

# Từ Primary test sang Secondary (Port 5022):
Test-NetConnection -ComputerName sql-web03.vietsov.com.vn -Port 5022
```

## 4. Quy trình khắc phục từng bước (Step-by-Step Fix)

### Bước 1: Ép DNS phân giải cố định về IPv4 qua file `hosts`

Mở Notepad với quyền Administrator (`C:\Windows\System32\drivers\etc\hosts`) trên cả 2 server:

* **Trên máy Secondary (`sql-web03`):** Thêm bản ghi trỏ về Primary
```text
172.19.9.34    sql-intergrated.vietsov.com.vn    sql-intergrated
```

* **Trên máy Primary (`sql-intergrated`):** Thêm bản ghi trỏ về Secondary và chính nó
```text
172.19.9.34    sql-intergrated.vietsov.com.vn    sql-intergrated
172.19.9.37    sql-web03.vietsov.com.vn          sql-web03
```

Xóa cache DNS trên Windows PowerShell:

```powershell
ipconfig /flushdns
```

### Bước 2: Khớp lại Endpoint URL trong Availability Group

Chạy lệnh T-SQL trên **node Primary** để sửa URL trỏ đúng vào cổng lắng nghe thực tế của từng node:

```sql
-- Cập nhật cho replica sql-intergrated (cổng Primary đang listen: 5023)
ALTER AVAILABILITY GROUP [Ten_Availability_Group]
MODIFY REPLICA ON N'sql-intergrated' 
WITH (ENDPOINT_URL = N'TCP://sql-intergrated.vietsov.com.vn:5023');

-- Cập nhật cho replica sql-web03\INTERGRATED (cổng Secondary đang listen: 5022)
ALTER AVAILABILITY GROUP [Ten_Availability_Group]
MODIFY REPLICA ON N'sql-web03\INTERGRATED' 
WITH (ENDPOINT_URL = N'TCP://sql-web03.vietsov.com.vn:5022');
```

### Bước 3: Restart Endpoint trên Secondary để buộc kết nối lại

Thực thi trên **node Secondary**:

```sql
ALTER ENDPOINT [Hadr_endpoint] STATE = STOPPED;
GO
ALTER ENDPOINT [Hadr_endpoint] STATE = STARTED;
GO
```
Lưu ý:Cái tên Hadr_endpoint là tên phổ biến nhất do giao diện SSMS tự đặt theo mặc định. Tuy nhiên, nó có thể mang tên khác tùy thuộc vào người tạo lúc đầu (ví dụ: MirroringEndpoint, AG_Endpoint...).
Để biết chính xác tên endpoint trên instance của bạn là gì, kiểm tra bằng lệnh:

```SQL
SELECT name, endpoint_id, protocol_desc, state_desc, port 
FROM sys.tcp_endpoints 
WHERE type_desc = 'DATABASE_MIRRORING';
```

### Bước 4: Kích hoạt đồng bộ lại Database (Resume HADR)

Sau khi `connected_state_desc` trong DMV hiển thị **`CONNECTED`**, chạy trên **node Secondary**:

```sql
ALTER DATABASE [your-database] SET HADR RESUME;
```