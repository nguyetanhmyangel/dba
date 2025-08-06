### Tạo Job Step dùng PowerShell

- Tạo một Job mới (hoặc một Step mới trong Job bảo trì).

- Trong cửa sổ New Job Step:

- Ở mục Type, bạn phải chọn là PowerShell.

- Ở mục Run as, chọn tài khoản có quyền đọc/ghi/xóa trên thư mục backup (thường là tài khoản của SQL Server Agent).

- Nội dung cần dán vào mục Command:

```bash
# Script dọn dẹp file backup log cũ hơn 8 giờ
# Phiên bản tương thích với PowerShell v2.0

# --- Các biến có thể thay đổi ---
$Path = "D:\Backup\Tranlogs"
$Hours = 8
# --------------------------------

try {
    # Ghi log bắt đầu
    Write-Host "Start the backup log file creation process..."

    # Tính toán thời gian giới hạn
    $CutoffTime = (Get-Date).AddHours(-$Hours)
    Write-Host "Time limit (delete older files): $CutoffTime"
    Write-Host "Find and delete file .trn older than $Hours in the folder: $Path"

    # Lấy danh sách file cần xóa
    $files_to_delete = Get-ChildItem -Path $Path -Recurse -File -Filter "*.trn" | Where-Object { $_.LastWriteTime -lt $CutoffTime }

    if ($files_to_delete) {
        # Thực thi xóa
        $files_to_delete | Remove-Item -Force -Verbose
        Write-Host "Deleted."
    } else {
        Write-Host "Can't find any file to delete."
    }

    # Báo thành công cho SQL Agent
    exit 0
}
catch {
    # Ghi lỗi
    # === DÒNG ĐÃ SỬA LỖI ===
    Write-Error ("Error: " + $_.Exception.Message)
    
    # Báo thất bại cho SQL Agent
    exit 1
}
```