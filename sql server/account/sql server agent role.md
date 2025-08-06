### 1. Để một người dùng có thể xem và tạo các công việc (jobs) trong SQL Server Agent, bạn cần cấp cho họ các vai trò (roles) cụ thể trong cơ sở dữ liệu msdb.

### 2. Các vai trò liên quan đến SQL Server Agent

| Vai trò trong `msdb`     | Quyền được cấp                                                     |
| ------------------------ | ------------------------------------------------------------------ |
| `SQLAgentUserRole`       | Tạo, sửa, chạy, xóa job **do chính user đó sở hữu**                |
| `SQLAgentReaderRole`     | Xem **tất cả** job (không tạo, không sửa)                          |
| `SQLAgentOperatorRole`   | Xem và chạy tất cả job, xem lịch sử job, nhưng **không chỉnh sửa** |
| `sysadmin` (trên server) | Toàn quyền với tất cả job                                          |


### 3. So sánh các vai trò trong msdb:

| Vai trò (`msdb`)       | Có thể tạo job | Có thể xem job của người khác | Có thể chạy job |
| ---------------------- | -------------- | ----------------------------- | --------------- |
| `SQLAgentUserRole`     | ✅              | ❌                             | ✅ job của mình  |
| `SQLAgentReaderRole`   | ❌              | ✅                             | ❌               |
| `SQLAgentOperatorRole` | ❌              | ✅                             | ✅               |
| `sysadmin`             | ✅              | ✅                             | ✅               |


### 4. Phân quyền user 

```bash
USE msdb;
GO

-- Thêm user vào msdb
CREATE USER [agent_user] FOR LOGIN [agent_user];

-- Cấp quyền SQLAgentUserRole cho user
EXEC sp_addrolemember N'SQLAgentUserRole', N'UserName';

-- Cấp quyền SQLAgentReaderRole cho user
EXEC sp_addrolemember N'SQLAgentReaderRole', N'UserName';

-- Cấp quyền SQLAgentOperatorRole cho user
EXEC sp_addrolemember N'SQLAgentOperatorRole', N'UserName';
```