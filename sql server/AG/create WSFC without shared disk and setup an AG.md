#### 0. Lưu ý quan trọng:

- Cần ít nhất 2 node (server) chạy Windows Server (khuyến nghị Windows Server 2022 hoặc mới hơn).

- Môi trường phải có Active Directory Domain (không hỗ trợ workgroup).

- SQL Server phiên bản Enterprise (từ 2012 trở lên) để hỗ trợ AlwaysOn AG.

- Không cần shared disk; sử dụng quorum dựa trên Node and File Share Witness.

- Thực hiện trên môi trường test trước khi áp dụng production.

- Nếu gặp lỗi, kiểm tra quyền admin và firewall (nên disable firewall trong domain cho test).

#### 1. Chuẩn bị môi trường (Prerequisites)

Trước khi bắt đầu, đảm bảo các yêu cầu sau:

    - Hardware/VM: Ít nhất 2 server (node) với cấu hình tương đương: CPU 4 cores, RAM 16GB+, storage riêng (ví dụ: C: OS, D: Apps, G: Data, L: Logs). 

    - Format ổ đĩa với allocation unit size 64KB cho SQL.

    - Network: Static IP cho mỗi node (ví dụ: SQL01: 10.10.10.150, SQL02: 10.10.10.151). Cần IP riêng cho cluster (CNO: 10.10.10.152) và AG Listener (10.10.10.153). Đảm bảo các node ping lẫn nhau.

    - Domain: Tất cả node phải join domain (ví dụ: mydomain.com). Cần Domain Controller (DC) với Active Directory và DNS.

    - Accounts: Tạo domain account cho SQL service (ví dụ: mydomain\sqlsvc) và group admin (mydomain\sqladmins).

    - Software: Windows Server 2022+, SQL Server 2019+ Enterprise Edition. Tải ISO SQL từ Microsoft.

    - Permissions: Tài khoản cài đặt phải là domain admin hoặc có quyền tương đương.

Sử dụng PowerShell để kiểm tra và cấu hình cơ bản trên mỗi node:

- Đổi tên server và IP:

```bash
textRename-Computer -NewName "SQL01" -Force
New-NetIPAddress -InterfaceAlias "Ethernet" -IPAddress 10.10.10.150 -PrefixLength 24 -DefaultGateway 10.10.10.1
Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses 10.10.10.10
Restart-Computer
```

(Lặp lại cho SQL02 với IP phù hợp).

- Join domain:

```bash
textAdd-Computer -DomainName "mydomain.com"
Restart-Computer
```

- Firewall 

    - Disable firewall:

    ```bash
    textSet-NetFirewallProfile -Profile Domain,Public,Private -Enabled False
    ```

    - Hoặc giữ Firewall bật và chỉ mở các port cần thiết:

    ```bash
    # Cho phép Failover Clustering
    Enable-NetFirewallRule -DisplayGroup "Failover Cluster Manager"
    Enable-NetFirewallRule -DisplayGroup "Windows Management Instrumentation (WMI)"
    Enable-NetFirewallRule -DisplayGroup "Windows Remote Management"

    # Port mặc định cho SQL Server
    New-NetFirewallRule -DisplayName "SQL Server (TCP 1433)" -Direction Inbound -Protocol TCP -LocalPort 1433 -Action Allow

    # Port mặc định cho AG Endpoint (Database Mirroring)
    New-NetFirewallRule -DisplayName "SQL AG Endpoint (TCP 5022)" -Direction Inbound -Protocol TCP -LocalPort 5022 -Action Allow

    # Cho phép Ping (ICMP) để kiểm tra kết nối
    New-NetFirewallRule -DisplayName "Allow ICMPv4-In" -Protocol ICMPv4 -IcmpType 8 -Action Allow
    ```
- Enable Remote Desktop:

```bash
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -name "fDenyTSConnections" -value 0
Restart-Computer
```

- Phân quyền quản trị (Administrator) cho user hoặc nhóm mydomain\sqladmins

```bash
Add-LocalGroupMember -Group "Administrators" -Member "mydomain\sqladmins"
Restart-Computer
```
- Restart server

```bash
Restart-Computer
```

#### 2. Cài đặt SQL Server trên mỗi node

Mỗi node sẽ có instance SQL riêng, với storage riêng (không shared).

- Cấp quyền "Perform volume maintenance tasks" trong Local Security Policy:

    - Mở secpol.msc.

    - Đi đến Local Policies > User Rights Assignment.

    - Tìm và mở "Perform volume maintenance tasks".

    - Thêm tài khoản mydomain\sqlsvc vào danh sách.

- Mount ISO SQL và chạy setup qua PowerShell trên SQL01 (thay password thực tế):

```bash
textNET USE Y: '\\path\to\sql\iso'
Y:\setup.exe /qs /ACTION=Install /FEATURES=SQLEngine,FullText /INSTANCENAME=INST01 /SQLSVCACCOUNT='mydomain\sqlsvc' /SQLSVCPASSWORD='password' /SQLSYSADMINACCOUNTS='mydomain\sqladmins' /AGTSVCACCOUNT='mydomain\sqlsvc' /AGTSVCPASSWORD='password' /AGTSVCSTARTUPTYPE=Automatic /TCPENABLED=1 /SQLSVCINSTANTFILEINIT=True /INSTALLSQLDATADIR='D:\Program Files\Microsoft SQL Server' /SQLBACKUPDIR='G:\SQL\INST01\Backup' /SQLUSERDBDIR='G:\SQL\INST01\DATA' /SQLUSERDBLOGDIR='L:\SQL\INST01\LOGS' /USESQLRECOMMENDEDMEMORYLIMITS /IACCEPTSQLSERVERLICENSETERMS
```

