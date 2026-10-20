- Để hiểu **SPN và Kerberos trong SQL Server**, bạn có thể hình dung theo chuỗi: **Client → DNS/hostname → SPN → Kerberos → AD → Service Account → SQL Server**

#### 1. SPN là gì?

- SPN = Service Principal Name. **tên định danh duy nhất của một dịch vụ trong Active Directory**, giúp Kerberos biết: 
"Dịch vụ SQL Server mà tôi muốn kết nối đang chạy dưới account nào?"

- Ví dụ SQL Server:

```text
Server: sql-web01
Port: 1433
Service Account: VIETSOV\sqlcluster
```

- SPN tương ứng:

```text
MSSQLSvc/sql-web01:1433
```

- thường thêm FQDN:

```text
MSSQLSvc/sql-web01.vietsov.com.vn:1433
```

- AD sẽ biết:

```text
MSSQLSvc/sql-web01:1433
        ↓
VIETSOV\sqlcluster
```

- Đây chính là vai trò quan trọng nhất của SPN.


#### 2. Tại sao Kerberos cần SPN?

- Giả sử user đăng nhập Windows:

```text
VIETSOV\nguyetanh
```

- Mở SSMS:

```text
Server name:
sql-web01,1433
```

- Client muốn xác thực với SQL Server bằng Kerberos. Nó cần nói với Active Directory: "Tôi muốn một ticket để truy cập dịch vụ SQL Server `MSSQLSvc/sql-web01:1433`."

- AD tìm SPN:

```text
MSSQLSvc/sql-web01:1433
```

```text
VIETSOV\sqlcluster
```

- AD cấp Kerberos service ticket cho dịch vụ đó. Sau đó client gửi ticket đến SQL Server. SQL Server biết:

```text
Ticket này dành cho MSSQLSvc/sql-web01:1433
```

- Dịch vụ đang chạy dưới:

```text
VIETSOV\sqlcluster
```

→ xác thực Kerberos thành công.

#### 3. SPN không phải là password. Đây là điểm rất quan trọng.

- SPN:

```text
MSSQLSvc/sql-web01:1433
```

- **không phải credential**. Nó giống như một: **"biển tên" / định danh dịch vụ**

- Kerberos ticket mới là thứ được dùng trong quá trình authentication.

- Có thể hình dung:

```text
SPN
 │
 │ xác định dịch vụ
 ▼
Active Directory
 │
 │ xác định account sở hữu dịch vụ
 ▼
VIETSOV\sqlcluster
 │
 │ Kerberos authentication
 ▼
SQL Server
```

#### 4. Kerberos là gì? 

**Kerberos là giao thức authentication**.

- Trong Windows Domain, Kerberos được tích hợp với: **Active Directory**.

- Thay vì client gửi username/password trực tiếp đến SQL Server, Kerberos sử dụng **ticket**.

- Ví dụ:

```text
User
 │
 │ đăng nhập Windows
 ▼
Active Directory / KDC
 │
 │ cấp Ticket
 ▼
Client
 │
 │ gửi Service Ticket
 ▼
SQL Server
```

- KDC = **Key Distribution Center**.

- Trong môi trường AD, Domain Controller thực hiện vai trò KDC.


#### 5. Kerberos khác NTLM như thế nào?

- Đây là lý do DBA rất quan tâm SPN. SQL Server có thể xác thực Windows bằng:

```text
Kerberos
hoặc
NTLM
```

- Kerberos thường được ưu tiên. Ví dụ kiểm tra:

```sql
SELECT
    session_id,
    auth_scheme,
    net_transport,
    client_net_address
FROM sys.dm_exec_connections
WHERE session_id = @@SPID;
```

Nếu:

```text
auth_scheme
-----------
KERBEROS
```

→ connection đang dùng Kerberos, nếu:

```text
NTLM
```

→ connection đang dùng NTLM.

#### 6. Nếu SPN sai thì chuyện gì xảy ra?

- Ví dụ SQL Server chạy:

```text
sql-web01:1433
```

- account:

```text
VIETSOV\sqlcluster
```

nhưng AD **không có**:

```text
MSSQLSvc/sql-web01:1433
```

- Client yêu cầu:

```text
MSSQLSvc/sql-web01:1433
```

- AD không tìm thấy SPN phù hợp. Kerberos không thể xác định đúng service principal. Trong nhiều trường hợp Windows sẽ **fallback sang NTLM**.

- Kết quả:

```text
SQL connection
      │
      ▼
Kerberos?
      │
      ├── YES → KERBEROS
      │
      └── NO
           │
           ▼
          NTLM
```

Vì vậy: **Không có SPN đúng ≠ SQL Server chắc chắn không kết nối được.**. Có thể vẫn kết nối được bằng NTLM.
Đây là lý do đôi khi application vẫn chạy bình thường nhưng DBA phát hiện:

```text
auth_scheme = NTLM
```

#### 7. Duplicate SPN nguy hiểm thế nào?

- Đây là phần rất quan trọng khi bạn chuẩn hóa SPN. Giả sử AD có:

```text
VIETSOV\sqlcluster
    MSSQLSvc/sql-web01:1433
```

đồng thời:

```text
VIETSOV\anotheraccount
    MSSQLSvc/sql-web01:1433
```

- Một SPN:

```text
MSSQLSvc/sql-web01:1433
```

nhưng có **2 owner**. Kerberos sẽ không biết: "Ticket này thuộc dịch vụ nào?" Đây gọi là:

**Duplicate SPN**

Vì vậy:

```cmd
setspn -X
```

rất quan trọng.

- Nếu thấy:

```text
Found 0 group of duplicate SPNs.
```

là tốt.

---

# 8. `setspn -Q` khác `-X` như thế nào?

- Ví dụ:

```cmd
setspn -Q MSSQLSvc/sql-web01:1433
```

hỏi:

> **SPN cụ thể này đang nằm trên account nào?**

Ví dụ:

```text
MSSQLSvc/sql-web01:1433
        ↓
VIETSOV\sqlcluster
```

Trong khi:

```cmd
setspn -X
```

hỏi:

> **Trong toàn AD có SPN nào bị duplicate không?**

---

# 9. `setspn -L` là gì?

```cmd
setspn -L VIETSOV\sqlcluster
```

hỏi:

> **Account `sqlcluster` hiện đang sở hữu những SPN nào?**

Ví dụ:

```text
Registered ServicePrincipalNames:

MSSQLSvc/sql-web01:1433
MSSQLSvc/sql-web01.vietsov.com.vn:1433
MSSQLSvc/sql-web02:1433
MSSQLSvc/sql-web02.vietsov.com.vn:1433
...
```

Nó **không kiểm tra duplicate toàn AD**.

---

# 10. Tại sao SQL Server phải có SPN?

SQL Server sử dụng SPN để Kerberos xác định **service identity**.

Ví dụ:

```text
SQL Server
    │
    ├── hostname = sql-web01
    ├── TCP = 1433
    └── service account = VIETSOV\sqlcluster
```

SPN:

```text
MSSQLSvc/sql-web01:1433
```

Có thể hiểu:

```text
MSSQLSvc
   │
   └── SQL Server service

sql-web01
   │
   └── hostname

1433
   │
   └── TCP port
```

---

# 11. Tại sao SPN có port?

Đây là điểm đặc biệt quan trọng với hệ thống của bạn vì **một server có nhiều SQL instance**.

Ví dụ `SQLFORM-NODE1` có:

```text
EHOS
TCP 62796

S2DNIPI
TCP 62134

S3DNIPI
TCP 63299
```

Do đó:

```text
MSSQLSvc/SQLFORM-NODE1:62796
MSSQLSvc/SQLFORM-NODE1:62134
MSSQLSvc/SQLFORM-NODE1:63299
```

là **3 SPN khác nhau**.

Đây là hoàn toàn hợp lệ.

Vì vậy:

```text
SQLFORM-NODE1
```

xuất hiện nhiều lần **không có nghĩa duplicate**.

Phải xét cả:

```text
hostname + port
```

---

# 12. AG Listener cũng cần SPN

