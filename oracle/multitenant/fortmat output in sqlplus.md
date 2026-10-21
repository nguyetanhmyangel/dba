# Hướng dẫn định dạng kết quả trong SQL\*Plus (Oracle)

Trong SQLPlus, các lệnh format dùng để điều khiển cách hiển thị kết quả truy vấn, độ rộng cột, tiêu đề, số trang, ngày tháng và nội dung báo cáo. Chúng chỉ thay đổi cách hiển thị trong SQLPlus, không thay đổi dữ liệu được lưu trong database.

Các lệnh quan trọng nhất gồm:

- `SET LINESIZE`, `SET PAGESIZE`: định dạng toàn bộ kết quả.
- `COLUMN ... FORMAT`: định dạng từng cột.
- `COLUMN ... HEADING`: đổi tiêu đề cột.
- `COLUMN ... JUSTIFY`: căn trái, căn phải hoặc căn giữa.
- `SET NUMFORMAT`, `SET NUMWIDTH`: định dạng số.
- `SET NULL`, `SET TRIMSPOOL`, `SET WRAP`: kiểm soát cách hiển thị dữ liệu.
- `TTITLE`, `BTITLE`, `BREAK`, `COMPUTE`: tạo báo cáo.

Các ví dụ dưới đây phù hợp để thực hành trên Oracle Database 19c và SQL\*Plus.

## 1. `SET LINESIZE` — Độ rộng dòng

### Cú pháp

```
SET LINESIZE {n}
```

`LINESIZE` quy định số ký tự tối đa trên một dòng hiển thị.

Ví dụ:

```
SET LINESIZE 100

SELECT employee_id, first_name, last_name, email, salary
FROM employees;
```

| Lệnh               | Ý nghĩa             |
| ------------------ | ------------------- |
| `SET LINESIZE 80`  | Dòng rộng 80 ký tự  |
| `SET LINESIZE 100` | Dòng rộng 100 ký tự |
| `SET LINESIZE 200` | Dòng rộng 200 ký tự |

Nếu `LINESIZE` quá nhỏ, kết quả có thể bị xuống dòng hoặc khó đọc. Nếu quá lớn, kết quả có thể vượt khỏi chiều rộng cửa sổ terminal.

Khuyến nghị: khi truy vấn các view quản trị như `V$DATABASE`, `V$INSTANCE`, `V$PDBS`, có thể bắt đầu với `SET LINESIZE 180` hoặc `200`, sau đó điều chỉnh theo terminal.

## 2. `COLUMN ... FORMAT` — Định dạng từng cột

Đây là nhóm lệnh bạn thường sử dụng nhất khi làm việc với SQL\*Plus.

### 2.1. Cú pháp

```
COLUMN column_name FORMAT format_model
```

Có thể viết tắt:

```
COL column_name FOR format_model
```

Ví dụ:

```
COL employee_id FORMAT 999999
COL first_name   FORMAT A20
COL salary       FORMAT 999,999.99
```

Trong đó:

- `COLUMN` có thể viết tắt thành `COL`.
- `FORMAT` có thể viết tắt thành `FOR`.
- `A20` quy định độ rộng ký tự là 20.
- `999,999.99` định dạng số có dấu phân cách hàng nghìn và 2 chữ số thập phân.

### 2.2. Định dạng chuỗi ký tự với `A`

Cú pháp:

```
COL column_name FORMAT A<n>
```

Ví dụ:

```
SET LINESIZE 120

COL first_name FORMAT A15
COL last_name  FORMAT A20
COL email      FORMAT A30

SELECT first_name, last_name, email
FROM employees;
```

| Format | Ý nghĩa                   |
| ------ | ------------------------- |
| `A5`   | Độ rộng hiển thị 5 ký tự  |
| `A10`  | Độ rộng hiển thị 10 ký tự |
| `A20`  | Độ rộng hiển thị 20 ký tự |
| `A30`  | Độ rộng hiển thị 30 ký tự |

Lưu ý:

- `A20` thường dùng cho dữ liệu ký tự.
- Nếu dữ liệu dài hơn độ rộng, SQL\*Plus có thể cắt bớt hoặc xuống dòng tùy cấu hình, kiểu dữ liệu và các thuộc tính khác.
- Định dạng hiển thị không thay đổi độ dài dữ liệu trong database.

