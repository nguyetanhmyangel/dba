### 1. Tắt Transparent HugePages:
- Kiểm tra:
```bash
sudo su -
cat /sys/kernel/mm/transparent_hugepage/enabled
```
- Giá trị trong [] là mode hiện tại:
  - always = kernel luôn cố dùng THP
  - madvise = chỉ dùng khi app yêu cầu
  - never = tắt hoàn toàn
- Nếu kết quả là [always] → Transparent HugePages (THP) đang được kích hoạt toàn thời gian -> tắt Transparent HugePages. Vào /etc/default/grub và chỉnh parameter GRUB_CMDLINE_LINUX như sau:
```bash
vi /etc/default/grub

GRUB_CMDLINE_LINUX="crashkernel=auto rhgb quiet transparent_hugepage=never"
```
- Tạo lại (regenerate) file cấu hình GRUB2 (grub.cfg), lưu tại đường dẫn /boot/grub2/grub.cfg và restart máy và kết nối lại:
```bash
grub2-mkconfig -o /boot/grub2/grub.cfg
reboot
```
### 2. Đặt hostname tĩnh và chỉnh "/etc/hostname"
- Giả sử ta muốn hostname và ip của server là oracle-lab,192.168.1.21
```bash
hostnamectl set-hostname oracle-lab
vi /etc/hosts
# thêm dòng dưới vào 
192.168.1.21 oracle-lab
# hoặc dùng command sau(chỉ ghi khi ko tồn tại,tránh duplicate)
grep -q "oracle-lab" /etc/hosts || echo "192.168.1.21 oracle-lab" | sudo tee -a /etc/hosts
```
### 4. Tắt firewalld trên server:
```bash
systemctl stop firewalld.service
systemctl disable firewalld.service
```

### 5. Set module bảo mật kernel Linux SELinux sang chế độ permissive(thay vì disable):
```bash
# chỉnh sửa config trong /etc/selinux/
vi /etc/selinux/config
SELINUX=permissive
# hoặc dùng command
sudo sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config
# áp dụng ngay (không cần reboot)
sudo setenforce 0
# kiểm tra 
getenforce
```

### 6. Bật đồng bộ thời gian:
```bash
systemctl enable chronyd.service
systemctl restart chronyd.service
systemctl status chronyd
chronyc tracking
chronyc sources
chronyc -a burst 4/4
chronyc -a makestep
```

## 7. Lấy bản sửa lỗi và lỗi bảo mật Linux mới nhất và áp dụng:
```bash
yum update -y
yum upgrade -y
Reboot
```
### 8. Đăng nhập vào server với tư cách là root rồi chạy lệnh sau để tự động cài đặt và cập nhật các gói hệ điều hành cần thiết cho phần mềm Oracle database 19c.
```bash
yum install oracle-database-preinstall-19c
```
Trong trường hợp thực tế, nếu máy không được kết nối Internet, chúng ta phải tải xuống và cài đặt thủ công các gói cần thiết.

### 9.1 Kiểm tra raw disk cho ASM:
```bash
lsblk -f
```
Output ví dụ:
```bash
NAME   FSTYPE MOUNTPOINT
sda    ext4   /
sdb
sdc    xfs    /data
```
sde → trống: raw disk (OK cho ASM). sdc → xfs: đã format + mount

- Script phát hiện disk “bẩn” (không dùng cho ASM)
```bash
lsblk -dn -o NAME,FSTYPE,MOUNTPOINT | awk '$2!="" || $3!="" {print "/dev/"$1 " NOT RAW"}'
```
- Check sâu hơn (Oracle hay dùng)
```bash
blkid
```
- Nếu có output kiểu:
```bash
/dev/sdc: UUID="..." TYPE="xfs"
```
=> đã format

- Nếu lỡ format + mount -> Làm 3 bước sau để làm sạch disk: unmount → wipe → verify

- Bước 1: Unmount
```bash
sudo umount /dev/sdc
```
Nếu báo busy:
```bash
lsof | grep /dev/sdc
```
- Bước 2: Xóa filesystem (QUAN TRỌNG)
```bash
sudo wipefs -a /dev/sdc
```
-> Xóa signature filesystem

Cách mạnh tay (khi cần)
```bash
sudo dd if=/dev/zero of=/dev/sdc bs=1M count=100
```
-> Xóa metadata đầu disk

- Bước 3: Verify lại kiểm tra phải thấy không FSTYPE, không MOUNTPOINT
```bash
lsblk -f
```
- Bonus: check có bị mount tự động không
```bash
cat /etc/fstab
```
-> Nếu có dòng kiểu:  "/dev/sdc /data xfs defaults 0 0" thì phải xóa đi, không nó mount lại khi reboot

