# Oracle 19c – PDB Properties

## 1. Phạm vi

Tài liệu này tập trung vào các thuộc tính của Pluggable Database (PDB), đặc biệt là:

- `DATABASE_PROPERTIES`
- `CDB_PROPERTIES`
- Ý nghĩa của các thuộc tính
- Cách xác định thuộc tính nào có thể thay đổi
- Cách thay đổi và kiểm tra lại giá trị

Không bao gồm các nhóm riêng như `V$PDBS`, initialization parameters, tablespace usage hay trạng thái dịch vụ.

## 2. Phân biệt hai view

### 2.1. `DATABASE_PROPERTIES`

View này liệt kê các permanent database properties của container hiện tại.

```
SELECT PROPERTY_NAME,
       PROPERTY_VALUE,
       DESCRIPTION
FROM DATABASE_PROPERTIES
ORDER BY PROPERTY_NAME;
```

Ba cột:

| Cột              | Ý nghĩa            |
| ---------------- | ------------------ |
| `PROPERTY_NAME`  | Tên thuộc tính     |
| `PROPERTY_VALUE` | Giá trị thuộc tính |
| `DESCRIPTION`    | Mô tả thuộc tính   |

### 2.2. `CDB_PROPERTIES`

View này cung cấp các properties nhìn thấy từ những container trong CDB, kèm `CON_ID` để xác định container.

```
SELECT CON_ID,
       PROPERTY_NAME,
       PROPERTY_VALUE,
       DESCRIPTION
FROM CDB_PROPERTIES
ORDER BY CON_ID, PROPERTY_NAME;
```

**Điều kiện:** cần truy cập từ `CDB$ROOT` và có quyền đọc phù hợp để xem dữ liệu của các container khác.

### 2.3. So sánh

| Đặc điểm                                | `DATABASE_PROPERTIES` | `CDB_PROPERTIES`                         |
| --------------------------------------- | --------------------- | ---------------------------------------- |
| Phạm vi                                 | Container hiện tại    | Các container có thể nhìn thấy trong CDB |
| Cột nhận diện container                 | Không có `CON_ID`     | Có `CON_ID`                              |
| Dùng để xem thuộc tính của PDB          | Chuyển vào PDB trước  | Lọc theo `CON_ID`                        |
| Dùng để xem toàn CDB                    | Không trực tiếp       | Có                                       |
| Có phải bảng cấu hình để sửa trực tiếp? | Không                 | Không                                    |

---

## 3. Xem toàn bộ properties của một PDB

Giả sử PDB cần kiểm tra là `PROD_PDB`.

### Cách 1: Truy vấn trực tiếp trong PDB

```
ALTER SESSION SET CONTAINER = PROD_PDB;

SELECT PROPERTY_NAME,
       PROPERTY_VALUE,
       DESCRIPTION
FROM DATABASE_PROPERTIES
ORDER BY PROPERTY_NAME;
```

Cách này phù hợp khi muốn nghiên cứu từng thuộc tính ngay trong PDB.

Kiểm tra container hiện tại:

```
SHOW CON_NAME;
```

### Cách 2: Truy vấn từ CDB Root

```
ALTER SESSION SET CONTAINER = CDB$ROOT;

SELECT CON_ID,
       PROPERTY_NAME,
       PROPERTY_VALUE,
       DESCRIPTION
FROM CDB_PROPERTIES
WHERE CON_ID = (
    SELECT CON_ID
    FROM V$PDBS
    WHERE NAME = 'PROD_PDB'
)
ORDER BY PROPERTY_NAME;
```

Thay `PROD_PDB` bằng tên PDB thực tế.

Cách này thuận tiện khi cần so sánh properties của nhiều PDB mà không phải chuyển container nhiều lần.

---

## 4. Những properties cần chú ý

