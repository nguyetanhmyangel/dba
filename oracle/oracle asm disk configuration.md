## PHẦN I — ASM KHÔNG DÙNG MULTIPATH

Áp dụng cho:
- VMware
- KVM
- VirtualBox
- Local Disk
- Oracle Restart
- RAC lab/test nhỏ

KHÔNG áp dụng cho:
- SAN Storage
- Fibre Channel
- iSCSI enterprise

### I.1 — STORAGE DISCOVERY
- Kiểm tra disk
```bash
lsblk -o NAME,SIZE,TYPE,TRAN,VENDOR,MODEL
```
- Output cột TYPE phải là disk, ví dụ:
```bash
sdb    100G disk
sdc    100G disk
```
- Tạo 1 partition chiếm toàn bộ disk sẽ tạo ASM.

```bash
sudo fdisk /dev/sdb
# thao tác:
# d (nếu cần)
# n
# p
# 1
# Enter
# Enter
# w

# Hệ thống nhận diện các thay đổi
sudo partprobe
```
- Sau đó tạo UDEV rule theo partition UUID hoặc ID.
### I.2 — VERIFY DISK IDENTITY

- Lấy WWN/SERIAL,Ưu tiên:ID_WWN, ID_SERIAL
```bash
udevadm info --query=all --name=/dev/sdb | egrep 'ID_WWN|ID_SERIAL'
```
- Output kỳ vọng ví dụ: E: ID_WWN=0x60022480abcd1234 hoặc E: ID_SERIAL=123456789
- Giải thích: Trên Linux, tên /dev/sdb có thể bị đổi thành sdc sau khi khởi động lại. Do đó, bắt buộc phải dùng ID phần cứng (WWN hoặc SERIAL) để làm "căn cước công dân" cố định cho đĩa.
- NOTE DÀNH CHO VMWARE: Nếu lệnh trên trả về kết quả rỗng (không thấy WWN/SERIAL), nguyên nhân là ảo hóa đang che giấu thông tin đĩa. Hãy yêu cầu vSphere Admin thêm dòng disk.EnableUUID = "TRUE" vào Advanced Settings của máy ảo và Reboot OS.

### I.3 — CLEAN OLD METADATA

- Chỉ thao tác đúng disk ASM.
```bash
# Xóa filesystem signature - chữ ký filesystem (ext4, xfs, lvm) ở đầu đĩa.
wipefs -a /dev/sdb
# Xóa GPT/MBR metadata. GPT có một bản backup nằm ở cuối đĩa, nếu không dùng sgdisk xóa đi, đôi khi OS tự quét lại và khôi phục nhầm, gây hỏng ASM Header.
sgdisk --zap-all /dev/sdb
# Verify disk sạch, Disk ASM KHÔNG được hiện:TYPE=, UUID=, PARTUUID=
blkid
```

### I.4 — CREATE UDEV RULES
- Tạo rule file
```bash
vi /etc/udev/rules.d/99-oracle-asm.rules
```
- Ví dụ rule chuẩn:
```bash
ACTION=="add|change", KERNEL=="sd*[!0-9]", SUBSYSTEM=="block", ENV{ID_WWN}=="0x60022480abcd1234", SYMLINK+="asm-data01", OWNER="grid", GROUP="asmadmin", MODE="0660", OPTIONS+="last_rule"
ACTION=="add|change", KERNEL=="sd*[!0-9]", SUBSYSTEM=="block", ENV{ID_WWN}=="0x60022480abcd5678", SYMLINK+="asm-fra01", OWNER="grid", GROUP="asmadmin", MODE="0660", OPTIONS+="last_rule"
```
- Giải thích:
  - KERNEL=="sd*[!0-9]": Chốt chặn an toàn! Chỉ áp dụng cho ổ vật lý (sdb, sdc), tuyệt đối bỏ qua các phân vùng (sdb1, sdc2). Giúp tăng tốc boot.
  - OPTIONS+="last_rule": Bảo UDEV rằng "Đọc đến đây là xong, đừng cho các rules mặc định khác của hệ thống ghi đè lên quyền của đĩa này nữa".

