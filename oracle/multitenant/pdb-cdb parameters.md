# Oracle Database 19c — Initialization Parameters của CDB và PDB

Một điểm quan trọng cần phân biệt ngay từ đầu:

- CDB parameters: các tham số khởi tạo của Oracle instance, thường được quản lý ở cấp CDB/instance.
- PDB parameters: các tham số mà Oracle cho phép đặt giá trị riêng cho từng PDB, gọi là PDB-modifiable parameters.
- Không phải mọi tham số của CDB đều có thể cấu hình riêng cho PDB.
- `DATABASE_PROPERTIES`, `CDB_PROPERTIES` và `V$PARAMETER` là các view phục vụ những mục đích khác nhau; 
không thể dùng chúng thay thế cho nhau.

## 1. Khái niệm Initialization Parameters

Trong Oracle Database, **Initialization Parameters** là các tham số điều khiển cách Oracle instance khởi động, 
sử dụng bộ nhớ, quản lý session, xử lý SQL, ghi redo, quản lý tiến trình và nhiều hoạt động khác.

Ví dụ:

| Parameter              | Vai trò                                             |
| ---------------------- | --------------------------------------------------- |
| `DB_NAME`              | Tên database                                        |
| `DB_UNIQUE_NAME`       | Tên định danh duy nhất của database                 |
| `OPEN_CURSORS`         | Số cursor tối đa mà một session có thể mở đồng thời |
| `PROCESSES`            | Giới hạn tiến trình Oracle                          |
| `SESSIONS`             | Giới hạn session                                    |
| `SGA_TARGET`           | Mục tiêu bộ nhớ SGA                                 |
| `PGA_AGGREGATE_TARGET` | Mục tiêu bộ nhớ PGA                                 |
| `UNDO_RETENTION`       | Mục tiêu thời gian giữ thông tin undo               |
| `COMPATIBLE`           | Mức tương thích của database với phiên bản Oracle   |
| `MAX_PDB_STORAGE`      | Giới hạn dung lượng lưu trữ của PDB                 |

Lưu ý: `MAX_PDB_STORAGE` liên quan đến giới hạn dung lượng PDB và không nên nhầm với các initialization parameters thông thường. Muốn kiểm tra giá trị giới hạn này, cần xem đúng cơ chế cấu hình và view dành cho PDB.

### 1.1. Parameter khác Property như thế nào?

Oracle có nhiều loại thông tin cấu hình khác nhau.

| Loại                             | View hoặc cơ chế                                         | Ví dụ                              |
| -------------------------------- | -------------------------------------------------------- | ---------------------------------- |
| Initialization parameters        | `V$PARAMETER`, `V$SYSTEM_PARAMETER`                      | `OPEN_CURSORS`, `SGA_TARGET`       |
| Parameters được lưu trong SPFILE | `V$SPPARAMETER`                                          | Giá trị cấu hình cho lần khởi động |
| Database properties              | `DATABASE_PROPERTIES`                                    | `NLS_CHARACTERSET`, `NLS_LANGUAGE` |
| PDB properties                   | `CDB_PROPERTIES` hoặc `DATABASE_PROPERTIES`, tùy phạm vi | Thuộc tính của container           |
| PDB storage limit                | Thuộc tính PDB và `ALTER PLUGGABLE DATABASE`             | `MAX_PDB_STORAGE`                  |

Không nên sử dụng `DATABASE_PROPERTIES` để liệt kê tất cả initialization parameters.

### 1.2. CDB và PDB liên quan đến Parameters ra sao?

Một CDB có thể chứa nhiều PDB:

```
Oracle Instance
    |
    +-- CDB$ROOT
    |      |
    |      +-- CDB-level initialization parameters
    |
    +-- PDB$SEED
    |
    +-- PROD_PDB
    |
    +-- TEST_PDB
```

Oracle sử dụng mô hình kế thừa parameters: PDB nhận giá trị từ root đối với các tham số có cơ chế kế thừa. Một số tham số cho phép PDB đặt giá trị riêng, nhưng không phải tất cả.

Nguồn: Oracle Database 19c, *Administering a CDB*.

---

## 2. Phân biệt CDB Parameters và PDB Parameters

### 2.1. CDB Parameters

Là các tham số được quản lý ở cấp Oracle instance hoặc CDB.

Ví dụ:

```
SHOW PARAMETER db_name;
SHOW PARAMETER compatible;
SHOW PARAMETER sga_target;
SHOW PARAMETER processes;
```

Những tham số này ảnh hưởng đến instance và có thể có phạm vi tác động rộng hơn một PDB.

Ví dụ `SGA_TARGET` liên quan đến bộ nhớ SGA của instance. Không thể đặt mỗi PDB một SGA riêng bằng cách thay đổi 
tham số này trong PDB.

### 2.2. PDB Parameters

