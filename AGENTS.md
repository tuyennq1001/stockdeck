# AGENTS & CODING RULES (QUY TẮC VẬN HÀNH & KỸ THUẬT)

Tài liệu này là bộ quy tắc cốt lõi gồm 2 phần rõ rệt:
- **PHẦN 1: NGUYÊN TẮC KỸ THUẬT CHUNG (UNIVERSAL COMMON RULES)**: Bắt buộc tuân thủ trên mọi dự án phần mềm (Web, Mobile, Backend, CLI... bất kể ngôn ngữ). **Giữ nguyên 100% khi copy sang dự án mới hoặc đưa vào ChatGPT/AI tool.**
- **PHẦN 2: QUY TẮC ĐẶC THÙ DỰ ÁN (PROJECT-SPECIFIC RULES)**: Tùy biến theo từng dự án cụ thể. *(Hiện tại cấu hình cho dự án: StockDeck)*. Khi sang dự án mới, chỉ cần thay đổi nội dung phần này.

---

# ==============================================================================
# PHẦN 1: QUY TẮC KỸ THUẬT CHUNG CHO MỌI DỰ ÁN (UNIVERSAL COMMON RULES)
# (Độc lập ngôn ngữ & nền tảng — Tái sử dụng nguyên vẹn cho bất kỳ dự án nào)
# ==============================================================================

## 1. Quy trình Git Branching & Quản lý PR (Git Automation Workflow)
- **Tuyệt đối không commit trực tiếp vào nhánh chính**: Không bao giờ commit lên `main` hoặc `master`.
- **Luôn tạo nhánh riêng biệt trước khi viết code**: Tự động tạo nhánh `feature/<tên-tính-năng>` hoặc `fix/<tên-lỗi>` từ nhánh chính trước khi thực hiện bất kỳ thay đổi nào.
- **Quy trình chuẩn 4 bước**:
  1. Viết code.
  2. Chạy toàn bộ bộ kiểm thử tự động (Unit / Integration Tests) — **PHẢI PASS 100%**.
  3. Chạy build/compile dự án — **PHẢI BUILD THÀNH CÔNG**.
  4. Chờ người dùng xác nhận trải nghiệm thực tế chạy đúng mong đợi ➔ **Mới tiến hành commit**.
- **Tiêu chuẩn Commit/PR**:
  - Tiêu đề tuân theo Conventional Commits (`feat(...)`, `fix(...)`), **tối đa ≤ 72 ký tự**.
  - Nội dung mô tả (Body) **ngắn gọn ≤ 5 dòng**. Nếu cần mô tả chi tiết, ghi ra file riêng và đính kèm link.
- **Chỉ Push & Merge khi được yêu cầu**:
  - Mặc định **không tự ý push** lên remote repository. Chỉ push và tạo PR (`gh pr create`) khi người dùng yêu cầu rõ ràng.
  - Chỉ merge PR (`gh pr merge`) vào nhánh chính khi người dùng trực tiếp xác nhận "OK" hoặc "Duyệt".

---

## 2. An toàn Thực thi Terminal & Script (Terminal Safety)
- **Không viết inline script dài trong `-c`**: Bất kỳ script nào (Bash, Python, Node...) nếu dài quá ~5 dòng, **bắt buộc phải ghi ra file script tạm**, cấp quyền và thực thi file đó, sau đó xóa file tạm đi.
- **Không pipe build output qua bộ lọc chặn (blocking filter)**: Tránh dùng `| grep ...` trực tiếp trên luồng build/compile vì dễ gây treo tiến trình (hang/freeze/timeout) nếu output không khớp pattern.
- **Giới hạn độ dài dòng lệnh**: Mỗi câu lệnh CLI không vượt quá ~2000 ký tự để tránh lỗi buffer overflow và timeout.

---