Để Reload và Verify xem phần III(dùng chung cho cả phần I và Phần II)

## PHẦN II — ASM DÙNG MULTIPATH

Áp dụng cho:
- Oracle RAC
- SAN Storage
- Fibre Channel
- iSCSI
- Enterprise Production

### II.1 — STORAGE DISCOVERY
- Kiểm tra topology
```bash
lsblk -o NAME,SIZE,TYPE,TRAN,VENDOR,MODEL
```
Output kì vọng ,ví dụ:
```bash
sdb     500G disk
sdc     500G disk
└─mpatha 500G mpath
```

### II.2 — VERIFY MULTIPATH
```bash
multipath -ll
```
Output kì vọng ,ví dụ:
```bash
mpatha (36001405abc1234567890000000000001)
size=500G
|- sdb active ready running
|- sdc active ready running
```

### II.3 — INSTALL MULTIPATH, ENABLE MULTIPATH
```bash
dnf install -y device-mapper-multipath
mpathconf --enable
systemctl enable --now multipathd
```
### II.4 — CONFIGURE MULTIPATH
File cấu hình
```bash
vi /etc/multipath.conf
```
Ví dụ chuẩn production:
```bash
defaults {
find_multipaths smart
user_friendly_names no
}

blacklist {
devnode "^sda"
}

multipaths {
multipath {
wwid "36001405abc1234567890000000000001"
alias asm_data01
}

    multipath {
        wwid "36001405abc1234567890000000000002"
        alias asm_fra01
    }
}
```
- Giải thích:
  - user_friendly_names no kết hợp alias: Ép hệ thống dùng tên alias ta tự đặt thay vì tự sinh ra mpatha, mpathb. Điều này đảm bảo đĩa trên Node 1 và Node 2 của cụm RAC có tên giống hệt nhau 100%.
  - blacklist "^sda": Bỏ qua ổ đĩa cài hệ điều hành (để OS tự quản lý).

### II.5 — VERIFY & REBUILD INITRAMFS
```bash
systemctl restart multipathd
multipath -ll
dracut -f
```
Output kì vọng, ví dụ:
```bash
asm_data01 (36001405abc...)
asm_fra01  (36001405abc...)
```
- Giải thích lệnh dracut -f: Trên môi trường Production, Multipath phải được nạp ngay từ khi boot OS. Lệnh này đóng gói driver multipath và cấu hình vào nhân kernel (initramfs) để đảm bảo đĩa ASM xuất hiện sớm nhất.

### II.6 — CLEAN OLD METADATA

- CHỈ thao tác trên device mapper (/dev/mapper/...). TUYỆT ĐỐI KHÔNG DÙNG /dev/sdb.
```bash
wipefs -a /dev/mapper/asm_data01
sgdisk --zap-all /dev/mapper/asm_data01
multipath -r
```
- Giải thích multipath -r: Ép Multipath daemon làm mới lại (refresh) bản đồ các thiết bị trong bộ nhớ sau khi ta vừa xóa rác.

II.7 — GET DM_UUID AND CREATE UDEV RULES

- Lấy DM_UUID
```bash
udevadm info --query=all --name=/dev/mapper/asm_data01 | grep DM_UUID
```
- Output kì vọng,ví dụ: DM_UUID=mpath-36001405abc1234567890000000000001

- Tạo rule file
```bash
vi /etc/udev/rules.d/99-oracle-asm.rules
```