Các thuộc tính xuất hiện phụ thuộc phiên bản Oracle, cấu hình và trạng thái của container. 
Trước khi áp dụng ví dụ, hãy xác nhận thuộc tính thực sự tồn tại bằng truy vấn ở phần 3.


### 4.1. `DEFAULT_PERMANENT_TABLESPACE`

**Ý nghĩa:** Tablespace mặc định được sử dụng cho các schema/user trong container nếu không chỉ định rõ ràng mệnh đề `DEFAULT TABLESPACE` khi tạo user, hoặc khi tạo bảng mà không chỉ định tablespace lưu trữ.

**Xem giá trị:**

```sql
SELECT PROPERTY_NAME,
       PROPERTY_VALUE,
       DESCRIPTION
FROM DATABASE_PROPERTIES
WHERE PROPERTY_NAME = 'DEFAULT_PERMANENT_TABLESPACE';

```

**Cảnh báo & Phạm vi thực hiện:**

* **Phạm vi:** Áp dụng độc lập trên từng PDB riêng biệt.
* **Yêu cầu trạng thái:** **Không** cần `CLOSE IMMEDIATE`, **không** cần `OPEN RESTRICTED` hay `OPEN UPGRADE`. PDB đang mở ở chế độ `READ WRITE` bình thường.
* **CDB$ROOT:** Không cần can thiệp từ `CDB$ROOT`.

**Thay đổi cấu hình (thực hiện bên trong PDB):**

```sql
-- Chuyển session vào PDB cần cấu hình
ALTER SESSION SET CONTAINER = pdb1;

-- Chỉ định tablespace USERS làm tablespace vĩnh viễn mặc định
ALTER DATABASE DEFAULT TABLESPACE USERS;

```

**Kiểm tra lại:**

```sql
SELECT PROPERTY_NAME, PROPERTY_VALUE
FROM DATABASE_PROPERTIES
WHERE PROPERTY_NAME = 'DEFAULT_PERMANENT_TABLESPACE';

```

**Lưu ý:** Thao tác này chỉ áp dụng cho các segment/user tạo mới về sau; không tự động di chuyển các data segment (table, index) đã tồn tại và không ghi đè tablespace đã gán cứng cho các user trước đó.

---

### 4.2. `DEFAULT_TEMP_TABLESPACE`

**Ý nghĩa:** Temporary tablespace mặc định của container dùng cho các thao tác sắp xếp (`ORDER BY`, `GROUP BY`), hash join, hoặc tạo index khi không đủ bộ nhớ PGA.

**Xem giá trị:**

```sql
SELECT PROPERTY_NAME, PROPERTY_VALUE
FROM DATABASE_PROPERTIES
WHERE PROPERTY_NAME = 'DEFAULT_TEMP_TABLESPACE';

```

**Cảnh báo & Phạm vi thực hiện:**

* **Phạm vi:** Áp dụng độc lập trên từng PDB riêng biệt.
* **Yêu cầu trạng thái:** **Không** cần `CLOSE IMMEDIATE`, **không** cần `OPEN RESTRICTED`. PDB đang mở `READ WRITE`.
* **CDB$ROOT:** Không cần can thiệp từ `CDB$ROOT`.

**Thay đổi cấu hình:**

```sql
-- Gán TEMP làm temporary tablespace mặc định cho PDB
ALTER DATABASE DEFAULT TEMPORARY TABLESPACE TEMP;

```

**Kiểm tra lại:**

```sql
SELECT PROPERTY_NAME, PROPERTY_VALUE
FROM DATABASE_PROPERTIES
WHERE PROPERTY_NAME = 'DEFAULT_TEMP_TABLESPACE';

```

**Lưu ý:** Tablespace chỉ định (ví dụ `TEMP`) bắt buộc phải tồn tại từ trước trong PDB. Việc đổi giá trị không làm ngắt các session đang dùng temporary segment cũ dở dang; các session mới hoặc truy vấn mới sẽ tự động nhận tablespace này.

---

### 4.3. `DEFAULT_TBS_TYPE`

