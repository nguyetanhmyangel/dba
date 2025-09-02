### 1, Memory

#### 1.1 Kiểm tra cấu hình Max Server Memory và chừa RAM cho OS

```bash
-- Xem cấu hình max/min server memory (MB)
EXEC sp_configure 'show advanced options', 1;
RECONFIGURE;
EXEC sp_configure 'max server memory (MB)';
EXEC sp_configure 'min server memory (MB)';
```

Cách đọc:

- max server memory (MB) = giới hạn tối đa SQL Server được dùng.

- Khuyến nghị: Để chừa RAM cho OS, ví dụ server có 64 GB, để 56 GB cho SQL và chừa 8 GB cho OS và các dịch vụ khác.

#### 1.2. Check Available OS Memory

```bash
-- Memory của hệ điều hành
SELECT total_physical_memory_kb/1024 AS Total_Physical_MB,
       available_physical_memory_kb/1024 AS Available_Physical_MB,
       total_page_file_kb / 1024 AS Total_Page_File_MB,
       system_memory_state_desc
FROM sys.dm_os_sys_memory;
```

Cách đọc:

- Available_Physical_MB: RAM còn trống của OS. Nếu < 5% tổng RAM → thiếu RAM.

- system_memory_state_desc: NORMAL (ổn), LOW (thiếu).

- physical_memory_in_use_kb: RAM SQL Server đang dùng

#### 1.3. Check Total vs Target Server Memory

```bash
-- Memory SQL Server đang dùng vs target
SELECT (total_physical_memory_kb/1024) AS Total_Physical_MB,
       (committed_kb/1024) AS SQL_Committed_MB,
       (committed_target_kb/1024) AS SQL_Target_MB
FROM sys.dm_os_sys_info;
```

Cách đọc:

- SQL_Committed_MB = SQL đang dùng.

- SQL_Target_MB = SQL muốn dùng.

- Nếu Committed ≈ Target → SQL đã đạt ngưỡng memory được phép.

- Nếu Target < Max Configured → SQL chưa cần thêm memory.

#### 1.4. Kiểm tra Page Life Expectancy (PLE)

```bash
-- PLE theo từng NUMA node
SELECT object_name, counter_name, cntr_value AS PLE_Seconds
FROM sys.dm_os_performance_counters
WHERE counter_name = 'Page life expectancy';
```

Cách đọc:

- PLE = số giây một page tồn tại trong buffer pool trước khi bị thay thế.

- Chuẩn cũ: PLE > 300 giây (5 phút) là ổn (cho mỗi NUMA node).

- Nếu PLE < 300 thường xuyên → thiếu memory hoặc query load cao.

#### 1.5. Check Memory Grants Pending

```bash
-- Memory grants pending = số session đang chờ cấp memory cho sort/hash
SELECT *
FROM sys.dm_exec_query_memory_grants
WHERE grant_time IS NULL;
```

Hoặc chỉ số tổng quan:

```bash
SELECT cntr_value AS Memory_Grants_Pending
FROM sys.dm_os_performance_counters
WHERE counter_name = 'Memory Grants Pending';
```


Cách đọc:

- Memory_Grants_Pending > 0 lâu dài → thiếu memory hoặc query cần nhiều memory (hash join, sort).

#### 1.6. Kiểm tra wait type RESOURCE_SEMAPHORE

```bash
SELECT wait_type, waiting_tasks_count, wait_time_ms
FROM sys.dm_os_wait_stats
WHERE wait_type = 'RESOURCE_SEMAPHORE';
```

Cách đọc:

- Nếu RESOURCE_SEMAPHORE cao → session bị chờ cấp memory cho sort/hash → memory pressure.

#### 1.7. Kiểm tra Buffer Pool Hit Ratio

```bash
SELECT counter_name, cntr_value
FROM sys.dm_os_performance_counters
WHERE counter_name = 'Buffer cache hit ratio';
```

Cách đọc:

- Giá trị lý tưởng > 95%.

- Nếu < 90% → SQL phải đọc nhiều từ disk → thiếu memory hoặc query không tối ưu.

