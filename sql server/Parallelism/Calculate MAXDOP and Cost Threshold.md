### 1. Dựa trên khuyến nghị của Microsoft Tính toán giá trị MAXDOP (Max Degree of Parallelism) được khuyến nghị, dựa trên cấu hình phần cứng (Số core logic và số NUMA node).

| Cấu hình hệ thống             | MAXDOP khuyến nghị                                |
| ----------------------------- | ------------------------------------------------- |
| ≤ 8 logical CPUs              | Bằng số logical CPU                               |
| > 8 logical CPUs, 1 NUMA node | 8                                                 |
| > 1 NUMA node                 | Bằng số logical CPU trên mỗi NUMA node (tối đa 8) |
| Hệ thống OLTP                 | Thường 4 hoặc 8                                   |
| Hệ thống Data Warehouse       | 8 hoặc cao hơn nếu cần (nhưng cần test)           |

Giới hạn khuyến nghị:

- MAXDOP không vượt quá 8 (trừ khi hệ thống DW lớn hoặc đã test kỹ)

- Không nên để MAXDOP = 0 (cho phép dùng toàn bộ CPU → dễ gây nghẽn song song)

Cost Threshold for Parallelism với mặc định: 5 → quá thấp với đa số hệ thống hiện đại

Khuyến nghị:

≥ 25 cho hầu hết hệ thống OLTP

≥ 50 cho hệ thống lớn hoặc phức tạp

Nên test tăng dần: 25, 50, 75, v.v., rồi kiểm tra hiệu suất

### 2. Công thức:

```bash
SET NOCOUNT ON;

-- Khai báo các biến cần thiết
DECLARE @TotalLogicalCPUs INT;          -- Tổng số core logic mà SQL Server thấy
DECLARE @NumaNodeCount INT;             -- Số lượng NUMA node
DECLARE @CoresPerNuma INT;              -- Số core logic trên mỗi NUMA node
DECLARE @RecommendedMAXDOP INT;         -- Giá trị MAXDOP được khuyến nghị (kết quả)
DECLARE @CurrentMAXDOP SQL_VARIANT;     -- Giá trị MAXDOP hiện tại của server
DECLARE @CurrentCostThreshold SQL_VARIANT; -- Giá trị Cost Threshold hiện tại

-- 1. Lấy các thông số của server từ Dynamic Management Views (DMVs)
SELECT
    @TotalLogicalCPUs = cpu_count,
    @CurrentMAXDOP = (SELECT value_in_use FROM sys.configurations WHERE name = 'max degree of parallelism'),
    @CurrentCostThreshold = (SELECT value_in_use FROM sys.configurations WHERE name = 'cost threshold for parallelism')
FROM sys.dm_os_sys_info;

SELECT @NumaNodeCount = COUNT(DISTINCT memory_node_id)
FROM sys.dm_os_nodes
WHERE memory_node_id < 64; -- Lọc bỏ node DAC (Dedicated Admin Connection)

-- Đề phòng trường hợp không tìm thấy NUMA node (rất hiếm)
IF @NumaNodeCount = 0 SET @NumaNodeCount = 1;

SET @CoresPerNuma = @TotalLogicalCPUs / @NumaNodeCount;

-- 2. Áp dụng logic khuyến nghị của Microsoft
-- Kịch bản 1: Server chỉ có 1 NUMA node
IF @NumaNodeCount = 1
BEGIN
    SET @RecommendedMAXDOP =
        CASE
            WHEN @TotalLogicalCPUs <= 8 THEN @TotalLogicalCPUs -- Nếu <= 8 core, đặt MAXDOP bằng số core
            ELSE 8 -- Nếu > 8 core, đặt MAXDOP = 8
        END;
END
-- Kịch bản 2: Server có nhiều NUMA node
ELSE
BEGIN
    SET @RecommendedMAXDOP =
        CASE
            WHEN @CoresPerNuma > 8 THEN 8 -- Giới hạn số core mỗi NUMA ở mức 8
            ELSE @CoresPerNuma           -- Đặt MAXDOP bằng số core trên mỗi NUMA
        END;
END

-- 3. Hiển thị kết quả một cách rõ ràng
SELECT
    '------------------------------------------------------------' AS [Phân Tích Cấu Hình MAXDOP],
    GETDATE() AS [Thời Gian Phân Tích];

SELECT
    @TotalLogicalCPUs AS [Tổng Số Core Logic],
    @NumaNodeCount AS [Số Lượng NUMA Node],
    @CoresPerNuma AS [Số Core Logic trên mỗi NUMA],
    @CurrentMAXDOP AS [MAXDOP Hiện Tại],
    @RecommendedMAXDOP AS [==> MAXDOP Khuyến Nghị <==],
    @CurrentCostThreshold AS [Cost Threshold Hiện Tại],
    CASE
        WHEN @CurrentCostThreshold <= 5 THEN 'Nên tăng lên >= 50'
        ELSE 'Đã cấu hình tốt'
    END AS [Ghi Chú Về Cost Threshold];
GO
```

### 3. Set MAXDOP & Cost Threshold

```bash
-- Đặt MAXDOP (ví dụ đặt là 8)
EXEC sp_configure 'show advanced options', 1;
RECONFIGURE;
EXEC sp_configure 'max degree of parallelism', 8;
RECONFIGURE;

-- Đặt Cost Threshold for Parallelism (ví dụ đặt là 50)
EXEC sp_configure 'cost threshold for parallelism', 50;
RECONFIGURE;
```