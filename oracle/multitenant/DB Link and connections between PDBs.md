## 1. DB Link là gì?

Database Link (DB Link) là một đối tượng trong Oracle Database cho phép một database truy cập đối tượng dữ liệu ở database khác thông qua kết nối mạng Oracle Net.

Ví dụ, bạn đang kết nối vào `PDB` và cần đọc bảng `HR.EMPLOYEES` ở database đích. Thay vì xuất dữ liệu rồi nhập vào database hiện tại, bạn có thể truy vấn từ xa:

```
SELECT *
FROM hr.employees@hr_link;
```

Trong đó:

- `hr.employees`: bảng `EMPLOYEES` thuộc schema `HR`.
- `@hr_link`: sử dụng DB Link tên `HR_LINK`.
- Database hiện tại là local database đối với câu truy vấn.
- Database chứa bảng `HR.EMPLOYEES` là remote database.

DB Link không phải là một bản sao dữ liệu. Nó tạo đường truy cập đến dữ liệu ở xa khi câu SQL được thực thi.

### DB Link được dùng vào việc gì?

- Truy vấn dữ liệu giữa các database.
- Đồng bộ hoặc đối chiếu dữ liệu giữa hệ thống.
- Kết hợp bảng local và remote trong một câu SQL.
- Gọi một số procedure hoặc function ở database từ xa.
- Hỗ trợ tích hợp dữ liệu giữa các hệ thống Oracle.
- Kết nối giữa các PDB trong cùng CDB, hoặc giữa PDB thuộc các CDB khác nhau, thông qua cấu hình kết nối phù hợp.

Tuy nhiên, DB Link không thay thế công cụ ETL, replication hay kiến trúc tích hợp dữ liệu chuyên dụng khi yêu cầu có tải lớn, đồng bộ liên tục hoặc độ sẵn sàng cao.

## 2. Hiểu đúng các thành phần của DB Link

| Thành phần         | Vai trò                                                        |
| ------------------ | -------------------------------------------------------------- |
| Local database     | Database nơi câu SQL được khởi chạy                            |
| Remote database    | Database chứa dữ liệu hoặc chương trình được truy cập          |
| DB Link            | Đối tượng lưu thông tin cần thiết để kết nối đến database đích |
| Database link user | Tài khoản được sử dụng để xác thực ở database đích             |
| Oracle Net service | Định danh kết nối đến dịch vụ database đích                    |
| Listener           | Tiếp nhận kết nối Oracle Net và chuyển đến dịch vụ phù hợp     |
| Remote privilege   | Quyền tài khoản remote được phép thực hiện                     |

Trong môi trường Production, nên dùng một TNS alias được quản lý tập trung thay vì hard-code Easy Connect 
trực tiếp trong DB Link. Cách này giúp DBA thay đổi hostname, port, service hoặc bổ sung cấu hình 
Oracle Net mà không phải `DROP` rồi tạo lại DB Link. Load balancing, connect-time failover, TAF hoặc FCF không tự xuất hiện chỉ vì dùng alias; chúng cần cấu hình phù hợp ở Oracle Net, service và client/application stack theo khả năng hỗ trợ của từng cơ chế.

Ví dụ alias `PDB1_REMOTE` trong file `tnsnames.ora`:

```ini
PDB1_REMOTE =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = oracle-lab)(PORT = 1521))
    (CONNECT_DATA =
      (SERVICE_NAME = pdb1)
    )
  )
```

Trong ví dụ này:

- `oracle-lab`: hostname.
- `1521`: port listener.
- `pdb1`: service name của PDB đích.

Điểm rất quan trọng: DB Link sử dụng database service, không đơn thuần kết nối đến tên PDB. 
Service phải tồn tại, listener phải tiếp nhận được kết nối và tài khoản remote phải có quyền thích hợp.

# 3. Phân loại DB Link

Oracle có nhiều cách phân loại DB Link. DBA cần hiểu cả phạm vi sử dụng và cách xác thực user remote.

## 3.1. Private DB Link và Public DB Link

