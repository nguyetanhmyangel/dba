

1.  Page trong SQL ServerTrong SQL Server (và nhiều hệ quản trị cơ sở dữ liệu khác), một page dữ liệu (data page) là đơn vị cơ bản để lưu trữ dữ liệu trên đĩa và trong bộ nhớ. Đây là cách SQL Server quản lý dữ liệu ở mức thấp nhất.

Kích thước cố định:

- Mỗi page có kích thước 8 KB (8192 byte).

- Đây là kích thước chuẩn cho tất cả các page trong SQL Server.

Các loại Page:

SQL Server có nhiều loại page, ví dụ:

- Data Page (loại 1): Chứa dữ liệu của bảng hoặc chỉ mục (các hàng).

- Index Page: Chứa các entry của index.

- IAM Page: Quản lý allocation map (các extent được cấp phát).

- Text/Image Page: Chứa dữ liệu kiểu LOB (Large Object) như TEXT, IMAGE, VARCHAR(MAX).

Cách dữ liệu lưu trong page:

- Một page có phần header (~96 bytes) chứa thông tin quản lý (Page ID, type, mối quan hệ với các page khác).

- Phần còn lại chứa data rows.

- Một page có thể chứa nhiều rows, tùy kích thước mỗi row (trừ khi row > 8 KB → sẽ dùng row-overflow hoặc LOB storage).

Extent:

- 8 page liên tiếp (8 x 8 KB = 64 KB) tạo thành một extent.

- SQL Server cấp phát theo extent để tối ưu I/O.

2. PLE (Page Life Expectancy)

- PLE là thời gian trung bình (tính bằng giây) mà một page dữ liệu vẫn còn tồn tại trong buffer pool trước khi bị thay thế.

- Chỉ số cao → tốt (ít áp lực bộ nhớ), chỉ số thấp → có vấn đề về memory hoặc query I/O.

Ngưỡng chuẩn:

- Trước đây: 300 giây là tốt.

- Hiện nay: phụ thuộc kích thước RAM. Công thức khuyến nghị:

PLE >= (RAM / 4 GB) * 300


Ví dụ: Server có 64GB RAM → PLE nên >= 4800 giây.

Nếu PLE giảm mạnh: Có thể do query scan lớn, thiếu index, hoặc áp lực bộ nhớ (Ad Hoc plans quá nhiều cũng góp phần).

3. Pages/sec (Counter của PerfMon)

- Pages/sec đo tốc độ hệ thống thực hiện paging (chuyển page giữa RAM và disk) của toàn bộ Windows, không chỉ SQL Server.

- Giá trị cao liên tục → thiếu RAM hoặc memory pressure.

Lưu ý:

- Pages/sec cao tạm thời khi đọc file hoặc backup là bình thường.

- Nếu liên tục cao khi workload ổn định → RAM thiếu hoặc cấu hình bộ nhớ sai.

4. Buffer Pool

Buffer Pool trong SQL Server là vùng bộ nhớ chính mà SQL Server dùng để lưu trữ dữ liệu đã đọc từ data files (.mdf, .ndf) hoặc các đối tượng khác để tránh phải đọc lại từ đĩa (I/O vật lý). Nó là thành phần quan trọng của SQL Server Memory Architecture.

Chi tiết về Buffer Pool

- Là một phần của SQL Server Buffer Manager.

- Chứa các data pages (mặc định 8 KB mỗi page).

- Khi bạn thực hiện một truy vấn, SQL Server:

- Kiểm tra trong Buffer Pool xem page dữ liệu có sẵn không (Buffer Hit).

- Nếu có → đọc trực tiếp từ RAM (Logical Read).

- Nếu không → đọc từ đĩa vào Buffer Pool (Physical Read), sau đó trả về cho truy vấn.

Vai trò

- Giảm I/O: Truy cập RAM nhanh hơn đọc từ disk.

- Cache dữ liệu & index pages để tái sử dụng.

- Cũng dùng cho:

    - Procedure Cache (lưu Execution Plans).

    - Workspace Memory (cho Sort, Hash, Join…).

Cấu trúc

- Buffer Pool bao gồm nhiều 8KB pages:

- Data Pages: lưu dữ liệu bảng.

- Index Pages: lưu chỉ mục.

- IAM Pages: quản lý allocation.

- PFS, GAM, SGAM: quản lý page allocation.

Quản lý dung lượng

- Dung lượng phụ thuộc vào Max Server Memory.

- Khi bộ nhớ bị thiếu:

- SQL Server dùng Lazy Writer để đẩy các page ít dùng ra disk.

- Sử dụng thuật toán LRU (Least Recently Used).