### 9.2 Phân vùng disk sẽ cài đặt, ổ đây là: /dev/sde
- tạo phân vùng:
```bash
sudo fdisk /dev/sde
# d (nếu cần)
# n
# p
# 1
# Enter
# Enter
# w
```
- Hệ thống nhận diện các thay đổi
```bash
sudo partprobe
```
- Định dạng (Format) File System
```bash
sudo mkfs.ext4 /dev/sde1
```
- Tạo Thư mục và Mount Point
```bash
sudo mkdir /u01
sudo mount /dev/sde1 /u01/
```
- Để mount không bị mất sau reboot: lấy UUID của các phân vùng.Mở file /etc/fstab để chỉnh sửa, thêm các dòng sau vào cuối file với YOUR_UUID_FOR_SDB1 là UUID thực tế của ổ đĩa sdb1:
```bash
# Lấy UUID của disk
sudo blkid
# chỉnh sửa fstab
sudo vi /etc/fstab
UUID=YOUR_UUID_FOR_SDB1 /u02 ext4 defaults 0 2
# hoặc dùng ommand sau thay vì chỉnh sửa fstab trực tiếp:
UUID=$(blkid -s UUID -o value /dev/sde1)

grep -q "$UUID" /etc/fstab || \
echo "UUID=$UUID /u01 ext4 defaults,nofail 0 2" | sudo tee -a /etc/fstab
```
### 10. Tạo các group cần thiết & user cần thiết(nếu ko dùng ASM disk thì có thể bỏ qua các group có tiền tố asm)
```bash
declare -A grps=([oinstall]=54321 [dba]=54322 [oper]=54323 [backupdba]=54324 [dgdba]=54325 [kmdba]=54326 [asmadmin]=54327 [asmdba]=54328 [asmoper]=54329 [racdba]=54330)
for g in "${!grps[@]}"; do sudo groupadd -f -g "${grps[$g]}" "$g"; done

# user 'grid'
if ! id grid &>/dev/null; then
    sudo useradd -m -u 54331 -g oinstall -G asmadmin,asmdba,asmoper -d /home/grid -s /bin/bash -c "Grid Infrastructure Owner" grid
else
    sudo usermod -g oinstall -G asmadmin,asmdba,asmoper -c "Grid Infrastructure Owner" grid
fi

# user 'oracle'
if ! id oracle &>/dev/null; then
    sudo useradd -m -u 54332 -g oinstall -G dba,oper,backupdba,dgdba,kmdba,racdba,asmdba -d /home/oracle -s /bin/bash -c "Oracle Software Owner" oracle
else
    sudo usermod -g oinstall -G dba,oper,backupdba,dgdba,kmdba,racdba,asmdba -c "Oracle Software Owner" oracle
fi

# change password grid, oracle user:
passwd oracle
passwd grid
```
### 11. Tạo biến môi trường cho grid và oracle user
- oracle user:
```bash
# switch sang user to oracle ,change bash_profile
su - oracle
vi .bash_profile

# .bash_profile
if [ -f ~/.bashrc ]; then
. ~/.bashrc
fi

# Oracle Settings
export ORACLE_SID=orcl
export ORACLE_UNQNAME=orcl
export ORACLE_BASE=/u01/app/oracle
export ORACLE_HOME=$ORACLE_BASE/product/19.0.0/dbhome_1
export TNS_ADMIN=$ORACLE_HOME/network/admin
export NLS_DATE_FORMAT="DD-MON-YYYY HH24:MI:SS"

# Path Settings
export PATH=$ORACLE_HOME/bin:/usr/local/bin:/usr/bin:/bin:$HOME/bin:$PATH
export LD_LIBRARY_PATH=$ORACLE_HOME/lib:/lib:/usr/lib:/usr/local/lib

# Temp Directory Settings
export TEMP=/tmp
export TMPDIR=/tmp

umask 022
```
- grid user:
```bash
# switch sang user to grid ,change bash_profile
su - oracle
vi .bash_profile

# .bash_profile
if [ -f ~/.bashrc ]; then
. ~/.bashrc
fi

# Oracle Settings
export ORACLE_SID=+ASM
export ORACLE_BASE=/u01/app/grid
export ORACLE_HOME=/u01/app/19.0.0/grid
export TNS_ADMIN=$ORACLE_HOME/network/admin

# Path Settings
export PATH=$ORACLE_HOME/bin:/usr/local/bin:/usr/bin:/bin:$HOME/bin:$PATH
export LD_LIBRARY_PATH=$ORACLE_HOME/lib:/lib:/usr/lib:/usr/local/lib

# Temp Directory Settings
export TEMP=/tmp
export TMPDIR=/tmp

umask 022
```
- chạy lệnh ở từng user tương ứng để nạp cấu hình:
```bash
. ~/.bash_profile 
# hoặc 
source ~/.bash_profile
```