| Tiêu chí          | Private DB Link                                     | Public DB Link                                             |
| ----------------- | --------------------------------------------------- | ---------------------------------------------------------- |
| Tạo bằng          | `CREATE DATABASE LINK`                              | `CREATE PUBLIC DATABASE LINK`                              |
| Phạm vi nhìn thấy | Schema sở hữu link                                  | Các user trong database/container có thể nhìn thấy link    |
| Quyền sử dụng     | Owner của link và các ngữ cảnh được Oracle cho phép | Các user có thể sử dụng link theo quyền truy cập liên quan |
| Phù hợp           | Ứng dụng hoặc schema riêng                          | Nhiều schema cần dùng chung đường kết nối                  |
| Khuyến nghị       | Ưu tiên                                             | Chỉ dùng khi thực sự cần                                   |

Public DB Link không có nghĩa mọi user đều được đọc mọi bảng ở remote database. User remote mà link sử dụng vẫn bị giới hạn bởi privilege tại database đích. Tuy nhiên, public link có thể làm tăng phạm vi người dùng có thể sử dụng thông tin xác thực được cấu hình trong link.&#x20;


## 3.2. Fixed User, Connected User và Current User DB Link

### A. Fixed User DB Link

DB Link luôn kết nối đến remote bằng một tài khoản cố định.

Ví dụ:

```
CREATE DATABASE LINK hr_link
CONNECT TO hr_link_user
IDENTIFIED BY "Replace_With_Strong_Password"
USING 'PDB1_REMOTE';
```

Khi chạy:

```
SELECT *
FROM hr.employees@hr_link;
```

Oracle kết nối tới remote database bằng tài khoản `HR_LINK_USER`.

Đây là mô hình phổ biến cho ứng dụng và tích hợp dữ liệu vì tài khoản remote có thể được cấp quyền tối thiểu.

### B. Connected User DB Link

DB Link không chỉ định `CONNECT TO user IDENTIFIED BY password`. Oracle sử dụng danh tính của user đang kết nối ở local database để xác thực ở remote database.

Ví dụ:

```
CREATE DATABASE LINK connected_link
USING 'PDB1_REMOTE';
```

Mô hình này yêu cầu tài khoản remote tương ứng và cơ chế xác thực phù hợp. Không nên mặc định rằng chỉ cần cùng tên user là sẽ kết nối được; mật khẩu và phương thức xác thực cũng phải đáp ứng yêu cầu.

### C. Current User DB Link

Ví dụ:

```
CREATE DATABASE LINK current_user_link
CONNECT TO CURRENT_USER
USING 'PDB1_REMOTE';
```

Loại này dùng danh tính current user theo các điều kiện xác thực enterprise/global user của Oracle. Hành vi còn phụ thuộc việc DB Link được gọi trực tiếp hay thông qua stored object, đặc biệt là quyền definer's rights và invoker's rights.

Khuyến nghị cho DBA Junior: Hãy bắt đầu bằng private fixed-user DB Link, sau khi hiểu rõ xác thực và phạm vi quyền mới nghiên cứu connected-user hoặc current-user link.&#x20;

# 4. Chuẩn bị trước khi tạo DB Link

Giả sử lab của bạn có cấu hình:

| Thành phần     | Giá trị        |
| -------------- | -------------- |
| CDB            | `ORCLCDB`      |
| Local PDB      | `PDB`          |
| Remote PDB     | `PDB1`         |
| Host           | `oracle-lab`   |
| Listener port  | `1521`         |
| Remote service | `pdb1`         |
| Remote account | `HR_LINK_USER` |
| Local account  | `APP_USER`     |

Các giá trị này là ví dụ dựa trên tên lab. Hãy xác nhận service thực tế của bạn trước khi chạy.

## 4.1. Kiểm tra trạng thái PDB

Trong SQL\*Plus hoặc IDE, nếu có quyền truy cập `V$PDBS`:

```
SELECT con_id, name, open_mode
FROM v$pdbs
ORDER BY con_id;
```

Đảm bảo `PDB1` đã mở ở chế độ phù hợp với mục đích truy cập.

## 4.2. Kiểm tra service đích

Ở phía máy chủ Oracle, tài khoản quản trị Grid/Oracle có thể kiểm tra listener bằng công cụ hệ điều hành:

```
lsnrctl status
lsnrctl services
```

Nếu dùng Oracle Restart, có thể kiểm tra service được quản lý bằng SRVCTL:

```
srvctl status service -db ORCLCDB
```

Cần phân biệt tên PDB với tên service. Một PDB có thể có nhiều service; tên service kết nối phải là service thực sự được listener đăng ký.

## 4.3. Kiểm tra kết nối Oracle Net trước

