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

Các thuộc tính xuất hiện phụ thuộc phiên bản Oracle, cấu hình và trạng thái của container. Trước khi áp dụng ví dụ, hãy xác nhận thuộc tính thực sự tồn tại bằng truy vấn ở phần 3.

### 4.1. `DEFAULT_PERMANENT_TABLESPACE`

**Ý nghĩa:** Tablespace mặc định được sử dụng cho các user mới trong container, nếu không chỉ định tablespace riêng khi tạo user.

Xem giá trị:

```
SELECT PROPERTY_NAME,
       PROPERTY_VALUE,
       DESCRIPTION
FROM DATABASE_PROPERTIES
WHERE PROPERTY_NAME = 'DEFAULT_PERMANENT_TABLESPACE';
```

Thay đổi trong PDB cần quản trị:

```
ALTER DATABASE DEFAULT TABLESPACE USERS;
```

Kiểm tra lại:

```
SELECT PROPERTY_NAME, PROPERTY_VALUE
FROM DATABASE_PROPERTIES
WHERE PROPERTY_NAME = 'DEFAULT_PERMANENT_TABLESPACE';
```

Lưu ý: thao tác này không di chuyển các segment đã tồn tại và không ghi đè tablespace đã chỉ định riêng cho từng user.

### 4.2. `DEFAULT_TEMP_TABLESPACE`

**Ý nghĩa:** Temporary tablespace mặc định của container.

Xem:

```
SELECT PROPERTY_NAME, PROPERTY_VALUE
FROM DATABASE_PROPERTIES
WHERE PROPERTY_NAME = 'DEFAULT_TEMP_TABLESPACE';
```

Thay đổi:

```
ALTER DATABASE DEFAULT TEMPORARY TABLESPACE TEMP;
```

Kiểm tra lại:

```
SELECT PROPERTY_NAME, PROPERTY_VALUE
FROM DATABASE_PROPERTIES
WHERE PROPERTY_NAME = 'DEFAULT_TEMP_TABLESPACE';
```

`TEMP` phải là temporary tablespace hợp lệ trong PDB. Thay đổi mặc định không có nghĩa là mọi session hiện tại lập tức chuyển sang một tablespace khác.

### 4.3. `DEFAULT_TBS_TYPE`

**Ý nghĩa:** Loại tablespace mặc định được sử dụng khi tạo tablespace mà không chỉ định rõ loại, thường là `SMALLFILE` hoặc `BIGFILE`.

Xem:

```
SELECT PROPERTY_NAME, PROPERTY_VALUE, DESCRIPTION
FROM DATABASE_PROPERTIES
WHERE PROPERTY_NAME = 'DEFAULT_TBS_TYPE';
```

Thay đổi loại mặc định tại PDB:

```
ALTER PLUGGABLE DATABASE SET DEFAULT BIGFILE TABLESPACE;
```

Hoặc:

```
ALTER PLUGGABLE DATABASE SET DEFAULT SMALLFILE TABLESPACE;
```

Kiểm tra lại:

```
SELECT PROPERTY_NAME, PROPERTY_VALUE
FROM DATABASE_PROPERTIES
WHERE PROPERTY_NAME = 'DEFAULT_TBS_TYPE';
```

Thay đổi này chỉ điều chỉnh mặc định cho các tablespace được tạo sau đó; không chuyển các tablespace hiện có từ smallfile sang bigfile hoặc ngược lại.

### 4.4. `DEFAULT_EDITION`

**Ý nghĩa:** Edition mặc định của PDB, liên quan đến Edition-Based Redefinition (EBR).

Kiểm tra:

```
SELECT PROPERTY_NAME, PROPERTY_VALUE, DESCRIPTION
FROM DATABASE_PROPERTIES
WHERE PROPERTY_NAME = 'DEFAULT_EDITION';
```

Xem các edition:

```
SELECT EDITION_NAME
FROM DBA_EDITIONS
ORDER BY EDITION_NAME;
```

Nếu PDB sử dụng EBR, có thể đặt edition mặc định theo cú pháp được hỗ trợ:

```
ALTER PLUGGABLE DATABASE
DEFAULT EDITION = edition_name;
```

Thay `edition_name` bằng edition thực tế đã tồn tại.

Nếu ứng dụng không sử dụng EBR, thường không cần thay đổi thuộc tính này.

### 4.5. `LOCAL_UNDO_ENABLED`

**Ý nghĩa:** Cho biết chế độ local undo của CDB. Đây là thuộc tính liên quan đến kiến trúc undo trong môi trường multitenant, không phải một giá trị nên tùy ý thay đổi riêng cho từng PDB.

Xem:

```
SELECT PROPERTY_NAME, PROPERTY_VALUE, DESCRIPTION
FROM DATABASE_PROPERTIES
WHERE PROPERTY_NAME = 'LOCAL_UNDO_ENABLED';
```

Nếu cần thay đổi chế độ undo, phải thực hiện theo quy trình chuyển đổi được Oracle hỗ trợ ở cấp CDB. Không sửa trực tiếp thuộc tính trong dictionary và không coi đây là một thao tác `ALTER` thông thường ở cấp PDB.


