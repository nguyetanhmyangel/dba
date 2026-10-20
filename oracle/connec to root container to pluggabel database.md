**Cách kết nối và chuyển đổi giữa Root Container (CDB$ROOT) và Pluggable Database (PDB) trong Oracle**

### 1. Kiểm tra container hiện tại
```sql
SHOW CON_NAME;
-- hoặc
SELECT SYS_CONTEXT('USERENV', 'CON_NAME') AS current_container FROM dual;
```

### 2. Xem danh sách PDB
```sql
SHOW PDBS;
-- hoặc
SELECT name, open_mode, restricted FROM v$pdbs ORDER BY name;
```

### 3. Chuyển đổi giữa Root và PDB (trong cùng một session)

**Chuyển sang PDB:**
```sql
ALTER SESSION SET CONTAINER = tên_pdb;
-- Ví dụ:
ALTER SESSION SET CONTAINER = ORCLPDB1;
```

**Chuyển về Root (CDB$ROOT):**
```sql
ALTER SESSION SET CONTAINER = CDB$ROOT;
```

> Lưu ý: Bạn phải có quyền `SET CONTAINER` (thường là user `SYS` hoặc user có quyền tương đương).

### 4. Kết nối trực tiếp vào Root hoặc PDB

**Kết nối vào Root (CDB$ROOT):**
```bash
sqlplus / as sysdba
# hoặc
sqlplus sys/password@hostname:1521/CDB_SERVICE as sysdba
```

**Kết nối trực tiếp vào PDB:**
```bash
sqlplus user/password@hostname:1521/PDB_SERVICE_NAME
# hoặc dùng Easy Connect
sqlplus user/password@//hostname:1521/pdb_service
```

- Dùng tnsnames.ora với service name của CDB/PDB (Khuyến nghị cho môi trường ứng dụng/client) để kết nối tiện lợi hơn.
- Lab VirtualBox: dùng localhost khi kết nối ngay trong VM và 192.168.56.101 khi kết nối từ máy host qua Host-only.
- Production máy đơn: ưu tiên hostname DNS nội bộ ổn định; dùng IP nội bộ nếu phù hợp với quy hoạch mạng.
- Production RAC: dùng SCAN/VIP theo kiến trúc RAC, không tùy tiện dùng IP của một node.
- Ngoài ra, nếu kết nối từ Windows bằng SQL Developer hoặc SQLPlus, hãy cấu hình alias trong tnsnames.ora mà 
  Oracle Client trên Windows đang sử dụng; sửa file trong Oracle Home trên Linux không tự động cập nhật cấu hình Windows.
- LISTENER_ORCLCDB: không phải alias dùng để đăng nhập database. 
  Nó thường là một network name được tham chiếu trong cấu hình listener,  không cần đổi nó sang IP nếu 
  hostname oracle-lab đang phân giải đúng.

```Plaintext
# Connect to CDB locally using hostname
ORCLCDB =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = oracle-lab)(PORT = 1521))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = orclcdb)
    )
  )

# Connect to CDB locally using localhost
CDBROOT_LOCAL =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = localhost)(PORT = 1521))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = orclcdb)
    )
  )

# Connect to CDB remotely using host-only IP
CDBROOT_REMOTE =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = 192.168.56.101)(PORT = 1521))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = orclcdb)
    )
  )

# Connect to PDB1 locally
PDB1 =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = localhost)(PORT = 1521))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = pdb1)
    )
  )

# Connect to PDB1 remotely using host-only IP
PDB1_REMOTE =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = 192.168.56.101)(PORT = 1521))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = pdb1)
    )
  )

# Local listener address
LISTENER_ORCLCDB =
  (ADDRESS = (PROTOCOL = TCP)(HOST = oracle-lab)(PORT = 1521))
```

- Kiểm tra sau khi lưu, Chạy trên máy Linux bằng user oracle:

```bash
tnsping ORCLCDB
tnsping CDBROOT_LOCAL
tnsping CDBROOT_REMOTE
tnsping PDB1
tnsping PDB1_REMOTE
```

- Kết nối CDB/PDB:
sqlplus system@CDBROOT_REMOTE
sqlplus system@CDBROOT_LOCAL
sqlplus pdb1_admin@PDB1_REMOTE

### 5. Các lệnh hữu ích khác

```sql
-- Mở PDB (nếu đang MOUNTED)
ALTER PLUGGABLE DATABASE tên_pdb OPEN;
-- hoặc mở tất cả
ALTER PLUGGABLE DATABASE ALL OPEN;

-- Đóng PDB
ALTER PLUGGABLE DATABASE tên_pdb CLOSE IMMEDIATE;

-- Xem service name của PDB
SELECT name, pdb FROM v$services ORDER BY pdb, name;
```

### Ví dụ thực tế

```sql
SQL> SHOW CON_NAME;
CON_NAME
----------------
CDB$ROOT

SQL> ALTER SESSION SET CONTAINER = ORCLPDB1;
Session altered.

SQL> SHOW CON_NAME;
CON_NAME
----------------
ORCLPDB1

SQL> ALTER SESSION SET CONTAINER = CDB$ROOT;
Session altered.
```

### chú ý:
- 1. sqlplus / as sysdba
	- Cách hoạt động: Khi bạn gõ dấu /, Oracle không kiểm tra user/password trong cơ sở dữ liệu. Thay vào đó, Oracle tin tưởng vào người dùng Linux/Unix đang chạy lệnh. Nếu tài khoản OS thuộc nhóm quản trị (mặc định là nhóm dba), Oracle sẽ cấp ngay quyền SYSDBA.
	- Ưu điểm:
	- Cực kỳ hữu ích khi bạn quên mật khẩu user SYS.
	- Dùng để khởi động database (startup) khi instance hoặc listener chưa hoạt động.
	- Hạn chế: Bắt buộc bạn phải SSH trực tiếp vào máy chủ chạy database và đăng nhập bằng tài khoản có quyền (thường là user oracle).

2. sqlplus sys/admin123@orclcdb as sysdba
	- Cách hoạt động:
	- Ký hiệu @orclcdb yêu cầu SQLPlus tìm kiếm cấu hình mạng TNS (trong file tnsnames.ora hoặc qua EZCONNECT) để kết nối tới cổng của Oracle Listener (mặc định 1521).
	- Listener nhận yêu cầu và chuyển tiếp tới instance.
	- Instance đối chiếu mật khẩu admin123 với file mật khẩu của database (orapw<ORACLE_SID>).
	- Ưu điểm: Cho phép quản trị viên kết nối từ xa từ máy tính cá nhân hoặc máy trạm mà không cần phải SSH vào OS của server.
	- Hạn chế: Nếu Oracle Listener đang bị tắt hoặc file cấu hình mạng/password file có lỗi, lệnh này sẽ thất bại (báo lỗi như ORA-12154, ORA-12541, hoặc ORA-01031).

---

**Tóm tắt nhanh:**

| Mục đích                    | Lệnh / Cách làm                          |
|----------------------------|------------------------------------------|
| Xem container hiện tại     | `SHOW CON_NAME`                          |
| Chuyển sang PDB            | `ALTER SESSION SET CONTAINER = pdb_name` |
| Chuyển về Root             | `ALTER SESSION SET CONTAINER = CDB$ROOT` |
| Kết nối trực tiếp PDB      | `sqlplus user/pass@pdb_service`          |
| Xem danh sách PDB          | `SHOW PDBS`                              |


