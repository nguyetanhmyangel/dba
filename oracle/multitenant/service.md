# Oracle Database Service

## 1. Oracle Service là gì?

Trong Oracle Database, **Service** là một tên dịch vụ logic dùng để xác định nhóm kết nối đến cơ sở dữ liệu. 
Client sử dụng Service để yêu cầu Oracle Database xử lý kết nối và định tuyến session đến 
database hoặc Pluggable Database (PDB) phù hợp.

Ví dụ, một hệ thống Oracle có:

- CDB: `ORCLCDB`
- PDB: `PROD_PDB`
- Listener: `LISTENER`
- Service: `prod_pdb`

Ứng dụng có thể kết nối bằng Service `prod_pdb` mà không cần biết cấu trúc vật lý của các datafile trong ASM.

### Ví dụ chuỗi kết nối

```
sqlplus app_user@//192.168.56.101:1521/prod_pdb
```

Trong đó:

| Thành phần       | Ý nghĩa                   |
| ---------------- | ------------------------- |
| `sqlplus`        | Công cụ kết nối Oracle    |
| `app_user`       | Tên tài khoản database    |
| `192.168.56.101` | Địa chỉ máy chủ           |
| `1521`           | Cổng Listener             |
| `prod_pdb`       | Service mà client yêu cầu |

Lưu ý: `prod_pdb` phải là Service thực sự được đăng ký và có thể kết nối trên Listener đó. 
IP và port trên chỉ là ví dụ cho môi trường lab.

---

## 2. Phân biệt Database, CDB, PDB, Instance, Service và Listener

Đây là những khái niệm có liên quan nhưng không đồng nghĩa với nhau.

| Thành phần | Vai trò                                                                                                     |
| ---------- | ----------------------------------------------------------------------------------------------------------- |
| Database   | Cơ sở dữ liệu vật lý, gồm các file dữ liệu, control file và online redo log                                 |
| CDB        | Container Database, cơ sở dữ liệu container trong kiến trúc Multitenant                                     |
| PDB        | Pluggable Database, database logic có thể được quản lý riêng bên trong CDB                                  |
| Instance   | Các tiến trình Oracle và vùng nhớ SGA dùng để vận hành database                                             |
| Service    | Tên logic dùng để định tuyến kết nối đến database hoặc PDB                                                  |
| Listener   | Tiến trình nhận yêu cầu kết nối từ client và giúp chuyển kết nối đến instance/service phù hợp               |
| ASM        | Hệ thống quản lý lưu trữ của Oracle, có thể quản lý các file database trên disk group như `+DATA` và `+FRA` |

### Minh họa luồng kết nối

```
Ứng dụng / SQL*Plus
        |
        | Connect bằng Service
        v
Oracle Listener
        |
        | Xác định handler phù hợp
        v
Oracle Instance
        |
        | Tạo session trong container phù hợp
        v
CDB$ROOT hoặc PDB
        |
        v
Xử lý truy vấn và dữ liệu
```

**Điểm quan trọng:** Listener không phải là database, Service không phải là PDB, và Instance cũng không phải là Service.

Một PDB có thể có nhiều Service phục vụ các nhóm ứng dụng hoặc mục đích kết nối khác nhau.

---

## 3. Phân biệt SID và SERVICE_NAME

Đây là hai khái niệm thường bị nhầm lẫn khi cấu hình Oracle Client.

### 3.1. SID là gì?

SID (System Identifier) xác định một Oracle Instance.

Ví dụ:

```
ORACLE_SID=ORCLCDB
```

Biến môi trường này thường được sử dụng trên máy chủ để các công cụ Oracle biết cần làm việc với instance nào.

Kết nối theo SID thường có dạng Easy Connect hoặc connect descriptor sử dụng `SID`:

```
(DESCRIPTION=
  (ADDRESS=
    (PROTOCOL=TCP)
    (HOST=192.168.56.101)
    (PORT=1521)
  )
  (CONNECT_DATA=
    (SID=ORCLCDB)
  )
)
```