Là các tham số mà Oracle cho phép cấu hình riêng cho một PDB.

Ví dụ:

```
ALTER SESSION SET CONTAINER = PROD_PDB;

SHOW PARAMETER open_cursors;
```

Nếu `OPEN_CURSORS` được phép thay đổi ở cấp PDB, DBA có thể đặt giá trị riêng cho `PROD_PDB` mà không cần thay đổi giá trị của các PDB khác.

### 2.3. Bảng so sánh

| Đặc điểm         | CDB/Instance                                | PDB                                                           |
| ---------------- | ------------------------------------------- | ------------------------------------------------------------- |
| Phạm vi          | Instance hoặc CDB                           | Một PDB đối với tham số được phép override                    |
| Bộ nhớ SGA       | Quản lý ở cấp instance                      | Không có SGA riêng cho từng PDB                               |
| Giá trị mặc định | Giá trị hiệu lực ở root/instance            | Thường kế thừa root                                           |
| Override giá trị | Không phải mọi tham số đều có phạm vi riêng | Chỉ áp dụng khi tham số cho phép sửa đổi ở PDB                |
| Lưu cấu hình     | SPFILE hoặc PFILE                           | Giá trị override có thể được lưu trong SPFILE                 |
| Kiểm tra         | `V$SYSTEM_PARAMETER`, `V$SPPARAMETER`       | Kiểm tra trong container hoặc qua view có thông tin container |
| Thay đổi         | `ALTER SYSTEM`                              | `ALTER SYSTEM` khi đang ở PDB, nếu được hỗ trợ                |

---

## 3. Các view dùng để kiểm tra Parameters

Đây là phần quan trọng nhất khi quản trị Oracle.

### 3.1. `V$PARAMETER`

Hiển thị các initialization parameters có hiệu lực đối với session hiện tại.

```
SELECT name,
       value,
       display_value,
       isdefault,
       issys_modifiable,
       ispdb_modifiable
FROM   v$parameter
ORDER BY name;
```

Một số cột quan trọng:

- `NAME`: tên parameter.
- `VALUE`: giá trị hiệu lực.
- `DISPLAY_VALUE`: giá trị ở dạng hiển thị.
- `ISDEFAULT`: giá trị có phải mặc định hay không.
- `ISSYS_MODIFIABLE`: có thể thay đổi bằng `ALTER SYSTEM` hay không.
- `ISPDB_MODIFIABLE`: có thể thay đổi trong PDB hay không.

Để tìm một parameter cụ thể:

```
SELECT name,
       value,
       display_value,
       issys_modifiable,
       ispdb_modifiable
FROM   v$parameter
WHERE  name = 'open_cursors';
```

### 3.2. `V$SYSTEM_PARAMETER`

Hiển thị các giá trị parameter ở cấp system/instance, không phải chỉ riêng session.

```
SELECT name,
       value,
       display_value,
       issys_modifiable,
       ispdb_modifiable
FROM   v$system_parameter
ORDER BY name;
```

Dùng view này khi cần kiểm tra cấu hình có hiệu lực ở cấp hệ thống.

### 3.3. `V$SPPARAMETER`

Hiển thị thông tin parameter được lưu trong SPFILE.

```
SELECT name,
       value,
       isspecified,
       ordinal,
       update_comment
FROM   v$spparameter
WHERE  name IS NOT NULL
ORDER BY name, ordinal;
```

Ý nghĩa:

- `NAME`: tên parameter.
- `VALUE`: giá trị được lưu.
- `ISSPECIFIED`: parameter có được chỉ định trong SPFILE hay không.
- `ORDINAL`: thứ tự của giá trị đối với parameter dạng danh sách.
- `UPDATE_COMMENT`: ghi chú thay đổi nếu có.

**Điểm cần nhớ:** giá trị trong SPFILE và giá trị đang có hiệu lực trong bộ nhớ có thể khác nhau.

### 3.4. `V$PARAMETER2` và `V$SYSTEM_PARAMETER2`

Hai view này hữu ích đối với parameters có nhiều giá trị, chẳng hạn các danh sách đường dẫn.

```
SELECT name,
       ordinal,
       value
FROM   v$parameter2
WHERE  name = 'control_files'
ORDER BY ordinal;
```

`V$PARAMETER2` tách các giá trị trong danh sách thành nhiều dòng, giúp việc đọc dễ dàng hơn.

### 3.5. `SHOW PARAMETER`

Đây là lệnh SQLPlus, không phải câu SQL thông thường.

```
SHOW PARAMETER;
SHOW PARAMETER open_cursors;
SHOW PARAMETER processes;
SHOW PARAMETER sga_target;
```

Tìm theo một phần tên:

```
SHOW PARAMETER undo;
SHOW PARAMETER cursor;
SHOW PARAMETER pdb;
```

