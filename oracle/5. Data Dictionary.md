### 1. DATA DICTIONARY LÀ GÌ?

Data Dictionary trong Oracle là tập hợp các bảng và view hệ thống mà Oracle sử dụng để lưu thông tin về database:

- Tên và cấu trúc bảng

- Cột, kiểu dữ liệu

- User, quyền

- Index, sequence, trigger, view...

- Cấu trúc vật lý: tablespace, datafile, redo log...

Nói đơn giản:

➡️ Nó là bộ não lưu thông tin "metadata" (siêu dữ liệu) của Oracle Database.

### 2. VAI TRÒ CỦA DATA DICTIONARY

- Cho biết ai là chủ sở hữu bảng, bảng có cột nào, cột đó có kiểu dữ liệu gì...

- Oracle tự động cập nhật nội dung từ điển dữ liệu khi bạn tạo, thay đổi, hoặc xóa các đối tượng như bảng, view, user,...

- Người dùng có thể truy vấn để kiểm tra thông tin.

### 3. CÁC LOẠI DATA DICTIONARY VIEW

| Loại view | Mô tả                                                                             | Ví dụ                             |
|-----------|-----------------------------------------------------------------------------------|-----------------------------------|
| `USER_`   | Thông tin về đối tượng **do user hiện tại sở hữu**                                | `USER_TABLES`, `USER_TAB_COLUMNS` |
| `ALL_`    | Thông tin về đối tượng user **có quyền truy cập** (không cần sở hữu)              | `ALL_TABLES`, `ALL_VIEWS`         |
| `DBA_`    | Thông tin **tất cả các đối tượng trong DB** (chỉ xem được nếu có quyền `DBA`)     | `DBA_USERS`, `DBA_TABLES`         |
| `V$`      | View động – thống kê hoạt động runtime của DB                                     | `V$SESSION`, `V$INSTANCE`         |

### 4. MỘT SỐ VIEW THƯỜNG DÙNG

```bash
-- Thông tin về user và quyền
SELECT * FROM DBA_USERS;
SELECT * FROM USER_ROLE_PRIVS;

-- Danh sách bảng
SELECT table_name FROM USER_TABLES;
SELECT table_name FROM ALL_TABLES WHERE owner = 'HR';
SELECT table_name FROM DBA_TABLES WHERE tablespace_name = 'USERS';

-- Cấu trúc bảng, cột
SELECT column_name, data_type, data_length 
FROM USER_TAB_COLUMNS 
WHERE table_name = 'EMPLOYEES';

-- Kiểm tra quyền (privileges)
SELECT * FROM USER_SYS_PRIVS;
SELECT * FROM ROLE_SYS_PRIVS;

-- Tablespace và dữ liệu
SELECT * FROM DBA_TABLESPACES;
SELECT * FROM DBA_DATA_FILES;

-- Xem danh sách bảng user hiện tại sở hữu
SELECT table_name FROM user_tables;

-- Xem thông tin chi tiết bảng, ví dụ: EMPLOYEES
SELECT column_name, data_type, data_length 
FROM user_tab_columns 
WHERE table_name = 'EMPLOYEES';

-- Kiểm tra các index trên một bảng
SELECT index_name, column_name 
FROM user_ind_columns 
WHERE table_name = 'EMPLOYEES';

-- Kiểm tra các sequence user hiện tại sở hữu
SELECT sequence_name FROM user_sequences;

-- Kiểm tra SID, serial number, và status của session hiện tại
SELECT SID, SERIAL#, STATUS FROM V$SESSION WHERE USERNAME='SYSTEM'; 

-- Mô tả cấu trúc của V$TABLESPACE và DBA_TABLESPACES
DESC V$TABLESPACE
DESC DBA_TABLESPACES

-- Lấy tên tablespace trong database và datafiles trong mỗi tablespace.
SELECT S.NAME TABLESPACE_NAME, D.NAME DATAFILE
FROM V$TABLESPACE S, V$DATAFILE D
WHERE S.TS# = D.TS#
ORDER BY 1; 
```
### 5. Ý nghĩa của các tiền tố & các tình huống cần sử dụng:

| Tiền tố | Ý nghĩa                                        |
|---------|------------------------------------------------|
| `USER_` | Những gì user hiện tại **sở hữu**              |
| `ALL_`  | Những gì user hiện tại **có thể truy cập**     |
| `DBA_`  | Những gì toàn bộ **database chứa**             |
| `V$`    | Thống kê về **hoạt động runtime** của hệ thống |


| Tình huống                          | View nên dùng      |
|-------------------------------------|--------------------|
| Tên các bảng của user hiện tại      | `USER_TABLES`      |
| Cột trong bảng                      | `USER_TAB_COLUMNS` |
| Quyền của user hiện tại             | `USER_SYS_PRIVS`   |
| Các bảng user hiện tại có quyền xem | `ALL_TABLES`       |
| Tất cả user trong hệ thống          | `DBA_USERS`        |
| Trạng thái phiên                    | `V$SESSION`        |
| Tên sequence user hiện tại tạo      | `USER_SEQUENCES`   |
| Tên trigger                         | `USER_TRIGGERS`    |

