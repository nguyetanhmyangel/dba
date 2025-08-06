### 1. Hệ thống OLTP (Online Transaction Processing) – Xử lý giao dịch trực tuyến

- Mục tiêu:

Tối ưu cho các giao dịch nhỏ, nhanh, giao dịch đọc/ghi liên tục, như:

Thêm/sửa/xóa dữ liệu

Đơn hàng, thanh toán, đăng nhập, cập nhật hồ sơ...

- Đặc điểm:

| Đặc điểm                                  | Giá trị |
| ----------------------------------------- | ------- |
| Truy vấn nhỏ, đơn giản                    | ✅       |
| Giao dịch nhanh (ms)                      | ✅       |
| Số lượng truy cập lớn                     | ✅       |
| Cần tính toàn vẹn dữ liệu cao (ACID)      | ✅       |
| Ghi (INSERT/UPDATE) nhiều                 | ✅       |
| Sử dụng chỉ mục chính xác                 | ✅       |
| Song song hóa thấp (`MAXDOP` thường thấp) | ✅       |

- Ví dụ:

Ứng dụng ngân hàng

Hệ thống bán hàng POS

Quản lý bệnh nhân, học sinh, nhân sự, tài chính...

### 2. Hệ thống Data Warehouse (OLAP – Online Analytical Processing) – Phân tích dữ liệu trực tuyến

- Mục tiêu:

Tối ưu cho truy vấn phân tích lớn, dữ liệu lịch sử, tính toán tổng hợp:

Báo cáo doanh thu theo tháng/năm

So sánh xu hướng, drill-down dữ liệu

- Đặc điểm:

| Đặc điểm                                         | Giá trị |
| ------------------------------------------------ | ------- |
| Truy vấn phức tạp (JOIN nhiều bảng, GROUP BY)    | ✅       |
| Truy vấn chạy lâu (giây hoặc phút)               | ✅       |
| Giao dịch chủ yếu là đọc (SELECT)                | ✅       |
| Tổng hợp, phân tích dữ liệu                      | ✅       |
| Dữ liệu theo thời gian (dữ liệu lớn)             | ✅       |
| Cấu trúc dữ liệu dạng star schema hoặc snowflake | ✅       |
| Song song hóa cao (MAXDOP cao hơn OLTP)          | ✅       |

- Ví dụ:

Hệ thống báo cáo doanh nghiệp

Dashboard KPI, phân tích thị trường

Hệ thống phân tích dữ liệu lớn (BI)

- So sánh nhanh

| Tiêu chí           | OLTP                      | Data Warehouse (OLAP)       |
| ------------------ | ------------------------- | --------------------------- |
| Loại tác vụ chính  | Giao dịch, CRUD           | Truy vấn, phân tích         |
| Truy vấn           | Nhỏ, đơn giản             | Lớn, phức tạp               |
| Tốc độ             | Rất nhanh (ms)            | Nhanh chậm tùy khối lượng   |
| Khối lượng dữ liệu | Ít hơn                    | Rất lớn (nhiều năm dữ liệu) |
| Giao dịch ghi      | Nhiều                     | Ít (phần lớn là đọc)        |
| Cấu trúc DB        | Quan hệ chuẩn hóa         | Denormalized, star schema   |
| Dùng cho           | Ứng dụng thao tác dữ liệu | Báo cáo, dashboard, BI      |


### 3. Kết luận & lời khuyên

Nếu bạn đang vận hành hệ thống CRUD, nhập liệu, xử lý đơn hàng → OLTP → Nên để MAXDOP = 4 hoặc 8, và Cost Threshold ≥ 50

Nếu hệ thống của bạn chủ yếu để báo cáo, BI, đọc dữ liệu lớn → OLAP / Data Warehouse → MAXDOP = 8~16, Cost Threshold = 50~100