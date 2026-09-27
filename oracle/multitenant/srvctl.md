### srvctl là công cụ quan trọng nhất để DBA quản lý các tài nguyên (database, listener, ASM, service...). Nó là lớp quản lý phía trên SQLPlus, được Oracle RestartClusterware sử dụng.

### Phân quyền sử dụng srvctl
- ASM, Listener, Diskgroup, toàn bộ tài nguyên Grid Infrastructure
	- User chạy lệnh: grid
	- $ORACLE_HOME: /u01/app/19.0.0/grid (Grid Infrastructure Home)

- Database, Service, Instance
	- User chạy lệnh: oracle
	- $ORACLE_HOME: /u01/app/oracle/product/19.0.0/dbhome_1 (Database Home)
		
### Kiểm tra cấu hình tổng quan hệ thống

#### 1. User thực hiện: grid (Khuyên dùng) hoặc oracle

- Liệt kê toàn bộ Database đang được quản lý:
```Bash
srvctl config database
```
Kết quả ví dụ:
```Plaintext
ORCLCDB
TESTCDB
```

- Xem cấu hình chi tiết của một Database cụ thể:
```Bash
srvctl config database -db ORCLCDB
```
Kết quả ví dụ:
```Plaintext
Database unique name: ORCLCDB
Oracle home: /u01/app/oracle/product/19.0.0/dbhome_1
Oracle user: oracle
Spfile: +DATA/ORCLCDB/PARAMETERFILE/spfile.ora
Start options: open
Stop options: immediate
Management policy: AUTOMATIC
```

- Kiểm tra trạng thái của TOÀN BỘ tài nguyên hệ thống (Sử dụng tiện ích CRS):
```Bash
crsctl stat res -t
```

#### 2. Quản lý trạng thái và khởi động Database
- User thực hiện: oracle (Hoặc grid)

- Kiểm tra trạng thái Database:
```Bash
srvctl status database -db ORCLCDB
```
Kết quả ví dụ: Instance ORCLCDB is running on node oracle-lab hoặc Instance ORCLCDB is not running.

- Khởi động Database lên chế độ thông thường (OPEN):
```Bash
srvctl start database -db ORCLCDB
```

- Khởi động Database ở chế độ MOUNT:
```Bash
srvctl start database -db ORCLCDB -startoption mount
```

- Khởi động Database ở chế độ NOMOUNT:
```Bash
srvctl start database -db ORCLCDB -startoption nomount
```

- Tắt Database an toàn (Mặc định là IMMEDIATE):
```Bash
srvctl stop database -db ORCLCDB
```

- Tắt Database khẩn cấp (ABORT) - Dùng khi DB bị treo không thể shutdown thông thường:
```Bash
srvctl stop database -db ORCLCDB -stopoption abort
```

- Khởi động lại nhanh Database (Tự động Tắt tắt/Bật lại trong 1 dòng lệnh):
```Bash
srvctl restart database -db ORCLCDB
```

- Khởi động lại ép buộc (Dùng khi bảo trì gấp mà DB đang có session treo):
```Bash
srvctl restart database -db ORCLCDB -stopoption abort
```
#### 3. Quản lý ASM (Automatic Storage Management)
- User thực hiện: Bắt buộc dùng grid

- Kiểm tra trạng thái ASM:
```Bash
srvctl status asm
```

- Xem chi tiết trạng thái ASM (Hiển thị các client đang kết nối):
```Bash
srvctl status asm -detail
```

- Khởi động ASM:
```Bash
srvctl start asm
```

- Tắt ASM:
```Bash
srvctl stop asm
```

#### 4. Quản lý Đĩa (ASM Disk Group)
- User thực hiện: Bắt buộc dùng grid

- Kiểm tra trạng thái một Disk Group cụ thể:
```Bash
srvctl status diskgroup -diskgroup DATA
```
Kết quả ví dụ: Disk group DATA is running on oracle-lab

- Mount một Disk Group:
```Bash
srvctl start diskgroup -diskgroup DATA
```

- Dismount một Disk Group (Phục vụ bảo trì Storage/SAN):
```Bash
srvctl stop diskgroup -diskgroup DATA
```

#### 5. Quản lý Listener
- User thực hiện: Bắt buộc dùng grid

- Kiểm tra trạng thái Listener:
```Bash
srvctl status listener
```

- Xem cấu hình Listener (Cổng, đường dẫn Home):
```Bash
srvctl config listener
```

- Khởi động Listener:
```Bash
srvctl start listener
```

- Tắt Listener:
```Bash
srvctl stop listener
```

#### 6. Quản lý Database Services (Ứng dụng kết nối)
- User thực hiện: oracle

