## Service cho PDB

### Kiểm tra trước khi triển khai

- Xác nhận CDB và PDB đích.
- Xác nhận PDB đang ở trạng thái phù hợp.
- Liệt kê Service hiện có để tránh tạo trùng.
- Xác định Service nào dành cho ứng dụng và Service nào dành cho quản trị.
- Kiểm tra Listener và port đang sử dụng.
- Xác định cách quản lý Service: mặc định, `DBMS_SERVICE`, SRVCTL hoặc công cụ phù hợp khác.
- Xác định yêu cầu tự khởi động sau restart.
- Xác nhận tài khoản ứng dụng chỉ có quyền cần thiết.

### Kiểm tra sau khi triển khai

- Service xuất hiện trong truy vấn database.
- Listener nhận biết Service.
- Client kết nối thành công bằng Service Name.
- Session vào đúng PDB.
- Kiểm tra khả năng kết nối sau khi khởi động lại trong cửa sổ bảo trì được phê duyệt.
- Xác nhận ứng dụng không sử dụng nhầm Service quản trị hoặc Service của môi trường khác.

---