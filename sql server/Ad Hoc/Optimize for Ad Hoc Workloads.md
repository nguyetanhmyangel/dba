### 1.Ad Hoc trong SQL Server là các truy vấn động được gửi trực tiếp đến SQL Server mà không dùng tham số hóa hoặc stored procedure.

Ví dụ:

SELECT * FROM Orders WHERE OrderID = 1001;

SELECT * FROM Orders WHERE OrderID = 1002;

Hai câu lệnh này khác nhau về giá trị, nên SQL Server sẽ tạo hai execution plan riêng biệt, dẫn đến việc tốn nhiều bộ nhớ trong plan cache.

Tác động:

- Bình thường: Khi SQL Server nhận một câu query được tham số hóa (ví dụ: ...WHERE Id = @p0), nó sẽ tạo ra một "kế hoạch thực thi" (execution plan) và lưu vào bộ nhớ đệm (plan cache). Lần sau, dù bạn truyền giá trị @p0 là 100 hay 200, SQL Server vẫn tái sử dụng kế hoạch đã có, rất nhanh và tiết kiệm bộ nhớ.

- Với query ad-hoc: Mỗi câu query (...WHERE Id = 100, ...WHERE Id = 200) được xem là một câu query hoàn toàn mới và độc nhất. SQL Server phải tạo một kế hoạch thực thi riêng cho từng câu và lưu tất cả vào cache.

Kết quả là bộ nhớ đệm bị lấp đầy bởi hàng ngàn kế hoạch chỉ được dùng một lần duy nhất, gây lãng phí bộ nhớ nghiêm trọng và làm chậm hiệu năng hệ thống..

Cách xử lý:

1. Bật optimize for ad hoc workloads: Khi ON, SQL Server sẽ chỉ lưu stub plan cho truy vấn Ad Hoc lần đầu (chỉ tốn vài KB). Nếu truy vấn chạy lần 2, nó mới compile full plan.

- Khi bật tùy chọn này:

    - Lần đầu tiên một câu query ad-hoc chạy, SQL Server không lưu toàn bộ kế hoạch thực thi. Thay vào đó, nó chỉ lưu một "mẩu kế hoạch" (plan stub) rất nhỏ, giống như một cái bookmark.

    - Chỉ khi nào câu query y hệt đó chạy lần thứ hai, SQL Server mới nói: "À, câu này được dùng lại", và lúc đó nó mới tạo và lưu trữ kế hoạch thực thi đầy đủ.

    - Việc này giúp ngăn chặn bộ nhớ đệm bị lấp đầy bởi các kế hoạch chỉ dùng một lần.

Bật "Optimize for Ad Hoc Workloads" được xem là một trong những "best practice" cho hầu hết các hệ thống SQL Server hiện đại.

Lợi ích:

- Bảo vệ bộ nhớ: Nó là một "lưới an toàn" cực kỳ hiệu quả để chống lại vấn đề "plan cache bloating", dù cho ứng dụng của bạn có sử dụng query ad-hoc hay không.

- Rủi ro thấp: Chi phí hiệu năng để tạo ra "plan stub" là không đáng kể. Lợi ích về việc tiết kiệm bộ nhớ và giữ cho plan cache sạch sẽ lớn hơn rất nhiều so với chi phí nhỏ này.

- An toàn cho mọi môi trường: Ngay cả khi ứng dụng của bạn được tham số hóa hoàn hảo, vẫn có thể có các script bảo trì, các truy vấn kiểm tra của quản trị viên, hoặc các công cụ khác chạy các query ad-hoc. Tùy chọn này bảo vệ bạn khỏi tất cả chúng.

```bash
-- Chạy trên database master
sp_configure 'show advanced options', 1;
GO
RECONFIGURE;
GO
sp_configure 'optimize for ad hoc workloads', 1;
GO
RECONFIGURE;
GO
```

2. Parameterization: Tự động hoặc ép buộc SQL Server dùng tham số để tái sử dụng execution plan (ví dụ: SELECT * FROM Orders WHERE OrderID = @p1).


### 2. Chẩn đoán xem máy chủ của mình có đang bị lãng phí bộ nhớ bởi các truy vấn ad-hoc dùng một lần hay không, từ đó đưa ra quyết định có nên bật Optimize for Ad Hoc Workloads.

```bash
WITH PlanCacheStats AS (
    SELECT
        objtype,
        usecounts,
        size_in_bytes
    FROM sys.dm_exec_cached_plans
    WHERE objtype = 'Adhoc'
      AND cacheobjtype = 'Compiled Plan'
)
SELECT
    COUNT(*) AS total_adhoc_plans,
    SUM(CASE WHEN usecounts = 1 THEN 1 ELSE 0 END) AS single_use_plans,
    CAST(SUM(CASE WHEN usecounts = 1 THEN 1 ELSE 0 END) * 100.0 / COUNT(*) AS DECIMAL(5, 2)) AS pct_single_use_plans,
    CAST(SUM(CAST(size_in_bytes AS BIGINT)) / 1024.0 / 1024.0 AS DECIMAL(18, 2)) AS total_adhoc_cache_mb,
    CAST(SUM(CASE WHEN usecounts = 1 THEN CAST(size_in_bytes AS BIGINT) ELSE 0 END) / 1024.0 / 1024.0 AS DECIMAL(18, 2)) AS wasted_on_single_use_mb,
    CAST(SUM(CASE WHEN usecounts = 1 THEN CAST(size_in_bytes AS BIGINT) ELSE 0 END) * 100.0 / NULLIF(SUM(CAST(size_in_bytes AS BIGINT)), 0) AS DECIMAL(5, 2)) AS pct_wasted_cache,
    CASE
        WHEN SUM(CASE WHEN usecounts = 1 THEN CAST(size_in_bytes AS BIGINT) ELSE 0 END) > (20 * 1024 * 1024)
             AND (SUM(CASE WHEN usecounts = 1 THEN CAST(size_in_bytes AS BIGINT) ELSE 0 END) * 100.0 / NULLIF(SUM(CAST(size_in_bytes AS BIGINT)), 0)) > 20
        THEN N'NÊN BẬT: Lãng phí bộ nhớ đáng kể. Hãy bật "Optimize for Ad Hoc Workloads".'
        ELSE N'CHƯA CẦN THIẾT: Mức lãng phí bộ nhớ hiện tại thấp.'
    END AS recommendation
FROM PlanCacheStats;

```

- wasted_on_single_use_mb: Đây là dung lượng bộ nhớ (MB) mà các kế hoạch chỉ chạy một lần đang chiếm dụng.

- pct_wasted_cache: Đây là tỷ lệ phần trăm của bộ nhớ cache ad-hoc bị chiếm bởi các kế hoạch dùng một lần này.

Nên bật Optimize for Ad Hoc Workloads nếu: 💡

- Cột wasted_on_single_use_mb cho thấy một con số lớn. "Lớn" ở đây tùy thuộc vào tổng RAM server, nhưng một quy tắc chung là trên 20-50 MB đã là một dấu hiệu đáng chú ý.

- VÀ/HOẶC cột pct_wasted_cache cao, ví dụ trên 20-25%. Điều này có nghĩa là hơn 1/4 bộ nhớ cache dành cho các truy vấn ad-hoc đang bị lãng phí.