Đây là phần rất quan trọng đối với Always On.

Ví dụ:

```text
Node 1:
SQLFORM-NODE1
TCP 62134

Node 2:
SQLFORM-NODE2
TCP 49909

Listener:
S2DDB
TCP 53969
```

Bạn sẽ có:

```text
MSSQLSvc/SQLFORM-NODE1:62134
MSSQLSvc/SQLFORM-NODE2:49909
```

cho các SQL instance.

Nhưng application thường kết nối:

```text
S2DDB,53969
```

chứ không kết nối trực tiếp:

```text
SQLFORM-NODE1,62134
```

Do đó cần listener SPN:

```text
MSSQLSvc/S2DDB:53969
```

và FQDN:

```text
MSSQLSvc/S2DDB.vietsov.com.vn:53969
```

Có thể hình dung:

```text
Application
     │
     │ S2DDB,53969
     ▼
AG Listener
     │
     ├── Node1
     │    SQLFORM-NODE1:62134
     │
     └── Node2
          SQLFORM-NODE2:49909
```

---

# 13. Vì vậy với AG, bạn đang xử lý hai loại SPN

### SPN của SQL instance

Ví dụ:

```text
MSSQLSvc/SQLFORM-NODE1:62134
MSSQLSvc/SQLFORM-NODE2:49909
```

### SPN của AG Listener

Ví dụ:

```text
MSSQLSvc/S2DDB:53969
```

Hai loại này đều cần nếu bạn muốn Kerberos hoạt động đúng khi client kết nối theo các tên tương ứng.

---

# 14. Vì sao FQDN cũng thường được đăng ký?

Client có thể kết nối bằng:

```text
sql-web01
```

hoặc:

```text
sql-web01.vietsov.com.vn
```

Đây là **hai service names khác nhau về mặt SPN lookup**.

Vì vậy thường đăng ký cả:

```text
MSSQLSvc/sql-web01:1433
```

và:

```text
MSSQLSvc/sql-web01.vietsov.com.vn:1433
```

Tương tự listener:

```text
MSSQLSvc/S2DDB:53969
MSSQLSvc/S2DDB.vietsov.com.vn:53969
```

---

# 15. Tại sao tất cả SPN của bạn nằm trên `sqlcluster`?

Bạn đang có nhiều SQL instance:

```text
sql-web01
sql-web02
SQLFORM-NODE1
SQLFORM-NODE2
SQLFORM-NODE3
sql-web03
sql-intergrated
...
```

nhưng nhiều instance đều chạy dưới:

```text
VIETSOV\sqlcluster
```

Do đó SPN tương ứng có thể cùng nằm trên:

```text
VIETSOV\sqlcluster
```

Ví dụ:

```text
VIETSOV\sqlcluster
    │
    ├── MSSQLSvc/sql-web01:1433
    ├── MSSQLSvc/sql-web02:1433
    ├── MSSQLSvc/SQLFORM-NODE1:62796
    ├── MSSQLSvc/SQLFORM-NODE1:62134
    ├── MSSQLSvc/SQLFORM-NODE1:63299
    ├── MSSQLSvc/EHOS:62796
    ├── MSSQLSvc/S2DDB:53969
    └── ...
```

Điều này **không có nghĩa các SPN bị duplicate**.

Chúng chỉ là nhiều SPN khác nhau cùng thuộc một service account.

---

# 16. `setspn -S` thực sự làm gì?

Ví dụ:

```cmd
setspn -S MSSQLSvc/S2DDB:53969 VIETSOV\sqlcluster
```

Nó nói với AD:

> Đăng ký SPN `MSSQLSvc/S2DDB:53969` cho account `VIETSOV\sqlcluster`, nhưng trước đó kiểm tra xem SPN này đã tồn tại ở nơi khác chưa.

Đây là lý do tôi khuyên bạn dùng:

```text
-S
```

thay vì:

```text
-A
```

`-A` chỉ thêm.

`-S` thêm **và kiểm tra duplicate**.

---

# 17. Toàn bộ quy trình của bạn

Với hệ thống SQL Server/AG hiện tại, quy trình chuẩn có thể hiểu như sau:

```text
                 Active Directory
                       │
                       │ SPN
                       ▼
              VIETSOV\sqlcluster
                       │
          ┌────────────┼─────────────┐
          │            │             │
          ▼            ▼             ▼
       SQLWEB        EHOS          S2DDB
       Listener      Listener      Listener
          │            │             │
          ▼            ▼             ▼
       SQL Nodes     SQL Nodes     SQL Nodes
```

Trước khi thêm:

```cmd
setspn -L VIETSOV\sqlcluster
setspn -X
```

Sau đó kiểm tra từng SPN:

```cmd
setspn -Q MSSQLSvc/S2DDB:53969
```

Nếu chưa có:

```cmd
setspn -S MSSQLSvc/S2DDB:53969 VIETSOV\sqlcluster
```

Cuối cùng:

```cmd
setspn -L VIETSOV\sqlcluster
setspn -X
```

và quan trọng nhất là **test thực tế Kerberos**:

```sql
SELECT
    auth_scheme,
    net_transport
FROM sys.dm_exec_connections
WHERE session_id = @@SPID;
```

Kỳ vọng:

```text
auth_scheme   net_transport
------------  ------------
KERBEROS      TCP
```

---

## 18. Một câu dễ nhớ nhất

Bạn có thể nhớ thế này:

> **Kerberos = cơ chế xác thực bằng ticket.**
> **SPN = tên định danh để Kerberos biết ticket đó dành cho dịch vụ/account nào.**
> **Active Directory = nơi quản lý SPN và cấp Kerberos ticket.**

Với SQL Server:

```text
Client
  │
  │ "Tôi muốn SQL Server S2DDB:53969"
  ▼
AD/KDC
  │
  │ tìm SPN
  ▼
MSSQLSvc/S2DDB:53969
  │
  │ thuộc về
  ▼
VIETSOV\sqlcluster
  │
  │ cấp Kerberos ticket
  ▼
Client
  │
  │ Ticket
  ▼
SQL Server
  │
  ▼
KERBEROS
```

Và nếu **SPN thiếu/sai/duplicate**, đây là một trong những nguyên nhân quan trọng khiến Kerberos không hoạt động đúng và connection có thể rơi về **NTLM**.


################################################################

I. AG: SQL-S3DNIPI

1. Thông tin

  instance name SQLFORM-NODE1\S3DNIPI
  ip: 172.19.2.121
  hostname:sqlform-node1
  TCP: 63299
  Service Account: VIETSOV\sqlcluster
  --------------------------------------------
  istance name: SQLFORM-NODE2\S3DNIPI
  ip: 172.19.2.120
  hostname: sqlform-node2
  TCP: 63299
  Service Account: VIETSOV\sqlcluster
  ---------------------------------------------
  AG Listener
  Listener Name: S3DDB
  ip: 172.19.2.101	
  TCP: 51159
  
2. SPN cần có
- Node 1: 172.19.2.121
setspn -S MSSQLSvc/sqlform-node1:63299 VIETSOV\sqlcluster
setspn -S MSSQLSvc/sqlform-node1.vietsov.com.vn:63299 VIETSOV\sqlcluster

- Node 2: : 172.19.2.120
setspn -S MSSQLSvc/sqlform-node2:63299 VIETSOV\sqlcluster
setspn -S MSSQLSvc/sqlform-node2.vietsov.com.vn:63299 VIETSOV\sqlcluster

- AG Listener 
setspn -S MSSQLSvc/S3DDB:51159 VIETSOV\sqlcluster
setspn -S MSSQLSvc/S3DDB.vietsov.com.vn:51159 VIETSOV\sqlcluster

0k
    
########################################################
III. AG: sqlform-s2d

1. Thông tin

  instance name: SQLFORM-NODE1\S2DNIPI
  ip: 172.19.2.121
  hostname:sqlform-node1
  TCP: 62134
  Service Account: VIETSOV\sqlcluster
  -----------------------------------------
  instance name: SQLFORM-NODE2\S2DNIPI
  ip: 172.19.2.120
  hostname: sqlform-node2
  TCP: 49909
  Service Account: VIETSOV\sqlcluster
  -----------------------------------------
  AG Listener
  AG Listener Name S2DDB
  IP:172.19.2.123	
  TCP: 53969
  