**Ý nghĩa:** Xác định loại kiến trúc datafile mặc định khi chạy lệnh `CREATE TABLESPACE` mà không chỉ định từ khóa `SMALLFILE` hay `BIGFILE`.

**Xem giá trị:**

```sql
SELECT PROPERTY_NAME, PROPERTY_VALUE, DESCRIPTION
FROM DATABASE_PROPERTIES
WHERE PROPERTY_NAME = 'DEFAULT_TBS_TYPE';

```

**Cảnh báo & Phạm vi thực hiện:**

* **Phạm vi:** Áp dụng độc lập trên từng PDB riêng biệt (hoặc toàn CDB nếu chạy tại `CDB$ROOT`).
* **Yêu cầu trạng thái:** **Không** cần `CLOSE IMMEDIATE`, **không** cần `OPEN RESTRICTED`.
* **CDB$ROOT:** Thực hiện trực tiếp trong PDB tương ứng.

**Thay đổi cấu hình:**

```sql
-- Mặc định tạo Bigfile Tablespace (chỉ có 1 datafile đơn dung lượng tối đa lên đến hàng chục TB)
ALTER DATABASE SET DEFAULT BIGFILE TABLESPACE;

-- Hoặc mặc định tạo Smallfile Tablespace truyền thống (chứa tối đa 1022 datafiles)
ALTER DATABASE SET DEFAULT SMALLFILE TABLESPACE;

```

*(Ghi chú: Lệnh chuẩn của Oracle là `ALTER DATABASE SET DEFAULT...` bên trong session của PDB).*

**Kiểm tra lại:**

```sql
SELECT PROPERTY_NAME, PROPERTY_VALUE
FROM DATABASE_PROPERTIES
WHERE PROPERTY_NAME = 'DEFAULT_TBS_TYPE';

```

**Lưu ý:** Chỉ tác động đến các lệnh `CREATE TABLESPACE` được thực thi sau thời điểm cấu hình; không làm biến đổi cấu trúc các tablespace sẵn có.

---

### 4.4. `DEFAULT_EDITION`

**Ý nghĩa:** Xác định Edition mặc định của PDB khi phiên người dùng kết nối tới, phục vụ tính năng nâng cấp mã nguồn ứng dụng trực tuyến không gián đoạn (Edition-Based Redefinition - EBR).

**Kiểm tra giá trị và danh sách editions:**

```sql
SELECT PROPERTY_NAME, PROPERTY_VALUE, DESCRIPTION
FROM DATABASE_PROPERTIES
WHERE PROPERTY_NAME = 'DEFAULT_EDITION';

SELECT EDITION_NAME, USABLE FROM DBA_EDITIONS ORDER BY EDITION_NAME;

```

**Cảnh báo & Phạm vi thực hiện:**

* **Phạm vi:** Áp dụng độc lập trên từng PDB riêng biệt.
* **Yêu cầu trạng thái:** **Không bắt buộc** `CLOSE IMMEDIATE` hay `OPEN RESTRICTED`. Tuy nhiên, khuyến nghị bảo trì thời điểm ít tải vì các kết nối mới sẽ lập tức kích hoạt bộ mã PL/SQL/View theo edition mới, có thể gây bất đồng bộ logic với các session cũ chưa ngắt.
* **CDB$ROOT:** Không cần can thiệp từ `CDB$ROOT`.

**Thay đổi cấu hình:**

```sql
-- Thiết lập edition mặc định cho PDB (edition_name phải tồn tại trước trong DBA_EDITIONS)
ALTER DATABASE DEFAULT EDITION = edition_name;

```

**Lưu ý:** Nếu ứng dụng không dùng EBR, giữ nguyên giá trị mặc định của Oracle (`ORA$BASE`).

---

### 4.5. `LOCAL_UNDO_ENABLED`