## 3. Trung thực Dữ liệu & Phê duyệt Trước khi Code (Mandatory Approval)
- **Trung thực dữ liệu tuyệt đối (No Fake / Dummy Data)**: Tuyệt đối không tự ý bịa dữ liệu giả định, tên công ty giả, hoặc nhồi kết quả heuristic giả lập. Mọi dữ liệu hiển thị bắt buộc phải là dữ liệu thật 100% từ API chính thống hoặc nguồn đã kiểm chứng (trừ trường hợp kịch bản mock test được chỉ định rõ).
- **Bắt buộc chờ phê duyệt phương án trước khi sửa code**:
  1. AI phải giải thích nguyên nhân gốc rễ và trình bày phương án kỹ thuật rõ ràng.
  2. **CHỈ TIẾN HÀNH VIẾT CODE KHI NGƯỜI DÙNG XÁC NHẬN "OK" / DUYỆT TRỰC TIẾP** bằng lời nhắn trong chat.
  3. Tuyệt đối không tự động nhảy sang bước viết code / thực thi thay đổi khi người dùng chưa đồng ý.

---

## 4. Tiêu chuẩn Kỹ thuật Hiệu năng (Universal Performance Engineering)
*(Áp dụng cho mọi hệ thống: Frontend UI, Backend API, Mobile, Desktop, CLI)*
- **Cô lập State & Sự kiện tần số cao (State & Event Isolation)**:
  - Các sự kiện hoặc state biến động liên tục (hover chuột, con trỏ, vị trí scroll, sensors, keystrokes input...) **bắt buộc phải cô lập trong component/module con**. Tuyệt đối không đặt ở component cha vì sẽ kích hoạt re-render hoặc re-calculate toàn bộ cây view/component.
- **Cấm tính toán nặng trong Render Loop & Request Hot-Path**:
  - Không chạy sắp xếp (`sort`), lọc mảng lớn (`filter`), parse JSON nặng, hoặc các thuật toán tính toán phức tạp trực tiếp bên trong vòng lặp render giao diện hoặc hàm xử lý request chính.
  - Mọi phép tính nặng phải tính trước (pre-compute) và lưu cache bộ nhớ (in-memory cache / memoization). View/handler chỉ đóng vai trò đọc dữ liệu đã chuẩn bị.
- **Tối ưu cấp phát bộ nhớ & Giảm tải Garbage Collection (Allocation Optimization)**:
  - Tránh khởi tạo các đối tượng tốn kém tài nguyên (date formatters, regex parsers, database connections, crypto engines) lặp đi lặp lại trong vòng lặp kín hoặc từng item của danh sách. Bắt buộc tái sử dụng instance static/singleton hoặc object pool.
- **Ảo hóa & Phân trang dữ liệu lớn (Virtualization & Pagination)**:
  - Trên giao diện: Danh sách lớn bắt buộc phải dùng cơ chế ảo hóa (virtual list/lazy loading), chỉ render các phần tử thực sự nằm trong khung nhìn.
  - Dưới backend/DB: Luôn phân trang (pagination), stream hoặc chunking dữ liệu, tuyệt đối không tải hàng loạt triệu bản ghi vào RAM cùng lúc.
- **Gom cụm & Tiết chế luồng dữ liệu thời gian thực (Buffering & Throttling)**:
  - Dữ liệu từ luồng thời gian thực (WebSocket, Message Queue, Event Stream) không được bắn trực tiếp từng event đơn lẻ lên UI/Main Loop. Bắt buộc có cơ chế buffer gom batch và debounce/throttle (ví dụ: 0.5s – 1.0s) để giảm tải tần suất cập nhật.
- **Bất đồng bộ & Không chặn luồng chính (Non-blocking I/O)**:
  - Mọi thao tác I/O (đọc/ghi file, gọi network, truy vấn DB) tuyệt đối không chạy đồng bộ trên Main Thread / Event Loop chính.
  - Thao tác ghi đĩa/persistence lặp đi lặp lại phải được debounce và đẩy xuống background worker/thread.

---