Từ máy chạy Oracle Client, có thể kiểm tra:

```
tnsping pdb1
```

Lệnh này chỉ kiểm tra việc phân giải và tiếp cận Oracle Net theo cấu hình tương ứng; nó không xác nhận rằng username/password hợp lệ hay user có quyền truy cập dữ liệu.

Easy Connect có thể tiện cho kiểm tra ad-hoc, ví dụ `//oracle-lab:1521/pdb1`. Với DB Link production, ưu tiên alias TNS được quản lý trên Local Database Server, ví dụ:

```sql
SELECT * FROM dual@PDB1_REMOTE;
```

Để kiểm tra alias, chạy `tnsping PDB1_REMOTE` từ máy chủ database nguồn, trong đúng Oracle Net environment mà server process sử dụng.

# 5. Ví dụ tạo DB Link giữa hai PDB trong cùng CDB

## Bước 1. Tạo user remote trong PDB1

Kết nối vào `PDB1` bằng tài khoản quản trị có quyền phù hợp:

```
ALTER SESSION SET CONTAINER = PDB1;
```

Tạo tài khoản riêng cho DB Link:

```
CREATE USER hr_link_user
IDENTIFIED BY "Replace_With_Strong_Password"
DEFAULT TABLESPACE users
QUOTA 0 ON users;
```

`DEFAULT TABLESPACE users` đặt tablespace mặc định cho user; `QUOTA 0 ON users` chủ động không cấp dung lượng để user tạo segment trong tablespace `USERS`. Đây là tài khoản dùng để xác thực và đọc object được cấp quyền, nên không cần quota nếu không có yêu cầu tạo dữ liệu riêng. Nếu schema hoặc object được thiết kế cần tạo segment, hãy cấp quota có giới hạn theo yêu cầu đã được phê duyệt.

Cấp quyền đăng nhập:

```
GRANT CREATE SESSION TO hr_link_user;
```

Nếu tài khoản cần đọc bảng của schema `HR`, cấp object privilege trên bảng được phép đọc.

Ví dụ:

```
GRANT SELECT ON hr.employees TO hr_link_user;
GRANT SELECT ON hr.departments TO hr_link_user;
```

Nếu schema `HR` không tồn tại trong PDB1, hãy thay bằng schema và object thực tế ở remote database.

Không cấp `DBA`, `SELECT ANY TABLE` hoặc quyền rộng chỉ để DB Link hoạt động.

## Bước 2. Tạo DB Link tại PDB nguồn

Chuyển về PDB nguồn:

```
ALTER SESSION SET CONTAINER = PDB;
```

Đăng nhập bằng user cần sở hữu DB Link, ví dụ `APP_USER`, hoặc dùng tài khoản quản trị được phép tạo link trong schema đó.

Nếu tạo private link bằng tài khoản `APP_USER`, user cần có system privilege `CREATE DATABASE LINK`.

Ví dụ khi quản trị viên cấp quyền:

```
GRANT CREATE DATABASE LINK TO app_user;
```

Sau đó kết nối bằng `APP_USER` và tạo link:

```
CREATE DATABASE LINK pdb1_link
CONNECT TO hr_link_user
IDENTIFIED BY "Replace_With_Strong_Password"
USING 'PDB1_REMOTE';
```

DB Link được tạo trong schema của `APP_USER` tại PDB nguồn. Bạn không cần tạo một DB Link trong `CDB$ROOT` chỉ vì hai PDB nằm trong cùng CDB.

Trong production, không nên dùng mật khẩu thật trực tiếp trong script được lưu vào repository, file chia sẻ hoặc lịch sử lệnh. Hãy tuân theo quy trình quản lý secret và thay đổi mật khẩu của tổ chức.

## Bước 3. Kiểm tra DB Link

```
SELECT
    db_link,
    username,
    host,
    created
FROM user_db_links;
```

Kiểm tra kết nối thực tế:

```
SELECT *
FROM dual@pdb1_link;
```

Kiểm tra danh tính remote:

```
SELECT
    user AS remote_user,
    SYS_CONTEXT('USERENV', 'CON_NAME') AS remote_container
FROM dual@pdb1_link;
```

Kết quả mong đợi:

- `REMOTE_USER` là `HR_LINK_USER`.
- `REMOTE_CONTAINER` là PDB đích, ví dụ `PDB1`.