**Ý nghĩa:** Xác định chế độ quản lý Undo của toàn bộ CDB: Local Undo (mỗi PDB tự quản lý tablespace UNDO riêng) hay Shared Undo (dùng chung một UNDO tablespace tại `CDB$ROOT`).

**Xem giá trị:**

```sql
SELECT PROPERTY_NAME, PROPERTY_VALUE, DESCRIPTION
FROM DATABASE_PROPERTIES
WHERE PROPERTY_NAME = 'LOCAL_UNDO_ENABLED';

```

**Cảnh báo & Phạm vi thực hiện:**

* **Phạm vi:** **KHÔNG ÁP DỤNG TRÊN PDB RIÊNG BIỆT.** Thuộc tính này là toàn cục và chỉ được điều khiển từ `CDB$ROOT`.
* **Yêu cầu trạng thái:** **BẮT BUỘC ĐÓNG TOÀN BỘ CDB (`SHUTDOWN IMMEDIATE`)** và mở ở chế độ nâng cấp **`STARTUP UPGRADE`**.
* **CDB$ROOT:** **Bắt buộc 100% can thiệp từ CDB$ROOT** với quyền `SYSDBA`. Tuyệt đối không dùng DDL sửa dictionary.

**Quy trình thay đổi (Chuyển sang Local Undo từ CDB$ROOT):**

```sql
-- 1. Đăng nhập SYSDBA tại CDB$ROOT và dừng toàn bộ CDB
SHUTDOWN IMMEDIATE;

-- 2. Mở CDB ở chế độ UPGRADE
STARTUP UPGRADE;

-- 3. Kích hoạt Local Undo cho toàn bộ Multitenant
ALTER DATABASE LOCAL UNDO ON;

-- 4. Khởi động lại CDB về chế độ bình thường
SHUTDOWN IMMEDIATE;
STARTUP;

```
---

### 4.7. `GLOBAL_DB_NAME`

**Ý nghĩa:** Tên toàn cục của PDB (`<DB_NAME>.<DB_DOMAIN>`), dùng để định danh phân giải mạng và bắt buộc phải khớp chính xác khi kết nối qua Database Link nếu tham số `GLOBAL_NAMES = TRUE`.

**Xem giá trị:**

```sql
SELECT PROPERTY_NAME, PROPERTY_VALUE, DESCRIPTION
FROM DATABASE_PROPERTIES
WHERE PROPERTY_NAME = 'GLOBAL_DB_NAME';

SELECT * FROM GLOBAL_NAME;

```

**Cảnh báo & Phạm vi thực hiện:**

* **Phạm vi:** Áp dụng trên PDB riêng biệt.
* **Yêu cầu trạng thái:** **RẤT KHUYẾN NGHỊ ĐƯA VỀ RESTRICTED**.
* Cần `CLOSE IMMEDIATE` và `OPEN RESTRICTED` để cắt dứt điểm các kết nối hiện tại của ứng dụng và dọn sạch lock/dictionary cache.
* Nếu không close, ít nhất phải chạy `ALTER SYSTEM ENABLE RESTRICTED SESSION` và kill toàn bộ session người dùng đang duy trì trước khi đổi tên.
* *(Lưu ý: Nếu đổi tên định danh PDB bằng `ALTER PLUGGABLE DATABASE ... RENAME TO ...`, PDB bắt buộc phải ở trạng thái `MOUNT` từ `CDB$ROOT`).*


* **CDB$ROOT:** Có thể thực hiện chuyển session trực tiếp vào PDB hoặc quản trị từ `CDB$ROOT`.

**Thay đổi cấu hình:**