## 5. Tư duy Triển khai Ngang (Horizontal Deployment Mindset)
Khi giải quyết bất kỳ lỗi hoặc phát triển tính năng nào, bắt buộc tự động rà soát đồng bộ theo 4 trục:
- **Trục Tính năng & Thành phần tương đồng (Feature Parity)**: Nếu sửa/thêm logic ở Module A, phải tự động quét toàn bộ codebase tìm các Module B, C có vai trò hoặc logic tương tự (ví dụ: danh sách chính ↔ danh sách phụ; chế độ xem bảng ↔ chi tiết modal; giỏ hàng ↔ thanh toán) để áp dụng đồng bộ.
- **Trục Đa Nền tảng / Đa Môi trường (Environment & Platform Parity)**: Đảm bảo tính năng hoạt động nhất quán trên mọi nền tảng được hỗ trợ (Desktop ↔ Mobile, Web Responsive, macOS ↔ iOS, Dark Mode ↔ Light Mode).
- **Trục Đầy đủ Trạng thái Dữ liệu (State Parity)**: Mọi thành phần hiển thị/xử lý dữ liệu phải đáp ứng trọn vẹn 4 trạng thái:
  1. `Loading`: Có skeleton/placeholder dự trù, không làm vỡ hoặc giật layout.
  2. `Empty`: Giao diện thông báo trạng thái trống thân thiện, có chỉ dẫn hành động.
  3. `Error`: Bắt lỗi lịch sự, có nút thử lại (Retry), không để crash ứng dụng.
  4. `Loaded`: Hiển thị dữ liệu chính xác.
- **Trục Ổn định Giao diện & Hợp đồng Dữ liệu (Contract & Layout Stability)**:
  - Trên UI: Giữ vững kích thước khung hình, triệt tiêu hiện tượng giật nhảy layout (Zero Layout Shift).
  - Trên Logic: Xử lý triệt để các trường hợp biên (`null/undefined`, chia cho 0 sinh ra `NaN/Inf`, lỗi tràn mảng `Index out of bounds`). Khi thiếu số liệu, hiển thị ký hiệu thay thế lịch sự (`-` hoặc `--`), tuyệt đối không làm crash hay hiển thị giá trị bất thường.

---

## 6. An toàn Concurrency & Kiểm thử Hồi quy (Concurrency & Test Guard)
- **Luồng UI vs Luồng Background**: Mọi cập nhật trạng thái hiển thị người dùng bắt buộc diễn ra trên Main/UI Thread. Mọi tính toán thuật toán nặng hoặc I/O bắt buộc đẩy sang Background Thread/Worker.
- **Kiểm thử hồi quy (Regression Testing Guard)**: Khi sửa đổi các hàm tính toán cốt lõi hoặc thuật toán quan trọng, bắt buộc phải chạy hoặc viết bổ sung Unit Test tương ứng để đảm bảo lỗi không bao giờ tái phát.

---

# ==============================================================================
# PHẦN 2: QUY TẮC ĐẶC THÙ DỰ ÁN (PROJECT-SPECIFIC RULES: STOCKDECK)
# (Phần này tùy biến theo từng dự án — Sang dự án mới chỉ cần thay đổi phần này)
# ==============================================================================

## 1. Định giá Portfolio & Phiên giao dịch (Valuation & Market Session)
- **Dùng giá đóng cửa phiên chính (`quote.price`)**: Tất cả định giá Portfolio Value, Total P&L, Position P&L, Top Gainers & Top Losers **bắt buộc** chỉ sử dụng giá và biến động của phiên chính (`quote.price`, `quote.changePercent`).
- **Không dùng Extended Hours cho P&L**: Tuyệt đối **không** dùng giá giao dịch ngoài giờ (Pre-Market / After-Hours) để tính định giá Portfolio hay xếp hạng Top Gainers/Losers. Cột `Ext` (nếu hiển thị) chỉ mang tính chất tham khảo riêng biệt.
- **Tính ổn định ngoài giờ**: Sau khi giờ giao dịch chính đóng cửa, giá trị các danh mục chứng khoán/quỹ **bắt buộc giữ cố định 100%**, không được thay đổi. Riêng tài sản Crypto (24/7) được phép cập nhật realtime theo đặc thù thị trường.

---

## 2. Tiền tệ: Native Currency trong Bảng Vị thế vs Preferred Currency
- **Bảng Vị Thế (Positions Table / Cards)**: Các cột **Cost basis**, **Market Value**, và **P&L** của mỗi vị thế **bắt buộc dùng nguyên đồng tiền gốc (Native Currency)** của symbol đó (ví dụ: `₫` / VND cho mã Việt Nam, `$` / USD cho mã Mỹ, `¥` / JPY cho mã Nhật). **Tuyệt đối không tự ý quy đổi (convert)** sang đồng tiền ưu tiên danh mục (`preferredCurrency`).
- **Thống Kê Tổng Quan (Hero Card & Portfolio Overview)**: Chỉ quy đổi theo tỷ giá FX rate sang `preferredCurrency` đối với các con số **thống kê tổng quát chung** của Portfolio (như Portfolio Total Value, Total Cost, Total P&L, Daily P&L...).