`SHOW PARAMETER` rất tiện khi kiểm tra nhanh. Tuy nhiên, khi cần lọc, sắp xếp hoặc xuất báo cáo, nên dùng các view `V$...`.

---

## 4. Giải thích các thuộc tính của Parameter

Ví dụ truy vấn:

```
SELECT name,
       value,
       default_value,
       issys_modifiable,
       ispdb_modifiable,
       isdefault,
       ismodified,
       isadjusted,
       isdeprecated
FROM   v$parameter
WHERE  name IN (
    'open_cursors',
    'processes',
    'sessions',
    'undo_retention',
    'compatible'
)
ORDER BY name;
```

### 4.1. `ISSYS_MODIFIABLE`

Cho biết cách parameter có thể được thay đổi bằng `ALTER SYSTEM`.

| Giá trị     | Ý nghĩa                                                            |
| ----------- | ------------------------------------------------------------------ |
| `IMMEDIATE` | Thay đổi có hiệu lực ngay                                          |
| `DEFERRED`  | Áp dụng cho các session mới                                        |
| `FALSE`     | Không thể thay đổi động bằng `ALTER SYSTEM` theo cách thông thường |

Nếu là `FALSE`, việc thay đổi parameter thường cần được lưu vào SPFILE và có hiệu lực khi instance khởi động lại.

### 4.2. `ISPDB_MODIFIABLE`

Cho biết parameter có thể được sửa đổi ở cấp PDB hay không.

| Giá trị | Ý nghĩa                                                            |
| ------- | ------------------------------------------------------------------ |
| `TRUE`  | Parameter có thể được thay đổi trong PDB, theo các quy tắc áp dụng |
| `FALSE` | Không thể đặt giá trị riêng bằng cơ chế parameter của PDB          |

Đây là cột quan trọng nhất khi quyết định có nên thực hiện `ALTER SYSTEM SET` trong một PDB hay không.

### 4.3. `ISDEFAULT`

- `TRUE`: giá trị đang dùng là giá trị mặc định.
- `FALSE`: giá trị khác mặc định.

Cột này không tự cho biết giá trị được kế thừa từ root hay được override ở PDB.

### 4.4. `ISMODIFIED`

Cho biết parameter đã được sửa đổi như thế nào sau khi instance khởi động.

Các giá trị thường gặp:

- `FALSE`: chưa có thay đổi được ghi nhận sau khi khởi động.
- `SYSTEM_MOD`: đã được thay đổi bằng `ALTER SYSTEM`.
- `MODIFIED`: đã được thay đổi bằng `ALTER SESSION`.

Cách diễn giải cần dựa vào loại parameter và ngữ cảnh truy vấn.

### 4.5. `ISADJUSTED`

Cho biết Oracle có điều chỉnh giá trị đã nhập thành giá trị khác phù hợp hơn hay không.

### 4.6. `ISDEPRECATED`

Cho biết parameter đã bị đánh dấu deprecated hay chưa.

Không nên tiếp tục sử dụng parameter deprecated cho cấu hình mới nếu Oracle đã cung cấp phương án thay thế.

### 4.7. `DEFAULT_VALUE`

Giá trị mặc định do Oracle xác định cho parameter. Giá trị mặc định có thể phụ thuộc phiên bản, nền tảng và các điều kiện cấu hình.

Không nên coi giá trị mặc định trong tài liệu của một phiên bản khác là chính xác cho môi trường hiện tại.

---

## 5. Phân loại Parameters theo phạm vi

### 5.1. Parameters chỉ áp dụng ở cấp instance

Một số ví dụ thường gặp:

| Parameter           | Vai trò                      | Lưu ý                                                      |
| ------------------- | ---------------------------- | ---------------------------------------------------------- |
| `SGA_TARGET`        | Mục tiêu bộ nhớ SGA          | Phạm vi instance                                           |
| `SGA_MAX_SIZE`      | Giới hạn tối đa của SGA      | Liên quan khởi động và thay đổi bộ nhớ                     |
| `MEMORY_TARGET`     | Quản lý bộ nhớ tự động       | Phụ thuộc nền tảng và cấu hình                             |
| `MEMORY_MAX_TARGET` | Giới hạn bộ nhớ tự động      | Có thể cần restart khi thay đổi                            |
| `CONTROL_FILES`     | Đường dẫn control files      | Tham số cấu hình database/instance                         |
| `DB_NAME`           | Tên database                 | Không phải tham số để đặt tên riêng cho từng PDB           |
| `COMPATIBLE`        | Mức tương thích của database | Thay đổi có thể ảnh hưởng khả năng tương thích và nâng cấp |

### 5.2. Parameters có thể cấu hình riêng cho PDB

Một số ví dụ phổ biến cần kiểm tra trên đúng phiên bản và môi trường:

| Parameter                | Vai trò                                                                       |
| ------------------------ | ----------------------------------------------------------------------------- |
| `OPEN_CURSORS`           | Giới hạn cursor của một session                                               |
| `SESSION_CACHED_CURSORS` | Số cursor được cache trong session                                            |
| `UNDO_RETENTION`         | Mục tiêu giữ undo                                                             |
| `OPTIMIZER_MODE`         | Chế độ tối ưu hóa SQL                                                         |
| `NLS_DATE_FORMAT`        | Định dạng ngày mặc định trong session/database context theo phạm vi parameter |
| `NLS_TIMESTAMP_FORMAT`   | Định dạng timestamp mặc định                                                  |

Không nên suy luận rằng tất cả các parameter trong bảng trên đều có cùng hành vi hoặc cùng khả năng thay đổi động. Hãy kiểm tra `ISPDB_MODIFIABLE` và `ISSYS_MODIFIABLE` trên hệ thống thực tế.

### 5.3. Vì sao không thể liệt kê tất cả Parameters chỉ bằng một bảng ngắn?

Oracle có rất nhiều initialization parameters. Một số được sử dụng trong cấu hình bộ nhớ, optimizer, RAC, Data Guard, auditing, networking và các tính năng chuyên biệt.

Danh sách hỗ trợ có thể thay đổi theo phiên bản Oracle và các tùy chọn cài đặt.

Cách đúng để xác định parameter có thể đặt ở PDB là truy vấn metadata của Oracle, sau đó đối chiếu tài liệu Oracle Database Reference đúng phiên bản.


## 6. Các Parameters quan trọng ở cấp CDB

Phần này giải thích các parameter DBA thường kiểm tra khi cài đặt, vận hành và xử lý sự cố Oracle Database 19c.

### 6.1. `DB_NAME`

Tên database.

```
SHOW PARAMETER db_name;
```

Ví dụ:

```
NAME     TYPE    VALUE
-------- ------- --------
db_name  string  orclcdb
```

`DB_NAME` không phải tên PDB. Một CDB có thể có nhiều PDB nhưng không vì thế mà mỗi PDB có một `DB_NAME` riêng.

### 6.2. `DB_UNIQUE_NAME`

Tên định danh duy nhất của database, đặc biệt quan trọng khi quản lý Data Guard.

```
SHOW PARAMETER db_unique_name;
```

Không nhầm `DB_UNIQUE_NAME` với tên service dùng cho kết nối ứng dụng.

### 6.3. `COMPATIBLE`

Xem giá trị:

```
SHOW PARAMETER compatible;
```

Parameter này kiểm soát mức tương thích định dạng và tính năng của database với phiên bản Oracle.

Không nên thay đổi tùy tiện. Việc nâng giá trị `COMPATIBLE` có thể ảnh hưởng khả năng quay lại phiên bản cũ và cần được thực hiện theo kế hoạch nâng cấp được Oracle hỗ trợ.

### 6.4. `PROCESSES`

Giới hạn số tiến trình của Oracle instance.

```
SHOW PARAMETER processes;
```

Kiểm tra thêm số tiến trình hiện tại:

```
SELECT COUNT(*) AS current_processes
FROM   v$process;
```

Không nên tăng `PROCESSES` chỉ vì thấy số lượng session lớn. Cần kiểm tra cả tiến trình, session, mức sử dụng tài nguyên và cấu hình ứng dụng.

### 6.5. `SESSIONS`

Giới hạn session theo cấu hình Oracle.

```
SHOW PARAMETER sessions;
```

Kiểm tra số session hiện tại:

```
SELECT COUNT(*) AS current_sessions
FROM   v$session;
```

`SESSIONS` có thể được Oracle tính toán từ các parameter khác nếu không được chỉ định trực tiếp. Không nên mặc định rằng `SESSIONS` luôn bằng `PROCESSES`.

### 6.6. `SGA_TARGET`

Mục tiêu tổng bộ nhớ SGA của instance khi sử dụng Automatic Shared Memory Management.

```
SHOW PARAMETER sga_target;
SHOW PARAMETER sga_max_size;
```

Kiểm tra cấu hình và sử dụng bộ nhớ:

```
SELECT component,
       current_size,
       min_size,
       max_size
FROM   v$sga_dynamic_components
ORDER BY component;
```

Không cấu hình `SGA_TARGET` riêng trong PDB như thể mỗi PDB là một instance độc lập.

### 6.7. `PGA_AGGREGATE_TARGET`

Mục tiêu bộ nhớ PGA dành cho các hoạt động xử lý của tiến trình Oracle.

```
SHOW PARAMETER pga_aggregate_target;
SHOW PARAMETER pga_aggregate_limit;
```

Hai parameter này có vai trò khác nhau:

- `PGA_AGGREGATE_TARGET`: mục tiêu quản lý PGA.
- `PGA_AGGREGATE_LIMIT`: giới hạn sử dụng PGA theo cơ chế Oracle.