### 3.2. SERVICE_NAME là gì?

`SERVICE_NAME` xác định dịch vụ mà client muốn kết nối.

Ví dụ:

```
//192.168.56.101:1521/prod_pdb
```

Trong trường hợp này, `prod_pdb` là tên Service, không nhất thiết trùng với SID hoặc tên PDB.

### 3.3. So sánh

| Tiêu chí                                   | SID                        | SERVICE_NAME                               |
| ------------------------------------------ | -------------------------- | ------------------------------------------ |
| Mục đích                                   | Xác định Instance          | Xác định dịch vụ kết nối                   |
| Phạm vi                                    | Gắn với Instance           | Có thể đại diện cho PDB hoặc nhóm workload |
| Kết nối ứng dụng hiện đại                  | Có thể sử dụng             | Thường được ưu tiên                        |
| Có nhất thiết trùng tên PDB?               | Không                      | Không                                      |
| Có thể có nhiều Service trên một Instance? | Không áp dụng theo cách đó | Có                                         |

**Khuyến nghị:** Với ứng dụng kết nối đến PDB, nên sử dụng Service của PDB thay vì mặc định dùng Service của CDB hoặc kết nối theo SID.

---

## 4. Oracle có những loại Service nào?

### 4.1. Default Service

Khi tạo database, Oracle thường tạo một Service mặc định gắn với database. Tên của Service này có thể trùng với tên database hoặc tên được cấu hình trong quá trình tạo database.

Không nên giả định rằng mọi Service mặc định đều có tên giống SID hoặc rằng Service mặc định luôn phù hợp cho ứng dụng PDB.

### 4.2. PDB Service

Service được sử dụng để kết nối đến một PDB cụ thể.

Ví dụ:

```
prod_pdb
```

Ứng dụng kết nối bằng Service này sẽ được định tuyến đến PDB tương ứng khi cấu hình Service và trạng thái PDB cho phép.

### 4.3. User-defined Service

DBA có thể tạo Service riêng để phân chia workload.

Ví dụ:

- `prod_app` — ứng dụng production.
- `prod_batch` — tác vụ batch.
- `prod_report` — ứng dụng báo cáo.

Các tên trên chỉ là ví dụ. Khi tạo Service, DBA cần xác định PDB đích, chính sách khởi động, client và yêu cầu vận hành.

Trong môi trường Oracle RAC, Service còn có thể được cấu hình để quản lý phân phối workload, failover và availability. Với Oracle Database đơn instance, Service vẫn hữu ích để phân chia các nhóm kết nối logic.

---

## 5. Service trong kiến trúc CDB/PDB

Giả sử database của bạn có cấu trúc:

```
ORCLCDB
|
+-- CDB$ROOT
|
+-- PDB$SEED
|
+-- PROD_PDB
|
+-- TEST_PDB
```

Giả sử Service tương ứng là:

```
ORCLCDB
PROD_PDB
TEST_PDB
```

Đây chỉ là ví dụ minh họa, không khẳng định các Service này đã tồn tại trên máy của bạn.

| Service    | Container dự kiến                            | Mục đích                           |
| ---------- | -------------------------------------------- | ---------------------------------- |
| `ORCLCDB`  | CDB hoặc container được cấu hình cho Service | Quản trị hoặc kết nối cấp database |
| `PROD_PDB` | `PROD_PDB`                                   | Ứng dụng production                |
| `TEST_PDB` | `TEST_PDB`                                   | Kiểm thử                           |

Thông thường, `PDB$SEED` là PDB mẫu ở trạng thái chỉ đọc để tạo PDB mới. Không nên sử dụng nó làm database phục vụ ứng dụng thông thường.

### Vì sao PDB nên có Service riêng?