Nếu truy vấn trên thành công, bạn đã kiểm tra được cả khả năng kết nối và danh tính remote. Nếu chỉ truy vấn `DUAL` thành công, điều đó chưa chứng minh user có quyền đọc bảng nghiệp vụ.

## Bước 4. Đọc dữ liệu remote

```
SELECT
    employee_id,
    first_name,
    last_name
FROM hr.employees@pdb1_link
FETCH FIRST 10 ROWS ONLY;
```

Nếu cần đối chiếu dữ liệu local và remote, bạn có thể kết hợp bảng trong cùng câu SQL:

```
SELECT
    l.employee_id,
    l.last_name AS local_last_name,
    r.last_name AS remote_last_name
FROM hr.employees l
JOIN hr.employees@pdb1_link r
    ON r.employee_id = l.employee_id;
```

Câu SQL này giả định bảng `HR.EMPLOYEES` có ở cả PDB nguồn và PDB đích, với cấu trúc tương thích.

# 6. Ứng dụng DB Link trong công việc DBA

## 6.1. Truy vấn bảng remote như bảng local

Cú pháp:

```
SELECT column_list
FROM schema_name.table_name@dblink_name;
```

Ví dụ:

```
SELECT COUNT(*)
FROM hr.employees@pdb1_link;
```

Một số ứng dụng thực tế:

- Đếm số bản ghi giữa hai PDB.
- So sánh dữ liệu giữa môi trường nguồn và đích.
- Đọc dữ liệu danh mục dùng chung.
- Tạo báo cáo tổng hợp từ nhiều database.
- Kiểm tra tính nhất quán sau khi chạy batch.

Với truy vấn lớn, cần xem execution plan và lượng dữ liệu truyền qua network. Tránh `SELECT *` từ bảng remote rất lớn khi chỉ cần một vài cột.

## 6.2. Tạo Synonym để ẩn tên DB Link

Nếu ứng dụng phải viết:

```
SELECT *
FROM hr.employees@pdb1_link;
```

bạn có thể tạo synonym:

```
CREATE SYNONYM remote_employees
FOR hr.employees@pdb1_link;
```

Sau đó:

```
SELECT *
FROM remote_employees;
```

Synonym giúp đơn giản hóa SQL, nhưng không tự cấp quyền truy cập dữ liệu remote và không thay thế DB Link. User vẫn phải có quyền phù hợp đối với synonym và object remote theo quy tắc Oracle.

## 6.3. DML qua DB Link

Oracle cho phép thực hiện DML trên bảng remote nếu tài khoản remote có quyền tương ứng.

Ví dụ thêm dữ liệu:

```
INSERT INTO hr.employees@pdb1_link
    (employee_id, last_name, email, hire_date, job_id)
VALUES
    (9999, 'LAB_TEST', 'LAB_TEST@example.com',
     SYSDATE, 'IT_PROG');
```

Ví dụ cập nhật:

```
UPDATE hr.employees@pdb1_link
SET last_name = 'LAB_UPDATED'
WHERE employee_id = 9999;
```

Ví dụ xóa:

```
DELETE FROM hr.employees@pdb1_link
WHERE employee_id = 9999;
```

Chỉ thử DML trên bảng lab có dữ liệu thử nghiệm. Các ví dụ trên không được chạy trên production nếu chưa xác minh ràng buộc, trigger, dữ liệu và quy trình phê duyệt.

Trong bài lab, bạn có thể kiểm tra transaction:

```
ROLLBACK;
```

hoặc:

```
COMMIT;
```

Đối với transaction liên quan đến nhiều database, Oracle có cơ chế distributed transaction và two-phase commit. 
Nếu transaction lỗi hoặc bị gián đoạn, có thể xuất hiện giao dịch chưa hoàn tất cần DBA kiểm tra. 
Không tự ý xóa các bản ghi giao dịch phân tán chỉ để dọn lỗi.

## 6.4. Gọi procedure remote

Nếu có procedure được phép thực thi ở remote:

```
BEGIN
    hr.some_procedure@pdb1_link;
END;
```

Trong thực tế, hãy kiểm tra chữ ký procedure, quyền `EXECUTE` và khả năng gọi từ xa của object trước khi sử dụng. 
Với API nghiệp vụ, ưu tiên cấp quyền thực thi package được thiết kế rõ ràng thay vì cấp quyền truy cập rộng trên các bảng nền.