### 2.3. Định dạng số

SQL\*Plus sử dụng các format model để quy định số chữ số, dấu phân cách và cách hiển thị số.

Ví dụ:

```
COL salary FORMAT 999999.99

SELECT salary
FROM employees;
```

Một số ký hiệu thường dùng:

| Ký hiệu | Ý nghĩa                                                                   |
| ------- | ------------------------------------------------------------------------- |
| `9`     | Vị trí chữ số; không bắt buộc hiển thị số 0 ở đầu                         |
| `0`     | Vị trí chữ số; hiển thị số 0 nếu cần                                      |
| `,`     | Dấu phân cách hàng nghìn                                                  |
| `.`     | Dấu thập phân trong format model                                          |
| `$`     | Hiển thị ký hiệu đô la                                                    |
| `B`     | Hiển thị khoảng trắng thay cho số 0 ở phần nguyên trong một số trường hợp |
| `MI`    | Hiển thị dấu trừ ở cuối số âm                                             |
| `PR`    | Đặt số âm trong dấu ngoặc nhọn góc `< >`                                  |

Ví dụ:

```
SET LINESIZE 100

COL salary FORMAT 999,999,990.00
COL commission_pct FORMAT 0.99
COL employee_id FORMAT 999999

SELECT employee_id, salary, commission_pct
FROM employees;
```

So sánh một số format model:

| Format       | Giá trị minh họa | Kết quả     |
| ------------ | ---------------- | ----------- |
| `9999`       | `25`             | `25`        |
| `0999`       | `25`             | `0025`      |
| `9990`       | `25`             | `0025`      |
| `9,999`      | `2500`           | `2,500`     |
| `9990.00`    | `25.5`           | `25.50`     |
| `$99,990.00` | `1250.5`         | `$1,250.50` |

Kết quả cụ thể còn phụ thuộc giá trị, độ rộng format và thiết lập NLS. Nếu format model không đủ rộng để biểu diễn giá trị, SQL\*Plus có thể hiển thị ký tự `#`.

## 3. `COLUMN HEADING` — Đổi tiêu đề cột

Mặc định, SQL\*Plus lấy tên cột hoặc alias trong câu SQL làm tiêu đề. Bạn có thể đổi tiêu đề bằng `HEADING`.

### Cú pháp

```
COLUMN column_name HEADING 'new_heading'
```

Ví dụ:

```
SET LINESIZE 100

COL employee_id HEADING 'Employee|ID'
COL first_name  HEADING 'First|Name'
COL salary      HEADING 'Monthly Salary'

SELECT employee_id, first_name, salary
FROM employees;
```

Trong SQL\*Plus, ký tự `|` trong heading được dùng để ngắt tiêu đề thành nhiều dòng.

Ví dụ, `Employee|ID` hiển thị thành:

```
Employee
ID
```

Bạn cũng có thể dùng alias ngay trong SQL:

```
SELECT employee_id AS "Employee ID",
       first_name  AS "First Name",
       salary      AS "Monthly Salary"
FROM employees;
```

Khác biệt:

- `AS "Employee ID"` là alias trong câu SQL.
- `COLUMN employee_id HEADING 'Employee ID'` là cấu hình hiển thị của SQL\*Plus.

Cấu hình `COLUMN` có thể tiếp tục ảnh hưởng đến những câu truy vấn sau trong cùng phiên SQL\*Plus cho đến khi bị thay đổi hoặc xóa.

## 4. `COLUMN JUSTIFY` — Căn lề dữ liệu

### Cú pháp

```
COLUMN column_name JUSTIFY {LEFT | CENTER | RIGHT}
```

Có thể viết tắt:

```
COL salary JUST RIGHT
```

Ví dụ:

```
COL first_name FORMAT A20 JUSTIFY LEFT
COL salary     FORMAT 999,999.99 JUSTIFY RIGHT
```

| Tùy chọn | Ý nghĩa  |
| -------- | -------- |
| `LEFT`   | Căn trái |
| `CENTER` | Căn giữa |
| `RIGHT`  | Căn phải |