1. Ứng dụng kết nối đúng PDB.
2. Tách biệt cấu hình kết nối giữa production và test.
3. Dễ thay đổi chính sách kết nối mà không cần thay đổi tên database vật lý.
4. Có thể quản lý workload và giám sát session theo Service.
5. Hỗ trợ các kiến trúc HA khi được triển khai cùng những tính năng Oracle tương ứng.

---

## 6. Kiểm tra Service trong Oracle

Các lệnh dưới đây dùng để kiểm tra trước khi cấu hình hoặc thay đổi hệ thống.

### 6.1. Kiểm tra Instance và Database

Kết nối bằng SQL\*Plus với tài khoản có quyền thích hợp:

```
SELECT
    instance_name,
    host_name,
    status
FROM v$instance;
```

Kiểm tra thông tin chung của toàn bộ Database (cấp độ Instance/Database vật lý):

```
SELECT
    name,
    db_unique_name,
    cdb,
    open_mode
FROM v$database;
```

Kết quả `CDB = YES` cho biết database sử dụng kiến trúc Multitenant.

### 6.2. Kiểm tra container hiện tại

```
SHOW CON_NAME;
```

Hoặc:

```
SELECT
    SYS_CONTEXT('USERENV', 'CON_NAME') AS CON_NAME,
    SYS_CONTEXT('USERENV', 'SERVICE_NAME') AS SERVICE_NAME
FROM dual;
```

Hai thông tin này giúp xác định session hiện tại đang ở container nào và sử dụng Service nào.

### 6.3. Liệt kê các PDB

```
SHOW PDBS;
```

Hoặc:

```
SELECT
    con_id,
    name,
    open_mode,
    restricted
FROM v$pdbs
ORDER BY con_id;
```

Lưu ý: PDB tồn tại không đồng nghĩa với việc Service tương ứng đã được đăng ký hoặc có thể kết nối từ bên ngoài.

### 6.4. Liệt kê Service trong database

```
SELECT
    name,
    network_name,
    pdb
FROM cdb_services
ORDER BY pdb, name;
```

Tùy phiên bản Oracle và quyền truy cập, các cột hiển thị có thể khác nhau. Nếu truy vấn `CDB_SERVICES` không được phép, thử:

```
SELECT
    name,
    network_name
FROM v$services
ORDER BY name;
```

`V$SERVICES` cho biết các Service mà instance nhận biết. Để kiểm tra Service nào thực sự được Listener đăng ký, cần kiểm tra thêm từ phía Listener.

### 6.5. Kiểm tra Service từ hệ điều hành

Trên máy chủ Oracle, chạy bằng tài khoản có quyền truy cập Oracle Home:

```
lsnrctl status
```

Để xem chi tiết các Service mà Listener biết:

```
lsnrctl services
```

Ví dụ kết quả có thể thể hiện:

```
Service "prod_pdb" has 1 instance(s).
  Instance "ORCLCDB", status READY
```

Điều này cho biết Listener đã nhận biết Service `prod_pdb` và có Instance đăng ký cung cấp dịch vụ.

Nếu Service xuất hiện trong truy vấn database nhưng không xuất hiện tại Listener, cần kiểm tra đăng ký động, cấu hình Listener và trạng thái instance.

---

## 7. Kết nối đến Service bằng SQL\*Plus

### 7.1. Kết nối đến PDB

```
sqlplus app_user@//192.168.56.101:1521/prod_pdb
```

SQLPlus sẽ yêu cầu mật khẩu nếu không có cơ chế xác thực khác được cấu hình.

Sau khi kết nối, xác minh:

```
SHOW CON_NAME;

SELECT
    SYS_CONTEXT('USERENV', 'SERVICE_NAME') AS SERVICE_NAME
FROM dual;
```

Kết quả cần thể hiện đúng PDB và Service mà bạn mong muốn.

### 7.2. Kết nối đến CDB

Ví dụ:

```
sqlplus admin_user@//192.168.56.101:1521/orclcdb
```

