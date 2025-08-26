### 1. kiểm tra các ổ đĩa hiện có trên hệ thống

```bash
lsblk
```

### 2. Tạo Phân vùng

Các command khi fdisk, giả sử ta cần fdisk sdb: 

- d (delete) nếu có bất kỳ phân vùng nào hiện có trên ổ đĩa này mà bạn muốn xóa. Lặp lại cho đến khi không còn phân vùng nào.

- n (new) để tạo phân vùng mới.

- p (primary) để tạo phân vùng chính.

- w (write) để lưu các thay đổi và thoát fdisk.

```bash
sudo fdisk /dev/sdb
# d (nếu cần)
# n
# p
# 1
# Enter
# Enter
# w
```

### 3. Hệ thống nhận diện các thay đổi

```bash
sudo partprobe
```

### 4. Định dạng (Format) File System

```bash
sudo mkfs.ext4 /dev/sdb1
```

### 5. Tạo Thư mục và Mount Point 

```bash
sudo mkdir /u02
sudo mount /dev/sdb1 /u02
```

### 6. Cấu hình Mount tự động khi khởi động (Fstab)

- Lấy UUID của các phân vùng:

```bash
sudo blkid
```

- Mở file /etc/fstab để chỉnh sửa, thêm các dòng sau vào cuối file với YOUR_UUID_FOR_SDB1 là UUID thực tế của ổ đĩa sdb1

```bash
sudo vi /etc/fstab
UUID=YOUR_UUID_FOR_SDB1 /u02 ext4 defaults 0 2
```

- Mount thủ công để kiểm tra trước khi reboot:

```bash
sudo systemctl daemon-reload
sudo mount -a
```