Thông thường, SQL\*Plus căn trái dữ liệu ký tự và căn phải dữ liệu số. Dùng `JUSTIFY` khi bạn muốn chủ động điều khiển cách trình bày.

## 5. `COLUMN WRAPPED`, `WORD_WRAPPED`, `TRUNCATED`

Ba tùy chọn này kiểm soát dữ liệu dài hơn chiều rộng cột.

### Cú pháp

```
COL column_name WRAPPED
COL column_name WORD_WRAPPED
COL column_name TRUNCATED
```

| Tùy chọn       | Ý nghĩa                                                               |
| -------------- | --------------------------------------------------------------------- |
| `WRAPPED`      | Phần dữ liệu vượt quá chiều rộng cột được chuyển xuống dòng tiếp theo |
| `WORD_WRAPPED` | Xuống dòng theo ranh giới từ nếu có thể                               |
| `TRUNCATED`    | Cắt bỏ phần vượt quá chiều rộng cột                                   |

Ví dụ:

```
SET LINESIZE 100

COL comments FORMAT A20 WORD_WRAPPED

SELECT comments
FROM some_table;
```

Nếu `COMMENTS` chứa văn bản dài, `WORD_WRAPPED` giúp trình bày dễ đọc hơn.

Lưu ý: `FORMAT A20` không có nghĩa là dữ liệu dài hơn 20 ký tự chắc chắn sẽ được giữ nguyên trên một dòng. Hãy chọn tùy chọn wrap phù hợp với mục tiêu hiển thị.

## 6. `SET PAGESIZE` — Số dòng trong một trang

### Cú pháp

```
SET PAGESIZE n
```

`PAGESIZE` quy định số dòng trong một trang báo cáo SQL\*Plus, ảnh hưởng đến việc lặp lại tiêu đề cột và cách phân trang.

Ví dụ:

```
SET PAGESIZE 50

SELECT employee_id, first_name, salary
FROM employees;
```

| Lệnh                 | Ý nghĩa                                             |
| -------------------- | --------------------------------------------------- |
| `SET PAGESIZE 14`    | Thiết lập trang tương đối ngắn                      |
| `SET PAGESIZE 50`    | Trang có 50 dòng                                    |
| `SET PAGESIZE 100`   | Trang có 100 dòng                                   |
| `SET PAGESIZE 50000` | Giảm đáng kể việc lặp lại tiêu đề trong kết quả dài |

Nếu muốn hiển thị kết quả truy vấn dài mà không lặp lại tiêu đề thường xuyên, có thể sử dụng:

```
SET PAGESIZE 50000
```

Tuy nhiên, nếu đang tạo báo cáo nhiều trang, bạn nên chọn `PAGESIZE` vừa phải.

## 7. Các lệnh `SET` quan trọng khác

### 7.1. `SET HEADING`

Điều khiển việc hiển thị tiêu đề cột.

```
SET HEADING ON
SET HEADING OFF
```

- `ON`: hiển thị tiêu đề.
- `OFF`: ẩn tiêu đề.

### 7.2. `SET FEEDBACK`

Điều khiển dòng thông báo số bản ghi.

```
SET FEEDBACK ON
SET FEEDBACK OFF
SET FEEDBACK 5
```

Ví dụ, khi chạy truy vấn:

```
SELECT employee_id
FROM employees;
```

SQL\*Plus có thể hiển thị:

```
107
108
109

107 rows selected.
```

`SET FEEDBACK OFF` ẩn thông báo số dòng. `SET FEEDBACK 5` chỉ hiển thị thông báo khi số dòng đạt ngưỡng 5 trở lên.

### 7.3. `SET VERIFY`

Hiển thị giá trị trước và sau khi thay thế biến `&`.

```
SET VERIFY ON

SELECT employee_id, first_name
FROM employees
WHERE employee_id = &emp_id;
```

SQL\*Plus sẽ yêu cầu nhập giá trị cho `emp_id`, đồng thời hiển thị dòng trước và sau khi thay thế biến.

```
SET VERIFY OFF
```

Tắt thông báo `old` và `new`.

### 7.4. `SET ECHO`

Điều khiển việc hiển thị các lệnh được đọc từ file script.

```
SET ECHO ON
@report.sql
```