Việc thay đổi cần căn cứ vào tải thực tế, không chỉ dựa vào tổng RAM máy chủ.

### 6.8. `UNDO_RETENTION`

Mục tiêu thời gian giữ thông tin undo.

```
SHOW PARAMETER undo_retention;
```

`UNDO_RETENTION` không phải cam kết rằng mọi undo sẽ luôn được giữ đủ thời gian đó. Kết quả còn phụ thuộc cấu hình undo tablespace, dung lượng, tải và các cơ chế quản lý undo của Oracle.

### 6.9. `OPEN_CURSORS`

Giới hạn số cursor có thể mở đồng thời trong một session.

```
SHOW PARAMETER open_cursors;
```

Parameter này là ví dụ hữu ích khi tìm hiểu cơ chế PDB override. Trước khi thay đổi, hãy kiểm tra:

```
SELECT name,
       value,
       issys_modifiable,
       ispdb_modifiable
FROM   v$parameter
WHERE  name = 'open_cursors';
```

### 6.10. `CONTROL_FILES`

Đường dẫn đến các control files mà Oracle sử dụng.

```
SHOW PARAMETER control_files;
```

Có thể xem đầy đủ từng giá trị bằng:

```
SELECT name,
       ordinal,
       value
FROM   v$parameter2
WHERE  name = 'control_files'
ORDER BY ordinal;
```

Không thay đổi `CONTROL_FILES` như một thao tác thử nghiệm thông thường. Cấu hình sai có thể khiến database không khởi động được.

---

## 7. Các Parameters có thể cấu hình ở cấp PDB

### 7.1. Kiểm tra parameter có cho phép PDB override không

Ví dụ:

```
SELECT name,
       value,
       default_value,
       issys_modifiable,
       ispdb_modifiable,
       isdefault
FROM   v$parameter
WHERE  name IN (
    'open_cursors',
    'session_cached_cursors',
    'undo_retention',
    'optimizer_mode'
)
ORDER BY name;
```

Nếu `ISPDB_MODIFIABLE = TRUE`, parameter có thể được thay đổi ở cấp PDB theo quy tắc Oracle quy định.

### 7.2. `OPEN_CURSORS`

Ví dụ, DBA muốn đặt `OPEN_CURSORS = 500` cho riêng `PROD_PDB`.

Trước tiên:

```
SHOW CON_NAME;
```

Chuyển vào PDB:

```
ALTER SESSION SET CONTAINER = PROD_PDB;
```

Kiểm tra giá trị hiện tại:

```
SHOW PARAMETER open_cursors;
```

Sau khi xác nhận parameter cho phép PDB override và giá trị `500` phù hợp với ứng dụng, mới thực hiện thay đổi:

```
ALTER SYSTEM SET open_cursors = 500
SCOPE = BOTH;
```

Kiểm tra lại:

```
SELECT name,
       value,
       ispdb_modifiable
FROM   v$parameter
WHERE  name = 'open_cursors';
```

### 7.3. `SESSION_CACHED_CURSORS`

Parameter này điều khiển số cursor mà một session có thể cache để tái sử dụng.

```
SHOW PARAMETER session_cached_cursors;
```

Kiểm tra khả năng thay đổi tại PDB:

```
SELECT name,
       value,
       issys_modifiable,
       ispdb_modifiable
FROM   v$parameter
WHERE  name = 'session_cached_cursors';
```

Chỉ thay đổi sau khi xác minh khả năng sửa đổi và đánh giá workload ứng dụng.

### 7.4. `OPTIMIZER_MODE`

Parameter liên quan đến chế độ tối ưu hóa SQL.

```
SHOW PARAMETER optimizer_mode;
```

Kiểm tra metadata:

```
SELECT name,
       value,
       issys_modifiable,
       ispdb_modifiable
FROM   v$parameter
WHERE  name = 'optimizer_mode';
```

Không thay đổi parameter này trên production chỉ để thử nghiệm. Kết quả thực thi SQL còn phụ thuộc optimizer statistics, execution plan, bind variables và nhiều yếu tố khác.

### 7.5. Phân biệt initialization parameters với session settings

Một số thiết lập thường gặp như định dạng ngày tháng có thể được thay đổi cho session:

```
ALTER SESSION SET NLS_DATE_FORMAT = 'YYYY-MM-DD';
```

Lệnh này thay đổi cách session hiện tại diễn giải hoặc hiển thị giá trị ngày theo thiết lập tương ứng; nó không đồng nghĩa với việc sửa vĩnh viễn initialization parameter của PDB.

Muốn biết một tên xuất hiện trong `SHOW PARAMETER` có phải initialization parameter hay không, hãy kiểm tra metadata từ `V$PARAMETER` và tài liệu Oracle.

---

## 8. Cách thay đổi Parameters

