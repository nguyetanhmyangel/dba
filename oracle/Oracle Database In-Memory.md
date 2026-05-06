- Kiến trúc Dual-Format (Định dạng kép).

	- Row Format: Dữ liệu vẫn được lưu trữ dưới dạng hàng trong Buffer Cache để phục vụ các tác vụ OLTP (giao dịch, thêm/sửa/xóa) cực nhanh.

	- Column Format: Dữ liệu được sao chép vào một vùng bộ nhớ mới gọi là In-Memory Column Store (IM column store) dưới dạng cột. Định dạng này cực kỳ tối ưu cho Analytics (truy vấn, báo cáo, thống kê).

	- Không thay thế database truyền thống, mà bổ sung để tăng tốc query

- Bộ nhớ liên quan: 

| Thành phần         | Vai trò              |
| ------------------ | -------------------- |
| **SGA**            | Shared Global Area   |
| **Buffer Cache**   | Lưu data dạng row    |
| **In-Memory Area** | Lưu data dạng column |
| **PGA**            | Sort, hash, session  |

- Oracle khuyến nghị ASMM (SGA + PGA) cho hệ thống thật, KHÔNG bao giờ cấp 100% RAM cho Oracle

- OS còn cần RAM cho:

	- Kernel

	- Page cache

	- ASM / FS cache

	- Monitoring / backup agent

- Do đó Oracle memory chiếm dụng = SGA_TARGET + PGA_AGGREGATE_TARGET ~ 60% – 70% RAM vật lý 

- Kiểm tra memory_max_target, memory_target:

```sql
show parameter memory_target
show parameter memory_max_target
```
Nếu 2 giá trị trả vể = 0 -> AMM (Automatic Memory Management) tắt.

- Oracle có các view / advisor giúp tính TOÁN & GỢI Ý rất tốt, dựa trên workload thực tế

```sql
SELECT pga_target_for_estimate/1024/1024 AS pga_mb,
       pga_target_factor,
       estd_pga_cache_hit_percentage as hit_pct,
       estd_overalloc_count
FROM v$pga_target_advice;
```
kết quả trả vê:

```sql
PGA_MB PGA_TARGET_FACTOR    HIT_PCT ESTD_OVERALLOC_COUNT
---------- ----------------- ---------- --------------------
    95.625              .125         96                  690
    191.25               .25         96                  683
     382.5                .5         97                  509
    573.75               .75         98                  275
       765                 1        100                    4
       918               1.2        100                    0
      1071               1.4        100                    0
      1224               1.6        100                    0
      1377               1.8        100                    0
      1530                 2        100                    0
      2295                 3        100                    0

    PGA_MB PGA_TARGET_FACTOR    HIT_PCT ESTD_OVERALLOC_COUNT
---------- ----------------- ---------- --------------------
      3060                 4        100                    0
      4590                 6        100                    0
      6120                 8        100                    0

14 rows selected.
```

Ta phải chọn PGA nhỏ nhất mà ESTD_OVERALLOC_COUNT = 0: 

- Overalloc > 0 → sort/hash bị spill ra disk ❌

- Hit % cao không đủ, phải overalloc = 0

Từ kết quả trả về ta chọn PGA_TARGET_FOR_ESTIMATE ≈ 918 MB



```sql

```