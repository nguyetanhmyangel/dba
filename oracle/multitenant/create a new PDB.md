
### 1. Kiểm tra hệ thống (File System hay ASM?) và Vị trí Datafile
- Trước khi tạo PDB, cần kiểm tra xem CDB hiện tại đang lưu trữ dữ liệu trên File System thường hay ASM, 
cũng như đường dẫn của PDB$SEED để làm căn cứ convert dữ liệu.

#### 1. Kiểm tra vị trí và định dạng file của PDB$SEED. Query này xác định biết PDB$SEED đang nằm ở đâu. Nếu đường dẫn bắt đầu bằng dấu + (ví dụ: +DATA/...), 
hệ thống đang dùng ASM. Nếu là đường dẫn thông thường (ví dụ: /u01/app/... hoặc D:\app\...), hệ thống đang dùng File System.

```SQL
sqlplus / as sysdba
SELECT con_id, name
FROM v$datafile
WHERE con_id = 2; -- con_id = 2 luôn là PDB$SEED
```
#### 2. Kiểm tra tham số OMF (Oracle Managed Files). Nếu tham số db_create_file_dest đã được cấu hình, Oracle có thể tự động quản lý file mà không nhất thiết phải cần tới FILE_NAME_CONVERT. 

```SQL
SHOW PARAMETER db_create_file_dest;
```
### 2. Câu lệnh Tạo PDB sử dụng Convert Clause
- Giả sử chúng ta muốn tạo một PDB mới tên là PROD_PDB từ PDB$SEED. 
Tùy thuộc vào kết quả kiểm tra ở Bước 1, chọn 1 trong 2 trường hợp sau:

#### Trường hợp 1: Hệ thống dùng File System

- Giả sử kết quả Bước 1 cho thấy PDB$SEED nằm tại: /u01/app/oracle/oradata/CDB/pdbseed/ và muốn lưu PDB mới tại: /u01/app/oracle/oradata/CDB/prod_pdb/ . Sử dụng FILE_NAME_CONVERT (hoặc PDB_FILE_NAME_CONVERT, cả hai có cú pháp tương đương trong lệnh này):

```SQL
-- dùng tham số FILE_NAME_CONVERT
CREATE PLUGGABLE DATABASE prod_pdb 
ADMIN USER pdb_admin IDENTIFIED BY "Password_123"
ROLES = (DBA)
FILE_NAME_CONVERT = ('/u01/app/oracle/oradata/CDB/pdbseed/', '/u01/app/oracle/oradata/CDB/prod_pdb/');
```

#### Trường hợp 2: Hệ thống dùng ASM

- Giả sử kết quả Bước 1 cho thấy PDB$SEED nằm trên ASM Diskgroup: +DATA/CDB/DATAFILE/pdbseed/ và bạn muốn PDB mới nằm ở một thư mục khác trên ASM (hoặc cùng Diskgroup nhưng khác folder): +DATA/CDB/DATAFILE/prod_pdb/ . Cú pháp hoàn toàn tương tự, chỉ thay đường dẫn bằng ký tự của ASM:

```SQL
-- dùng tham số PDB_FILE_NAME_CONVERT
CREATE PLUGGABLE DATABASE prod_pdb 
ADMIN USER pdb_admin IDENTIFIED BY "Password_123"
ROLES = (DBA)
PDB_FILE_NAME_CONVERT = ('+DATA/CDB/DATAFILE/pdbseed/', '+DATA/CDB/DATAFILE/prod_pdb/');
```
- Nếu hệ thống ASM của đã bật OMF (tức là lệnh SHOW PARAMETER db_create_file_dest trả về một Diskgroup như +DATA), 
thậm chí không cần dùng FILE_NAME_CONVERT. 
Oracle sẽ tự tạo cấu trúc thư mục tối ưu. Best Practice trong trường hợp này:

```SQL
CREATE PLUGGABLE DATABASE prod_pdb 
ADMIN USER pdb_admin IDENTIFIED BY "Password_123"
ROLES = (DBA);
```

#### 3: Mở PDB mới tạo để sử dụng
Sau khi chạy lệnh tạo thành công, PDB mới sẽ ở trạng thái MOUNTED, ta cần mở nó lên:

```SQL
-- Kiểm tra trạng thái hiện tại của các PDB
SHOW PDBS;

-- Open PDB mới tạo
ALTER PLUGGABLE DATABASE prod_pdb OPEN;

-- (Tùy chọn) Lưu trạng thái để PDB tự động mở khi restart CDB. Không bắt buộc, nhưng trong hầu hết môi trường thực tế, rất nên làm
ALTER PLUGGABLE DATABASE prod_pdb SAVE STATE;

-- Đăng nhập từ terminal
sqlplus pdb_admin/Password_123@//hostname:1521/prod_pdb

-- đăng nhập từ local
sqlplus pdb_admin/Password_123@//localhost:1521/prod_pdb

-- đã vào SQL*Plus: sqlplus / as sysdba -> chuyển sang user khác,chỉ hoạt động nếu prod_pdb là một Oracle Net Service Name đã được cấu hình, ví dụ trong file tnsnames.ora:
-- PROD_PDB =
--  (DESCRIPTION =
--   (ADDRESS = (PROTOCOL = TCP)(HOST = dbserver01)(PORT = 1521))
--    (CONNECT_DATA =
--      (SERVICE_NAME = prod_pdb)
--    )
--  )
-- hoặc được cấu hình qua các cơ chế Oracle Net khác
SQL> conn pdb_admin/Password_123@prod_pdb

```