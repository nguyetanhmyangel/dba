### 1. Phân biệt giữa CDB và PDB

| Thuộc tính      | CDB (Container Database)                                   | PDB (Pluggable Database)                               |
| --------------- | ---------------------------------------------------------- | ------------------------------------------------------ |
| Khái niệm       | Là cơ sở dữ liệu chứa nhiều PDB.                           | Là cơ sở dữ liệu con được gắn vào CDB.                 |
| Vai trò         | Quản lý tài nguyên, người dùng chung, metadata toàn cục.   | Chứa dữ liệu ứng dụng, người dùng riêng.               |
| Truy cập        | SYSDBA truy cập toàn bộ CDB.                               | Có thể truy cập PDB riêng biệt như một DB bình thường. |
| Dữ liệu lưu trữ | Data dictionary, metadata chung, REDO, UNDO, control files | Dữ liệu ứng dụng riêng biệt                            |
| SID/DB Name     | Có SID riêng cho toàn CDB (ví dụ: `orcl`)                  | Có tên riêng cho từng PDB (ví dụ: `pdb1`)              |

### 2. Các thành phần trong Multitenant Architecture

Multitenant bao gồm:

- CDB$ROOT: Container gốc chứa metadata hệ thống, dictionary dùng chung.

- SEED PDB (PDB$SEED): Là PDB mẫu được dùng để tạo các PDB mới.

- PDBs (Pluggable Databases): Cơ sở dữ liệu độc lập lưu trữ dữ liệu ứng dụng.

- CDB: Bao gồm CDB$ROOT, PDB$SEED và tất cả PDBs.

- Container ID (CON_ID): Mỗi container có một ID riêng biệt.

- Services: Mỗi PDB có thể đăng ký dịch vụ riêng để kết nối.

### 3. Sử dụng Data Dictionary Views và V$ Views trong CDB

Khi đang ở chế độ CDB:

- Các view có tiền tố CDB_ cung cấp thông tin của tất cả container. Ví dụ:

	- CDB_USERS: Xem user ở tất cả PDB.

	- CDB_TABLESPACES, CDB_DATA_FILES, ...

- Các view có tiền tố DBA_, ALL_, USER_ hoạt động theo PDB hiện tại.

- Dynamic performance views (V$):

	- V$CONTAINERS: Danh sách các container.

	- V$PDBS: Danh sách PDB.

	- V$SESSION: Cột CON_ID cho biết session đang nằm ở PDB nào.

Ví dụ:

```bash
SELECT NAME, CON_ID FROM V$PDBS;

SELECT USERNAME, CON_ID FROM CDB_USERS WHERE USERNAME = 'HR';
```

### 4. Common Files trong CDBs

Các file được dùng chung trong CDB:

	- Control files

	- Redo log files

	- UNDO tablespace (nếu dùng shared undo)

	- SPFILE / Password file

	- Parameter files (init.ora hoặc spfile)

Các file riêng biệt cho mỗi PDB:

	- Datafile của PDB

	- Temp file (có thể riêng hoặc dùng chung)

### 5. Khác nhau giữa Common Users và Local Users

| Thuộc tính | Common User (`C##USERNAME`)                    | Local User (ví dụ `HR`)            |
| ---------- | ---------------------------------------------- | ---------------------------------- |
| Tạo ở      | `CDB$ROOT`                                     | PDB cụ thể                         |
| Truy cập   | Có thể truy cập nhiều PDB (nếu được cấp quyền) | Chỉ tồn tại trong PDB đó           |
| Quản lý    | DBAs quản lý toàn CDB                          | Quản lý bởi người quản trị PDB     |
| Ví dụ tạo  | `CREATE USER C##ADMIN IDENTIFIED BY oracle;`   | `CREATE USER HR IDENTIFIED BY hr;` |
| Phạm vi    | Toàn CDB                                       | PDB cụ thể                         |

### 6. Khác nhau giữa Shared UNDO và Local UNDO

| Thuộc tính    | Shared UNDO (truyền thống)                       | Local UNDO (Oracle 12.2+)                   |
| ------------- | ------------------------------------------------ | ------------------------------------------- |
| UNDO được lưu | Tại CDB\$ROOT dùng chung cho tất cả PDB          | Mỗi PDB có UNDO tablespace riêng            |
| Quản lý bởi   | CDB                                              | PDB độc lập                                 |
| Ưu điểm       | Đơn giản                                         | Cho phép clone / flashback PDB riêng lẻ     |
| Cấu hình      | `UNDO_MODE = AUTO`, không khai báo riêng cho PDB | `ENABLE_LOCAL_UNDO = TRUE` trong `CDB$ROOT` |

### 7. Một số lệnh kiểm tra

- Xem hiện tại đang ở container nào:

```bash
SELECT SYS_CONTEXT('USERENV', 'CON_NAME') FROM DUAL;
```

- Chuyển vào PDB:

```bash
ALTER SESSION SET CONTAINER = pdb1;
```

- Tạo user trong CDB (common):

```bash
CREATE USER C##ADMIN IDENTIFIED BY oracle CONTAINER=ALL;
GRANT CONNECT, DBA TO C##ADMIN CONTAINER=ALL;
```

- Tạo user trong PDB (local):

```bash
ALTER SESSION SET CONTAINER = pdb1;
CREATE USER hr IDENTIFIED BY hr;
GRANT CONNECT TO hr;
```