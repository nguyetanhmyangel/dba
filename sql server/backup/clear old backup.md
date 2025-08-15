### Xóa các file backup transaction log cũ hơn 8h

```bash
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

### 2. Xóa các file backup diff và full cũ hơn 7 ngày

```bash
# --- CÁC THAM SỐ CẦN THAY ĐỔI ---
$Path = "\\sharedisk\QLSX\Backup" # Đường dẫn đến thư mục chứa file backup
$Days = 7                         # Xóa các file cũ hơn số ngày này
# --------------------------------

try {
    # Ghi log bắt đầu
    Write-Host "Bat dau qua trinh don dep file backup cu..."

    # Tính toán mốc thời gian giới hạn
    $CutoffDate = (Get-Date).AddDays(-$Days)
    Write-Host "Moc thoi gian (xoa file cu hon): $CutoffDate"
    Write-Host "Tim va xoa cac file .bak cu hon $Days ngay trong thu muc: $Path"

    # Lấy danh sách các file .bak thỏa mãn điều kiện
    # Sử dụng -File để chỉ lấy file, -Recurse để tìm trong cả thư mục con
    $files_to_delete = Get-ChildItem -Path $Path -Recurse -File -Filter "*.bak" | Where-Object { $_.LastWriteTime -lt $CutoffDate }

    if ($files_to_delete) {
        # Thực thi xóa và hiển thị chi tiết (do có -Verbose)
        $files_to_delete | Remove-Item -Force -Verbose
        Write-Host "Da xoa xong cac file cu."
    } else {
        Write-Host "Khong tim thay file .bak nao cu hon $Days ngay de xoa."
    }

    # Báo thành công cho SQL Agent
    exit 0
}
catch {
    # Ghi lại lỗi nếu có sự cố xảy ra
    Write-Error ("Da xay ra loi: " + $_.Exception.Message)
    
    # Báo thất bại cho SQL Agent
    exit 1
}
```