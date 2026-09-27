- Để các giao diện mạng trên Oracle Linux (thường dùng NetworkManager trên các bản 7.x/8.x/9.x) tự động kích hoạt khi khởi động máy ảo, bạn cần cấu hình tham số ONBOOT trong các file cấu hình mạng.

- Dưới đây là các bước thực hiện trên terminal:

### 1. Kiểm tra trạng thái các interface
Trước tiên, hãy xác định tên của các card mạng đang được VirtualBox cấp phát bằng lệnh:

```Bash
nmcli device status
```
- Thông thường, chúng sẽ có tên như enp0s3 (NAT) và enp0s8 (Host-Only).

### 2. Thiết lập tự động khởi động (ONBOOT)
-Cần sửa file cấu hình của từng giao diện trong thư mục /etc/sysconfig/network-scripts/ (hoặc kiểm tra bằng nmcli để trực tiếp thay đổi thuộc tính). Cách nhanh nhất và an toàn nhất là dùng lệnh nmcli:

- Với card NAT (ví dụ enp0s3):

```Bash
sudo nmcli connection modify enp0s3 connection.autoconnect yes
```

- Với card Host-Only (ví dụ enp0s8):

```Bash
sudo nmcli connection modify enp0s8 connection.autoconnect yes
```

### 3. Kiểm tra file cấu hình (nếu muốn xác nhận thủ công)
- Nếu muốn kiểm tra trực tiếp file cấu hình, hãy mở file tương ứng (ví dụ: ifcfg-enp0s3):

```Bash
cat /etc/sysconfig/network-scripts/ifcfg-enp0s3
```

-Hãy đảm bảo ONBOOT đã được thiết lập là yes, nếu là no, có thể dùng vi hoặc nano để sửa lại thành yes. Sau khi sửa file thủ công, hãy chạy lệnh sudo nmcli connection reload để áp dụng thay đổi.

### 4. Lưu ý về Host-Only Adapter

- Đối với Host-Only Network, đôi khi giao diện mạng không lên được vì VirtualBox chưa cấp phát kịp IP hoặc dịch vụ DHCP của VirtualBox gặp vấn đề. Bạn nên cân nhắc đặt IP tĩnh (Static IP) cho card Host-Only này trong file cấu hình để tránh việc phụ thuộc vào DHCP của VirtualBox:

```Bash
# Thay 192.168.56.x bằng dải IP đã cấu hình trong VirtualBox Host Network Manager
sudo nmcli connection modify enp0s8 ipv4.addresses 192.168.56.x/24 ipv4.method manual
sudo nmcli connection up enp0s8
```

- Sau khi hoàn tất, hãy thử sudo reboot để kiểm tra lại kết quả. Việc này sẽ đảm bảo NetworkManager luôn "up" các interface này ngay khi hệ thống khởi tạo dịch vụ mạng.

