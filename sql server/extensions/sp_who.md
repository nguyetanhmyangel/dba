### 1. sp_who

- Đây là Stored Procedure hệ thống có sẵn trong SQL Server. Nó dùng để xem thông tin về các kết nối (sessions) đang hoạt động trên SQL Server.

- Cách sử dụng:

```bash
EXEC sp_who;
```

- Các cột quan trọng:

	- spid: Session ID (mỗi kết nối vào SQL có 1 SPID)      
	
	- status: Trạng thái của session (`running`, `sleeping`, `background`) 	
	
	- loginame: Tên login đang kết nối     
	
	- hostname: Tên máy tính kết nối        
	
	- blk: SPID đang chặn session này (nếu có)        
	
	- dbname: Database mà session đang dùng         
	
	- cmd: Lệnh đang chạy (`SELECT`, `UPDATE`, `AWAITING COMMAND`,...)  	
	
	- request_id: Đây là ID của request trong một session. Một session (SPID) có thể chứa nhiều request (trong trường hợp MARS – Multiple Active Result Sets). Giá trị: bằng 1 → request chính, lớn hơn 1 → nếu session đó có nhiều request đang chạy đồng thời (MARS bật). Nếu MARS không bật, thường chỉ thấy request_id = 0 hoặc 1.	
	
	- ecid (Execution Context ID): Đây là ID ngữ cảnh thực thi của một thread trong một session.Khi bạn có song song (parallelism), một session có thể có nhiều thread cùng thực thi.
		Giá trị: bằng 0 → là main thread (luồng chính). lớn hơn 0 → là additional threads được tạo cho việc thực thi song song.                      


- Ý nghĩa một số status

	- running → Đang chạy query.

	- sleeping → Đang rảnh (chờ lệnh).

	- rollback → Đang rollback transaction.

	- background → Tiến trình nền.

- Điểm yếu

	- Ít thông tin chi tiết (không thấy query đang chạy).

	- Không có thời gian chạy query.

	- Không có thông tin về I/O, Waits.
	
### 2. sp_who2 (bản nâng cấp nhẹ của sp_who)

- Cách sử dụng:

```bash
EXEC sp_who2;
```

- Thêm các cột như:

	- CPUTime → Thời gian CPU dùng.

	- DiskIO → Lượng I/O.

	- LastBatch → Lần cuối session chạy query.