- `ON`: hiển thị các lệnh trong script khi thực thi.
- `OFF`: không hiển thị các lệnh đó.

`ECHO` chủ yếu hữu ích khi chạy file `.sql`; nó không phải lệnh để ẩn kết quả truy vấn.

### 7.5. `SET WRAP`

Điều khiển việc xử lý dòng dài hơn `LINESIZE`.

```
SET WRAP ON
SET WRAP OFF
```

- `ON`: phần dữ liệu vượt chiều rộng dòng được chuyển sang dòng tiếp theo.
- `OFF`: phần vượt quá chiều rộng dòng có thể bị cắt khỏi phần hiển thị.

Nếu mục tiêu là không mất dữ liệu khi xuất báo cáo, đừng tắt `WRAP` một cách tùy tiện.

### 7.6. `SET NULL`

Quy định nội dung thay thế cho giá trị `NULL` khi hiển thị.

```
SET NULL '(NULL)'
```

Ví dụ:

```
SELECT employee_id, commission_pct
FROM employees;
```

Giá trị `NULL` có thể được hiển thị thành `(NULL)` thay vì để trống.

Muốn trở về hiển thị mặc định:

```
SET NULL ''
```

Lệnh này chỉ thay đổi phần hiển thị, không chuyển giá trị `NULL` thành chuỗi trong database.

### 7.7. `SET NUMFORMAT`

Thiết lập format mặc định cho các cột số khi chưa có định dạng riêng bằng `COLUMN FORMAT`.

```
SET NUMFORMAT 999,999,990.00
```

Ví dụ:

```
SELECT salary
FROM employees;
```

Các giá trị số sẽ sử dụng format mặc định trên, trừ trường hợp có định dạng riêng ghi đè.

### 7.8. `SET NUMWIDTH`

Thiết lập độ rộng mặc định cho việc hiển thị các cột số.

```
SET NUMWIDTH 12
```

Lệnh này hữu ích khi SQL\*Plus cần hiển thị các cột số không được định dạng riêng. Nếu dùng `COLUMN ... FORMAT` thì format của cột có thể quyết định độ rộng hiển thị.

### 7.9. `SET TAB`

```
SET TAB ON
SET TAB OFF
```

Điều khiển việc sử dụng tab trong đầu ra SQL\*Plus. Trong các báo cáo cần định dạng ổn định, có thể sử dụng:

```
SET TAB OFF
```

## 8. Các lệnh format khác dành cho báo cáo

### 8.1. `COLUMN ... NULL`

Có thể quy định nội dung hiển thị riêng cho cột khi giá trị là `NULL`:

```
COL commission_pct NULL 'No Commission'
```

Khác với `SET NULL`, cấu hình này áp dụng cho một cột cụ thể.

### 8.2. `COLUMN ... CLEAR`

Xóa cấu hình `COLUMN` của một cột:

```
COL salary CLEAR
```

Xóa toàn bộ cấu hình `COLUMN` trong phiên:

```
CLEAR COLUMNS
```

Ví dụ:

```
COL salary FORMAT 999,999.99
COL salary HEADING 'Monthly Salary'

CLEAR COLUMNS
```

Sau đó SQL\*Plus không còn áp dụng các thiết lập `COLUMN` đã khai báo trước đó.

### 8.3. `SET UNDERLINE`

Thiết lập ký tự dùng để gạch dưới tiêu đề cột.

```
SET UNDERLINE -
```

Hoặc:

```
SET UNDERLINE =
```

Ví dụ:

```
EMPLOYEE_ID  FIRST_NAME
-----------  ----------
         100 Steven
         101 Neena
```

Đây là ký tự gạch dưới tiêu đề, không phải định dạng đường viền bảng như trong Excel.

### 8.4. `SET TRIMSPOOL`

Điều khiển việc loại bỏ khoảng trắng ở cuối dòng khi ghi đầu ra vào file bằng `SPOOL`.

```
SET TRIMSPOOL ON
```

Hữu ích khi xuất báo cáo ra file text để giảm khoảng trắng không cần thiết ở cuối mỗi dòng.

Lưu ý: `TRIMSPOOL` ảnh hưởng đầu ra được ghi vào spool, không có nghĩa là dữ liệu gốc bị cắt.