Tên `orclcdb` chỉ sử dụng được nếu đó là Service đang tồn tại, được đăng ký và có thể kết nối. Tên Service không được xác định chỉ bằng việc nhìn thấy `ORACLE_SID=ORCLCDB`.

Để quản trị CDB, tài khoản cần có quyền phù hợp. Không nên sử dụng tài khoản quản trị cấp cao cho ứng dụng thông thường.

### 7.3. Kết nối nội bộ trên máy chủ

Với tài khoản hệ điều hành được cấu hình xác thực OSDBA phù hợp:

```
export ORACLE_SID=ORCLCDB
sqlplus / as sysdba
```

Đây là kiểu kết nối quản trị cục bộ, khác với việc ứng dụng kết nối qua TCP bằng Service.

---

## 8. Tạo và quản lý Service

Việc tạo hoặc xóa Service làm thay đổi cấu hình vận hành, vì vậy cần kiểm tra môi trường trước khi thực hiện.

### 8.1. Service mặc định của PDB

Oracle thường tự tạo Service mặc định cho PDB khi tạo PDB. Khi cần xác định tên thực tế, hãy kiểm tra bằng:

```
SELECT
    name,
    network_name,
    pdb
FROM cdb_services
ORDER BY pdb, name;
```

Không cần tạo Service mới nếu Service mặc định đã đáp ứng nhu cầu.

### 8.2. Tạo Service riêng bằng DBMS_SERVICE

Ví dụ minh họa tạo Service `prod_app` cho PDB `PROD_PDB` trên Oracle Database 19c:

```
-- Thực hiện tại CDB$ROOT bằng tài khoản phù hợp.

ALTER SESSION SET CONTAINER = CDB$ROOT;

BEGIN
    DBMS_SERVICE.CREATE_SERVICE(
        service_name => 'prod_app',
        network_name => 'prod_app'
    );
END;
/
```

Đây là bước tạo định nghĩa Service; **không nên hiểu rằng Service đã tự động hoạt động hoặc được Listener đăng ký ngay sau đó**.

Đối với PDB, cần triển khai Service trong đúng container và sử dụng phương thức quản lý phù hợp với môi trường. Với Oracle RAC, hãy dùng SRVCTL để quản lý Service theo chính sách Clusterware; không quản lý Service RAC như một database đơn instance.

### 8.3. Khởi động Service

Đối với Service đã được tạo trong đúng container và quản lý theo cách thủ công phù hợp:

```
BEGIN
    DBMS_SERVICE.START_SERVICE(
        service_name => 'prod_app'
    );
END;
/
```

Cần bảo đảm PDB đích đã được mở và Service được cấu hình đúng cho PDB đó. Nếu Service được quản lý bởi SRVCTL hoặc công cụ quản lý khác, phải dùng đúng công cụ quản lý thay vì trộn lẫn các phương thức.

### 8.4. Dừng Service

```
BEGIN
    DBMS_SERVICE.STOP_SERVICE(
        service_name => 'prod_app'
    );
END;
/
```

Dừng Service có thể làm ảnh hưởng các kết nối ứng dụng. Chỉ thực hiện sau khi đánh giá ảnh hưởng và có kế hoạch vận hành phù hợp.

### 8.5. Xóa Service

```
BEGIN
    DBMS_SERVICE.DELETE_SERVICE(
        service_name => 'prod_app'
    );
END;
/
```

Chỉ xóa Service khi đã xác nhận Service không còn được ứng dụng hoặc tác vụ nào sử dụng.

**Cảnh báo:** Các ví dụ `CREATE_SERVICE`, `START_SERVICE`, `STOP_SERVICE` và `DELETE_SERVICE` ở trên không phải một kịch bản cần chạy liên tiếp. Chúng là các thao tác riêng biệt. Cú pháp, container thực thi và phương pháp quản lý cần được xác nhận theo loại Service và môi trường Oracle cụ thể.

