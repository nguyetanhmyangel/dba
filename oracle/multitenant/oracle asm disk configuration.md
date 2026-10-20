#### Bước 1: Chia 1 phân vùng duy nhất cho từng ổ đĩa
- Tạo partition số 1 trên toàn bộ dung lượng của 3 đĩa:

```Bash
for disk in sdc sdd sde; do
  echo -e "n\np\n1\n\n\nw" | sudo fdisk /dev/$disk
done
```
- Xác minh: Chạy 

```Bash
lsblk /dev/sd[c-e] 
```
để kiểm tra các phân vùng con sdc1, sdd1, sde1 đã xuất hiện.

#### Bước 2: Truy vấn Serial/WWID thực tế của thiết bị cha

- Lấy chuỗi nhận diện duy nhất từ đĩa vật lý/ổ ảo gốc thông qua tiện ích scsi_id:

```Bash
for dev in /dev/sdc /dev/sdd /dev/sde; do
  echo "$dev: $(sudo /usr/lib/udev/scsi_id -g -u -d $dev)"
done
```
- Trường hợp lệnh không trả về kết quả (đặc trưng của VirtualBox): Ổ đĩa ảo SATA trong VirtualBox mặc định không bật SCSI Page 0x83. Hãy kiểm tra giá trị bằng lệnh udevadm:

```Bash
sudo udevadm info --query=property --name=/dev/sdc | grep -E "ID_SERIAL=|ID_SCSI_SERIAL="
```

- Hoặc bật thuộc tính serial từ máy Host (khi máy ảo tắt):

```Bash
VBoxManage setextradata "<TÊN_VM>" "VBoxInternal/Devices/ahci/0/Config/Port2/SerialNumber" "ASM_DATA1"
VBoxManage setextradata "<TÊN_VM>" "VBoxInternal/Devices/ahci/0/Config/Port3/SerialNumber" "ASM_FRA1"
VBoxManage setextradata "<TÊN_VM>" "VBoxInternal/Devices/ahci/0/Config/Port4/SerialNumber" "ASM_RECO1"
```

#### Bước 3: Tạo file quy tắc UDEV chuẩn Oracle

- Mở file cấu hình UDEV:

```Bash
sudo vi /etc/udev/rules.d/99-oracle-asmdevices.rules
```

- Dán nội dung cấu hình dưới đây (thay thế các chuỗi SERIAL_THUC_TE_... bằng chuỗi hash thu được ở Bước 2):

```Code snippet
# ASM Disk 1: DATA (40G - sdc1)
SUBSYSTEM=="block", KERNEL=="sd?1", PROGRAM=="/usr/lib/udev/scsi_id -g -u -d /dev/$parent", RESULT=="SERIAL_THUC_TE_SDC", OWNER="grid", GROUP="asmadmin", MODE="0660", SYMLINK+="oracleasm/disks/asm-data1"

# ASM Disk 2: FRA (30G - sdd1)
SUBSYSTEM=="block", KERNEL=="sd?1", PROGRAM=="/usr/lib/udev/scsi_id -g -u -d /dev/$parent", RESULT=="SERIAL_THUC_TE_SDD", OWNER="grid", GROUP="asmadmin", MODE="0660", SYMLINK+="oracleasm/disks/asm-fra1"

# ASM Disk 3: RECO (30G - sde1)
SUBSYSTEM=="block", KERNEL=="sd?1", PROGRAM=="/usr/lib/udev/scsi_id -g -u -d /dev/$parent", RESULT=="SERIAL_THUC_TE_SDE", OWNER="grid", GROUP="asmadmin", MODE="0660", SYMLINK+="oracleasm/disks/asm-reco1"
```

hoặc 

```bash
cat << 'EOF' > /etc/udev/rules.d/99-oracle-asmdevices.rules
KERNEL=="sd*", SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", ATTR{ID_SERIAL}=="<WWID_CỦA_SDC>", SYMLINK+="asm-disk1", OWNER="grid", GROUP="asmadmin", MODE="0660"
KERNEL=="sd*", SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", ATTR{ID_SERIAL}=="<WWID_CỦA_SDD>", SYMLINK+="asm-disk2", OWNER="grid", GROUP="asmadmin", MODE="0660"
KERNEL=="sd*", SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", ATTR{ID_SERIAL}=="<WWID_CỦA_SDE>", SYMLINK+="asm-disk3", OWNER="grid", GROUP="asmadmin", MODE="0660"
EOF
```

#### Bước 4: Áp dụng và kiểm tra quyền thiết bị

- Nạp lại rules và kích hoạt bộ kích hoạt UDEV:

```Bash
sudo udevadm control --reload-rules
sudo udevadm trigger --action=change
sudo udevadm settle
```
- Kiểm tra liên kết Symlink:

```Bash
ls -la /dev/oracleasm/disks/
```

- Kết quả hợp lệ: Xuất hiện 3 symlink asm-data1, asm-fra1, asm-reco1 trỏ tương ứng về ../../sdc1, ../../sdd1, ../../sde1.

- Kiểm tra quyền sở hữu trên block device gốc:

```Bash
ls -l /dev/sd[c-e]1
```

- Kết quả hợp lệ: Tất cả các block device phải hiển thị quyền brw-rw---- với chủ sở hữu là grid:asmadmin:

```Plaintext
brw-rw---- 1 grid asmadmin ... /dev/sdc1
brw-rw---- 1 grid asmadmin ... /dev/sdd1
brw-rw---- 1 grid asmadmin ... /dev/sde1
```

### Bước 5: Thiết lập trong quá trình và sau khi cài đặt Grid Infrastructure

Bước này chỉ bắt đầu khi bạn chuyển sang user grid và chạy trình cài đặt:
- Lúc chạy ./gridSetup.sh (màn hình cấu hình Disk Group):
- Trình cài đặt sẽ hỏi đường dẫn tìm kiếm đĩa (Disk Discovery String). Lúc này bạn mới nhập:

```Plaintext
/dev/oracleasm/disks/*
```
- Grid sẽ quét và thấy các đĩa bạn đã chuẩn bị. Bạn tick chọn đĩa asm-data1 để tạo diskgroup đầu tiên (DATA).
- Tiếp tục bấm Next để hoàn tất cài đặt Grid Infrastructure.
- Sau khi Grid Infrastructure cài xong thành công:
- Lúc này dịch vụ Oracle Clusterware/ASM đã khởi động.
- Mở công cụ ASMCA (asmca) bằng giao diện hoặc chạy lệnh SQL với quyền SYSASM để tạo nốt 2 diskgroup còn lại (FRA gán vào asm-fra1, RECO gán vào asm-reco1).