### 8.5. `SET LONG` và `SET LONGCHUNKSIZE`

Dùng để điều khiển việc hiển thị dữ liệu kiểu `LONG` và một số đầu ra dạng văn bản lớn.

```
SET LONG 100000
SET LONGCHUNKSIZE 10000
```

- `LONG`: giới hạn số byte tối đa SQL\*Plus lấy để hiển thị đối với các kiểu dữ liệu được hỗ trợ.
- `LONGCHUNKSIZE`: kích thước khối đọc cho dữ liệu `LONG`.

Hai lệnh này không phải giải pháp tổng quát cho mọi cột `CLOB`, `BLOB` hay dữ liệu nhị phân. Với `CLOB`, hãy kiểm tra thêm `SET LONG` và khả năng hiển thị của phiên bản SQL\*Plus đang dùng.

## 9. `TTITLE` và `BTITLE` — Tiêu đề đầu trang và cuối trang

Hai lệnh này thường dùng khi tạo báo cáo bằng SQL\*Plus.

### 9.1. `TTITLE` — Tiêu đề đầu trang

```
TTITLE 'EMPLOYEE REPORT'
```

Mỗi trang báo cáo sẽ có tiêu đề ở đầu trang.

Ví dụ:

```
SET PAGESIZE 40
SET LINESIZE 100

TTITLE CENTER 'EMPLOYEE REPORT'

SELECT employee_id, first_name, salary
FROM employees;

TTITLE OFF
```

Một số cách căn chỉnh thường dùng:

```
TTITLE LEFT 'EMPLOYEE REPORT'
TTITLE CENTER 'EMPLOYEE REPORT'
TTITLE RIGHT 'EMPLOYEE REPORT'
TTITLE OFF
```

### 9.2. `BTITLE` — Tiêu đề cuối trang

```
BTITLE CENTER 'END OF REPORT'
```

Tắt tiêu đề cuối trang:

```
BTITLE OFF
```

Các lệnh này phù hợp với báo cáo nhiều trang hơn là việc truy vấn nhanh trong terminal.

## 10. `BREAK` — Nhóm dữ liệu và ngắt dòng báo cáo

`BREAK` cho phép nhóm kết quả theo giá trị của một cột và kiểm soát cách trình bày giữa các nhóm.

Ví dụ, nhóm nhân viên theo mã phòng ban:

```
SET LINESIZE 100
SET PAGESIZE 50

BREAK ON department_id SKIP 1

SELECT department_id, employee_id, first_name, salary
FROM employees
ORDER BY department_id, employee_id;
```

Ý nghĩa:

- `ON department_id`: tạo nhóm theo `department_id`.
- `SKIP 1`: chừa một dòng trống giữa các nhóm.
- `ORDER BY department_id`: giúp các bản ghi cùng nhóm nằm cạnh nhau.

Nếu không có `ORDER BY` thích hợp, dữ liệu cùng nhóm có thể không xuất hiện liên tiếp, khiến báo cáo khó đọc.

Xóa cấu hình:

```
CLEAR BREAKS
```

## 11. `COMPUTE` — Tính tổng và thống kê trong báo cáo

`COMPUTE` kết hợp với `BREAK` để tính các giá trị thống kê theo nhóm.

Ví dụ tính tổng lương theo phòng ban:

```
SET LINESIZE 100
SET PAGESIZE 50

BREAK ON department_id SKIP 1
COMPUTE SUM OF salary ON department_id

SELECT department_id, employee_id, salary
FROM employees
ORDER BY department_id, employee_id;
```

SQL\*Plus có thể hiển thị tổng lương cho từng nhóm `department_id`.

Một số phép tính thường dùng:

| Lệnh            | Ý nghĩa          |
| --------------- | ---------------- |
| `COMPUTE SUM`   | Tính tổng        |
| `COMPUTE AVG`   | Tính trung bình  |
| `COMPUTE MIN`   | Giá trị nhỏ nhất |
| `COMPUTE MAX`   | Giá trị lớn nhất |
| `COMPUTE COUNT` | Đếm số giá trị   |

Xóa cấu hình:

```
CLEAR COMPUTES
CLEAR BREAKS
```

