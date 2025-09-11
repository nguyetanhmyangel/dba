### 1. PAGEIOLATCH_ (Thường gặp: SH, EX, UP)*

- Ví dụ dễ hiểu: Tưởng tượng bạn là một đầu bếp (SQL Server) và cần một nguyên liệu (dữ liệu) đang ở trong kho lạnh (ổ đĩa). PAGEIOLATCH chính là thời gian bạn phải đứng chờ cửa kho lạnh mở ra để lấy nguyên liệu đó vào bếp (RAM).

- Nói một cách kỹ thuật, đây là thời gian SQL Server phải chờ một trang dữ liệu (data page) được đọc từ ổ đĩa (HDD/SSD) vào bộ nhớ đệm (Buffer Pool/RAM). Đây là một trong những "điểm nghẽn" (bottleneck) phổ biến nhất.

- Các loại thường gặp:

	- PAGEIOLATCH_SH (Shared): Chờ để đọc một trang dữ liệu. Đây là loại phổ biến nhất.

	- PAGEIOLATCH_EX (Exclusive) / PAGEIOLATCH_UP (Update): Chờ để ghi một trang dữ liệu.

- Nguyên nhân phổ biến:

	- Hệ thống I/O (ổ đĩa) chậm: Đây là nguyên nhân hàng đầu. Ổ đĩa của bạn không đủ nhanh để cung cấp dữ liệu theo yêu cầu.

	- Thiếu RAM (Memory Pressure): SQL Server không có đủ RAM để lưu trữ các trang dữ liệu thường xuyên truy cập. Do đó, nó phải liên tục đẩy dữ liệu cũ ra khỏi RAM và đọc lại từ đĩa khi cần, gây ra nhiều PAGEIOLATCH.

	- Query không hiệu quả: Các câu lệnh SQL phải quét (scan) một lượng lớn dữ liệu thay vì tìm kiếm (seek) hiệu quả. Ví dụ:

	- Thiếu Index phù hợp.

	- Index bị phân mảnh (fragmented).

	- Thống kê (statistics) bị lỗi thời, khiến SQL Server chọn một kế hoạch thực thi (execution plan) tồi.

	- "TempDB Contention": Quá nhiều thao tác tạo bảng tạm, sắp xếp, hoặc nối bảng lớn xảy ra trên TempDB, gây áp lực I/O lên các file của TempDB.

- Cách xử lý và chẩn đoán:

	- Bước 1: Kiểm tra sức khỏe I/O: Dùng công cụ như DiskSpd để đo tốc độ đọc/ghi của ổ đĩa. Kiểm tra sys.dm_io_virtual_file_stats để xem file nào có độ trễ (latency) cao.

	- Bước 2: Kiểm tra bộ nhớ: Dùng sp_Blitz hoặc kiểm tra chỉ số Buffer Cache Hit Ratio và Page Life Expectancy (PLE). Nếu PLE thấp, đó là dấu hiệu thiếu RAM.

	- Bước 3: Tối ưu Query: Dùng sp_BlitzCache @SortOrder = 'reads' để tìm ra những query đang đọc nhiều dữ liệu nhất. Sau đó dùng sp_BlitzIndex để phân tích và thêm các index còn thiếu cho những query này.

	- Bước 4: Nâng cấp phần cứng: Nếu đã tối ưu phần mềm mà vẫn chậm, việc nâng cấp lên ổ SSD nhanh hơn hoặc tăng thêm RAM là giải pháp cuối cùng.

### 2. CXPACKET

- Ví dụ dễ hiểu: Tưởng tượng bạn có một công việc lớn cần hoàn thành (một query phức tạp). Bạn quyết định chia nhỏ công việc cho một nhóm nhân viên (nhiều CPU core) cùng làm cho nhanh (parallelism). CXPACKET chính là thời gian người quản lý (coordinator thread) phải đứng chờ tất cả nhân viên hoàn thành phần việc của mình để ghép kết quả lại.

- CXPACKET xảy ra khi một query được thực thi song song trên nhiều CPU. Nó không hoàn toàn là "xấu", mà là một dấu hiệu tự nhiên của việc xử lý song song. Tuy nhiên, khi CXPACKET chiếm tỷ lệ cao trong tổng thời gian chờ, nó cho thấy sự "mất cân bằng" trong việc xử lý song song.