# 12. tạo các folder cần thiết cho install:
```bash
su - root
mkdir /u01/app/oraInventory
mkdir /u01/app/grid
mkdir /u01/app/19.0.0/grid
mkdir /u01/app/oracle/product/19.0.0/dbhome_1

chown -R grid:oinstall /u01/app/oraInventory
chown -R grid:oinstall /u01/app/grid
chown -R grid:oinstall /u01/app/19.0.0/grid

chown -R oracle:oinstall /u01/app/oracle
# Permissions
chmod -R 775 /u01/app


```
# 13. Cấu hình ASM disk sử dụng udev(ở đây ko dùng multipath, xem thêm về "oracle asm disk configuration")
- Chỉ thao tác đúng disk sẽ dùng ASM.
```bash
# Xóa filesystem signature - chữ ký filesystem (ext4, xfs, lvm) ở đầu đĩa.
wipefs -a /dev/sdb
# Xóa GPT/MBR metadata. GPT có một bản backup nằm ở cuối đĩa, nếu không dùng sgdisk xóa đi, đôi khi OS tự quét lại và khôi phục nhầm, gây hỏng ASM Header.
sgdisk --zap-all /dev/sdb
# Verify disk sạch, Disk ASM KHÔNG được hiện:TYPE=, UUID=, PARTUUID=
blkid
```

- Tạo 1 partition chiếm toàn bộ disk sẽ tạo ASM.
```bash
# --- c1: partition dùng fdisk ----
sudo fdisk /dev/sdb
# thao tác:
# d (nếu cần)
# n
# p
# 1
# Enter
# Enter
# w
# ---- end fdisk ----

# ---- c2: partition dùng parted(tốt hơn) ----
parted /dev/sdb
## Tạo GPT label
mklabel gpt
## 
mkpart primary 1MiB 100%
## kiểm tra và thoát
print
quit
# ------ end parted --------------------------

# --- (hoặc viết gọn hơn cho parted:)----
parted /dev/sdb --script \
mklabel gpt \
mkpart primary 1MiB 100%
# -----------------end short parted ---------------------

# Hệ thống nhận diện các thay đổi
sudo partprobe /dev/sdb
```
- Tạo UDEV rule theo partition UUID hoặc ID.
### I.2 — VERIFY DISK IDENTITY

- Lấy WWN/SCSI ID/SERIAL, theo thứ tự ưu tiên:ID_WWN,SCSI ID, ID_SERIAL
```bash
udevadm info --query=all --name=/dev/sdb | egrep 'ID_WWN|ID_SERIAL'
# hoặc sử dụng SCSI ID 
/usr/lib/udev/scsi_id -g -u -d /dev/sdb
```
  - Output kỳ vọng ví dụ: E: ID_WWN=0x60022480abcd1234 hoặc E: ID_SERIAL=123456789
  - Giải thích: Trên Linux, tên /dev/sdb có thể bị đổi thành sdc sau khi khởi động lại. Do đó, bắt buộc phải dùng ID phần cứng (WWN hoặc SERIAL) để làm "căn cước công dân" cố định cho đĩa.
  - NOTE DÀNH CHO VMWARE: Nếu lệnh trên trả về kết quả rỗng (không thấy WWN/SERIAL), nguyên nhân là ảo hóa đang che giấu thông tin đĩa. Hãy yêu cầu vSphere Admin thêm dòng disk.EnableUUID = "TRUE" vào Advanced Settings của máy ảo và Reboot OS.
```
- Tạo rule file
```bash
vi /etc/udev/rules.d/99-oracle-asm.rules
```
- Ví dụ rule chuẩn:
```bash
# sử dụng WWN
ACTION=="add|change", KERNEL=="sd*1", SUBSYSTEM=="block", ENV{ID_WWN}=="0x60022480abcd1234", SYMLINK+="asm-data01", OWNER="grid", GROUP="asmadmin", MODE="0660", OPTIONS+="last_rule"