Lưu ý: `BREAK` và `COMPUTE` là các lệnh định dạng báo cáo của SQL\*Plus, không phải hàm SQL. Chúng phù hợp với các báo cáo truyền thống; đối với phân tích dữ liệu phức tạp, các hàm SQL như `SUM() OVER (...)` hoặc `GROUP BY` thường linh hoạt hơn.

## 12. `SPOOL` — Ghi báo cáo ra file

`SPOOL` không trực tiếp định dạng dữ liệu, nhưng thường được sử dụng cùng các lệnh format để xuất báo cáo.

Ví dụ:

```
SET PAGESIZE 100
SET LINESIZE 150
SET TRIMSPOOL ON
SET FEEDBACK ON

SPOOL employee_report.txt

SELECT employee_id, first_name, last_name, salary
FROM employees
ORDER BY employee_id;

SPOOL OFF
```

Các lệnh:

| Lệnh                        | Ý nghĩa                                    |
| --------------------------- | ------------------------------------------ |
| `SPOOL employee_report.txt` | Bắt đầu ghi đầu ra vào file                |
| `SPOOL OFF`                 | Kết thúc ghi file                          |
| `SET TRIMSPOOL ON`          | Loại bỏ khoảng trắng cuối dòng trong spool |

File được tạo trong thư mục làm việc hiện tại của tiến trình SQL\*Plus, trừ khi chỉ định đường dẫn khác.

Nếu muốn xuất CSV, các phiên bản SQL\*Plus hiện đại hỗ trợ thêm `SET MARKUP CSV ON`. Khả năng và cú pháp chi tiết phụ thuộc phiên bản; không nên coi file spool văn bản có định dạng cột là CSV chuẩn.

## 13. Bảng tổng hợp các lệnh SQL\*Plus format

| Lệnh                      | Công dụng                                  |
| ------------------------- | ------------------------------------------ |
| `SET LINESIZE n`          | Độ rộng dòng                               |
| `SET PAGESIZE n`          | Số dòng mỗi trang                          |
| `COL c FORMAT A20`        | Độ rộng cột ký tự                          |
| `COL c FORMAT 999,990.00` | Định dạng số                               |
| `COL c HEADING 'Title'`   | Đổi tiêu đề                                |
| `COL c JUSTIFY LEFT`      | Căn trái                                   |
| `COL c WRAPPED`           | Cho phép xuống dòng                        |
| `COL c WORD_WRAPPED`      | Xuống dòng theo từ                         |
| `COL c TRUNCATED`         | Cắt phần vượt chiều rộng                   |
| `COL c NULL 'N/A'`        | Hiển thị thay thế cho `NULL` của cột       |
| `SET HEADING OFF`         | Ẩn tiêu đề                                 |
| `SET FEEDBACK OFF`        | Ẩn thông báo số dòng                       |
| `SET VERIFY OFF`          | Ẩn thông báo thay thế biến                 |
| `SET ECHO OFF`            | Ẩn lệnh đọc từ script                      |
| `SET WRAP OFF`            | Không chuyển phần vượt dòng sang dòng tiếp |
| `SET NULL '(NULL)'`       | Hiển thị giá trị `NULL`                    |
| `SET NUMFORMAT ...`       | Format mặc định cho số                     |
| `SET NUMWIDTH n`          | Độ rộng mặc định của cột số                |
| `SET UNDERLINE -`         | Ký tự gạch dưới heading                    |
| `SET TRIMSPOOL ON`        | Loại bỏ khoảng trắng cuối dòng trong spool |
| `SET LONG n`              | Giới hạn đầu ra dữ liệu `LONG`             |
| `TTITLE`                  | Tiêu đề đầu trang                          |
| `BTITLE`                  | Tiêu đề cuối trang                         |
| `BREAK`                   | Nhóm dữ liệu trong báo cáo                 |
| `COMPUTE`                 | Tính tổng hoặc thống kê trong báo cáo      |
| `SPOOL`                   | Ghi đầu ra ra file                         |
| `CLEAR COLUMNS`           | Xóa cấu hình cột                           |
| `CLEAR BREAKS`            | Xóa cấu hình break                         |
| `CLEAR COMPUTES`          | Xóa cấu hình compute                       |

## 14. Cấu hình SQL\*Plus thực tế dành cho DBA Oracle

