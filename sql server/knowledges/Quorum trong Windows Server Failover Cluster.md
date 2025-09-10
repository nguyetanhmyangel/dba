### 1. Quorum

Quorum trong Windows Server Failover Cluster (WSFC) là cơ chế xác định cụm (cluster) có thể hoạt động bình thường hay không, đảm bảo tránh tình trạng "split-brain" (khi các node hoạt động độc lập và gây ra xung đột dữ liệu).

- 1. Quorum là gì?

Quorum = số phiếu (votes) tối thiểu mà cluster cần để duy trì hoạt động.

Mỗi thành phần trong cluster có thể có vote:

Node: mỗi node trong cluster thường có 1 vote.

Witness: có thể là disk witness hoặc file share witness (cũng tính như 1 vote).

Quorum được tính dựa trên đa số (majority) votes.

Nếu mất quorum → cluster sẽ dừng để bảo vệ dữ liệu.

- 2. Các loại mô hình Quorum trong WSFC

Có 4 mô hình chính:

    - (a) Node Majority

    Chỉ tính vote từ các node.

    Phù hợp khi số lượng node là lẻ (3, 5, 7...).

    Ví dụ: 3 node → cần ≥2 votes để cluster hoạt động.

    - (b) Node and Disk Majority

    Các node + 1 disk witness (shared storage).

    Dùng khi số node chẵn (2, 4...).

    Ví dụ: 4 node + 1 disk witness → tổng 5 votes → cần 3 votes.

    - (c) Node and File Share Majority

    Các node + 1 file share witness (trên server thứ ba).

    Thường dùng khi không có SAN để tạo disk witness.

    File share witness không chứa dữ liệu, chỉ lưu thông tin quorum.

    - (d) No Majority: Disk Only

    Chỉ dùng disk witness để quyết định quorum.

    Rất rủi ro, vì mất disk witness → cluster fail.

    Hầu như không khuyến nghị cho production.

- 3. Witness là gì và khi nào cần?

Witness giúp đạt số lượng votes lẻ → giảm nguy cơ mất quorum.

Các loại witness:

Disk Witness: một LUN chung trong SAN.

File Share Witness: một thư mục chia sẻ SMB (trên server khác, không thuộc cluster).

Cloud Witness: dùng Azure Blob Storage (Windows Server 2016+).

Khi cần witness?

Số node chẵn → nên dùng witness.

Số node lẻ → có thể không cần.

- 4. Tính toán Quorum

Công thức:

Cần > 50% tổng votes để cluster hoạt động.


Ví dụ:

2 node (2 votes) → cần 2 votes (không an toàn → cần witness).

2 node + file share witness (3 votes) → cần 2 votes.

- 5. Split-Brain Scenario

Nếu quorum không đúng, cluster có thể bị chia làm 2 phần cùng hoạt động độc lập → gây mất dữ liệu.

Quorum giúp chỉ một phần cluster được hoạt động khi có sự cố.


### 2. Disk Witness

Disk Witness là một đĩa dùng chung (shared disk) trong cụm, thường nằm trên SAN (Storage Area Network).

Lưu trữ:

Một bản sao nhỏ thông tin cấu hình của cluster.

Dùng để bỏ phiếu khi cần đạt quorum.

Cơ chế:

Đĩa này được các node truy cập chung qua mạng SAN.

Chỉ một node sở hữu disk witness tại một thời điểm.

Ưu điểm:

Tốc độ nhanh (vì trong hạ tầng SAN).

Nhược điểm:

Nếu SAN bị sự cố → mất disk witness.

Không phù hợp nếu cluster không có shared storage (ví dụ: cluster chỉ dùng Storage Spaces Direct hoặc cloud).

### 3. File Share Witness

File Share Witness là một thư mục chia sẻ SMB trên một máy chủ hoặc thiết bị NAS ngoài cluster.

Lưu trữ:

Một file nhỏ (witness.log) để ghi thông tin bầu cử quorum.

Cơ chế:

Các node sẽ ghi/đọc vào file share để xác định ai có quyền vote.

Không lưu dữ liệu ứng dụng, chỉ lưu thông tin quorum.

Ưu điểm:

Dễ triển khai (chỉ cần một máy ngoài cluster làm file server).

Không yêu cầu SAN.

Nhược điểm:

Nếu file server witness bị down → mất 1 phiếu quorum.

### 4. So sánh nhanh

| Tiêu chí              | **Disk Witness**           | **File Share Witness**                    |
| --------------------- | -------------------------- | ----------------------------------------- |
| **Vị trí lưu**        | LUN trên SAN               | Thư mục SMB trên máy khác                 |
| **Dùng khi nào**      | Có SAN và dùng shared disk | Không có SAN, dùng NAS hoặc server thường |
| **Hiệu năng**         | Cao (vì SAN)               | Phụ thuộc vào SMB network                 |
| **Khả năng chịu lỗi** | Tốt nếu SAN ổn định        | Tốt nếu file server ổn định               |


Khi nào nên dùng loại nào?

Cluster truyền thống có SAN → dùng Disk Witness.

Cluster trên Storage Spaces Direct, Hyper-V, Azure → dùng File Share Witness hoặc Cloud Witness.