Trước khi chạy `ALTER SYSTEM`, cần xác định:

1. Đang ở `CDB$ROOT` hay PDB nào.
2. Parameter có hỗ trợ thay đổi động hay không.
3. Parameter có cho phép sửa đổi ở PDB không.
4. Thay đổi chỉ cần có hiệu lực trong bộ nhớ hay cần lưu bền vững.
5. Có cần restart instance hoặc đóng/mở PDB để thay đổi có hiệu lực không.

### 8.1. Các giá trị `SCOPE`

| SCOPE    | Ý nghĩa                                                                                                             |
| -------- | ------------------------------------------------------------------------------------------------------------------- |
| `MEMORY` | Thay đổi giá trị trong bộ nhớ; không lưu thay đổi vào SPFILE                                                        |
| `SPFILE` | Lưu thay đổi vào SPFILE; thường có hiệu lực khi khởi động lại hoặc khi điều kiện áp dụng của parameter được đáp ứng |
| `BOTH`   | Thay đổi trong bộ nhớ và lưu vào SPFILE                                                                             |

Khả năng sử dụng từng `SCOPE` phụ thuộc loại parameter, trạng thái instance và ngữ cảnh CDB/PDB.

### 8.2. Thay đổi parameter ở CDB Root

Ví dụ thay đổi `OPEN_CURSORS` cho root và các PDB vẫn kế thừa giá trị này:

```
SHOW CON_NAME;

ALTER SYSTEM SET open_cursors = 300
SCOPE = BOTH
CONTAINER = CURRENT;
```

Khi chạy tại `CDB$ROOT`, `CONTAINER = CURRENT` áp dụng cho root và các PDB đang kế thừa giá trị tương ứng. PDB đã override có thể tiếp tục giữ giá trị riêng.

### 8.3. Thay đổi parameter cho tất cả container

Ví dụ:

```
ALTER SYSTEM SET open_cursors = 300
SCOPE = BOTH
CONTAINER = ALL;
```

`CONTAINER = ALL` yêu cầu áp dụng giá trị cho tất cả container, bao gồm root và các PDB, đồng thời đặt lại trạng thái kế thừa của các PDB đối với parameter đó.

**Không chạy ví dụ này trên production nếu chưa xác nhận giá trị mong muốn cho toàn bộ PDB.**

### 8.4. Thay đổi parameter trong một PDB

Ví dụ:

```
ALTER SESSION SET CONTAINER = PROD_PDB;

ALTER SYSTEM SET open_cursors = 500
SCOPE = BOTH;
```

Chỉ thực hiện nếu parameter cho phép sửa đổi ở PDB và `SCOPE` được hỗ trợ cho thao tác đó.

### 8.5. Những trường hợp cần restart

Nếu parameter có:

```
ISSYS_MODIFIABLE = FALSE
```

thì không thể thay đổi nó động bằng `ALTER SYSTEM` theo cách thông thường.

Có thể cần lưu cấu hình vào SPFILE:

```
ALTER SYSTEM SET some_parameter = 'some_value'
SCOPE = SPFILE;
```

Đây là cú pháp minh họa. Thay `some_parameter` và `some_value` bằng tên cùng giá trị hợp lệ của parameter thực tế.

Không nên restart chỉ dựa vào việc thay đổi một giá trị. Cần xác định rõ parameter nào cần restart, phạm vi ảnh hưởng và kế hoạch khôi phục.

---

## 9. Inheritance và Override giữa CDB và PDB

Oracle sử dụng cơ chế kế thừa giá trị parameter từ root.

Giả sử cấu hình:

```
CDB$ROOT
    OPEN_CURSORS = 300

PROD_PDB
    OPEN_CURSORS = 500

TEST_PDB
    OPEN_CURSORS = kế thừa từ root
```

Khi đó:

| Container  | Giá trị hiệu lực |
| ---------- | ---------------- |
| `CDB$ROOT` | 300              |
| `PROD_PDB` | 500              |
| `TEST_PDB` | 300              |

Đây là ví dụ minh họa cơ chế, không phải giá trị mặc định của Oracle.

Nếu DBA thay đổi root:

```
ALTER SYSTEM SET open_cursors = 400
SCOPE = BOTH
CONTAINER = CURRENT;
```

thì root có giá trị mới là `400`. `TEST_PDB` đang kế thừa sẽ nhận giá trị root mới theo cơ chế áp dụng; `PROD_PDB` có thể tiếp tục giữ override `500`.

### 9.1. Tại sao phải quan tâm đến inheritance?

Nếu không theo dõi trạng thái kế thừa, DBA có thể gặp tình huống:

- Thay đổi parameter ở root nhưng một PDB không nhận giá trị mới.
- Các PDB có cấu hình không đồng nhất.
- Giá trị trong bộ nhớ khác với giá trị được lưu trong SPFILE.
- Sau khi đóng/mở PDB, giá trị hiệu lực khác với điều DBA dự đoán.

