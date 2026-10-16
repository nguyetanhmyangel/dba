Dưới đây là phần đánh giá, chỉnh sửa và **Cheat Sheet hoàn chỉnh** dành riêng cho vai trò **System Administrator & Oracle DBA trên nền tảng Oracle Linux / RHEL (7/8/9)**.

---

### Đánh giá & Các điểm sửa đổi, bổ sung cốt lõi

1. **Lỗi định dạng & lệnh chưa chuẩn:**
* Sửa lỗi dính lệnh (ví dụ: `pwdlsls` $\rightarrow$ `pwd`, `ls -lah`, v.v.).
* Sửa lệnh `du`: Thêm cờ `--max-depth=1` thay cho `du -xhd1` trên một số phiên bản coreutils cũ để tương thích 100%.
* Xóa bỏ các dòng trùng lặp trong bảng file cấu hình (như `/etc/fstab` bị lặp 2 lần).


2. **Bổ sung bắt buộc cho SysAdmin / DBA:**
* **Kernel & ASM/Storage:** `oracle-database-preinstall-19c/23ai`, Oracle ASMLib/ASM Filter Driver (`oracleasm`, `asmcmd`), cấu hình HugePages & Transparent HugePages (THP).
* **Resource Limits:** `/etc/security/limits.d/oracle.conf` (nofile, nproc, memlock, stack).
* **Networking:** `nmcli` (chuẩn NetworkManager trên EL8/9 thay thế file `/etc/sysconfig/network-scripts/ifcfg-*`), `tcpdump`, `traceroute`.
* **Xử lý Disk & Inode:** Tìm inode đầy (`df -i`), xử lý file log đã xóa nhưng vẫn bị process giữ (`lsof +L1`).
* **IPC & Shared Memory:** `ipcs -m`, `ipcrm` (dọn dẹp bộ nhớ chia sẻ khi Database crash).
* **SELinux thực chiến:** `restorecon`, `semanage fcontext`, `audit2why`.



---

# CHEAT SHEET THỰC CHIẾN: ORACLE LINUX / RHEL CHO SYSADMIN & DBA

---

## 1. Thông tin hệ thống (System Info)

```bash
# Kiểm tra phiên bản OS
cat /etc/os-release
cat /etc/oracle-release         # Đặc trưng Oracle Linux
uname -r                        # Kiểm tra Kernel (UEK hay RHCK)

# CPU
lscpu                           # Chi tiết kiến trúc CPU, Sockets, Cores/Socket, Threads
nproc                           # Tổng số logical cores khả dụng

# RAM & Memory Pressure
free -h                         # Tổng quan RAM/Swap (chú ý cột available)
cat /proc/meminfo               # Thông tin chi tiết RAM
vmstat 1 5                      # Theo dõi memory, swap (si/so), io (bi/bo), cpu

# Disk & Storage layout
lsblk -f                        # Danh sách ổ cứng kèm UUID và filesystem type
df -Th                          # Dung lượng disk kèm định dạng (XFS, ext4, nfs...)
df -ih                          # Kiểm tra Inode (hết inode sẽ không tạo thêm được file dù còn dung lượng)

```

---

## 2. Thao tác File & Điều hướng (Filesystem Navigation)

```bash
# Điều hướng
pwd                             # Đường dẫn hiện tại
cd /u01/app/oracle              # Chuyển thư mục
cd -                            # Quay lại thư mục trước đó
cd ~                            # Về Home directory

# Liệt kê & Phân tích dung lượng
ls -lah                         # Liệt kê chi tiết file ẩn, size dạng human-readable
du -sh * | sort -h              # Dung lượng từng thư mục con tại vị trí hiện tại
du -xh --max-depth=1 /var | sort -h | tail -20 # Tìm 20 thư mục nặng nhất trên cùng filesystem

# Tạo, Copy, Xóa
mkdir -p /u01/app/oracle/product/19c/dbhome_1 # Tạo cây thư mục
cp -a /backup/config /backup/config_bak       # Copy giữ nguyên permission, timestamp
mv old.log /tmp/
rm -rf /tmp/old_dir             # Cẩn thận tuyệt đối khi chạy với quyền root/oracle

```

---

## 3. Xem, Tìm kiếm & Xử lý File (File Handling & Logs)

```bash
# Xem log realtime
tail -f -n 200 alert_ORCL.log   # Xem 200 dòng cuối và bám theo log mới
less +G alert_ORCL.log          # Mở file lớn với less, nhảy ngay đến cuối file

# Tìm kiếm log (grep)
grep -i "ORA-" alert_ORCL.log   # Tìm lỗi Oracle không phân biệt hoa thường
grep -E "ORA-00600|ORA-07445" alert_ORCL.log # Tìm nhiều mã lỗi nghiêm trọng
grep -rn "ERROR" /var/log/      # Tìm đệ quy kèm số dòng

# Xử lý văn bản (sed & awk)
awk '{print $1, $5}' /var/log/messages # Lọc cột 1 và cột 5
sed -i 's/SELINUX=enforcing/SELINUX=permissive/g' /etc/selinux/config # Sửa file tại chỗ

# VIM cơ bản
# i (Insert mode), Esc (Command mode), :wq (Lưu & Thoát), :q! (Thoát không lưu)
# :set nu (Hiển thị số dòng), /pattern (Tìm kiếm, gõ 'n' để xem kết quả tiếp)

```