Với công việc kiểm tra CDB, PDB, ASM và các view quản trị Oracle, bạn có thể tạo một file cấu hình như `dba_format.sql`.

```

-- ============================================
-- SQL*Plus DBA formatting profile
-- Oracle Database 19c
-- ============================================

SET LINESIZE 200
SET PAGESIZE 100
SET TAB OFF
SET TRIMSPOOL ON
SET WRAP ON
SET HEADING ON
SET FEEDBACK ON
SET VERIFY OFF
SET NULL '(NULL)'
SET NUMWIDTH 12
SET UNDERLINE -

-- Format cho thông tin database
COL name          FORMAT A15
COL db_unique_name FORMAT A25
COL database_role FORMAT A18
COL open_mode     FORMAT A20
COL log_mode      FORMAT A15

-- Format cho thông tin instance
COL instance_name FORMAT A15
COL host_name     FORMAT A35
COL status        FORMAT A12

-- Format cho thông tin PDB
COL pdb_name      FORMAT A25
COL con_name      FORMAT A25
COL restricted    FORMAT A12

-- Format cho thông tin ASM
COL diskgroup_name FORMAT A20
COL state          FORMAT A12
COL type           FORMAT A10

-- Thông báo cấu hình
PROMPT SQL*Plus DBA formatting profile loaded.

```

Nạp cấu hình trong SQL\*Plus:

```
@dba_format.sql
```

Lưu ý: các lệnh `COLUMN` chỉ áp dụng khi tên cột thực tế hoặc alias của câu truy vấn khớp với tên được cấu hình. Ví dụ, `NAME` và `DB_NAME` là hai tên cột khác nhau.

Để áp dụng cho mọi phiên SQLPlus của một user, có thể đặt các lệnh cấu hình phù hợp trong file `login.sql` tại thư mục làm việc, hoặc `glogin.sql` tại thư mục quản trị SQLPlus. `glogin.sql` là cấu hình chung của bản cài đặt SQL\*Plus; thay đổi file này cần quyền quản trị hệ thống.

## 15. Ví dụ thực hành: định dạng kết quả `SHOW PDBS` và truy vấn PDB

Lệnh `SHOW PDBS` là lệnh SQL\*Plus có sẵn, không phải câu `SELECT`. Bạn không thể dùng `COLUMN FORMAT` để đặt format riêng cho từng cột của `SHOW PDBS` giống như đối với truy vấn SQL thông thường.

Muốn kiểm soát hoàn toàn tiêu đề, độ rộng và thứ tự cột, hãy truy vấn view quản trị:

```
SET LINESIZE 120
SET PAGESIZE 50

COL name         FORMAT A25 HEADING 'PDB Name'
COL open_mode    FORMAT A15 HEADING 'Open Mode'
COL restricted   FORMAT A10 HEADING 'Restricted'

SELECT name,
       open_mode,
       restricted
FROM v$pdbs
ORDER BY con_id;
```

Ví dụ kết quả:

```
PDB Name                  Open Mode       Restricted
------------------------- --------------- ----------
PDB$SEED                  READ ONLY       NO
PDB                       READ WRITE      NO
PDB1                      READ WRITE      NO
```

View `V$PDBS` hiển thị thông tin PDB của CDB hiện tại. Nếu truy vấn ở `CDB$ROOT`, bạn có thể quan sát các PDB thuộc CDB đó theo quyền truy cập của user.

### Ghi nhớ

- Dùng `SET LINESIZE` để điều chỉnh chiều rộng tổng thể.
- Dùng `SET PAGESIZE` để điều chỉnh phân trang.
- Dùng `COL ... FORMAT A<n>` cho dữ liệu ký tự.
- Dùng `COL ... FORMAT 999...` cho số.
- Dùng `HEADING`, `JUSTIFY`, `WRAPPED` để điều khiển cách trình bày từng cột.
- Dùng `BREAK`, `COMPUTE`, `TTITLE`, `BTITLE` khi tạo báo cáo.
- Dùng `SPOOL` khi cần lưu kết quả ra file.

Các thiết lập SQL\*Plus chủ yếu tác động đến phiên làm việc hiện tại; chúng không sửa cấu trúc bảng hay dữ liệu trong Oracle Database.