Vì vậy, hãy kiểm tra parameter ở cả root và PDB trước khi thay đổi.



## 10. Kiểm tra Parameters trong tất cả PDB

### 10.1. Xem danh sách PDB

Tại `CDB$ROOT`:

```
SHOW CON_NAME;

SELECT con_id,
       name,
       open_mode
FROM   v$pdbs
ORDER BY con_id;
```

### 10.2. Kiểm tra parameter tại từng container

Để kiểm tra chính xác giá trị đang có hiệu lực trong một PDB, chuyển vào PDB đó:

```
ALTER SESSION SET CONTAINER = PROD_PDB;

SELECT name,
       value,
       issys_modifiable,
       ispdb_modifiable,
       isdefault
FROM   v$parameter
WHERE  name IN (
    'open_cursors',
    'session_cached_cursors',
    'undo_retention',
    'optimizer_mode'
)
ORDER BY name;
```

Thực hiện tương tự với `TEST_PDB`:

```
ALTER SESSION SET CONTAINER = TEST_PDB;

SELECT name,
       value,
       ispdb_modifiable,
       isdefault
FROM   v$parameter
WHERE  name IN (
    'open_cursors',
    'session_cached_cursors',
    'undo_retention',
    'optimizer_mode'
)
ORDER BY name;
```

Điều này giúp so sánh giá trị hiệu lực của từng PDB.

### 10.3. Kiểm tra tham số có thông tin container

Một số view động trong môi trường CDB có cột `CON_ID`. Bạn có thể dùng nó để phân biệt thông tin toàn CDB, root và PDB khi view đó cung cấp các dòng tương ứng.

Ví dụ kiểm tra:

```
DESC V$SYSTEM_PARAMETER;
```

Nếu view có cột `CON_ID`, có thể truy vấn:

```
SELECT con_id,
       name,
       value,
       ispdb_modifiable
FROM   v$system_parameter
WHERE  name = 'open_cursors'
ORDER BY con_id;
```

Không nên giả định mọi view động đều trả về đầy đủ giá trị của tất cả PDB. Khi cần xác minh một PDB cụ thể, truy vấn trực tiếp bên trong PDB vẫn là cách kiểm tra rõ ràng.

---

## 11. Reset Parameters về giá trị kế thừa

Giả sử `PROD_PDB` đang override `OPEN_CURSORS`:

```
CDB$ROOT : OPEN_CURSORS = 300
PROD_PDB : OPEN_CURSORS = 500
```

Nếu muốn `PROD_PDB` quay lại kế thừa giá trị từ root, cần reset override trong PDB.

Trước tiên, chuyển vào đúng PDB:

```
ALTER SESSION SET CONTAINER = PROD_PDB;
```

Sau đó:

```
ALTER SYSTEM RESET open_cursors
SCOPE = SPFILE;
```

Đây là ví dụ theo cơ chế reset PDB parameter được lưu trong SPFILE. Hãy xác nhận trạng thái parameter và khả năng áp dụng trên đúng phiên bản trước khi thực hiện.

Sau khi reset, giá trị riêng được lưu cho PDB sẽ được loại bỏ theo cơ chế Oracle. Việc giá trị hiệu lực thay đổi ngay hay sau khi đóng/mở PDB phụ thuộc phạm vi thay đổi và trạng thái cấu hình.

**Không sử dụng `RESET` như một lệnh khôi phục chung cho mọi loại parameter.** Một số tham số có quy tắc riêng hoặc không cho phép override ở PDB.

---

## 12. Kiểm tra SPFILE và PFILE

### 12.1. Kiểm tra Oracle có sử dụng SPFILE không

```
SHOW PARAMETER spfile;
```

Nếu `VALUE` có đường dẫn SPFILE, instance đang sử dụng file đó.

Nếu giá trị trống, hãy kiểm tra khả năng instance được khởi động từ PFILE.

### 12.2. Xem các giá trị trong SPFILE

```
SELECT sid,
       name,
       value,
       isspecified,
       update_comment
FROM   v$spparameter
WHERE  name IS NOT NULL
ORDER BY sid, name;
```

Cột `SID` giúp nhận diện phạm vi cấu hình được ghi trong SPFILE. Trong môi trường có nhiều instance, không nên bỏ qua cột này khi kiểm tra cấu hình.

### 12.3. Tạo bản PFILE để kiểm tra

Có thể xuất cấu hình SPFILE thành PFILE:

```
CREATE PFILE = '/tmp/init_orclcdb_review.ora'
FROM SPFILE;
```

Đường dẫn trên chỉ là ví dụ cho hệ điều hành Linux/Unix. Hãy chọn thư mục mà tài khoản Oracle có quyền ghi và bảo đảm an toàn cho file chứa cấu hình.