- Kiểm tra trạng thái tất cả các Service thuộc Database:
```Bash
srvctl status service -db ORCLCDB
```

- Khởi động một Service cụ thể:
```Bash
srvctl start service -db ORCLCDB -service orclpdb_svc
```

- Tắt một Service cụ thể:
```Bash
srvctl stop service -db ORCLCDB -service orclpdb_svc
```

#### 7. Cấu hình tự động khởi động cùng OS (Policy)
- User thực hiện: oracle (Hoặc grid)

- Bật tính năng tự động khởi động DB khi reboot Server:
```Bash
srvctl enable database -db ORCLCDB
```

- Tắt tính năng tự động khởi động DB (Rất quan trọng khi chuẩn bị OS Maintenance, tránh DB tự lên khi OS chưa ổn định):
```Bash
srvctl disable database -db ORCLCDB
```

#### 8. Thêm / Xóa / Sửa đổi tài nguyên trong Oracle Restart
- User thực hiện: oracle khi thao tác với Database; grid khi thao tác với Listener/ASM.

- Đăng ký một Database mới (Tạo thủ công hoặc bị mất cấu hình) vào Oracle Restart:
```Bash
srvctl add database -db ORCLCDB -oraclehome /u01/app/oracle/product/19.0.0/dbhome_1 -spfile +DATA/ORCLCDB/PARAMETERFILE/spfile.ora
```

- Cập nhật cấu hình khi di chuyển SPFILE sang vị trí mới:
```Bash
srvctl modify database -db ORCLCDB -spfile +RECO/ORCLCDB/PARAMETERFILE/spfile.ora
```

- Cập nhật cấu hình khi nâng cấp Oracle Home (Ví dụ nâng cấp RU lên dbhome_2):
```Bash
srvctl modify database -db ORCLCDB -oraclehome /u01/app/oracle/product/19.0.0/dbhome_2
```

- Hủy đăng ký (Xóa cấu hình quản lý) Database khỏi Oracle Restart (Lưu ý: Không xóa file dữ liệu dưới đĩa):
```Bash
srvctl remove database -db ORCLCDB
```

#### 9. Quản lý biến môi trường của Database (Environment Variables)
- User thực hiện: oracle

Có nhiều trường hợp DB không khởi động được qua srvctl do lệch múi giờ hoặc thiếu thư viện. Nhóm lệnh này giúp xử lý triệt để:

- Xem các biến môi trường hiện tại của Database:
```Bash
srvctl getenv database -db ORCLCDB
```

- Thiết lập biến môi trường (Ví dụ cấu hình múi giờ Việt Nam):
```Bash
srvctl setenv database -db ORCLCDB -envs "TZ=Asia/Ho_Chi_Minh"
```

- Xóa bỏ một biến môi trường đã thiết lập:
```Bash
srvctl unsetenv database -db ORCLCDB -envs "TZ"
```

#### 10. Đồng bộ trạng thái khi có sự cố (Troubleshooting)
- User thực hiện: oracle

- Đồng bộ lại trạng thái thực tế: Trong trường hợp Database bị crash đột ngột hoặc DBA lỡ tay kill -9 tiến trình ở mức OS, Oracle Restart có thể bị bối rối về trạng thái thông tin (Misaligned state). Dùng lệnh sau để đồng bộ lại mà không làm ảnh hưởng đến tiến trình đang chạy:
```Bash
srvctl update database -db ORCLCDB
```

### KỊCH BẢN VẬN HÀNH THỰC TẾ (QUY TRÌNH CHUẨN ĐÚNG USER)

#### Kịch bản 1: Quy trình tắt hệ thống chuẩn để BẢO TRÌ SERVER

- Đăng nhập oracle: Tắt toàn bộ các database.

```Bash
srvctl stop database -db ORCLCDB
```

- Đăng nhập grid: Tắt Listener, các Diskgroup và ASM.
```Bash
srvctl stop listener
srvctl stop diskgroup -diskgroup DATA
srvctl stop asm
```

- Đăng nhập root: Tiến hành Reboot hoặc Shutdown Server.

#### Kịch bản 2: Quy trình kiểm tra và bật hệ thống SAU KHI REBOOT SERVER

- Đăng nhập grid: Kiểm tra hạ tầng đã tự động lên hết chưa.
```Bash
crsctl stat res -t
```

- Nếu ASM hoặc Listener chưa lên, dùng user grid để bật:
```Bash
srvctl start asm
srvctl start listener
```

- Đăng nhập oracle: Kiểm tra trạng thái Database, nếu chưa lên (do cấu hình MANUAL) thì thực hiện bật:
```Bash
srvctl status database -db ORCLCDB
srvctl start database -db ORCLCDB
```