# 7. Private DB Link và Public DB Link trong vận hành

## 7.1. Tạo Public DB Link

Cú pháp minh họa:

```
CREATE PUBLIC DATABASE LINK shared_pdb1_link
CONNECT TO hr_link_user
IDENTIFIED BY "Replace_With_Strong_Password"
USING 'PDB1_REMOTE';
```

Lệnh này cần system privilege `CREATE PUBLIC DATABASE LINK`.

Public link thường chỉ nên dùng khi nhiều schema thực sự cần cùng một đường truy cập và có thiết kế bảo mật rõ ràng. 
Với ứng dụng nghiệp vụ, private DB Link thường dễ kiểm soát quyền sở hữu và phạm vi sử dụng hơn.

## 7.2. Kiểm tra DB Link

### Link của schema hiện tại

```
SELECT
    db_link,
    username,
    host,
    created
FROM user_db_links;
```

### Link mà user có thể truy cập

```
SELECT
    owner,
    db_link,
    username,
    host
FROM all_db_links
ORDER BY owner, db_link;
```

### Kiểm tra ở phạm vi DBA

```
SELECT
    owner,
    db_link,
    username,
    host,
    created
FROM dba_db_links
ORDER BY owner, db_link;
```

Các view này cho biết metadata của DB Link, nhưng không phải công cụ xác minh hoàn chỉnh rằng remote database đang hoạt 
động hoặc mật khẩu vẫn hợp lệ.

## 7.3. Xóa DB Link

Xóa private link do schema hiện tại sở hữu:

```
DROP DATABASE LINK pdb1_link;
```

Xóa public link:

```
DROP PUBLIC DATABASE LINK shared_pdb1_link;
```

Lệnh thứ hai cần quyền phù hợp và phải được thực hiện trong đúng container.

Trước khi xóa, hãy kiểm tra view, procedure, job và ứng dụng nào đang phụ thuộc vào DB Link. Việc xóa link có thể 
khiến các tác vụ sử dụng link thất bại.

# 8. Kết nối giữa PDB trong cùng CDB và giữa các CDB khác nhau

Có hai kiến trúc cần phân biệt.

## Kiến trúc A — Hai PDB trong cùng CDB

CDB: ORCLCDB

PDB

Local

PDB1

Remote service

Dùng DB Link từ PDB nguồn tới service của PDB đích. Dù cùng CDB, hai PDB vẫn là các container có phạm vi bảo mật riêng.

## Kiến trúc B — Hai CDB khác nhau

CDB_A

PDB_A

Local

CDB_B

PDB_B

Remote

Cần network route, listener, remote service và xác thực. DB Link được tạo tại PDB nguồn để kết nối đến service ở CDB đích.

## 8.1. Hai PDB trong cùng CDB

Các bước chính:

1. Đảm bảo PDB đích đang mở.
2. Xác minh service đích.
3. Tạo remote account với quyền tối thiểu.
4. Tạo private DB Link trong PDB nguồn.
5. Kiểm tra `DUAL@link`, user remote và truy vấn object.
6. Theo dõi hiệu năng và lỗi kết nối.

Không nên nhầm DB Link với `ALTER SESSION SET CONTAINER`. Lệnh `ALTER SESSION SET CONTAINER` chuyển ngữ cảnh session của tài khoản được phép trong CDB; nó không tạo ra một kết nối database phân tán và không thay thế DB Link cho ứng dụng truy cập từ một PDB khác.

## 8.2. Hai CDB khác nhau

Giả sử:

- CDB nguồn: `ORCLCDB`
- PDB nguồn: `PDB`
- CDB đích: `FINCDB`
- PDB đích: `FINPDB`
- Remote service: `finpdb.example.com`

Tại PDB đích, tạo tài khoản và cấp quyền cần thiết:

```
CREATE USER fin_link_user
IDENTIFIED BY "Replace_With_Strong_Password";

GRANT CREATE SESSION TO fin_link_user;
GRANT SELECT ON finance.accounts TO fin_link_user;
```

Sau đó, tại PDB nguồn, tạo DB Link:

```
CREATE DATABASE LINK fin_link
CONNECT TO fin_link_user
IDENTIFIED BY "Replace_With_Strong_Password"
USING 'FINPDB_REMOTE';
```

Kiểm tra:

```
SELECT *
FROM dual@fin_link;
```

