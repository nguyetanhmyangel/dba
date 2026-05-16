### 1. Initialization Parameters (tham số khởi tạo) là tập hợp các giá trị cấu hình điều khiển hoạt động của Oracle Database khi khởi động (STARTUP). Ví Ví dụ:

- Kích thước bộ nhớ (SGA)

- Đường dẫn file dữ liệu, control file

- Số lượng process tối đa

- Ngôn ngữ, định dạng ngày giờ,...

### 2. FILE CHỨA PARAMETER – SPFILE và PFILE:

- SPFILE (Server Parameter File)

. Tên file mặc định: spfile<SID>.ora

. Đặc điểm: Nhị phân, Oracle dùng mặc định khi chạy STARTUP, có thể thay đổi trực tiếp thông qua câu lệnh SQL (ví dụ: ALTER SYSTEM SET).

. Nên dùng: ✅

- PFILE (Parameter File)

. Tên file mặc định: init<SID>.ora

. Đặc điểm: Dạng văn bản (text), khi thay đổi cần phải khởi động lại (restart) Oracle mới có hiệu lực.

. Nên dùng: ❌ (chỉ dùng trong khẩn cấp hoặc trong môi trường phát triển/dev)

SID là tên Instance – thường là tên database.

### 3. VỊ TRÍ CÁC FILE INIT/SPFILE
Trên Linux: /u01/app/oracle/product/19.0.0/dbhome_1/dbs/

Trên Windows: C:\app\oracle\product\19.0.0\dbhome_1\database\

Có thể kiểm tra spfile đang dùng:

```bash
SHOW PARAMETER spfile;
```

### 4. KIỂM TRA GIÁ TRỊ PARAMETER:

```bash
-- Xem toàn bộ
SHOW PARAMETER;

-- Hoặc lọc theo tên
SHOW PARAMETER sga;
SHOW PARAMETER processes;

-- Xem file SPFILE đang dùng
SHOW PARAMETER spfile;

-- Xem thông tin tham số hiện tại
SHOW PARAMETER processes;

-- Thay đổi và lưu vào SPFILE
ALTER SYSTEM SET processes = 500 SCOPE = SPFILE;

-- Restart database để áp dụng
SHUTDOWN IMMEDIATE;
STARTUP;
```

### 5. MỘT SỐ THAM SỐ KHỞI TẠO QUAN TRỌNG:

| Tham số                | Mô tả                                                   |
|------------------------|---------------------------------------------------------|
| `DB_NAME`              | Tên database (không đổi sau khi tạo)                    |
| `DB_BLOCK_SIZE`        | Kích thước khối dữ liệu – thường là 8KB                 |
| `CONTROL_FILES`        | Đường dẫn tới control file                              |
| `SGA_TARGET`           | Tổng bộ nhớ SGA                                         |
| `PGA_AGGREGATE_TARGET` | Tổng bộ nhớ PGA                                         |
| `PROCESSES`            | Số process tối đa                                       |
| `OPEN_CURSORS`         | Số cursor mở cùng lúc tối đa                            |
| `UNDO_MANAGEMENT`      | Kiểu quản lý undo (Tự động: `AUTO`, thủ công: `MANUAL`) |
| `UNDO_TABLESPACE`      | Tablespace chứa undo                                    |
| `NLS_LANGUAGE`         | Ngôn ngữ mặc định                                       |
| `NLS_DATE_FORMAT`      | Định dạng ngày                                          |

### 6. CÁCH THAY ĐỔI PARAMETER

a. Với SPFILE (không cần restart)

```bash
ALTER SYSTEM SET processes = 300 SCOPE = SPFILE;
ALTER SYSTEM SET sga_target = 1024M SCOPE = MEMORY;
```

| `SCOPE`  | Ý nghĩa                              |
|----------|--------------------------------------|
| `SPFILE` | Lưu vào spfile, hiệu lực sau restart |
| `MEMORY` | Hiệu lực ngay, không lưu             |
| `BOTH`   | Hiệu lực ngay và lưu vào spfile      |

b. Với PFILE (phải sửa file thủ công và restart)

Mở file init.ora

Sửa dòng, ví dụ:

```bash
processes=300
sga_target=1024M
```

Lưu lại và restart:

```bash
STARTUP PFILE='/path/to/init.ora';
```

### 7. XUẤT SPFILE THÀNH PFILE (BACKUP)

```bash
CREATE PFILE='/path/to/init_backup.ora' FROM SPFILE;
```

### 8. TẠO SPFILE TỪ PFILE

```bash
CREATE SPFILE FROM PFILE='/path/to/init.ora';
```


