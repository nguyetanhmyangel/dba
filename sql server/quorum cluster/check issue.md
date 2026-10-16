#### Kiểm tra các lỗi Warning, Critical, Error trong ngày chọn

```PowerShell
# 1. Chọn ngày cần kiểm tra (định dạng YYYY-MM-DD)
$targetDate = "2026-09-27"

$start = Get-Date "$targetDate 00:00:00"
$end   = Get-Date "$targetDate 23:59:59"

# 2. Quét log System (lọc theo Provider Cluster) và log Operational riêng của FailoverClustering
$events = @()

# Quét trên kênh System
$events += Get-WinEvent -FilterHashtable @{
    LogName      = 'System'
    ProviderName = 'Microsoft-Windows-FailoverClustering'
    Level        = 1, 2, 3   # 1 = Critical, 2=Error, 3 = Warning (thêm 2 nếu muốn lấy cả Error)
    StartTime    = $start
    EndTime      = $end
} -ErrorAction SilentlyContinue

# Quét trên kênh FailoverClustering/Operational
$events += Get-WinEvent -FilterHashtable @{
    LogName   = 'Microsoft-Windows-FailoverClustering/Operational'
    Level     = 1, 2, 3
    StartTime = $start
    EndTime   = $end
} -ErrorAction SilentlyContinue

# 3. Sắp xếp từ đầu ngày đến cuối ngày và hiển thị
$events | 
Sort-Object TimeCreated | 
Format-Table TimeCreated, Id, LevelDisplayName, Message -Wrap
```

#### Kiểm tra các event trong thời gian chọn
```PowerShell
$start = Get-Date "2026-09-27 00:01:00"
$end   = Get-Date "2026-09-27 00:15:00"

$logs = @('System', 'Application', 'Microsoft-Windows-FailoverClustering/Operational')

Get-WinEvent -FilterHashtable @{
    LogName   = $logs
    StartTime = $start
    EndTime   = $end
} -ErrorAction SilentlyContinue | 
Sort-Object TimeCreated | 
Format-Table TimeCreated, LogName, Id, LevelDisplayName, ProviderName, Message -Wrap
```

#### Kiểm tra trạng thái cluster hiện tại

```PowerShell
Get-ClusterNode
Get-ClusterResource
Get-ClusterNetwork
```

#### Kiểm tra time sync
```PowerShell
w32tm /query /status
w32tm /query /source
```

### VMware Tools time sync
```PowerShell
# Kiểm tra
& "C:\Program Files\VMware\VMware Tools\VMwareToolboxCmd.exe" timesync status

# Tắt time sync
& "C:\Program Files\VMware\VMware Tools\VMwareToolboxCmd.exe" timesync disable

Bật 
& "C:\Program Files\VMware\VMware Tools\VMwareToolboxCmd.exe" timesync enable

Xem phiên bản 
& "C:\Program Files\VMware\VMware Tools\VMwareToolboxCmd.exe" -v
```