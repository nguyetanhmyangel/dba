# Quy trình Khởi động và Tắt Container Database (CDB) trong Oracle

## 1. Thiết lập biến môi trường

Trước khi thực hiện bất kỳ thao tác quản trị nào, cần đảm bảo bạn đang đăng nhập bằng user hệ điều hành `oracle` và đã tải đúng biến môi trường.

```bash
# Đăng nhập bằng user oracle
su - oracle

# Thiết lập ORACLE_SID (thay 'orclcdb' bằng SID thực tế của hệ thống)
export ORACLE_SID=orclcdb
export ORACLE_HOME=/u01/app/oracle/product/19.0.0/dbhome_1
export PATH=$ORACLE_HOME/bin:$PATH
```

---
## 2. Quy trình Khởi động (Startup Process)

Thứ tự chuẩn: **Khởi động Listener** $\rightarrow$ **Khởi động CDB$ROOT** $\rightarrow$ **Mở các PDB**.

### Bước 2.1: Khởi động Oracle Net Listener

```bash
lsnrctl status
# Nếu Listener chưa chạy:
lsnrctl start
```

### Bước 2.2: Khởi động CDB$ROOT

Kết nối vào database với quyền quản trị OS:

```bash
sqlplus / as sysdba
```

Khởi động instance CDB lên trạng thái `OPEN`:

```sql
STARTUP;
```

*Ghi chú: Lệnh `STARTUP` sẽ tuần tự đưa instance qua các trạng thái: NOMOUNT $\rightarrow$ MOUNT $\rightarrow$ OPEN.*

### Bước 2.3: Mở các Pluggable Database (PDB)

Mặc định trong một số cấu hình, khi CDB mở, các PDB có thể chỉ dừng ở trạng thái `MOUNTED`.

Kiểm tra trạng thái các PDB:

```sql
SHOW PDBS;
```

Mở tất cả các PDB:

```sql
ALTER PLUGGABLE DATABASE ALL OPEN;
```

*(Hoặc chỉ mở một PDB cụ thể: `ALTER PLUGGABLE DATABASE <pdb_name> OPEN;`)*

**Mẹo tự động:** Để các PDB tự động mở khi CDB khởi động sau này:
```sql
ALTER PLUGGABLE DATABASE ALL SAVE STATE;
```
---

## 3. Quy trình Tắt an toàn (Shutdown Process)

Thứ tự chuẩn: **Đóng các PDB** (tùy chọn nhưng khuyến nghị) $\rightarrow$ **Tắt CDB** $\rightarrow$ **Dừng Listener** (nếu cần bảo trì hệ thống).

### Bước 3.1: Đóng các PDB

Kết nối vào `CDB$ROOT`:

```bash
sqlplus / as sysdba
```

Đưa tất cả các PDB về trạng thái đóng an toàn (`MOUNTED`):

```sql
ALTER PLUGGABLE DATABASE ALL CLOSE IMMEDIATE;
```

Kiểm tra lại trạng thái PDB:

```sql
SHOW PDBS;
```

*Xác nhận cột `OPEN MODE` chuyển sang `MOUNTED`.*

### Bước 3.2: Tắt Container Database (CDB)

Thực hiện tắt CDB an toàn:

```sql
SHUTDOWN IMMEDIATE;
```

*Lệnh này ngắt các phiên làm việc hiện tại, rollback các transaction chưa commit và đồng bộ checkpoint trước khi đóng dữ liệu.*

### Bước 3.3: Dừng Listener (khi cần bảo trì OS hoặc nâng cấp)

Thoát khỏi SQLPlus (`exit`) và chạy trên terminal:
```bash
lsnrctl stop
```
---

## 4. Bảng tóm tắt các chế độ Shutdown

| Chế độ                          | Cho phép kết nối mới? | Chờ phiên hiện tại kết thúc? | Chờ transaction hiện tại kết thúc? | Cần Instance Recovery khi bật lại? |
| --------------------------------| --------------------- | ---------------------------- | ---------------------------------- | ---------------------------------- |
| **`NORMAL`**                    | Không                 | Có                           | Có                                 | Không                              |
| **`TRANSACTIONAL`**             | Không                 | Không                        | Có                                 | Không                              |
| **`IMMEDIATE`** *(Khuyên dùng)* | Không                 | Không (Ngắt ngay)            | Không (Rollback)                   | Không                              |
| **`ABORT`** *(Cưỡng chế)*       | Không                 | Không (Ngắt tức thì)         | Không (Dừng tiến trình)            | **Có**                             |


- Có thể dùng Server Control (srvctl) để startup/ stop CDB