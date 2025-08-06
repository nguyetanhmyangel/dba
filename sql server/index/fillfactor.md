### 1. FILLFACTOR là gì?

FILLFACTOR quy định mức độ lấp đầy (%) của mỗi trang dữ liệu (data page) trong chỉ mục nonclustered hoặc clustered index khi được tạo hoặc rebuild.

Giá trị từ 1 đến 100.

Mặc định là 100, tức là SQL Server lấp đầy 100% trang dữ liệu.

### 2. Khi nào nên thay đổi FILLFACTOR?

FILLFACTOR không nên thay đổi tùy tiện. Nó hữu ích khi:
                                             | 
Tình huống nên dùng FILLFACTOR thấp (ví dụ: 80–90) 

- Dữ liệu được **chèn/xóa/cập nhật thường xuyên**          
- **Page split** xảy ra thường xuyên gây phân mảnh         
- Muốn **giảm IO**, hy sinh dung lượng để tối ưu hiệu suất 

(Page Split là hiện tượng khi trang đầy và SQL Server phải tách (split) trang để chứa thêm dữ liệu — gây tốn IO và fragment.)

### 3. khuyến nghị

| Loại Hệ Thống                       | FILLFACTOR |
| ----------------------------------- | ---------- |
| OLTP nhiều update/insert            | 80–90      |
| OLAP hoặc ít thay đổi               | 100        |
| Tempdb hoặc bảng tạm nhiều thay đổi | 70–90      |

### 4. Thiết lập FILLFACTOR mặc định cho SQL Server

```bash
EXEC sys.sp_configure 'show advanced options', 1;
RECONFIGURE;
EXEC sys.sp_configure 'fill factor (%)', 90; -- ví dụ 90%
RECONFIGURE;
```

- Chú ý:FILLFACTOR là một thuộc tính metadata của index. Nó chỉ được sử dụng khi index được xây dựng lại (REBUILD).

