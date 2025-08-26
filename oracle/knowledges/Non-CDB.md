### 1. Non-CDB trong Oracle là gì?

- Non-CDB (Non-Container Database) là kiến trúc truyền thống trước Oracle 12c, hoặc chế độ có thể chọn trong 12c+.

- Trong Non-CDB:

 - Chỉ có 1 database duy nhất trong instance (giống như 1 hệ quản trị độc lập).

 - Không có PDB (Pluggable Database).

 - Có thể tạo nhiều schema trong database đó, nhưng không thể tạo thêm PDB.

### 2. Container Database (CDB) khác gì?

- Từ Oracle 12c trở đi, mặc định kiến trúc là CDB.

- CDB gồm:

	- CDB root (giống hệ điều hành chính).

	- Seed PDB (mẫu).

	- Nhiều PDB (Pluggable Database), mỗi PDB hoạt động gần như một database riêng.

- CDB cho phép tạo nhiều PDB trong cùng một instance.

- So sánh với SQL Server:

	- SQL Server: 1 instance có thể có nhiều database độc lập.

	- Oracle Non-CDB: 1 instance = 1 database (nhưng có nhiều schema).

	- Oracle CDB: 1 instance = 1 CDB, trong đó có nhiều PDB (mỗi PDB ~ giống 1 database trong SQL Server).


- Nếu cài Oracle non-CDB, thì:

✔ Chỉ có 1 database duy nhất (ORACLE_SID = tên database đó, ví dụ oradb).

✔ Có thể tạo nhiều schema trong database đó.

✖ Không thể tạo thêm PDB (vì PDB chỉ có trong CDB).


### 3. SQL Server vs Oracle Non-CDB vs Oracle CDB

|                | SQL Server                         | Oracle Non-CDB                      | Oracle CDB                                  |
|----------------|------------------------------------|-------------------------------------|---------------------------------------------|
| **Instance**   | Instance                           | Instance                            | Instance                                    |
| **Tầng trên**  | Database                           | Database                            | CDB Root                                    |
| **Tầng dưới**  | Database                           | Schema                              | PDB                                         |
| **Tầng dưới**  | Database                           | Schema                              | PDB                                         |

#### Ghi chú:

- **SQL Server**: 1 Instance có nhiều Database độc lập.
- **Oracle Non-CDB**: 1 Instance có 1 Database duy nhất, chứa nhiều Schema.
- **Oracle CDB**: 1 Instance có 1 CDB (Root) và nhiều PDB (Pluggable Database).