---

## 3. Thống nhất Nguồn số liệu & Bộ nhớ Cache (Single Source of Truth)
- **Dùng chung 1 nguồn dữ liệu duy nhất**: Tất cả các chỉ số hiệu suất hiển thị ở các vị trí khác nhau (ví dụ: Pill mốc thời gian 1M/3M/1Y ở Hero Card trên và cột 1M/3M/1Y ở Bảng Performance & Benchmark dưới) **bắt buộc sử dụng chung 1 giá trị duy nhất** từ `cachedPerformance`.
- **Tính toán 1 lần duy nhất**: Mọi công thức hiệu suất nặng **bắt buộc chỉ được tính toán 1 lần duy nhất** trong phiên (lưu cache bộ nhớ) để tránh lãng phí tài nguyên CPU và băng thông mạng.
- **Đo lường biến động thị trường thực tế**: Tính % hiệu suất giai đoạn (1M, 3M, 6M...) dựa trên biến động giá thị trường thực tế (`valueSeries`), **không** sử dụng snapshot thô bị biến động do hành vi nạp/thêm/bớt vị thế cổ phiếu của người dùng.

---

## 4. Quản lý Tỷ giá Hối đoái (FX Rates)
- **Cố định tỷ giá theo ngày / khi mở app**: Tỷ giá hối đoái (FX Rate) dùng tính toán Portfolio **chỉ tải 1 lần duy nhất khi mở app** (hoặc tối đa 1 lần/ngày). Giữ cố định tỷ giá trong suốt phiên làm việc để app vừa nhẹ, vừa nhanh, vừa ổn định số dư.

---

## 5. Chuẩn hóa Quỹ Mở Nhật Bản (Japanese Mutual Funds)
- **Quy đổi Tỷ lệ 10,000 口 (`scale = 10000.0`)**: Mọi phép tính định giá hiện tại, giá vốn và chuỗi lịch sử cho các quỹ mở Nhật Bản **bắt buộc chia cho tỷ lệ `10000.0`**.

---

## 6. Bảng Benchmark & Dữ liệu Lịch sử
- **Trung thực dữ liệu**: Nếu danh mục chưa đủ khoảng thời gian lịch sử (ví dụ 5Y, 10Y), hiển thị dấu `-`, tuyệt đối không tự bịa số.
- **Tải dữ liệu đồng bộ**: Tải đồng thời cả `priceHistory` ngắn hạn và `priceHistoryMax` dài hạn cho tất cả các mã trong danh mục cũng như chỉ số S&P 500 (`^GSPC`) ngay khi mở ứng dụng.

---

## 7. Quy tắc Build & Nền tảng StockDeck (Build Rules)
- **Dùng `./dev.sh` làm lệnh build chính thức**: Luôn dùng `./dev.sh` thay vì `swift build` trực tiếp để đảm bảo nhất quán môi trường build macOS.
- **Nền tảng thuần macOS**: Dự án là ứng dụng thuần macOS (Menu Bar & Desktop App). Mỗi khi chỉnh sửa code hoặc hoàn thành tính năng, **bắt buộc phải build macOS (`./dev.sh`)** và chạy test tự động (`swift test`) để kiểm tra.

---

## 8. Bản địa hóa & Tên riêng / Thương hiệu (Localization & Proper Nouns)
- **Tuyệt đối không dịch tên riêng**: Các danh từ riêng, tên công ty, sàn giao dịch, mã chỉ số và nền tảng đối tác (ví dụ: TradingView, Yahoo Finance, Binance, S&P 500, Sparkle, Google, Gemini...) **bắt buộc giữ nguyên 100% tên gốc**, không dịch sang tiếng Việt hay bất kỳ ngôn ngữ nào.
- **Dùng `Text(verbatim:)` trong SwiftUI**: Khi hiển thị tên riêng hoặc nhãn thương hiệu trên giao diện SwiftUI, bắt buộc dùng `Text(verbatim: "...")` thay vì `Text("...")` để tránh việc SwiftUI tự động tra cứu từ điển `LocalizedStringKey` (ngăn chặn các lỗi dịch nhầm như `Text("Trading")` thành `Giao dịch`).