PFILE được tạo để kiểm tra, không có nghĩa Oracle tự động chuyển sang sử dụng PFILE.

---

## 13. Quy trình DBA an toàn

Trước khi thay đổi parameter trên môi trường production, nên thực hiện quy trình sau.

### Bước 1 — Xác định container

```
SHOW CON_NAME;
```

### Bước 2 — Kiểm tra giá trị hiện tại

```
SHOW PARAMETER open_cursors;
```

### Bước 3 — Kiểm tra metadata

```
SELECT name,
       value,
       default_value,
       issys_modifiable,
       ispdb_modifiable,
       isdefault,
       ismodified
FROM   v$parameter
WHERE  name = 'open_cursors';
```

### Bước 4 — Kiểm tra cấu hình lưu trữ

```
SELECT sid,
       name,
       value,
       isspecified
FROM   v$spparameter
WHERE  name = 'open_cursors';
```

### Bước 5 — Xác định phạm vi thay đổi

- Chỉ session hiện tại?
- Toàn instance?
- Chỉ một PDB?
- Tất cả PDB?
- Thay đổi có cần restart không?

### Bước 6 — Xác minh khả năng sửa đổi

Không thay đổi nếu chưa hiểu `ISSYS_MODIFIABLE`, `ISPDB_MODIFIABLE` và các giới hạn được tài liệu Oracle quy định.

### Bước 7 — Thực hiện trong phạm vi nhỏ nhất

Nếu yêu cầu chỉ dành cho `PROD_PDB`, không nên thay đổi toàn bộ CDB.

### Bước 8 — Xác minh sau thay đổi

```
SHOW PARAMETER open_cursors;
```

Sau đó kiểm tra lại `V$PARAMETER` và `V$SPPARAMETER`, đồng thời xác nhận các PDB khác không bị ảnh hưởng ngoài dự kiến.

---

## 14. Tóm tắt

| Nhu cầu                          | Lệnh hoặc view                                     |
| -------------------------------- | -------------------------------------------------- |
| Xem parameter nhanh              | `SHOW PARAMETER`                                   |
| Xem parameter của session        | `V$PARAMETER`                                      |
| Xem giá trị ở cấp system         | `V$SYSTEM_PARAMETER`                               |
| Xem parameter trong SPFILE       | `V$SPPARAMETER`                                    |
| Xem parameter dạng danh sách     | `V$PARAMETER2`                                     |
| Kiểm tra có thể sửa đổi động     | `ISSYS_MODIFIABLE`                                 |
| Kiểm tra có thể override tại PDB | `ISPDB_MODIFIABLE`                                 |
| Xác định container hiện tại      | `SHOW CON_NAME`                                    |
| Chuyển sang PDB khác             | `ALTER SESSION SET CONTAINER`                      |
| Thay đổi parameter               | `ALTER SYSTEM SET`                                 |
| Xóa cấu hình override trong PDB  | `ALTER SYSTEM RESET`                               |
| Lưu cấu hình để áp dụng sau      | `SCOPE = SPFILE`                                   |
| Thay đổi bộ nhớ và lưu cấu hình  | `SCOPE = BOTH`, nếu được hỗ trợ                    |
| Kiểm tra tất cả PDB              | `V$PDBS` kết hợp kiểm tra parameter theo container |

### Tài liệu Oracle tham khảo

- Oracle Database 19c — [Reading the Parameter Descriptions](https://docs.oracle.com/en/database/oracle/oracle-database/19/refrn/reading-the-parameter-descriptions.html)
- Oracle Database 19c — [Administering a CDB with SQL\*Plus](https://docs.oracle.com/en/database/oracle/oracle-database/19/multi/administering-a-cdb-with-sql-plus.html)
- Oracle Database 19c — [Creating and Configuring a CDB](https://docs.oracle.com/en/database/oracle/oracle-database/19/multi/creating-and-configuring-a-cdb.html)
- Oracle Database 19c — [Creating and Configuring an Oracle Database](https://docs.oracle.com/en/database/oracle/oracle-database/19/admin/creating-and-configuring-an-oracle-database.html)

Tài liệu chính thức giải thích rõ các thuộc tính `MODIFIABLE`, `MODIFIABLE IN A PDB`, mô hình kế thừa và cách sử dụng `ALTER SYSTEM` trong CDB/PDB.

**Nguyên tắc quan trọng nhất:** trước khi thay đổi một parameter, hãy kiểm tra giá trị hiệu lực, trạng thái lưu trong SPFILE, phạm vi container và khả năng sửa đổi ở PDB. Không nên áp dụng cùng một lệnh cho tất cả parameters mà chưa kiểm tra tài liệu tương ứng.

Các phần về phạm vi sửa đổi, kế thừa và `ALTER SYSTEM` ở trên dựa trên tài liệu chính thức Oracle Database 19c
