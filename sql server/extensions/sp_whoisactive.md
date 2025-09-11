### sp_whoisactive

- Cách sử dụng:

```bash
EXEC sp_whoisactive;
```

- Một stored procedure mạnh mẽ và phổ biến được phát triển bởi Adam Machanic để giám sát hoạt động trên SQL Server. Nó cung cấp thông tin chi tiết về các phiên (sessions), truy vấn (queries), và hiệu suất hệ thống theo thời gian thực. Dưới đây là hướng dẫn chi tiết và dễ hiểu nhất về cách sử dụng sp_WhoIsActive để giám sát SQL Server.

- Công dụng:  
	- Xem các phiên (sessions) hiện đang chạy trên SQL Server.
	- Xác định các truy vấn chậm, bị chặn (blocking), hoặc tiêu tốn tài nguyên.
	- Thu thập thông tin chi tiết như kế hoạch thực thi (execution plan), tài nguyên sử dụng, và trạng thái khóa (locks).
	- Lưu trữ dữ liệu vào bảng để phân tích sau này.

- Các tham số:
	- @filter: Lọc theo giá trị cụ thể (ví dụ: session_id:  database_name).
	- @filter_type: Loại bộ lọc (session:  program:  login:  database:  host).
	- @not_filter: Loại trừ giá trị cụ thể.
	- @not_filter_type: Loại bộ lọc loại trừ (session:  program:  login:  database:  host).
	- @show_own_spid: Hiển thị thông tin về session của chính bạn (mặc định: 0 - không hiển thị).
	- @show_system_spids: Hiển thị các session hệ thống (mặc định: 0 - không hiển thị).
	- @show_sleeping_spids: Hiển thị các session đang ngủ (0: không hiển thị:  1: chỉ thông tin cơ bản:  2: đầy đủ).
	- @get_full_inner_text: Lấy toàn bộ văn bản của truy vấn (mặc định: 0 - chỉ lấy phần đầu).
	- @get_plans: Lấy kế hoạch thực thi (0: không:  1: kế hoạch ước tính:  2: kế hoạch thực tế).
	- @get_outer_command: Lấy lệnh bên ngoài (batch) chứa truy vấn (mặc định: 0 - không lấy).
	- @get_transaction_info: Lấy thông tin giao dịch (mặc định: 0 - không lấy).
	- @get_task_info: Lấy thông tin tác vụ (0: không:  1: cơ bản:  2: chi tiết).
	- @get_locks: Lấy thông tin về khóa (locks) (mặc định: 0 - không lấy).
	- @get_avg_time: Tính thời gian trung bình cho các truy vấn (mặc định: 0 - không tính).
	- @get_additional_info: Lấy thông tin bổ sung như tempdb:  CPU:  đọc/ghi (mặc định: 0 - không lấy).
	- @find_block_leaders: Tìm các session gây ra blocking (mặc định: 0 - không tìm).
	- @sort_order: Sắp xếp kết quả (ví dụ: [CPU] DESC:  [reads] ASC).
	- @delta_interval: Chạy sp_WhoIsActive ở chế độ delta (theo dõi thay đổi sau mỗi khoảng thời gian:  đơn vị: giây).
	- @output_column_list: Tùy chỉnh cột hiển thị trong kết quả (ví dụ: [session_id][sql_text]).
	- @destination_table: Lưu kết quả vào một bảng thay vì hiển thị trực tiếp.
	- @return_schema: Trả về lược đồ (schema) của bảng kết quả (mặc định: 0 - không trả về).
	- @schema: Xác định lược đồ của bảng đích khi lưu kết quả.
	- @help: Hiển thị thông tin trợ giúp về sp_WhoIsActive (mặc định: 0).
	

- Các cột hiển thị:

	- session_id: ID của session.
	- sql_text: Truy vấn đang thực thi.
	- status: Trạng thái của session (running, sleeping, suspended,...).
	- percent_complete: Phần trăm hoàn thành (nếu có).
	- host_name, login_name, database_name: Thông tin về máy chủ, người dùng, và database.
	- wait_info: Thông tin về thời gian chờ (wait time).
	- CPU, reads, writes: Tài nguyên sử dụng.


- Để chỉ xem các session liên quan đến một database (ví dụ: AdventureWorks):

```bash
sqlEXEC sp_WhoIsActive @filter = 'AdventureWorks', @filter_type = 'database'
```
Kết quả: Chỉ hiển thị các session liên quan đến database AdventureWorks.

- Xem các session gây blocking

```bash
sqlEXEC sp_WhoIsActive @find_block_leaders = 1
```
Kết quả: Hiển thị các session đang khóa (blocking) session khác, bao gồm thông tin về blocking_session_id.

- Lấy kế hoạch thực thi (execution plan)

