# Project Rules

## Git Automation Rule
- Từ nay về sau, mỗi khi chỉnh sửa/bổ sung tính năng và chạy kiểm thử (`swift test`) thành công, tự động thực hiện `git add .`, `git commit` với mô tả rõ ràng, và `git push origin <branch>` lên GitHub mà không cần chờ nhắc nhở.

## Native Currency trong Bảng Positions (Positions Table Currency)
- Trong bảng vị thế (Positions Table / Positions Card), các cột **Cost basis**, **Market Value**, và **P&L** của mỗi vị thế **bắt buộc dùng nguyên đồng tiền gốc (Native Currency)** của symbol đó (ví dụ: `₫` / VND cho mã Việt Nam, `$` / USD cho mã Mỹ, `¥` / JPY cho mã Nhật), **không được tự động quy đổi (convert)** sang đồng tiền ưu tiên danh mục (`preferredCurrency`).
- Chỉ quy đổi (convert) theo tỷ giá FX rate sang `preferredCurrency` đối với các con số **thống kê tổng quát chung** của Portfolio (như Portfolio Total Value, Total Cost, Total P&L, Hero Card...).

## Cân Nhắc Kỹ Hiệu Năng Trước Khi Sửa Code (Performance First Consideration)
- Trước khi thực hiện bất kỳ thay đổi nào trong codebase (đặc biệt là quản lý state, tính toán dữ liệu, vòng lặp re-render hoặc lưu trữ I/O), **bắt buộc phải phân tích và đánh giá kỹ lưỡng ảnh hưởng đến hiệu năng** (CPU, Memory, Network Requests, Render latency / Frame rate).
- Đảm bảo các giải pháp kỹ thuật luôn tối ưu tài nguyên, không gây giật lag (zero UI frame drops), không gây re-render thừa và tận dụng tối đa cơ chế in-memory cache / debounced I/O.

## Quy Tắc Build (Build Rule)
- Mỗi khi chỉnh sửa code, kiểm thử hoặc hoàn thành tính năng, **bắt buộc phải build macOS (`./dev.sh`)**. **Mặc định KHÔNG build iOS (`./dev-ios.sh`)** để tiết kiệm token, trừ khi người dùng chỉ định rõ.



## Tư Duy Triển Khai Ngang (Horizontal Deployment)
- Khi sửa bất kỳ bug nào, bắt buộc phải rà soát và triển khai cách sửa tương tự sang các màn hình/tính năng khác có logic tương đồng để đảm bảo tính nhất quán.
