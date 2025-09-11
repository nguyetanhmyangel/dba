### 1. sp_Blitz 

Là công cụ kiểm tra sức khỏe tổng thể của SQL Server:  phát hiện các vấn đề về cấu hình:  bảo mật:  hiệu suất:  và độ tin cậy. Nó trả về danh sách các vấn đề được ưu tiên theo mức độ nghiêm trọng.

Tham số chính:

	- @CheckUserDatabaseObjects: Kiểm tra các đối tượng trong database người dùng (1: có:  0: không).
	- @CheckServerInfo: Hiển thị thông tin cấu hình server (1: có:  0: không).
	- @SkipChecksDatabase: Bỏ qua một database cụ thể khi kiểm tra.
	- @SkipChecksSchema: Bỏ qua một schema cụ thể.
	- @SkipChecksTable: Bỏ qua một bảng cụ thể.
	- @OutputDatabaseName: Lưu kết quả vào database được chỉ định.
	- @OutputSchemaName: Schema của bảng lưu kết quả.
	- @OutputTableName: Tên bảng lưu kết quả.
	
Ví dụ sử dụng:

1. Chạy cơ bản:

```bash
EXEC sp_Blitz
```

Kết quả: Danh sách các vấn đề với mức độ ưu tiên (Priority), nhóm vấn đề (FindingsGroup), và URL chi tiết để khắc phục.

2. Kiểm tra tất cả database người dùng:

```bash
EXEC sp_Blitz @CheckUserDatabaseObjects = 1
```

- Lưu kết quả vào bảng:

```bash
EXEC sp_Blitz @OutputDatabaseName = 'DBAtools', @OutputSchemaName = 'dbo', @OutputTableName = 'BlitzResults'
```

3. Ứng dụng thực tế:

- Kiểm tra cấu hình sai (ví dụ: quyền sa không an toàn, thiếu sao lưu).
- Phát hiện các vấn đề như auto-shrink, max memory không tối ưu.
- Lưu kết quả để theo dõi định kỳ.


### 2. sp_BlitzCache

Phân tích bộ nhớ cache của kế hoạch thực thi để tìm các truy vấn tiêu tốn nhiều tài nguyên (CPU, reads, writes, v.v.).
Tham số chính:

- @SortOrder: Sắp xếp kết quả theo (cpu, reads, writes, duration, executions).
- @Top: Số lượng truy vấn hiển thị (mặc định: 10).@ExpertModeHiển thị thông tin chi tiết hơn (1: có, 0: không).
- @DatabaseName: Chỉ kiểm tra truy vấn từ một database cụ thể.@OutputDatabaseNameLưu kết quả vào database được chỉ định.

Ví dụ sử dụng:

- Tìm 10 truy vấn tiêu tốn CPU nhiều nhất:

```bash
EXEC sp_BlitzCache @SortOrder = 'cpu', @Top = 10
```

- Kiểm tra truy vấn trong database cụ thể:

```bash
EXEC sp_BlitzCache @DatabaseName = 'AdventureWorks', @ExpertMode = 1
```

- Lưu kết quả vào bảng:

```bash
EXEC sp_BlitzCache @OutputDatabaseName = 'DBAtools', @OutputSchemaName = 'dbo', @OutputTableName = 'BlitzCache_Results'
```

Ứng dụng thực tế:

- Xác định các truy vấn chậm cần tối ưu hóa.
- Tìm các truy vấn gây ra parameter sniffing hoặc sử dụng bộ nhớ lớn.
- Phân tích lịch sử truy vấn để cải thiện hiệu suất.

### 3. sp_BlitzFirst

Theo dõi hiệu suất SQL Server theo thời gian thực, cung cấp thông tin về wait stats, file stats, Perfmon counters, và các truy vấn đang chạy (gọi sp_BlitzWho bên trong).

Tham số chính:

- @ExpertMode: Hiển thị dữ liệu chi tiết hơn (wait stats, file stats, v.v.) (1: có, 0: không).
- @Seconds: Thời gian lấy mẫu (mặc định: 5 giây).
- @SinceStartup: Hiển thị số liệu từ khi server khởi động (1: có, 0: không).
- @OutputDatabaseName: Lưu kết quả vào database được chỉ định.
- @OutputTableNameWaitStats: Tên bảng lưu wait stats.
- @OutputTableNameFileStats: Tên bảng lưu file stats.
- @OutputTableNamePerfmonStats: Tên bảng lưu Perfmon counters.

Ví dụ sử dụng:

- Chạy cơ bản với mẫu 5 giây:

```bash
EXEC sp_BlitzFirst
```

- Chạy ở chế độ chuyên gia với mẫu 30 giây:

```bash
EXEC sp_BlitzFirst @ExpertMode = 1, @Seconds = 30
```

Lưu kết quả vào bảng:

```bash
EXEC sp_BlitzFirst 
    @OutputDatabaseName = 'DBAtools', 
    @OutputSchemaName = 'dbo', 
    @OutputTableName = 'BlitzFirstResults', 
    @OutputTableNameFileStats = 'BlitzFirst_FileStats', 
    @OutputTableNameWaitStats = 'BlitzFirst_WaitStats'
```

Ứng dụng thực tế:

- Theo dõi hiệu suất tức thời khi server chạy chậm.
- Phân tích wait stats để xác định nguyên nhân tắc nghẽn.
- Lưu dữ liệu để phân tích xu hướng hiệu suất.

### 4. sp_BlitzIndex

Phân tích chỉ mục của database, phát hiện các vấn đề như chỉ mục trùng lặp, không sử dụng, hoặc thiếu.

Tham số chính:

- @DatabaseName: Database cần kiểm tra.
- @GetAllDatabases: Kiểm tra tất cả database (1: có, 0: không).
- @Mode: Chế độ kiểm tra (0: cơ bản, 1: tóm tắt, 2: chi tiết, 4: chỉ missing indexes).
- @ThresholdMB: Kích thước tối thiểu của đối tượng (MB) để hiển thị (mặc định: 250).
- @OutputDatabaseName: Lưu kết quả vào database được chỉ định.

Ví dụ sử dụng:

- Kiểm tra chỉ mục trong một database:

```bash
EXEC sp_BlitzIndex @DatabaseName = 'AdventureWorks'
```

- Kiểm tra tất cả database:

```bash
EXEC sp_BlitzIndex @GetAllDatabases = 1
```

- Lấy thông tin chi tiết (Mode 2):

```bash
EXEC sp_BlitzIndex @DatabaseName = 'AdventureWorks', @Mode = 2
```

- Lưu kết quả vào bảng:

```bash
EXEC sp_BlitzIndex @OutputDatabaseName = 'DBAtools', @OutputSchemaName = 'dbo', @OutputTableName = 'BlitzIndex_Results'
```

Ứng dụng thực tế:

- Phát hiện chỉ mục trùng lặp hoặc không sử dụng để giảm dung lượng lưu trữ.
- Gợi ý chỉ mục thiếu (missing indexes) để cải thiện hiệu suất truy vấn.
- Kiểm tra các bảng heap hoặc khóa gây blocking.


### 5. sp_BlitzWho

Hiển thị thông tin chi tiết về các session và truy vấn đang chạy, tương tự sp_WhoIsActive nhưng tích hợp với sp_BlitzFirst.

Tham số chính:

- @ExpertMode: Hiển thị thông tin chi tiết hơn (1: có, 0: không).
- @GetLiveQueryPlan: Lấy kế hoạch thực thi trực tiếp (1: có, 0: không).
- @OutputDatabaseName: Lưu kết quả vào database được chỉ định.
- @OutputTableName: Tên bảng lưu kết quả.

Ví dụ sử dụng:

- Chạy cơ bản:

```bash
EXEC sp_BlitzWho
```

- Lấy kế hoạch thực thi:

```bash
EXEC sp_BlitzWho @GetLiveQueryPlan = 1
```

- Lưu kết quả vào bảng:

```bash
EXEC sp_BlitzWho @OutputDatabaseName = 'DBAtools', @OutputSchemaName = 'dbo', @OutputTableName = 'BlitzWho_Results'
```

Ứng dụng thực tế:

- Theo dõi các truy vấn đang chạy trong thời gian thực.
- Xác định các session tiêu tốn tài nguyên hoặc gây blocking.
- Dùng trong sp_BlitzFirst để cung cấp snapshot của các truy vấn.

### 6. Hướng dẫn cách sử dụng & đọc 1 số command:

#### 6.1. Kiểm tra cấu hình & vấn đề tiềm ẩn với sp_Blitz

```bash
EXEC sp_Blitz;
```

Cách đọc kết quả:

- Priority: Độ nghiêm trọng (1 = rất quan trọng)

- Finding: Vấn đề phát hiện

- URL More Info: Link giải thích chi tiết

Ví dụ lỗi thường gặp:

- Max Server Memory not configured → SQL Server dùng toàn bộ RAM.

- Auto Grow set to % → Có thể gây fragmentation.

Fix:

```bash
-- Giới hạn RAM cho SQL
EXEC sys.sp_configure 'max server memory (MB)', 8192;
RECONFIGURE;

-- Chỉnh Auto Growth sang MB
ALTER DATABASE YourDB
MODIFY FILE (NAME = N'YourDB_Data', FILEGROWTH = 512MB);
```