2. SPN cần có
- Node 1: 172.19.2.121
setspn -S MSSQLSvc/SQLFORM-NODE1:62134 VIETSOV\sqlcluster
setspn -S MSSQLSvc/SQLFORM-NODE1.vietsov.com.vn:62134 VIETSOV\sqlcluster

- Node 2: : 172.19.2.120
setspn -S MSSQLSvc/SQLFORM-NODE2:49909 VIETSOV\sqlcluster
setspn -S MSSQLSvc/SQLFORM-NODE2.vietsov.com.vn:49909 VIETSOV\sqlcluster

- AG Listener 
setspn -S MSSQLSvc/S2DDB:53969 VIETSOV\sqlcluster
setspn -S MSSQLSvc/S2DDB.vietsov.com.vn:53969 VIETSOV\sqlcluster

OK
########################################################
IV. AG: ehos-group

1. Thông tin

  instance name: SQLFORM-NODE1\EHOS
  ip:172.19.2.121
  hostname: sqlform-node1
  TCP: 62796
  Service Account: VIETSOV\sqlcluster
  ---------------------------------------------
  instance name: SQLFORM-NODE3\EHOS
  ip: 172.19.2.31
  hostname: SQLFORM-NODE3 
  TCP: 55926
  Service Account: VIETSOV\sqlcluster
  ---------------------------------------------
  AG Listener
  AG Listener Name: EHOS
  ip: 172.19.2.122	
  TCP: 62796
  
2. SPN cần có
- Node 1: 172.19.2.121
setspn -S MSSQLSvc/SQLFORM-NODE1:62796 VIETSOV\sqlcluster
setspn -S MSSQLSvc/SQLFORM-NODE1.vietsov.com.vn:62796 VIETSOV\sqlcluster

- Node 3: : 172.19.2.31
setspn -S MSSQLSvc/SQLFORM-NODE3:55926 VIETSOV\sqlcluster
setspn -S MSSQLSvc/SQLFORM-NODE3.vietsov.com.vn:55926 VIETSOV\sqlcluster

- AG Listener 
setspn -S MSSQLSvc/EHOS:62796 VIETSOV\sqlcluster
setspn -S MSSQLSvc/EHOS.vietsov.com.vn:62796 VIETSOV\sqlcluster

OK  
########################################################
V. AG: intergrated

1. Thông tin

  instance name: sql-intergrated 
  ip: 172.19.9.34
  hostname: sql-intergrated
  TCP: 1433
  Service Account: VIETSOV\sqlcluster
  -------------------------------------------
  instance name: sql-web03\INTERGRATED 
  ip: 172.19.2.37
  hostname: sql-web03
  TCP: 53980
  Service Account: VIETSOV\sqlcluster
  ------------------------------------------
  AG Listener
  AG Listener name: intergrated
  ip: 172.19.9.39	
  TCP: 1434
  
2. SPN cần có
- Node 1: 172.19.9.34
setspn -S MSSQLSvc/sql-intergrated:1433 VIETSOV\sqlcluster
setspn -S MSSQLSvc/sql-intergrated.vietsov.com.vn:1433 VIETSOV\sqlcluster

- Node 3: : 172.19.2.31
setspn -S MSSQLSvc/sql-web03:53980 VIETSOV\sqlcluster
setspn -S MSSQLSvc/sql-web03.vietsov.com.vn:53980 VIETSOV\sqlcluster

- AG Listener 
setspn -S MSSQLSvc/intergrated:1434 VIETSOV\sqlcluster
setspn -S MSSQLSvc/intergrated.vietsov.com.vn:1434 VIETSOV\sqlcluster
  
 OK
########################################################
 
VI. AG: sqlweb