# sử dụng scsi_id
ACTION=="add|change",KERNEL=="sd*1", SUBSYSTEM=="block", PROGRAM=="/usr/lib/udev/scsi_id -g -u -d /dev/%k", RESULT=="1ATA_VBOX_HARDDISK_VBc32a8285-2f41fe02", SYMLINK+="asm-disk1", OWNER="grid", GROUP="asmadmin", MODE="0660", OPTIONS+="last_rule"

# sử dụng ID_SERIAL
ACTION=="add|change", KERNEL=="sd*1", SUBSYSTEM=="block", ENV{ID_SERIAL}=="VBOX_HARDDISK_VBc32a8285-2f41fe02", SYMLINK+="asm-disk1", OWNER="grid", GROUP="asmadmin", MODE="0660", OPTIONS+="last_rule"
```
  - Giải thích:
    - KERNEL=="sd*[!0-9]": Chốt chặn an toàn! Chỉ áp dụng cho ổ vật lý (sdb, sdc), tuyệt đối bỏ qua các phân vùng (sdb1, sdc2). Giúp tăng tốc boot.
    - OPTIONS+="last_rule": Bảo UDEV rằng "Đọc đến đây là xong, đừng cho các rules mặc định khác của hệ thống ghi đè lên quyền của đĩa này nữa".

- RELOAD UDEV (Áp dụng rule không cần khởi động lại)
```Bash
udevadm control --reload-rules
udevadm trigger --subsystem-match=block
udevadm settle
```
- Kiểm tra quyền truy cập (Rất quan trọng),KHÔNG dùng ls -l vì nó chỉ hiển thị quyền của cái symlink (luôn là root).
```Bash
ls -lL /dev/asm-*
```
- Kỳ vọng: brw-rw---- 1 grid asmadmin
- Giải thích: Cờ -L bắt lệnh ls chạy xuyên qua symlink để kiểm tra quyền của đĩa cứng thực sự nằm ở cuối đường link.

- VERIFY Grid user access
```Bash
su - grid
dd if=/dev/asm-disk1 of=/dev/null bs=1M count=1
```
### 14. Upload file cài đặt cần thiết & unzip
- Ở đây là upload từ Ubuntu host:
```Bash
# upload file bộ cài database vào đường dẫn: /u01/app/oracle/product/19.0.0/dbhome_1/
scp "/mnt/data/Tools/Oracle 19c/Enterprise/Database/V982063-01.zip" root@192.168.1.21:/u01/app/oracle/product/19.0.0/dbhome_1/
# upload file bộ cài grid vào đường dẫn: /u01/app/19.0.0/grid/
scp "/mnt/data/Tools/Oracle 19c/Enterprise/Grid/V982068-01.zip" root@192.168.1.21:/u01/app/19.0.0/grid/
```
- Giải nén: 
```Bash
su -
cd /u01/app/19.0.0/grid/
unzip V982068-01.zip

cd /u01/app/oracle/product/19.0.0/dbhome_1/
unzip V982063-01.zi
```
### 15. Khởi động lại hệ thống, Login vào user grid và tiến hành cài đặt Grid Infra (GI):

- 1. Với Window host
```Bash
su - grid

# set biến DISPLAY: 
export DISPLAY=192.168.1.21:0.0

# Không truyền tham số thì cd sẽ quay về home directory của user hiện tại. ví du: user grid → về /home/grid
cd
# đọc và thực thi file shell ngay trong session hiện tại ~ source .bash_profile
. .bash_profile

cd /u01/app/19.0.0/grid
./gridSetup.sh
```
Trong đó IP = ip của máy tính window hiện tại đang thực hiện SSH vào server Linux

- 2. Ubuntu host(linux khác tương tự):

    - install:
    ```Bash
    sudo apt update
    sudo apt install xauth x11-apps openssh-client -y
    ```
    - SSH vào Oracle Linux bằng X11 forwarding .Từ Ubuntu terminal:
    ```Bash
    ssh -X grid@IP_ORACLE_SERVER
    #hoặc tốt hơn:
    ssh -Y grid@IP_ORACLE_SERVER
    ```
    Ví dụ: ssh -Y grid@192.168.1.50
    
    - Kiểm tra DISPLAY
    
    ```Bash
    echo $DISPLAY
    ```
    ouput phải ra: localhost:10.0.KHÔNG phải IP Ubuntu nữa.
    
    - Test GUI
    ```Bash
    xclock
    # hoặc:
    xdpyinfo
    ```
    - Chạy Oracle Grid
    ```Bash
    cd
    . .bash_profile
    cd /u01/app/19.0.0/grid
    ./gridSetup.sh
    ```
  