#### 6.2. Giám sát hiệu năng tức thì với sp_BlitzFirst

```bash
EXEC sp_BlitzFirst @Seconds = 30, @ExpertMode = 1;
```

Cách đọc kết quả:

- Waits: Xem loại wait nào chiếm nhiều nhất

- PAGEIOLATCH_* → I/O chậm

- CXPACKET → Parallelism cao

- CPU Utilization: Nếu > 80% → CPU bão hòa

- Memory Grants Pending: > 0 → Thiếu RAM hoặc query lớn

Fix:

- Nếu PAGEIOLATCH cao → Kiểm tra disk subsystem (RAID, SAN)

- Nếu CXPACKET cao → Điều chỉnh:

```bash
EXEC sys.sp_configure 'max degree of parallelism', 4;
EXEC sys.sp_configure 'cost threshold for parallelism', 50;
RECONFIGURE;
```

- Nếu Memory Grants Pending → Thêm RAM hoặc tối ưu query, index.

#### 6.3. CPU cao → Phân tích với sp_BlitzCache

```bash
EXEC sp_BlitzCache @SortOrder = 'cpu', @Top = 10;
```

Cách đọc kết quả:

- Query Text: Tên query

- CPU: CPU time

- Executions: Số lần chạy

- Warnings: Missing index, scalar functions

Fix:

- Nếu thấy Missing Index → Thêm index hợp lý:

```bash
CREATE NONCLUSTERED INDEX IX_Table_Column ON Table(Column);
```

- Tránh Scalar function trong SELECT → Đưa logic vào query hoặc APPLY

- Nếu query chạy nhiều lần nhỏ → dùng parameterization hoặc proc.

#### 6.4. Blocking → Dùng sp_BlitzWho

```bash
EXEC sp_BlitzWho;
```

Cách đọc kết quả:

- BlockedBy: block bởi tác nhân nào

- WaitInfo: Loại wait (LCK_M_S, LCK_M_X)

- QueryText: Query đang chạy

Fix:

- Nếu session bị khóa lâu → KILL:

```bash
KILL 53; -- 53 là session_id
```

- Tối ưu transaction: Commit sớm, giảm batch update lớn.

#### 6.5. Kiểm tra Index với sp_BlitzIndex

```bash
EXEC sp_BlitzIndex @DatabaseName = 'YourDB';
```

Cách đọc kết quả:

- High Value Missing Index: Cần tạo ngay

- Duplicate Index: Nên gộp

- Unused Index: Nên xóa nếu không dùng

Fix:

- Tạo index thiếu:

```bash
CREATE NONCLUSTERED INDEX IX_Table_Column ON Table(Column);
```

- Xóa index không dùng:

```bash
DROP INDEX IX_Table_Column ON Table;
```

#### 6.6. Muốn xem như Activity Monitor nhưng nhanh hơn

```bash
EXEC sp_BlitzWho;      -- Phiên bản gọn nhẹ
-- Hoặc:
EXEC sp_WhoIsActive;   -- Của Adam Machanic
```

Xem:

- wait_info: Loại wait

- tempdb_allocations: TempDB đang bị tiêu tốn

- blocking_session_id: Blocking chain

#### 6.7 Tóm tắt khi gặp sự cố

| Tình huống          | Dùng SP nào        | Tham số                   | Kiểm tra gì?                | Fix gợi ý                |
|---------------------|--------------------|---------------------------|-----------------------------|--------------------------|
| Server chậm         | sp_BlitzFirst      | @Seconds=30, ExpertMode=1 | Waits, CPU, Memory          | Tối ưu query, thêm RAM   |
| CPU cao             | sp_BlitzCache      | @SortOrder='cpu'          | Query CPU cao               | Index, tối ưu plan       |
| Blocking            | sp_BlitzWho        |                           | Ai khóa ai                  | Kill session, tối ưu txn |
| Thiếu RAM           | sp_Blitz           |                           | Max Memory, PLE             | Cấu hình RAM             |
| Index bất hợp lý    | sp_BlitzIndex      | @DatabaseName='YourDB'    | Missing/Duplicate/Unused    | Tạo, xóa index           |

---

#### 6.8 Tài liệu tham khảo

- [First Responder Kit - Brent Ozar](https://www.brentozar.com/first-aid/)
- [sp_Blitz Docs](https://www.brentozar.com/blitz/)
- [sp_BlitzFirst Docs](https://www.brentozar.com/blitzfirst/)
- [sp_BlitzCache Docs](https://www.brentozar.com/blitzcache/)
- [sp_BlitzIndex Docs](https://www.brentozar.com/blitzindex/)
- [sp_BlitzWho Docs](https://www.brentozar.com/blitzwho/)