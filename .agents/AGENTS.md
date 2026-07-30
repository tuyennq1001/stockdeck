# Project Rules

## Git Automation Rule
- Từ nay về sau, mỗi khi chỉnh sửa/bổ sung tính năng và chạy kiểm thử (`swift test`) thành công, tự động thực hiện `git add .`, `git commit` với mô tả rõ ràng, và `git push origin <branch>` lên GitHub mà không cần chờ nhắc nhở.

## Native Currency trong Bảng Positions (Positions Table Currency)
- Trong bảng vị thế (Positions Table / Positions Card), các cột **Cost basis**, **Market Value**, và **P&L** của mỗi vị thế **bắt buộc dùng nguyên đồng tiền gốc (Native Currency)** của symbol đó (ví dụ: `₫` / VND cho mã Việt Nam, `$` / USD cho mã Mỹ, `¥` / JPY cho mã Nhật), **không được tự động quy đổi (convert)** sang đồng tiền ưu tiên danh mục (`preferredCurrency`).
- Chỉ quy đổi (convert) theo tỷ giá FX rate sang `preferredCurrency` đối với các con số **thống kê tổng quát chung** của Portfolio (như Portfolio Total Value, Total Cost, Total P&L, Hero Card...).

