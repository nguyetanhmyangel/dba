### 1. Database Memory là gì?

Khi Oracle Database chạy, nó cần bộ nhớ (RAM) để:

    - Lưu tạm dữ liệu đọc/ghi từ đĩa

    - Lưu cache của SQL, kết quả tính toán

    - Lưu trạng thái của các session (kết nối)

    - Hỗ trợ các tiến trình nền (background processes)

Nói ngắn gọn Database Memory: bộ nhớ Oracle sử dụng để làm việc, giúp tăng tốc độ xử lý so với việc đọc/ghi trực tiếp từ ổ đĩa.

### 2. Kiến trúc bộ nhớ của Oracle

Bộ nhớ Oracle được chia thành 2 vùng lớn:

| Vùng                            | Chứa gì                                    | Ý nghĩa                                                          |
| ------------------------------- | ------------------------------------------ | ---------------------------------------------------------------- |
| **SGA** (*System Global Area*)  | Bộ nhớ **dùng chung** cho tất cả session   | Tăng hiệu năng vì nhiều session dùng chung dữ liệu đã được cache |
| **PGA** (*Program Global Area*) | Bộ nhớ **riêng cho mỗi session / process** | Chứa thông tin tạm của session như sort, join, biến bind…        |


### 3. Chi tiết về SGA (System Global Area)

SGA là bộ nhớ chính của Oracle Database, dùng chung cho toàn bộ instance.

Các thành phần chính của SGA

| Thành phần                    | Mô tả                                                                     | Vai trò                                          |
| ----------------------------- | ------------------------------------------------------------------------- | ------------------------------------------------ |
| **Database Buffer Cache**     | Lưu **các block dữ liệu** vừa được đọc từ đĩa                             | Giúp tránh đọc đĩa nhiều lần                     |
| **Shared Pool**               | Lưu **các câu lệnh SQL, PL/SQL đã biên dịch**, metadata (data dictionary) | Giảm thời gian parse và optimize câu SQL lặp lại |
| **Redo Log Buffer**           | Lưu **thông tin thay đổi dữ liệu** trước khi ghi xuống redo log file      | Đảm bảo khả năng khôi phục (recoverability)      |
| **Large Pool** *(tùy chọn)*   | Lưu dữ liệu cho **RMAN backup/restore**, parallel execution…              | Giảm tải cho Shared Pool                         |
| **Java Pool** *(tùy chọn)*    | Bộ nhớ cho chương trình Java chạy trong DB                                | Hỗ trợ ứng dụng Java                             |
| **Streams Pool** *(tùy chọn)* | Cho tính năng **Oracle Streams / GoldenGate replication**                 | Đồng bộ dữ liệu giữa các DB                      |

Quan trọng nhất với hiệu năng OLTP là:

- Buffer Cache

- Shared Pool

- Redo Log Buffer

### 4. Chi tiết về PGA (Program Global Area)

PGA là bộ nhớ riêng của mỗi process (session), không dùng chung.

Thành phần của PGA

| Thành phần         | Mô tả                                                          |
| ------------------ | -------------------------------------------------------------- |
| **SQL Work Area**  | Bộ nhớ cho các thao tác như **sort, hash join, bitmap merge…** |
| **Session Memory** | Biến bind, session variables                                   |
| **Stack Space**    | Ngăn xếp cho các thủ tục PL/SQL                                |


Nếu PGA không đủ, Oracle sẽ phải dùng TEMP tablespace trên đĩa → giảm hiệu năng.

### 5. Cách Oracle quản lý bộ nhớ

Có 2 chế độ chính:

| Chế độ                                        | Tham số chính                                        | Đặc điểm                                                                         |
| --------------------------------------------- | ---------------------------------------------------- | -------------------------------------------------------------------------------- |
| **Automatic Memory Management (AMM)**         | `MEMORY_TARGET` & `MEMORY_MAX_TARGET`                | Oracle tự động điều chỉnh SGA và PGA → dễ quản lý                                |
| **Automatic Shared Memory Management (ASMM)** | `SGA_TARGET`, `SGA_MAX_SIZE`, `PGA_AGGREGATE_TARGET` | Oracle tự động điều chỉnh các thành phần **trong SGA**, nhưng PGA cấu hình riêng |
| **Manual Memory Management**                  | `DB_CACHE_SIZE`, `SHARED_POOL_SIZE`, …               | Quản trị viên tự phân bổ từng vùng → linh hoạt nhưng phức tạp                    |

Từ Oracle 11g trở lên, thường dùng AMM hoặc ASMM.

### 6. Kiểm tra bộ nhớ trong Oracle

6.1. Xem tổng bộ nhớ

```bash
SHOW PARAMETER memory;

SHOW PARAMETER sga;
SHOW PARAMETER pga;
```

6.2. Xem chi tiết sử dụng thực tế

```bash
SELECT * FROM v$sga_dynamic_components;
SELECT * FROM v$sgainfo;
SELECT * FROM v$pgastat;
```

### 7. Điều chỉnh bộ nhớ (ví dụ)

7.1. Dùng AMM

```bash
ALTER SYSTEM SET MEMORY_TARGET = 4G SCOPE=SPFILE;
ALTER SYSTEM SET MEMORY_MAX_TARGET = 6G SCOPE=SPFILE;
```

7.2. Dùng ASMM

```bash
ALTER SYSTEM SET SGA_TARGET = 3G SCOPE=BOTH;
ALTER SYSTEM SET PGA_AGGREGATE_TARGET = 1G SCOPE=BOTH;
```

Sau khi thay đổi một số tham số (như MEMORY_TARGET), cần restart instance.

### 8. Tóm tắt

- Oracle Memory = SGA (chung) + PGA (riêng)

- SGA: chứa dữ liệu, SQL, redo log → quan trọng cho tốc độ đọc/ghi

- PGA: chứa dữ liệu tạm cho mỗi session → quan trọng cho các truy vấn cần sort, join lớn

- Có thể để Oracle tự quản lý (AMM/ASMM) hoặc tự phân bổ thủ công

- Kiểm tra bằng SHOW PARAMETER, v$sga_dynamic_components, v$pgastat