```bash
sqlEXEC sp_WhoIsActive @get_plans = 1
```
Kết quả: Thêm cột query_plan chứa kế hoạch thực thi dạng XML. Bạn có thể nhấp vào để xem chi tiết trong SSMS.

- Lưu kết quả vào bảng để phân tích

```bash
sqlEXEC sp_WhoIsActive @destination_table = 'dbo.WhoIsActive_Log'
```

Lưu ý: Bảng dbo.WhoIsActive_Log phải được tạo trước với cấu trúc phù hợp. Để lấy cấu trúc bảng:

```bash
sqlEXEC sp_WhoIsActive @return_schema = 1, @schema = @destination_table
```bash

Sau đó, sử dụng câu lệnh CREATE TABLE được trả về để tạo bảng.

- Theo dõi thay đổi theo thời gian (Delta Mode). Để chạy sp_WhoIsActive ở chế độ delta (theo dõi thay đổi sau mỗi 5 giây):

```bash
sqlEXEC sp_WhoIsActive @delta_interval = 5
```bash

Kết quả: Hiển thị các thay đổi trong hoạt động của session sau mỗi 5 giây, hữu ích để theo dõi các truy vấn dài.

- Tùy chỉnh cột đầu ra

```bash
sqlEXEC sp_WhoIsActive @output_column_list = '[session_id][sql_text][CPU]'
```

- Xem thông tin chi tiết về tài nguyên

```bash
sqlEXEC sp_WhoIsActive @get_additional_info = 1
```

Kết quả: Thêm các cột như tempdb_allocations, tempdb_current, used_memory.

- Kết hợp nhiều tham số

```bash
sqlEXEC sp_WhoIsActive 
    @filter = 'AdventureWorks', 
    @filter_type = 'database', 
    @get_plans = 1, 
    @get_locks = 1
```

- Xác định truy vấn chậm: sử dụng @sort_order = '[CPU] DESC' hoặc @sort_order = '[reads] DESC' để tìm các truy vấn tiêu tốn nhiều tài nguyên.

```bash
sqlEXEC sp_WhoIsActive @sort_order = '[CPU] DESC'
```

- Giám sát blocking, dùng @find_block_leaders = 1 để xác định session gây khóa và truy vấn liên quan. Kiểm tra cột blocking_session_id và wait_info.


- Theo dõi tiến độ của các truy vấn dài. Sử dụng cột percent_complete để theo dõi tiến độ của các tác vụ như sao lưu, khôi phục, hoặc kiểm tra database.


- Tạo job tự động để giám sát:

	Tạo một SQL Server Agent Job để chạy sp_WhoIsActive định kỳ và lưu kết quả vào bảng để phân tích sau này.

	- Bước 1: Tạo bảng lưu kết quả:
	sqlCREATE TABLE dbo.WhoIsActive_Log (
		[collection_time] [datetime] NULL,
		[session_id] [smallint] NOT NULL,
		[sql_text] [nvarchar](max) NULL,
		[status] [nvarchar](30) NULL,
		[login_name] [nvarchar](128) NULL,
		[host_name] [nvarchar](128) NULL,
		[database_name] [nvarchar](128) NULL,
		[CPU] [bigint] NULL,
		[reads] [bigint] NULL,
		[writes] [bigint] NULL,
		[wait_info] [nvarchar](4000) NULL,
		[percent_complete] [float] NULL,
		[blocking_session_id] [smallint] NULL,
		[query_plan] [xml] NULL,
		[locks] [xml] NULL
	)

	- Bước 2: Tạo job trong SQL Server Agent:

	Mở SSMS, vào SQL Server Agent > Jobs > New Job.

	Tạo một bước (Step) với lệnh:

	```bash
	sqlEXEC sp_WhoIsActive @destination_table = 'dbo.WhoIsActive_Log', @get_plans = 1, @get_locks = 1
	```

	Thiết lập lịch chạy (Schedule) (ví dụ: mỗi 5 phút).

	- Bước 3: Phân tích dữ liệu:

	Sử dụng truy vấn để phân tích dữ liệu từ bảng dbo.WhoIsActive_Log:

	```bash
	sqlSELECT collection_time, session_id, sql_text, CPU, reads, writes
	FROM dbo.WhoIsActive_Log
	WHERE collection_time >= DATEADD(HOUR, -1, GETDATE())
	ORDER BY CPU DESC
```

- Lưu ý khi sử dụng sp_WhoIsActive

	- Hiệu suất: Chạy sp_WhoIsActive với quá nhiều tham số (như @get_plans, @get_locks) có thể tiêu tốn tài nguyên. Sử dụng cẩn thận trên hệ thống tải nặng.
	- Quyền truy cập: Yêu cầu quyền VIEW SERVER STATE để chạy sp_WhoIsActive. Nếu cần thêm thông tin khóa, cần quyền VIEW DATABASE STATE.