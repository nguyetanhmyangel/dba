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
  👉 Sau đó:
  ```bash
  ./runInstaller
  ```
  - Cách 2: Dùng VNC (ổn định hơn)
  ```bash
  yum install tigervnc-server
  ```