```sql
-- 1. Từ CDB$ROOT: Đóng PDB và mở ở chế độ hạn chế (ngắt phiên thường)
ALTER PLUGGABLE DATABASE pdb1 CLOSE IMMEDIATE;
ALTER PLUGGABLE DATABASE pdb1 OPEN RESTRICTED;

-- 2. Chuyển vào PDB và thực hiện đổi GLOBAL_NAME
ALTER SESSION SET CONTAINER = pdb1;
ALTER DATABASE RENAME GLOBAL_NAME TO pdb1.lab.internal;

-- 3. Đưa PDB trở lại hoạt động bình thường
ALTER PLUGGABLE DATABASE pdb1 CLOSE IMMEDIATE;
ALTER PLUGGABLE DATABASE pdb1 OPEN;

```

**Lưu ý:** Việc thay đổi `GLOBAL_DB_NAME` sẽ làm gián đoạn hoặc lỗi toàn bộ Database Link đang trỏ đến PDB này nếu phía gọi bật kiểm tra `GLOBAL_NAMES = TRUE`.

---

### 4.8. `NLS_CHARACTERSET` & `NLS_NCHAR_CHARACTERSET`

**Ý nghĩa:** Xác định bảng mã ký tự lưu trữ dữ liệu của database/PDB.

* `NLS_CHARACTERSET`: Dành cho `CHAR`, `VARCHAR2`, `CLOB` (chuẩn khuyến nghị: `AL32UTF8`).
* `NLS_NCHAR_CHARACTERSET`: Dành cho kiểu quốc gia `NCHAR`, `NVARCHAR2`, `NCLOB` (thường là `AL16UTF16`).

**Xem giá trị:**

```sql
SELECT PROPERTY_NAME, PROPERTY_VALUE, DESCRIPTION
FROM DATABASE_PROPERTIES
WHERE PROPERTY_NAME IN ('NLS_CHARACTERSET', 'NLS_NCHAR_CHARACTERSET');

```

**Cảnh báo & Phạm vi thực hiện:**

* **Phạm vi:** PDB có thể có character set riêng nếu `CDB$ROOT` sử dụng `AL32UTF8`. Nếu `CDB$ROOT` không phải `AL32UTF8`, PDB bị ràng buộc chặt chẽ theo bộ mã của ROOT.
* **Yêu cầu trạng thái:** **BẮT BUỘC CÔ LẬP HOÀN TOÀN (`RESTRICTED` hoặc `OPEN UPGRADE`)**.
* **Không dùng lệnh thông thường:** Không thể thay đổi an toàn bằng các lệnh `ALTER DATABASE` thông thường. Phải dùng công cụ chuyên dụng như **DMU (Database Migration Assistant for Unicode)** để quét và chuyển đổi dữ liệu.
* **CDB$ROOT:** Cần quyền DBA/SYSDBA can thiệp mở PDB ở chế độ bảo trì riêng:
```sql
ALTER PLUGGABLE DATABASE pdb1 CLOSE IMMEDIATE;
ALTER PLUGGABLE DATABASE pdb1 OPEN UPGRADE;

```

---

### 4.9. `MAX_SIZE`

**Ý nghĩa:** Giới hạn tổng dung lượng lưu trữ tối đa (Storage Limit) mà datafile của PDB được phép cấp phát, tránh việc một PDB chiếm dụng cạn kiệt dung lượng đĩa dùng chung hoặc ASM Diskgroup.

**Xem giá trị:**

```sql
SELECT PROPERTY_NAME, PROPERTY_VALUE, DESCRIPTION
FROM DATABASE_PROPERTIES
WHERE PROPERTY_NAME = 'MAX_SIZE';

```

**Cảnh báo & Phạm vi thực hiện:**

* **Phạm vi:** Áp dụng độc lập trên từng PDB riêng biệt.
* **Yêu cầu trạng thái:** **Không** cần `CLOSE IMMEDIATE`, **không** cần `OPEN RESTRICTED`. Có thể tăng/giảm trực tiếp khi PDB đang hoạt động online.
* **CDB$ROOT:** Có thể thực hiện từ `CDB$ROOT` hoặc thực hiện ngay bên trong PDB.

**Thay đổi cấu hình:**

