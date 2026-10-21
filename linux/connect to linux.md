## Kết nối từ 1 máy linux tới 1 máy linux:

### 1. SSH (có sẵn)

- Dùng terminal luôn:
```bash
ssh oracle@192.168.1.21
```
Đây chính là thứ MobaXterm dùng bên trong

- Truyền file (thay SFTP của MobaXterm)
```bash
scp file.zip oracle@192.168.1.21:/home/oracle
```
hoặc:
```bash
rsync -av file.zip oracle@192.168.1.21:/home/oracle
```
### 2.Dùng GUI:

- Remmina (RDP, SSH)
- File Manager (Nautilus):
- Other Locations → sftp://ip
- Nếu cần GUI của Oracle (installer)
  - Cách 1: X11 Forwarding (giống MobaXterm)
  ```bash
  ssh -X oracle@192.168.1.21
  ```
  Sau đó:
  ```bash
  ./runInstaller
  ```
  - Cách 2: Dùng VNC (ổn định hơn)
  ```bash
  yum install tigervnc-server
  ```
  
### ssh vào oracle máy ảo trên máy thật:

```bash
ssh -J nghianl.ts@172.19.13.27 root@192.168.56.101
```

output:
```text
nghianl.ts@172.19.13.27's password: -> nhập password vào máy remote
root@192.168.56.101's password: -> nhập passwrod vào máy ảo trên máy thật remote
Last login: Mon Oct 19 11:35:17 2026
[root@oracle-lab ~]#
```

### dùng toad kết nối đến oracle máy ảo trên máy thật:

- Bước 1: Mở SSH Tunnel

- Mở terminal (CMD hoặc PowerShell) trên Windows và chạy lệnh:

```DOS
ssh -J nghianl.ts@172.19.13.27 -L 1521:192.168.56.101:1521 -N root@192.168.56.101
```
Nhập mật khẩu cho từng server khi được hỏi. Để nguyên cửa sổ này chạy ngầm (không tắt).

- Bước 2: cài đặt Oracle database client, tạo tnsname ví dụ dưới và dùng toad kết nối qua tnsname
```text
# Connect to the PDB1 via an SSH tunnel 
ORCL_TUNNEL_PDB1 =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = 127.0.0.1)(PORT = 1521))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = pdb1)
    )
  )

# Connect to the CDB Root via an SSH tunnel (use SERVICE_NAME)
ORCL_TUNNEL_CDB =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = 127.0.0.1)(PORT = 1521))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = orclcdb)
    )
  )

# Connect to the CDB Root via an SSH tunnel (using the SID as a fallback, if necessary)
ORCL_TUNNEL_CDB_SID =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = 127.0.0.1)(PORT = 1521))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SID = orclcdb)
    )
  )
```