Truy vấn dữ liệu:

```
SELECT account_id, account_name
FROM finance.accounts@fin_link;
```

Ví dụ alias `FINPDB_REMOTE` trong `tnsnames.ora`:

```ini
FINPDB_REMOTE =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = finance-host.example.com)(PORT = 1521))
    (CONNECT_DATA =
      (SERVICE_NAME = finpdb.example.com)
    )
  )
```

Tên host, port, service và schema ở trên là ví dụ. Bạn phải thay bằng thông tin đã xác minh trong môi trường thực tế.

Khi DB Link được gọi, Oracle server process của **Local Database Server** thực hiện việc phân giải tên và mở kết nối ra remote database. Vì vậy, alias TNS phải có trong cấu hình Oracle Net mà instance/local database server sử dụng — thường là `$ORACLE_HOME/network/admin/tnsnames.ora`, trừ khi môi trường dùng `TNS_ADMIN` hoặc cấu hình Oracle Net khác. Không chỉ cấu hình alias trên máy client, máy chạy TOAD hoặc SQL Developer rồi giả định DB Link sẽ tự dùng được alias đó.

Sau khi tạo hoặc chỉnh alias, hãy kiểm tra từ đúng môi trường Oracle Home/TNS_ADMIN của máy chủ database nguồn. `tnsping PDB1_REMOTE` là bước kiểm tra phân giải Oracle Net hữu ích, nhưng không xác nhận username/password hay quyền truy cập dữ liệu remote.

# 9. Phân quyền và bảo mật DB Link

DB Link có thể lưu thông tin xác thực để database nguồn kết nối tới database đích. Vì vậy, DBA cần xem nó như một thành phần bảo mật, không chỉ là một tiện ích truy vấn.

## 9.1. Mô hình phân quyền khuyến nghị

Local user

Chỉ được phép tạo và sử dụng DB Link khi có quyền tương ứng. Ưu tiên private link.

Remote user

Chỉ được `CREATE SESSION` và quyền SELECT, DML hoặc EXECUTE thực sự cần thiết.

Credential

Không ghi mật khẩu thật vào source control, ticket, tài liệu chia sẻ hoặc script triển khai.

Một số lưu ý quan trọng:

- `CREATE DATABASE LINK` cho phép tạo private DB Link; `CREATE PUBLIC DATABASE LINK` cho phép tạo public DB Link.
- User remote cần quyền `CREATE SESSION`.
- Quyền truy cập bảng hoặc package remote được kiểm soát ở database đích.
- DB Link có thể tạo ra đường truy cập vượt khỏi ranh giới ứng dụng nếu remote account có quá nhiều quyền.
- Nếu cần đổi mật khẩu tài khoản remote, hãy lập kế hoạch cập nhật DB Link và kiểm thử kết nối trước khi hoàn tất thay đổi.

Oracle mô tả các yêu cầu này trong tài liệu chính thức về `CREATE DATABASE LINK`.&#x20;

## 9.2. DB Link có thể bị dùng để truy cập dữ liệu ngoài dự kiến không?

Có, nếu quyền remote quá rộng hoặc DB Link có phạm vi sử dụng không phù hợp.

Ví dụ, tài khoản `HR_LINK_USER` được cấp `SELECT ANY TABLE` có thể đọc nhiều bảng hơn mức ứng dụng cần. Nếu một public DB Link sử dụng tài khoản này, phạm vi rủi ro sẽ lớn hơn so với private DB Link chỉ dùng cho một schema và một tập dữ liệu được duyệt.

Vì vậy, khi thiết kế DB Link production, hãy xác định rõ:

1. Schema hoặc ứng dụng nào cần sử dụng link.
2. Các object remote được phép truy cập.
3. Có cần ghi dữ liệu từ xa hay chỉ đọc.
4. Ai quản lý mật khẩu và quy trình xoay vòng mật khẩu.
5. Cách theo dõi lỗi, thời gian phản hồi và hoạt động bất thường.

# 10. Troubleshooting: Những lỗi DB Link DBA cần biết

