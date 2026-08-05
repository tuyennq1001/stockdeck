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

## 6. Quy trình Git Branching & Automation (Feature Branch & PR Workflow)
- **Tự động tạo Feature / Fix Branch**: Mỗi khi người dùng giao nhiệm vụ sửa bug hoặc phát triển tính năng mới, **tự động tạo nhánh riêng biệt** (`feature/<tên-tính-năng>` hoặc `fix/<tên-lỗi>`) từ `main` trước khi viết code.
- **Kiểm thử → Build → Xác nhận → Commit**: Sau khi viết code xong:
  1. Chạy `swift test` — PHẢI PASS 100% trước khi tiếp tục.
  2. Chạy `./dev.sh` (hoặc `swift build`) để rebuild app — PHẢI build thành công.
  3. **Chờ người dùng xác nhận** app chạy đúng trải nghiệm.
  4. Sau khi user OK mới commit code với mô tả rõ ràng (`feat(...)`, `fix(...)`).
- **Commit message ngắn gọn**: Tiêu đề commit/PR **bắt buộc ≤ 72 ký tự**. Body mô tả phải **ngắn gọn ≤5 dòng**. Nếu cần mô tả dài, ghi ra file riêng rồi dẫn link.
- **Push CHỈ KHI người dùng yêu cầu**: Mặc định KHÔNG push lên GitHub. Khi user bảo "push" mới thực hiện `git push origin <branch>`.
- **Tạo PR sau khi push**: Sử dụng GitHub CLI (`gh pr create`) với body ngắn gọn sau khi đã push và được user yêu cầu.
- **Rebuild trên nhánh Feature**: Chạy `./dev.sh` trên nhánh feature để user kiểm tra & trải nghiệm trực tiếp.
- **Xác nhận Merge (Sau khi người dùng đồng ý)**:
  - **Chờ người dùng xác nhận "OK" / Duyệt**: Sau khi người dùng đồng ý, tiến hành merge PR vào `main` (`gh pr merge --merge --delete-branch`), chuyển về `main` và xoá nhánh local.

---

## 7. Quy tắc CLI & Script (Tránh Treo/Timeout)
- **Không viết Python/Python3 inline script dài trong `-c`**: Nếu script Python vượt quá ~5 dòng, **bắt buộc ghi ra file `.py` tạm** (dùng `write_to_file` hoặc heredoc `cat > /tmp/script.py << 'EOF'`), chạy file đó, rồi xóa file tạm sau khi chạy xong. Tuyệt đối không nhồi toàn bộ script vào `python3 -c "..."`.
- **Không dùng heredoc trong `execute_command` nếu nội dung chứa ký tự đặc biệt**: Nếu cần, ghi file riêng rồi chạy.
- **Giới hạn độ dài command**: Mỗi câu lệnh CLI không vượt quá ~2000 ký tự. Nếu dài hơn, tách thành script file.
- **Commit/PR title**: Tối đa 72 ký tự. Body mô tả phải **ngắn gọn ≤5 dòng**. Nếu cần mô tả dài, ghi ra file riêng rồi dẫn link.

---

## 8. Quy tắc Build (Build Rules)
- **Dùng `./dev.sh` làm lệnh build chính thức**: Luôn dùng `./dev.sh` thay vì `swift build` trực tiếp để đảm bảo nhất quán môi trường build.
- **Không pipe build output qua `grep` hoặc filter blocking khác**: Hiển thị toàn bộ output build để không bỏ sót lỗi. `grep` có thể treo nếu pattern không khớp.
- **Nếu cần kiểm tra nhanh lỗi biên dịch**: Dùng `swift build 2>&1 | head -100` (có giới hạn dòng, không treo) hoặc `./dev.sh 2>&1 | tail -20`.

---

## 9. Nguyên Tắc Trung Thực & Xác Nhận Phương Án (Truthfulness & Mandatory Human Approval)
- **Trung thực dữ liệu tuyệt đối (No Fake / Dummy Data)**: Tuyệt đối **không tự ý tạo dữ liệu giả, tên giả (dummy names), hoặc nhồi kết quả giả định (placeholder heuristic)** vào danh sách tìm kiếm hay thông tin định giá. Tất cả tên công ty, mã chứng khoán và dữ liệu hiển thị bắt buộc phải là dữ liệu thật 100% lấy từ các API chính thức hoặc nguồn uy tín đã kiểm chứng.
- **Bắt buộc chờ Người dùng Approve trước khi sửa code**: Trước khi tiến hành chỉnh sửa bất kỳ dòng code nào:
  1. AI phải giải thích nguyên nhân và trình bày phương án kỹ thuật rõ ràng.
  2. **CHỈ TIẾN HÀNH VIẾT CODE KHI NGƯỜI DÙNG XÁC NHẬN "OK" / DUYỆT TRỰC TIẾP** bằng lời nhắn trong chat.
  3. Tuyệt đối **không tự động nhảy sang bước viết code / thực thi (Execute)** dù có thông báo chuyển bước từ hệ thống khi người dùng chưa trực tiếp nhắn tin đồng ý.