- Nguyên nhân phổ biến:

	- Dữ liệu phân bổ không đều: Một số luồng (thread) phải xử lý nhiều dữ liệu hơn các luồng khác, dẫn đến việc chúng hoàn thành sau và các luồng khác phải chờ.

	- Cấu hình MAXDOP (Max Degree of Parallelism) không phù hợp:

	- MAXDOP = 0: Cho phép SQL Server dùng tất cả các CPU có sẵn, đôi khi quá mức cần thiết cho các query đơn giản, gây ra nhiều chờ đợi không đáng có.

	- MAXDOP = 1: Tắt hoàn toàn xử lý song song, có thể làm các query lớn, phức tạp chạy chậm hơn.

	- Thống kê (Statistics) lỗi thời: Dẫn đến việc ước tính số lượng hàng (row estimation) bị sai, khiến SQL Server chọn một kế hoạch thực thi song song không hiệu quả.

	- Cost Threshold for Parallelism (CTFP) quá thấp: Đây là ngưỡng chi phí để SQL Server quyết định có nên chạy một query song song hay không. Nếu giá trị này quá thấp (mặc định là 5), các query đơn giản cũng bị chạy song song một cách không cần thiết.

- Cách xử lý và chẩn đoán:

	- Quan trọng: Khi thấy CXPACKET cao, hãy kiểm tra xem có đi kèm với wait type CXCONSUMER hay không. CXCONSUMER mới thực sự là vấn đề, nó cho thấy các luồng consumer đang phải chờ dữ liệu từ các luồng producer.

	- Bước 1: Điều chỉnh MAXDOP: Đây là cách phổ biến nhất.

		Quy tắc chung: Đối với server có nhiều CPU, hãy đặt MAXDOP bằng một nửa số core vật lý, nhưng không quá 8. Ví dụ: server có 16 core, đặt MAXDOP là 8.

	- Bước 2: Tăng Cost Threshold for Parallelism: Tăng giá trị này từ 5 lên một con số cao hơn (ví dụ: 30-50). Điều này sẽ ngăn các query nhỏ, nhanh chạy song song một cách lãng phí.

	- Bước 3: Tối ưu Query: Đôi khi, cách tốt nhất để giải quyết CXPACKET là tối ưu query để nó không cần chạy song song nữa. Thêm index phù hợp có thể giảm "chi phí" của query xuống dưới ngưỡng CTFP.

	- Bước 4: Cập nhật Statistics: Đảm bảo rằng statistics trên các bảng lớn được cập nhật thường xuyên.

### 3. SOS_SCHEDULER_YIELD

- Ví dụ dễ hiểu: Tưởng tượng bạn là một CPU và có một hàng dài người (các thread) đang chờ được bạn xử lý. Vì bạn chỉ có thể làm một việc tại một thời điểm, một người (thread) sau khi được bạn xử lý một chút phải tự nguyện nhường chỗ cho người tiếp theo và quay lại xếp hàng. SOS_SCHEDULER_YIELD chính là khoảng thời gian chờ đợi trong hàng đó.

- Wait type này xảy ra khi một luồng (thread) đã chạy hết "quantum" thời gian (khoảng 4 mili giây) trên CPU và phải tự nguyện nhường quyền thực thi cho một luồng khác đang chờ. Đây là một dấu hiệu rõ ràng của áp lực CPU (CPU Pressure) - có nhiều yêu cầu xử lý hơn khả năng của CPU.

- Nguyên nhân phổ biến:

- CPU không đủ mạnh: Số lượng hoặc tốc độ CPU không đáp ứng được khối lượng công việc.

- Query "ngốn" nhiều CPU: Các câu lệnh thực hiện nhiều phép tính phức tạp, sắp xếp lớn trên dữ liệu không có index, hoặc logic vòng lặp tồi.

- Kế hoạch thực thi không hiệu quả (Bad Execution Plans): Ví dụ, SQL Server chọn cách "Hash Join" hoặc "Sort" trên một tập dữ liệu rất lớn thay vì dùng một index hiệu quả.

- Parameter Sniffing: Một query được biên dịch với một tham số "tốt" nhưng sau đó lại được gọi với một tham số "xấu", dẫn đến việc tái sử dụng một kế hoạch thực thi không còn phù hợp, gây tốn CPU.

- Cách xử lý và chẩn đoán:

	- Bước 1: Xác định query tốn CPU: Dùng sp_BlitzCache @SortOrder = 'cpu' để tìm ra những query đang tiêu thụ nhiều CPU nhất.

	- Bước 2: Phân tích kế hoạch thực thi: Xem execution plan của các query đó. Tìm kiếm các toán tử (operator) tốn kém như Key Lookup, Index Scan trên bảng lớn, Sort, Hash Match.

	- Bước 3: Tối ưu Query và Index:

		- Thêm các index còn thiếu để tránh các thao tác quét (scan) tốn kém.

		- Xem xét viết lại logic query để giảm các phép tính phức tạp.

	- Bước 4: Kiểm tra cấu hình MAXDOP: MAXDOP không phù hợp cũng có thể gây ra áp lực CPU không cần thiết.

	- Bước 5: Nâng cấp CPU: Nếu tất cả các query đã được tối ưu mà CPU vẫn ở mức cao, bạn cần xem xét việc nâng cấp phần cứng.