- Rule chuẩn ví dụ:
```bash
ACTION=="add|change", ENV{DM_UUID}=="mpath-36001405abc1234567890000000000001", SYMLINK+="asm-data01", OWNER="grid", GROUP="asmadmin", MODE="0660", OPTIONS+="last_rule"
ACTION=="add|change", ENV{DM_UUID}=="mpath-36001405abc1234567890000000000002", SYMLINK+="asm-fra01", OWNER="grid", GROUP="asmadmin", MODE="0660", OPTIONS+="last_rule"
```

## PHẦN III: VERIFY & TROUBLESHOOTING (ÁP DỤNG CHO CẢ I VÀ II)

### III.1 — RELOAD UDEV (Áp dụng rule không cần khởi động lại)
```Bash
udevadm control --reload-rules
udevadm trigger --subsystem-match=block
```
### II.12 — Kiểm tra quyền truy cập (Rất quan trọng),KHÔNG dùng ls -l vì nó chỉ hiển thị quyền của cái symlink (luôn là root).
```Bash
```Bash
ls -lL /dev/asm-*
```
- Kỳ vọng: brw-rw---- 1 grid asmadmin
- Giải thích: Cờ -L bắt lệnh ls chạy xuyên qua symlink để kiểm tra quyền của đĩa cứng thực sự nằm ở cuối đường link.

### II.13 — VERIFY ASM

```Bash
su - grid
asmcmd lsdsk -p
# Hoặc:
SELECT path, header_status, mode_status
FROM v$asm_disk;
```
### II.14 — TROUBLESHOOTING

- Đĩa không lên quyền (Vẫn root:disk):
  - Chạy debug: udevadm test /block/sdb (hoặc /block/dm-2). Lệnh này sẽ in ra toàn bộ quá trình udev đọc file rule, bạn sẽ thấy ngay rule bị lỗi cú pháp ở dòng nào.
  
- Multipath bị lỗi đường truyền (Dành cho RAC):
  - Lệnh: multipathd show paths
  - Kiểm tra cột trạng thái. Nếu thấy faulty (chết cáp quang), orphan (đĩa không map được vào WWID nào) => Yêu cầu Storage/Network team kiểm tra lại zoning hoặc cáp. Trạng thái đúng phải là active hoặc ready.

- ASM không nhận đĩa:
  - Đăng nhập user grid chạy: asmcmd lsdsk -p.
  - Chạy SQL: SELECT path, header_status FROM v$asm_disk;
     - CANDIDATE / PROVISIONED: Đĩa sạch, sẵn sàng xài.
     - MEMBER: Đĩa này đã thuộc về cụm ASM nào đó rồi.
     - FOREIGN: Đĩa đang chứa ext4/LVM rác. (Quay lại bước wipefs/sgdisk).
  
## PHẦN IV: RED RULES — CÁC ĐIỀU CẤM KỴ TRÊN PRODUCTION
- Những điều sau đây nếu vi phạm có thể dẫn đến mất dữ liệu hoặc sập hệ thống:
  - KHÔNG cấu hình features "1 queue_if_no_path" trong multipath.conf. Khi kết nối SAN bị đứt, nếu cấu hình tính năng này, Linux sẽ "ôm" lệnh I/O lại chờ Storage sống lại. Đối với Oracle RAC, điều này làm tiến trình bị treo vô hạn (hang). Ta PHẢI để I/O lỗi ngay lập tức (fail-fast) để Oracle Clusterware nhận diện được sự cố và thực hiện evict/reboot node bị lỗi, nhường quyền sống cho node còn lại.
  - KHÔNG dùng lệnh format OS (như mkfs.ext4, mkfs.xfs) lên các đĩa cấp cho ASM. ASM tự quản lý block dữ liệu của nó (Oracle Automatic Storage Management). Format bằng OS sẽ phá hỏng cấu trúc này.
  - KHÔNG cấp quyền (OWNER) cho user oracle. Trong kiến trúc Grid Infrastructure, toàn bộ đĩa phải do user grid và group asmadmin quản lý. User oracle chỉ được cấp quyền sử dụng gián tiếp thông qua group asmdba.