---

## 9. Service có tự động khởi động sau khi restart không?

Không nên mặc định rằng mọi Service tự tạo sẽ tự khởi động sau khi database restart.

Cần phân biệt:

- Service mặc định của PDB.
- Service do DBA tạo bằng `DBMS_SERVICE`.
- Service được quản lý bằng SRVCTL trong môi trường RAC hoặc Oracle Restart.
- Trạng thái mở của PDB sau khi CDB khởi động.

### Lưu trạng thái mở PDB

Ví dụ, nếu muốn `PROD_PDB` tự mở sau khi CDB khởi động:

```
ALTER PLUGGABLE DATABASE PROD_PDB OPEN;
ALTER PLUGGABLE DATABASE PROD_PDB SAVE STATE;
```

Hai câu lệnh này có tác dụng mở PDB và lưu trạng thái mở. Chúng **không thay thế** việc cấu hình và quản lý Service.

Để kiểm tra trạng thái đã lưu:

```
SELECT
    con_name,
    state
FROM dba_pdb_saved_states;
```

Các thao tác này làm thay đổi trạng thái database. Hãy xác minh đúng tên PDB và thời điểm thực hiện trước khi chạy trên môi trường production.

---

## 10. Phân biệt lỗi Service và lỗi Listener

| Hiện tượng                           | Nguyên nhân có thể xảy ra                                             | Hướng kiểm tra                                           |
| ------------------------------------ | --------------------------------------------------------------------- | -------------------------------------------------------- |
| `ORA-12514`                          | Listener chưa biết Service được yêu cầu                               | `lsnrctl services`, kiểm tra đăng ký Service             |
| `ORA-12541`                          | Không có Listener tại địa chỉ/cổng được yêu cầu                       | `lsnrctl status`, kiểm tra host và port                  |
| `ORA-12505`                          | Listener không nhận biết SID được yêu cầu                             | Kiểm tra SID và connect descriptor                       |
| `ORA-01017`                          | Sai thông tin xác thực hoặc phương thức xác thực                      | Kiểm tra username/password và cấu hình xác thực          |
| Kết nối thành công nhưng vào sai PDB | Client sử dụng nhầm Service hoặc Service ánh xạ sai                   | `SHOW CON_NAME`, `SYS_CONTEXT('USERENV','SERVICE_NAME')` |
| PDB tồn tại nhưng kết nối không được | PDB đóng, Service chưa hoạt động, chưa đăng ký hoặc sai cấu hình mạng | `SHOW PDBS`, `CDB_SERVICES`, `lsnrctl services`          |

Không nên xử lý mọi lỗi kết nối bằng cách restart Listener. Trước tiên cần xác định lỗi nằm ở client, mạng, Listener, Service hay trạng thái database.

---

## 12. Tổng kết

Hãy ghi nhớ bốn điểm:

1. **Instance** là môi trường thực thi Oracle Database; **Service** là tên logic dùng để định tuyến kết nối.
2. **Listener** tiếp nhận yêu cầu kết nối và giúp client kết nối đến Service phù hợp.
3. Trong kiến trúc **CDB/PDB**, ứng dụng nên sử dụng Service tương ứng với PDB cần truy cập.
4. Tạo Service, mở PDB, đăng ký Service với Listener và cấu hình tự khởi động là những vấn đề liên quan nhưng không đồng nhất.

Đối với hệ thống Oracle Database 19c đơn instance trong môi trường lab, nên bắt đầu bằng việc kiểm tra `V$SERVICES`, `CDB_SERVICES`, `SHOW PDBS` và `lsnrctl services` trước khi tạo Service mới.

Tài liệu trên có thể được lưu thành file `oracle-database-service.md`. Tôi đã ưu tiên các câu lệnh kiểm tra trước, đồng thời đánh dấu rõ những lệnh làm thay đổi cấu hình để tránh chạy nhầm trên môi trường production.