| Lỗi         | Nguyên nhân thường gặp                                                        | Hướng kiểm tra                                                      |
| ----------- | ----------------------------------------------------------------------------- | ------------------------------------------------------------------- |
| `ORA-12154` | Không phân giải được connect identifier                                       | Kiểm tra alias TNS, `tnsnames.ora`, Oracle Net configuration        |
| `ORA-12514` | Listener chưa biết service được yêu cầu                                       | Kiểm tra service name và `lsnrctl services`                         |
| `ORA-01017` | Sai username/password hoặc xác thực không phù hợp                             | Kiểm tra remote account, mật khẩu và phương thức xác thực           |
| `ORA-02019` | Không tìm thấy mô tả kết nối remote                                           | Kiểm tra DB Link và connect string                                  |
| `ORA-02085` | Tên DB Link không khớp với global database name trong trường hợp kiểm tra tên | Kiểm tra `GLOBAL_NAMES` và tên link                                 |
| `ORA-00942` | Không thấy bảng/view hoặc không đủ quyền truy cập object                      | Kiểm tra owner, tên object và quyền remote                          |
| `ORA-01031` | Thiếu privilege                                                               | Kiểm tra quyền tạo link hoặc quyền trên object remote               |
| `ORA-02068` | Lỗi nghiêm trọng được truyền từ remote database                               | Đọc thông báo lỗi tiếp theo và log ở database đích                  |
| `ORA-03113` | Kết nối bị ngắt ngoài dự kiến                                                 | Kiểm tra alert log, network, listener và tình trạng remote database |

## Quy trình kiểm tra theo thứ tự

Khi một DB Link lỗi, đừng bắt đầu bằng cách xóa rồi tạo lại ngay. Hãy kiểm tra theo trình tự:

1. Kiểm tra DB Link có tồn tại không
   ```
   SELECT db_link, username, host
   FROM user_db_links;
   ```
2. Kiểm tra connect string

   Xác minh hostname, port và service; kiểm tra alias TNS nếu sử dụng alias.
3. Kiểm tra kết nối Oracle Net

   Từ máy chủ database nguồn, kiểm tra phân giải tên và khả năng tiếp cận listener đích.
4. Kiểm tra xác thực remote

   Xác nhận remote user tồn tại, tài khoản không bị khóa và mật khẩu hợp lệ.
5. Kiểm tra quyền trên object

   Nếu `SELECT * FROM dual@link` thành công nhưng truy vấn bảng thất bại, tập trung kiểm tra schema, object và privilege remote.
6. Kiểm tra log

   Nếu có lỗi mạng hoặc lỗi distributed transaction, xem alert log của cả database nguồn và đích, listener log và các thông báo lỗi đầy đủ.

# 11. Hiệu năng và transaction khi sử dụng DB Link

## 11.1. Hạn chế truyền dữ liệu không cần thiết

Không nên mặc định rằng truy vấn sau luôn hiệu quả:

```
SELECT *
FROM large_table@remote_link;
```

Nếu bảng có hàng triệu bản ghi, dữ liệu có thể phải truyền qua network với khối lượng lớn. Hãy lọc sớm và chỉ lấy các cột cần thiết:

```
SELECT customer_id, customer_name
FROM sales.customers@remote_link
WHERE status = 'ACTIVE';
```

Oracle có thể tối ưu hóa một phần truy vấn phân tán, nhưng không phải mọi phép join hay biểu thức đều được đẩy xuống remote. Hãy kiểm tra execution plan, số dòng truyền và thời gian thực thi thực tế.

## 11.2. Transaction phân tán

Một câu lệnh DML qua DB Link có thể tham gia transaction của session hiện tại. Nếu transaction tác động đến nhiều database, Oracle có thể sử dụng distributed transaction và two-phase commit để phối hợp commit.

Ví dụ khái niệm:

```
UPDATE local_accounts
SET balance = balance - 100
WHERE account_id = 1;

UPDATE remote_accounts@fin_link
SET balance = balance + 100
WHERE account_id = 2;

COMMIT;
```

Đây chỉ là ví dụ minh họa cơ chế, không phải một giải pháp chuyển tiền hoàn chỉnh. Trong thực tế, cần xử lý đồng thời, kiểm tra số dư, tính idempotency, kiểm soát lỗi và khả năng khôi phục.

Nếu có lỗi trong quá trình commit phân tán, DBA có thể cần điều tra các giao dịch in-doubt qua các view như `DBA_2PC_PENDING`. Không tự ý ép commit hoặc rollback giao dịch chưa rõ trạng thái; cần xác định trạng thái ở các bên tham gia và tuân thủ quy trình phục hồi.
