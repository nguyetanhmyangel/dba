WSFC sử dụng quorum để duy trì tính nhất quán và quyết định majority khi có sự cố. Có thể kiểm tra qua giao diện đồ họa (Failover Cluster Manager) hoặc PowerShell.

#### 1. Kiểm tra qua Failover Cluster Manager (GUI)

Failover Cluster Manager là công cụ trực quan dễ sử dụng nhất.

- Bước 1: Mở Failover Cluster Manager.

    Trên một node của cluster (ví dụ: SQL01), tìm kiếm "Failover Cluster Manager" trong Start Menu và mở nó.

- Bước 2: Kết nối đến cluster.

    Trong cửa sổ, click vào "Connect to Cluster" và chọn tên cluster của bạn (ví dụ: SQLCL01).

- Bước 3: Xem cấu hình quorum.

Trong cây bên trái, right-click vào tên cluster (SQLCL01) > chọn "More Actions" > "Configure Cluster Quorum Settings".

Hoặc, right-click cluster > Properties > tab "Quorum".

Ở đây, sẽ thấy loại quorum đang sử dụng:

Node Majority: Không dùng witness, chỉ dựa vào số node (phù hợp với số lẻ node).

Node and Disk Majority: Sử dụng shared disk (Disk Witness). Nếu thấy "Disk Witness" và chỉ định một ổ đĩa (ví dụ: Cluster Disk 1), nghĩa là đang dùng shared disk.

Node and File Share Majority: Sử dụng Node and File Share Witness. Nếu thấy "File Share Witness" và đường dẫn file share (ví dụ: \servername\QUORUM\SQLCL01), nghĩa là không dùng shared disk mà dùng file share làm witness.

No Majority: Disk Only: Cũ, chỉ dùng disk (không khuyến nghị).

- Bước 4: Nếu dùng File Share Witness, xem folder.

Trong phần Quorum Configuration, ghi chú đường dẫn file share (ví dụ: \servername\QUORUM\SQLCL01).

Mở File Explorer trên máy (hoặc remote đến server chứa file share).

Duyệt đến đường dẫn đó (ví dụ: \servername\QUORUM\SQLCL01). Sẽ thấy một thư mục chứa file quorum (thường là file .qrm hoặc tương tự, nhưng không cần chỉnh sửa, chỉ xem để xác nhận).

Lưu ý: Cần quyền truy cập (Full Control) cho account cluster (SQLCL01$) để xem. Nếu không thấy, kiểm tra quyền NTFS/Share Permissions.

Nếu cluster không hiển thị, kiểm tra xem feature Failover Clustering đã cài và đang chạy với quyền admin.

#### 2. Kiểm tra qua PowerShell (Dành cho script hoặc remote)

PowerShell nhanh hơn và có thể chạy từ xa.

Bước 1: Mở PowerShell với quyền admin trên một node.

Bước 2: Import module (nếu cần):

```bash
textImport-Module FailoverClusters
```

Bước 3: Kiểm tra quorum:

```bash
textGet-ClusterQuorum -Cluster "SQLCL01"  # Thay SQLCL01 bằng tên cluster
```

Kết quả sẽ hiển thị:

QuorumType: NodeMajority (không witness), NodeAndDiskMajority (shared disk), NodeAndFileShareMajority (file share witness), DiskOnly (cũ).

QuorumResource: Nếu dùng witness, sẽ chỉ định resource (disk hoặc file share).

Bước 4: Nếu dùng File Share Witness, xem chi tiết folder:

```bash
textGet-ClusterResource | Where-Object { $_.ResourceType -eq "File Share Witness" }
```

Kết quả sẽ hiển thị đường dẫn file share (ví dụ: \servername\QUORUM\SQLCL01).
Sau đó, dùng lệnh để xem folder từ xa:

```bash
textGet-ChildItem "\\servername\QUORUM\SQLCL01"  # Thay bằng đường dẫn thực tế
```

Nếu lỗi quyền, đăng nhập server chứa file share và kiểm tra thủ công.

Lưu ý chung

Nếu đang dùng shared disk (Disk Witness), sẽ thấy một resource disk trong Failover Cluster Manager dưới "Storage" > "Disks".

Với cấu hình không shared disk (như Node and File Share Witness), không có disk resource, và quorum dựa vào file share trên server thứ ba (không phải node cluster).

Nếu cluster có vấn đề (quorum lost), kiểm tra event log: Event Viewer > Applications and Services Logs > Microsoft > Windows > FailoverClustering.

Để thay đổi quorum, dùng lệnh Set-ClusterQuorum trong PowerShell, nhưng chỉ làm khi cần và test kỹ.