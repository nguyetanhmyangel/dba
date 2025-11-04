### 1. Khởi động một Oracle Instance có 3 giai đoạn:

| Giai đoạn   | Mô tả                                                                                                      |
|-------------|------------------------------------------------------------------------------------------------------------|
| NOMOUNT     | Khởi tạo Oracle instance (đọc `init.ora` hoặc `spfile.ora`, tạo background processes và cấu trúc SGA).     |
| MOUNT       | Đọc control file, nhưng chưa mở file dữ liệu. Thích hợp cho backup hoặc recovery.                          |
| OPEN        | Mở database (file dữ liệu + redo log), sẵn sàng cho user kết nối.                                          |

```bash
-- Mở SQL*Plus với quyền sysdba
sqlplus / as sysdba

-- Khởi động cơ bản (đầy đủ 3 bước)
STARTUP;

-- Hoặc có thể từng bước:
STARTUP NOMOUNT;
ALTER DATABASE MOUNT;
ALTER DATABASE OPEN;
```

### 2. Kiểm tra trạng thái:

```bash
SELECT status FROM v$instance;
```


### 3. Có nhiều chế độ shutdown khác nhau tùy tình huống:

| Lệnh                     | Mô tả                                                                               |
| ------------------------ | ----------------------------------------------------------------------------------- |
| `SHUTDOWN NORMAL`        | Đợi tất cả session user thoát. Không force.                                         |
| `SHUTDOWN IMMEDIATE`     | Hủy mọi transaction đang chạy, rollback nếu cần, tắt sạch sẽ. **Khuyến nghị dùng.** |
| `SHUTDOWN TRANSACTIONAL` | Đợi các transaction hiện tại hoàn tất. Không nhận kết nối mới.                      |
| `SHUTDOWN ABORT`         | Dừng ngay lập tức. Không đảm bảo nhất quán. Dùng khi khẩn cấp.                      |

```bash
-- Với quyền SYSDBA
sqlplus / as sysdba

-- Tắt tức thì, an toàn
SHUTDOWN IMMEDIATE;

-- đợi tất cả session user thoát
SHUTDOWN NORMAL;

-- đơi các transaction hiện tại hoàn tất
SHUTDOWN TRANSACTIONAL;

-- tắt ngay lập tức
SHUTDOWN ABORT;
```

### 4. Kiểm tra trạng thái CSDL và instance:

```bash
SELECT instance_name, status FROM v$instance;
SELECT name, open_mode FROM v$database;
```

Lưu ý:
Cần có quyền SYSDBA để thực hiện STARTUP và SHUTDOWN.

Trên môi trường Linux/Unix, bạn cần phải đặt ORACLE_SID trước:

```bash
export ORACLE_SID=YOUR_DB_NAME
sqlplus / as sysdba
```