- Lặp lại trên SQL02.

- Kiểm tra: Mở SQL Server Configuration Manager, đảm bảo service chạy.

#### 3. Cài đặt Failover Clustering Feature

- Trên cả hai node, cài feature qua PowerShell:

```bash
textInstall-WindowsFeature Failover-Clustering –IncludeManagementTools
```

#### 4. Pre-create Cluster Name Object (CNO) trong Active Directory

- Trên Domain Controller, mở Active Directory Users and Computers.

- Tạo computer account mới với tên cluster (ví dụ: SQLCL01).

- Gán quyền: Right-click CNO > Properties > Security > Add domain account cài đặt > Full Control.

#### 5. Tạo Windows Server Failover Cluster (WSFC)

- Trên SQL01, chạy PowerShell:

```bash
New-Cluster –Name SQLCL01 –StaticAddress 10.10.10.152 –Node SQL01,SQL02 –NoStorage
```

- Mở Failover Cluster Manager (tìm trong Start Menu) để kiểm tra cluster đã tạo.

- Validate cluster: Trong Failover Cluster Manager, right-click cluster > Validate Configuration > Chạy all tests (nên pass hết, bỏ qua warning về storage vì không dùng shared disk).

#### 6. Cấu hình Quorum (sử dụng Node and File Share Witness vì không shared disk)

Quorum giúp cluster quyết định majority vote khi có sự cố. Với 2 node, dùng File Share Witness làm "tie-breaker".

- Tạo file share trên server khác (không phải node, ví dụ: DC hoặc server thứ 3):

    - Tạo folder: C:\QUORUM\SQLCL01
    - Share folder, gán Full Control cho account cluster (SQLCL01$).

- Trên SQL01, chạy PowerShell:

```bash
textSet-ClusterQuorum -FileShareWitness "\\servername\QUORUM\SQLCL01"
```

- Kiểm tra trong Failover Cluster Manager: Right-click cluster > Properties > Quorum > Xác nhận File Share Witness.

#### 7. Enable AlwaysOn trên mỗi SQL Instance

- Trên mỗi node, chạy PowerShell:

```bash
text$ServerInstance = 'SQL01\INST01'  # Thay bằng tên instance
Enable-SqlAlwaysOn -ServerInstance $ServerInstance
```

(Lặp cho SQL02).

- Restart SQL service trong SQL Configuration Manager để apply.

#### 8. Tạo AlwaysOn Availability Groups (AG)

Sử dụng SQL Server Management Studio (SSMS) trên SQL01 (primary node).

- Kết nối SSMS đến SQL01\INST01.

- Right-click Always On High Availability > New Availability Group Wizard.

- Specify Name: Đặt tên AG (ví dụ: MyAG).

- Select Databases: Chọn database cần replicate (phải ở Full Recovery Mode, có full backup trước).

- Specify Replicas: Add SQL02\INST01 làm secondary replica.

    - Availability Mode: Synchronous Commit (cho HA, đồng bộ tức thì) hoặc Asynchronous Commit (cho DR, không đồng bộ, ít latency hơn nhưng có thể mất data).
    - Failover Mode: Automatic (nếu synchronous) hoặc Manual.
    - Readable Secondary: Yes (nếu cần read từ secondary).


- nSelect Data Synchronization: Automatic Seeding (nếu SQL 2016+), hoặc Manual (backup/restore thủ công).

- Specify Listener: Tạo Listener (ví dụ: Name: SQLAGL01, IP: 10.10.10.153, Port: 1433).

- Validate và Finish wizard.

- Kiểm tra: Expand Availability Groups trong SSMS, kiểm tra status synchronized.

- Lưu ý: 

    - AG Endpoint: Wizard sẽ tự động tạo một Database Mirroring Endpoint (thường ở port 5022) để các replica giao tiếp với nhau. Nên biết về sự tồn tại của nó và đảm bảo port này được mở trên firewall (như đã đề cập ở Mục 1).

    - Listener và Client Connection String: Khi ứng dụng kết nối qua Listener, đặc biệt trong môi trường có thể mở rộng ra nhiều subnet sau này, chuỗi kết nối (connection string) nên bao gồm tham số  MultiSubnetFailover=True. Tham số này giúp client nhanh chóng kết nối lại khi có failover xảy ra, tránh bị timeout. Đây là một lưu ý quan trọng cho đội phát triển ứng dụng.

#### 9. Kiểm tra và bảo trì

- Test failover: Trong SSMS, right-click AG > Failover > Chọn secondary làm primary.

- Monitor: Sử dụng Dashboard trong SSMS hoặc query sys.dm_hadr_availability_replica_states.

- Backup: Nên backup trên primary, nhưng có thể config preference cho secondary.

- Nếu cần mở rộng: Add thêm replica (tối đa 9, với 3 synchronous).