* **Cách 1: Thực hiện từ `CDB$ROOT`:**
```sql
-- Thiết lập mức trần dung lượng 50GB cho pdb1
ALTER PLUGGABLE DATABASE pdb1 STORAGE (MAXSIZE 50G);

-- Bỏ hạn mức dung lượng
ALTER PLUGGABLE DATABASE pdb1 STORAGE (MAXSIZE UNLIMITED);

```

* **Cách 2: Thực hiện trực tiếp bên trong PDB:**
```sql
ALTER SESSION SET CONTAINER = pdb1;
-- Cấu hình hạn mức trực tiếp cho container hiện tại
ALTER PLUGGABLE DATABASE STORAGE (MAXSIZE 50G);

```

**Kiểm tra lại:**

```sql
SELECT PROPERTY_NAME, PROPERTY_VALUE 
FROM DATABASE_PROPERTIES 
WHERE PROPERTY_NAME = 'MAX_SIZE';

```

**Lưu ý:** Nếu dung lượng thực tế vượt quá `MAX_SIZE`, PDB không bị treo nhưng mọi thao tác `AUTOEXTEND` datafile hoặc `ADD DATAFILE` sẽ bị từ chối với mã lỗi `ORA-65114: space usage in container exceeds MAXSIZE limit`.

---

## 5. Quy trình thay đổi một property an toàn

Áp dụng quy trình này cho từng thuộc tính cụ thể.

### Bước 1: Xác định đúng PDB

```
SHOW CON_NAME;
```

Nếu chưa đúng:

```
ALTER SESSION SET CONTAINER = PROD_PDB;
```

### Bước 2: Đọc giá trị hiện tại

```
SELECT PROPERTY_NAME,
       PROPERTY_VALUE,
       DESCRIPTION
FROM DATABASE_PROPERTIES
WHERE PROPERTY_NAME = 'DEFAULT_PERMANENT_TABLESPACE';
```

### Bước 3: Xác minh thuộc tính có thể thay đổi

Phân loại thuộc tính:

- Có cú pháp `ALTER DATABASE` được Oracle hỗ trợ.
- Có cú pháp `ALTER PLUGGABLE DATABASE` được Oracle hỗ trợ.
- Chỉ đọc hoặc chỉ thay đổi qua quy trình chuyển đổi chuyên biệt.

Không dùng `UPDATE DATABASE_PROPERTIES` hoặc `UPDATE SYS.PROPS$` để sửa giá trị.

### Bước 4: Thực hiện đúng câu lệnh

Ví dụ đổi default permanent tablespace:

```
ALTER DATABASE DEFAULT TABLESPACE USERS;
```

### Bước 5: Xác minh kết quả

```
SELECT PROPERTY_NAME,
       PROPERTY_VALUE,
       DESCRIPTION
FROM DATABASE_PROPERTIES
WHERE PROPERTY_NAME = 'DEFAULT_PERMANENT_TABLESPACE';
```

Nếu thay đổi không xuất hiện, hãy kiểm tra container, quyền, điều kiện của câu lệnh và tài liệu về property đó.

---

## 6. Các nguyên tắc cần nhớ

1. `DATABASE_PROPERTIES` là view để đọc properties của container hiện tại.
2. `CDB_PROPERTIES` dùng để xem properties theo container trong phạm vi được phép truy cập.
3. Không phải property nào cũng có thể thay đổi trực tiếp.
4. `DEFAULT_PERMANENT_TABLESPACE`, `DEFAULT_TEMP_TABLESPACE` và `DEFAULT_TBS_TYPE` có thể thay đổi bằng các câu lệnh quản trị tương ứng.
5. `LOCAL_UNDO_ENABLED` không phải thuộc tính cấu hình thông thường để sửa riêng ở một PDB.
6. Luôn kiểm tra giá trị trước và sau thay đổi.
7. Trên production, cần đánh giá ảnh hưởng và có phương án rollback trước khi thay đổi cấu hình.