---

## 4. Quản lý User, Group & Phân quyền (User, Permissions & Sudo)

```bash
# Tạo User & Group chuẩn cho Oracle DBA
groupadd -g 54321 oinstall
groupadd -g 54322 dba
groupadd -g 54323 oper
groupadd -g 54324 backupdba
groupadd -g 54325 dgdba
groupadd -g 54326 kmdba
groupadd -g 54327 asmdba

useradd -u 54321 -g oinstall -G dba,asmdba,backupdba,dgdba,kmdba,oper -m oracle
passwd oracle

# Phân quyền & Sở hữu
chown -R oracle:oinstall /u01
chmod -R 775 /u01
chmod 600 /home/oracle/.ssh/id_rsa

# Cấp quyền Sudo an toàn
visudo -f /etc/sudoers.d/99-oracle-admin
# Cú pháp bên trong file:
# oracle ALL=(ALL) NOPASSWD: ALL

```

---

## 5. Quản lý Process, CPU & Memory (Process & Performance)

```bash
# Giám sát & Tìm kiếm Process
ps -ef | grep pmon              # Kiểm tra các instance Oracle đang chạy (ora_pmon_<ORACLE_SID>)
pgrep -fl pmon
top -c                          # Monitor CPU/RAM kèm full command path
htop                            # Giao diện trực quan (cần cài đặt: dnf install htop)

# Sắp xếp Process theo tài nguyên
ps aux --sort=-%cpu | head -n 10
ps aux --sort=-%mem | head -n 10

# Kill Process
kill -15 PID                    # SIGTERM: Yêu cầu dừng an toàn
kill -9 PID                     # SIGKILL: Ép dừng ngay (chỉ dùng khi process treo hoàn toàn)

# Dọn dẹp IPC / Shared Memory (Khi DB crash nhưng memory segment chưa giải phóng)
ipcs -m                         # Xem danh sách shared memory
ipcrm -m <shmid>                # Xóa shared memory segment bị cô lập

```

---

## 6. Systemd & Quản lý Nhật ký (Systemd & Journald)

```bash
# Service management
systemctl status oracle-database-preinstall-19c
systemctl enable --now chronyd  # Bật khởi động cùng OS và chạy ngay lập tức
systemctl restart firewalld
systemctl list-units --type=service --state=failed # Kiểm tra các service bị lỗi

# Journalctl logs
journalctl -xeu sshd.service    # Xem log chi tiết kèm giải thích lỗi của sshd
journalctl -f -u chronyd        # Bám log realtime theo service
journalctl --since "30 minutes ago"
journalctl -b -0 -p err..emerg  # Xem các log mức Error -> Emergency từ lần boot hiện tại

```

---

## 7. Mạng, Port & Kết nối (Network & Connectivity)

```bash
# Quản lý mạng bằng NetworkManager (Chuẩn RHEL/OL 8/9)
nmcli connection show
nmcli device status
nmcli con mod eth0 ipv4.addresses 192.168.1.100/24 ipv4.gateway 192.168.1.1 ipv4.dns "8.8.8.8 1.1.1.1" ipv4.method manual
nmcli con up eth0

# Kiểm tra IP & Routing
ip a
ip route show

# Kiểm tra Port (Database Listeners, Web, SSH)
ss -tulpn                       # Xem tất cả listening ports (TCP/UDP) kèm Process
ss -lntp | grep 1521            # Kiểm tra Oracle Listener port 1521

# Kiểm tra kết nối & Bắt gói tin
nc -zvw3 192.168.1.50 1521      # Kiểm tra thông port từ xa với timeout 3s
curl -Iv http://127.0.0.1:8080  # Test endpoint HTTP
tcpdump -nn -i any port 1521 -c 50 # Bắt 50 gói tin qua port Listener để debug

```

---

## 8. Tường lửa & Bảo mật (Firewalld & SELinux)

```bash
# Firewalld cho Oracle DB
firewall-cmd --permanent --add-port=1521/tcp     # Mở port Listener
firewall-cmd --permanent --add-port=5500/tcp     # Mở port EM Express
firewall-cmd --reload
firewall-cmd --list-all

# SELinux Quản trị chuẩn
getenforce                      # Xem trạng thái (Enforcing/Permissive/Disabled)
sestatus                        # Thông tin chi tiết chính sách

# Xử lý lỗi SELinux mà không cần tắt
ausearch -m AVC -ts recent      # Tìm lỗi chặn gần nhất
restorecon -Rv /u01             # Khôi phục file context mặc định cho thư mục /u01
semanage fcontext -a -t usr_t "/u01(/.*)?" # Gán policy cho thư mục dữ liệu mới

```

---

## 9. Quản lý Storage, LVM & XFS (Storage & LVM Operations)