1. Thông tin
 
  instance name: sql-web01
  hostname: sql-web01
  ip: 172.19.9.33
  TCP: 1433
  Service Account: VIETSOV\sqlcluster
  ---------------------------------------------- 
  instance name: sql-web02
  hostname: sql-web02
  ip: 172.19.9.32
  TCP: 1433
  Service Account: VIETSOV\sqlcluster
  ----------------------------------------------
  AG Listener
  AG Listener name: sqlweb
  ip: 172.19.9.19	
  TCP: 1433
  
2. SPN cần có
- Node 1: 172.19.9.33
setspn -S MSSQLSvc/sql-web01:1433 VIETSOV\sqlcluster
setspn -S MSSQLSvc/sql-web01.vietsov.com.vn:1433 VIETSOV\sqlcluster

- Node 2: : 172.19.9.32
setspn -S MSSQLSvc/sql-web02:1433 VIETSOV\sqlcluster
setspn -S MSSQLSvc/sql-web02.vietsov.com.vn:1433 VIETSOV\sqlcluster

- AG Listener 
setspn -S MSSQLSvc/sqlweb:1433 VIETSOV\sqlcluster
setspn -S MSSQLSvc/sqlweb.vietsov.com.vn:1433 VIETSOV\sqlcluster
  
########################################################
 
VII. AG: sql-sharepoint-group

1. Thông tin

  instance name: sql-web02\SHAREPOINT
  ip: 172.19.9.32
  hostname: sql-web02
  TCP: 55878
  Service Account: VIETSOV\sqlcluster

  instance name: sql-web01\SHAREPOINT
  hostname: sql-web01
  TCP: 54800
  Service Account: VIETSOV\sqlcluster

  AG Listener
  AG Listener name: sql-sharepoint
  ip: 172.19.9.36	
  TCP: 1456
  
2. SPN cần có
- Node 1: 172.19.9.32
setspn -S MSSQLSvc/sql-web02:55878 VIETSOV\sqlcluster
setspn -S MSSQLSvc/sql-web02.vietsov.com.vn:55878 VIETSOV\sqlcluster

- Node 2: : 172.19.9.33
setspn -S MSSQLSvc/sql-web01:54800 VIETSOV\sqlcluster
setspn -S MSSQLSvc/sql-web01.vietsov.com.vn:54800 VIETSOV\sqlcluster

- AG Listener , làm trên node nào cũng dc
setspn -S MSSQLSvc/sql-sharepoint:1456 VIETSOV\sqlcluster
setspn -S MSSQLSvc/sql-sharepoint.vietsov.com.vn:1456 VIETSOV\sqlcluster
  
########################################################






################################
Sau khi set, kiểm tra lại danh sách SPN đã gán vào tài khoản bằng lệnh:

setspn -L VIETSOV\sqlcluster

Hoặc kiểm tra xem có bị trùng lặp SPN (Duplicate SPN) ở đâu không:

setspn -X

kiểm tra toàn bộ SPN của account:

setspn -L VIETSOV\sqlcluster

#########################################################
* Script check

-- Server identity
SELECT
    SERVERPROPERTY('ComputerNamePhysicalNetBIOS') AS ComputerName,
    SERVERPROPERTY('MachineName') AS MachineName,
    SERVERPROPERTY('ServerName') AS ServerName,
    SERVERPROPERTY('InstanceName') AS InstanceName,
    SERVERPROPERTY('IsClustered') AS IsClustered;


-- AG / Listener
SELECT
    ag.name AS AGName,
    agl.dns_name AS ListenerName,
    agl.port AS ListenerPort
FROM sys.availability_groups AS ag
LEFT JOIN sys.availability_group_listeners AS agl
    ON ag.group_id = agl.group_id;
	
	
-- SQL Server Database Engine + service account 
SELECT
    SERVERPROPERTY('ServerName') AS ServerName,
    SERVERPROPERTY('MachineName') AS MachineName,
    SERVERPROPERTY('InstanceName') AS InstanceName,
    servicename,
    service_account,
    status_desc,
    process_id
FROM sys.dm_server_services
WHERE servicename LIKE 'SQL Server (%';

Get-CimInstance Win32_Service |
    Where-Object { $_.Name -like "MSSQL*" } |
    Select-Object Name, StartName, State
	