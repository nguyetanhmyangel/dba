### 1. Phương pháp dùng ASMLib (Không khuyên dùng cho 19c)
ASMLib là thư viện hỗ trợ truyền thống của Oracle.
-Ưu điểm:
    -Quen thuộc với nhiều DBA lâu năm.
    -Các lệnh quản lý rất trực quan và dễ sử dụng (oracleasm createdisk, oracleasm scandisk, oracleasm listdisks).
-Nhược điểm:
    -Rủi ro phụ thuộc Kernel: Gói oracleasm gắn chặt với phiên bản kernel của Linux. Nếu update OS (ví dụ yum update) mà quên update gói ASMLib tương ứng, hệ thống ASM của bạn sẽ "mù" (không nhận được đĩa) khi khởi động lại, dẫn đến downtime database.
    -Công nghệ cũ: Oracle đang dần loại bỏ sự tập trung vào ASMLib trong các phiên bản mới.
-Đề xuất thay thế: Oracle ASM Filter Driver (AFD)
    -Nếu vẫn thích dùng các công cụ "chính chủ" của Oracle với các lệnh tạo đĩa tương tự như ASMLib, nên xem xét sử dụng AFD (ASM Filter Driver). Đây là công nghệ được Oracle thiết kế để thay thế hoàn toàn ASMLib từ bản 12cR2 và 19c.
    - Tính năng bảo mật vượt trội: Nó có tính năng I/O filtering. Nghĩa là nó sẽ từ chối mọi thao tác ghi (write) xuống đĩa từ các lệnh không phải của Oracle ở cấp độ OS (ví dụ ai đó lỡ tay gõ lệnh dd hay mkfs vào đĩa ASM, AFD sẽ chặn lại), giúp bảo vệ dữ liệu cực kỳ an toàn.

### 2. SM Filter Driver (ASMFD)
- ASMFD là giải pháp của chính Oracle, ra đời từ bản 12.1 nhằm thay thế cho ASMLib cũ. Nó hoạt động như một module kernel (filter driver) nằm giữa hệ điều hành và thiết bị lưu trữ.
- Ưu điểm cốt lõi (Bảo vệ I/O): Điểm "ăn tiền" lớn nhất của ASMFD là khả năng ngăn chặn các lệnh I/O không hợp lệ từ hệ điều hành. Nếu một sysadmin vô tình chạy lệnh dd, mkfs, hoặc fdisk trực tiếp lên một disk đã cấp cho ASM, ASMFD sẽ block lệnh đó lại, bảo vệ cấu trúc dữ liệu của database khỏi sự phá hoại vô ý.
- Quản lý disk: Việc gán label (disk name) và khởi tạo disk được thực hiện thông qua các command của Oracle (asmcmd afd_label), giúp việc nhận diện disk trong môi trường cluster dễ dàng hơn.
- Nhược điểm: Do là module của Oracle, nó gắn chặt với lifecycle của Grid Infrastructure. Đôi khi việc patch OS kernel hoặc nâng cấp Grid đòi hỏi phải kiểm tra tính tương thích của ASMFD cẩn thận hơn.

### 3. Phương pháp dùng UDEV
- Ưu điểm cốt lõi (Minh bạch & Native): Sử dụng udev mang lại sự kiểm soát hoàn toàn ở tầng hệ điều hành. Nó cực kỳ linh hoạt và minh bạch đối với những ai thích quản trị hệ thống qua giao diện command-line. Mọi thiết lập đều nằm trong file text rõ ràng (ví dụ: /etc/udev/rules.d/99-oracle-asmdevices.rules).
- Độ ổn định: Không phát sinh dependency với các module ngoài của Oracle. Việc nâng cấp hệ điều hành (như Oracle Linux) hoặc vá lỗi kernel diễn ra trơn tru mà không cần lo lắng về việc driver của Oracle có hỗ trợ kernel mới hay không.
- Nhược điểm: Không có cơ chế I/O Filter. Nếu ai đó có quyền root lỡ tay format nhầm phân vùng (ví dụ: mkfs.ext4 /dev/mapper/asm_disk1), hệ điều hành sẽ thực thi ngay lập tức và ASM disk group có thể bị hỏng. Cấu hình rule ban đầu (đặc biệt khi kết hợp với multipath) đòi hỏi phải bóc tách chính xác các WWID.

### 4. Lời Khuyên Áp Dụng
- Đối với việc cài đặt Oracle 19c Grid Infrastructure và ASM trên các hệ điều hành Linux hiện đại (như OEL 7/8, RHEL 7/8), không khuyến nghị dùng ASMLib (oracleasmlib, oracleasm-support) nữa cho phiên bản 19c+.
- Nên chọn ASMFD khi: Đội ngũ vận hành lớn, phân chia rạch ròi giữa team System/Storage và team DBA, và ưu tiên tuyệt đối việc bảo vệ dữ liệu khỏi các lỗi thao tác nhầm lẫn (human error) từ phía OS.
- Nên chọn udev khi: Quản trị viên có thế mạnh về Linux command-line, muốn một kiến trúc gọn nhẹ, native, dễ dàng troubleshoot từ tầng OS bằng các lệnh cơ bản và không muốn phụ thuộc vào các module độc quyền của Oracle. Trên các môi trường như Oracle Linux 7/8, kiến trúc kết hợp giữa multipathd và udev rules đã được chứng minh là cực kỳ ổn định và đạt hiệu năng cao cho các hệ thống Enterprise.

