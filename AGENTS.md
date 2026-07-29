# Project Rules & Vital Principles (Nguyên Tắc Sống Còn)

Dưới đây là tập hợp các nguyên tắc sống còn bắt buộc tuân thủ 100% trong mọi lần phát triển và bảo trì dự án StockDeck.

---

## 1. Định giá Portfolio & Phiên giao dịch (Valuation & Market Session)
- **Dùng giá đóng cửa phiên chính (`quote.price`)**: Tất cả định giá Portfolio Value, Total P&L, Position P&L, Top Gainers & Top Losers **bắt buộc** chỉ sử dụng giá và biến động của phiên chính (`quote.price`, `quote.changePercent`).
- **Không dùng Extended Hours cho P&L**: Tuyệt đối **không** dùng giá giao dịch ngoài giờ (Pre-Market / After-Hours) để tính định giá Portfolio hay xếp hạng Top Gainers/Losers. Cột `Ext` (nếu hiển thị) chỉ mang tính chất tham khảo riêng biệt.
- **Tính ổn định ngoài giờ**: Sau khi giờ giao dịch chính đóng cửa, giá trị các danh mục chứng khoán/quỹ **bắt buộc giữ cố định 100%**, không được thay đổi. Riêng tài sản Crypto (24/7) được phép cập nhật realtime theo đặc thù thị trường.

---

## 2. Thống nhất con số & Tối ưu tài nguyên (Single Source of Truth & Performance)
- **Dùng chung 1 nguồn dữ liệu duy nhất**: Tất cả các chỉ số hiệu suất hiển thị ở các vị trí khác nhau (ví dụ: Pill mốc thời gian 1M/3M/1Y ở Hero Card trên và cột 1M/3M/1Y ở Bảng Performance & Benchmark dưới) **bắt buộc sử dụng chung 1 giá trị duy nhất** từ `cachedPerformance`.
- **Tính toán 1 lần duy nhất**: Mọi công thức hiệu suất nặng **bắt buộc chỉ được tính toán 1 lần duy nhất** trong phiên (lưu cache bộ nhớ) để tránh lãng phí tài nguyên CPU và băng thông mạng.
- **Đo lường biến động thị trường thực tế**: Tính % hiệu suất giai đoạn (1M, 3M, 6M...) dựa trên biến động giá thị trường thực tế (`valueSeries`), **không** sử dụng snapshot thô bị biến động do hành vi nạp/thêm/bớt vị thế cổ phiếu của người dùng.

---

## 3. Quản lý Tỷ giá Hối đoái (FX Rates)
- **Cố định tỷ giá theo ngày / khi mở app**: Tỷ giá hối đoái (FX Rate) dùng tính toán Portfolio **chỉ tải 1 lần duy nhất khi mở app** (hoặc tối đa 1 lần/ngày). Giữ cố định tỷ giá trong suốt phiên làm việc để app vừa nhẹ, vừa nhanh, vừa ổn định số dư.

---

## 4. Chuẩn hóa Quỹ Mở Nhật Bản (Japanese Mutual Funds)
- **Quy đổi Tỷ lệ 10,000 口 (`scale = 10000.0`)**: Mọi phép tính định giá hiện tại, giá vốn và chuỗi lịch sử cho các quỹ mở Nhật Bản **bắt buộc chia cho tỷ lệ `10000.0`**.

---

## 5. Bảng Benchmark & Dữ liệu Lịch sử
- **Trung thực dữ liệu**: Nếu danh mục chưa đủ khoảng thời gian lịch sử (ví dụ 5Y, 10Y), hiển thị dấu `-`, tuyệt đối không tự bịa số.
- **Tải dữ liệu đồng bộ**: Tải đồng thời cả `priceHistory` ngắn hạn và `priceHistoryMax` dài hạn cho tất cả các mã trong danh mục cũng như chỉ số S&P 500 (`^GSPC`) ngay khi mở ứng dụng.

---

## 6. Quy trình Build & Automation Git
- **Kill App cũ khi Rebuild (`dev.sh`)**: Script `./dev.sh` **bắt buộc kill triệt để mọi phiên bản app StockDeck cũ** trước khi chạy bản build mới.
- **Tự động Git Commit & Push**: Mỗi khi chỉnh sửa/bổ sung tính năng và chạy kiểm thử (`swift test`) thành công, **tự động thực hiện `git add .`, `git commit` với mô tả rõ ràng, và `git push origin <branch>` lên GitHub** mà không cần chờ nhắc nhở.