```bash
# LVM Workflow: Disk -> PV -> VG -> LV -> Filesystem

# 1. Tạo mới
pvcreate /dev/sdb /dev/sdc
vgcreate vg_data /dev/sdb /dev/sdc
lvcreate -L 200G -n lv_u01 vg_data
mkfs.xfs /dev/vg_data/lv_u01

# 2. Mở rộng dung lượng online (Không cần downtime)
# Thêm disk mới vào VG nếu hết chỗ:
pvcreate /dev/sdd && vgextend vg_data /dev/sdd
# Tăng Logical Volume thêm 50GB:
lvextend -L +50G /dev/vg_data/lv_u01
# Mở rộng filesystem XFS:
xfs_growfs /u01                 # Đối với XFS dùng điểm mount /u01
# (Nếu là ext4 thì dùng: resize2fs /dev/vg_data/lv_u01)

# Kiểm tra fstab an toàn trước khi reboot
cat /etc/fstab
mount -a                        # Nếu lệnh này không báo lỗi thì reboot mới an toàn

```

---

## 10. Quản trị Đĩa ASM / Grid Infrastructure (Oracle Specific)

```bash
# 1. Cấu hình ASMLib
oracleasm configure -i          # Thiết lập user/group sở hữu (oracle/grid, dba/asmdba)
oracleasm init                  # Khởi tạo driver
oracleasm createdisk DATA1 /dev/sdb1
oracleasm listdisks
oracleasm scandisks

# 2. Quản trị qua ASMCMD (Khi đăng nhập bằng user grid/oracle)
asmcmd lsdg                     # Liệt kê Diskgroup, dung lượng Total/Free/Usable
asmcmd lsdsk -k                 # Liệt kê chi tiết từng ASM Disk

```

---

## 11. Cấu hình Kernel, HugePages & Limits cho Oracle Database

```bash
# Cài đặt gói tự động chuẩn bị môi trường (Khuyên dùng)
dnf install -y oracle-database-preinstall-19c
# (Hoặc oracle-database-preinstall-23ai tùy phiên bản)

# Tắt Transparent HugePages (THP) - Bắt buộc cho Oracle DB & RAC
cat /sys/kernel/mm/transparent_hugepage/enabled
# Thêm tham số sau vào cấu hình GRUB (/etc/default/grub):
# transparent_hugepage=never
grub2-mkconfig -o /boot/grub2/grub.cfg

# Resource Limits: /etc/security/limits.d/oracle-database-preinstall-19c.conf
# oracle   soft   nofile    1024
# oracle   hard   nofile    65536
# oracle   soft   nproc     2047
# oracle   hard   nproc     16384
# oracle   soft   stack     10240
# oracle   hard   stack     32768
# oracle   hard   memlock   134217728

# Kiểm tra limits đang áp dụng
su - oracle -c "ulimit -a"

# Nạp cấu hình Kernel Runtime
sysctl --system

```

---

## 12. Troubleshooting Tình huống Khẩn cấp (Incident Response)

| Tình huống | Lệnh kiểm tra nhanh | Hành động xử lý |
| --- | --- | --- |
| **Server chậm / Treo I/O** | `uptime`<br>

<br>`iostat -xz 1 5`<br>

<br>`sar -q 1 5` | Xem `%iowait` trên CPU và `%util` trên Disk. Nếu `%util ~ 100%`, ổ đĩa đang nghẽn I/O. |
| **Hết Disk ảo (Deleted files)** | `lsof +L1` hoặc<br>

<br>`lsof | grep deleted` | File đã bị `rm` nhưng process vẫn đang mở ghi. Cần reload/restart process đó để giải phóng dung lượng. |
| **Hết Inodes** | `df -ih` | Dùng `find /var/spool/clientmqueue -type f | wc -l` để tìm thư mục chứa hàng triệu file rác/mail. |
| **Port bị chiếm dụng** | `lsof -i :1521`<br>

<br>`fuser 1521/tcp` | Dùng `fuser -k 1521/tcp` để kill nhanh process đang chiếm port trái phép. |
| **Quản lý Kernel không reboot** | `ksplice uptrack-show`<br>

<br>`ksplice uptrack-upgrade -y` | Áp dụng bản vá bảo mật kernel trực tiếp qua Ksplice (Oracle Linux). |

---

## 13. Tổng hợp đường dẫn cấu hình cốt lõi

```
/etc/hosts                         # Phân giải tên miền nội bộ (RAC yêu cầu chuẩn)
/etc/resolv.conf                   # Cấu hình DNS Server
/etc/fstab                         # Danh sách Filesystem mount tự động
/etc/chrony.conf                   # Cấu hình NTP Time Sync (Cực kỳ quan trọng cho RAC)
/etc/security/limits.conf          # User resource limits (nofile, nproc...)
/etc/sysctl.d/99-oracle.conf       # Tham số Kernel (shmmax, shmall, file-max...)
/etc/systemd/system/               # Thư mục custom systemd service units
/var/log/messages                  # System message log chung
/var/log/audit/audit.log           # Log kiểm toán bảo mật & SELinux denials
/u01/app/oracle/diag/              # Oracle Automatic Diagnostic Repository (ADR)

```