### 4.7. GLOBAL_DB_NAME
Ý nghĩa: Tên toàn cục của database/container hiện tại (DB_NAME.DB_DOMAIN), quyết định việc phân giải kết nối và bắt buộc phải khớp khi cấu hình Database Link nếu tham số GLOBAL_NAMES = TRUE.

Xem giá trị:

```SQL
SELECT PROPERTY_NAME,
       PROPERTY_VALUE,
       DESCRIPTION
FROM DATABASE_PROPERTIES
WHERE PROPERTY_NAME = 'GLOBAL_DB_NAME';
```

Thay đổi trong PDB hoặc CDB:

```SQL
ALTER DATABASE RENAME GLOBAL_NAME TO pdb1.lab.internal;
```

Kiểm tra lại:

```SQL
SELECT * FROM GLOBAL_NAME;
```

Lưu ý: Thao tác đổi tên toàn cục có thể ảnh hưởng trực tiếp đến các Database Link đang kết nối tới container này và các chuỗi kết nối TNS client phụ thuộc vào GLOBAL_NAME.

### 4.8. NLS_CHARACTERSET & NLS_NCHAR_CHARACTERSET

Ý nghĩa: Xác định bộ mã ký tự lưu trữ dữ liệu của database/PDB.

NLS_CHARACTERSET: Bộ mã cho các kiểu dữ liệu CHAR, VARCHAR2, CLOB (thường là AL32UTF8).

NLS_NCHAR_CHARACTERSET: Bộ mã quốc gia cho các kiểu NCHAR, NVARCHAR2, NCLOB (thường là AL16UTF16).

Xem giá trị:

```SQL
SELECT PROPERTY_NAME,
       PROPERTY_VALUE,
       DESCRIPTION
FROM DATABASE_PROPERTIES
WHERE PROPERTY_NAME IN ('NLS_CHARACTERSET', 'NLS_NCHAR_CHARACTERSET');
```

Trong kiến trúc Multitenant, NLS_CHARACTERSET của PDB phải tương thích (thường là cùng bộ mã hoặc là tập con) với CDB$ROOT. 
Nếu CDB$ROOT là AL32UTF8, PDB có thể dùng các bảng mã khác, nhưng nếu CDB$ROOT không phải AL32UTF8, các PDB bị giới hạn khắt khe.


### 4.9. MAX_SIZE

Ý nghĩa: Giới hạn dung lượng lưu trữ tối đa (Storage Limit) mà một Pluggable Database (PDB) được phép sử dụng. Thuộc tính này giúp kiểm soát tài nguyên đĩa, ngăn chặn việc một PDB tăng trưởng mất kiểm soát làm cạn kiệt dung lượng dùng chung của toàn bộ CDB hoặc ASM diskgroup.

Xem giá trị:

```SQL
SELECT PROPERTY_NAME,
       PROPERTY_VALUE,
       DESCRIPTION
FROM DATABASE_PROPERTIES
WHERE PROPERTY_NAME = 'MAX_SIZE';
```

Thay đổi giới hạn dung lượng trong PDB:

```SQL
-- Đặt hạn mức lưu trữ tối đa (ví dụ: 50GB)
ALTER PLUGGABLE DATABASE STORAGE (MAXSIZE 50G);

-- Hoặc bỏ giới hạn dung lượng (không giới hạn)
ALTER PLUGGABLE DATABASE STORAGE (MAXSIZE UNLIMITED);
```

Kiểm tra lại:

```SQL
SELECT PROPERTY_NAME, 
       PROPERTY_VALUE 
FROM DATABASE_PROPERTIES 
WHERE PROPERTY_NAME = 'MAX_SIZE';
```

Lưu ý:

- Giá trị lưu trữ trong DATABASE_PROPERTIES thường được hiển thị theo đơn vị byte hoặc chuỗi giá trị cấu hình tương ứng.
- Dung lượng tính vào MAX_SIZE bao gồm tổng kích thước của tất cả các datafiles thuộc tablespace dữ liệu của PDB.
- Khi PDB chạm ngưỡng MAX_SIZE, các thao tác cấp phát mở rộng datafile (autoextend) hoặc tạo thêm tablespace mới sẽ bị chặn và trả về lỗi ORA-65114: space usage in container X exceeds MAXSIZE limit.
- Có thể giám sát thuộc tính này cùng với MAX_SHARED_TEMP_SIZE (giới hạn temp tablespace dùng chung) qua view CDB_PROPERTIES khi đứng từ CDB$ROOT.

### 4.10. Các thuộc tính khác

Không nên mặc định mọi hệ thống đều có cùng một danh sách properties.

Để xem tên, giá trị và mô tả chính xác của môi trường hiện tại:

```
SELECT PROPERTY_NAME,
       PROPERTY_VALUE,
       DESCRIPTION
FROM DATABASE_PROPERTIES
ORDER BY PROPERTY_NAME;
```

Đối với mỗi thuộc tính, cần đọc `DESCRIPTION` và kiểm tra tài liệu Oracle tương ứng trước khi tìm cách thay đổi.

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

