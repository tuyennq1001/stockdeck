# Superchart Essential — kế hoạch đảm bảo chất lượng

Trạng thái: **đề xuất gate nghiệm thu, chưa thực thi**. Ngày: 2026-10-25. Phạm vi: R1A trong [PRD](prd-superchart-essential.md); R1B có đợt kiểm thử riêng. Chủ sản phẩm quyết định go/no-go sau khi xem bằng chứng; bên triển khai chịu trách nhiệm chạy QA và sửa lỗi trước buổi thử Dev.

Nguồn: S1 yêu cầu và quy tắc dự án; S2 code hiện tại; A4 policy gate/protocol đề xuất. Nguồn/giả định tra tại discovery/sources.md và backlog/assumptions.md. Đây là kế hoạch kiểm tra kỹ thuật, không phải chứng nhận app không còn lỗi.

## 1. Definition of Done

Mỗi phần việc chỉ xong khi đủ: tiêu chí hành vi có thể kiểm tra → code → test phù hợp → code review độc lập → thử trên app Dev thật → bằng chứng được lưu. Không chuyển kiểm thử hồi quy thành việc của người dùng. Buổi user trial tập trung vào mức dễ dùng, thứ tự thao tác và khả năng đọc chart.

- Toàn bộ `swift test`, integration JS/WebKit và `./dev.sh` phải pass [S1]. Build thành công chỉ xác nhận compile/package, không tự xác nhận UX hay dữ liệu.
- Mọi ca bắt buộc ghi PASS / FAIL / BLOCKED / NOT RUN. Skip, thiếu fixture hoặc không có thiết bị không được tính PASS. Báo số ca đã chạy trên tổng số ca bắt buộc và lý do các ca chưa chạy.
- Không đặt % code coverage làm bằng chứng duy nhất. Ưu tiên độ phủ rủi ro: mỗi yêu cầu quan trọng có ca kiểm chứng, mỗi lỗi core đã sửa có regression test nếu có thể tự động hóa.
- Chưa có baseline/performance instrumentation hoặc chưa thử native app: chưa được tuyên bố đạt gate tương ứng.

## 2. Ma trận kiểm chứng bắt buộc

| ID | Rủi ro / kiểm tra | Phương pháp và oracle | Đạt khi / bằng chứng |
|---|---|---|---|
| Q-DATA | Sai OHLCV, indicator, ngày giao dịch | Unit trên fixture có source/date/resolution/currency; fixture nhỏ tính tay cho từng công thức; fixture lịch sử thật đối chiếu bộ tham chiếu độc lập có ghi công thức/seed/warmup. Không dùng cùng hàm production để tạo expected | OHLC/aggregation/date đúng; chỉ báo khớp oracle theo tolerance ghi trước từ độ chính xác nguồn và double, không nới sau khi thấy fail. Có test duplicate/missing/flat/short history/zero và non-finite |
| Q-SESSION | Hiện hoặc ghi dữ liệu sang mã khác | Integration bridge với request trả ngược thứ tự, đổi nguồn/interval/mode khi đang tải, event drawingCommit có session/symbol/revision cũ | Chỉ lựa chọn mới nhất được hiển thị/ghi; event sai bị reject; test assertion inspect state, không chỉ chụp ảnh |
| Q-STORE | Mất drawing hoặc lưu giả thành công | Test actor/store, migrate legacy, ghi lỗi, file hỏng, app đóng/mở lại, khôi phục từ bản backup; fault injection có kiểm soát trên dữ liệu test | Không ghi đè bản hợp lệ bằng dữ liệu hỏng; legacy còn nguyên trước commit migration; lỗi lưu báo Chưa lưu + Retry. Chỉ báo Đã lưu sau durable-write acknowledgment |
| Q-DRAW | Hình lệch khi scale/zoom, Undo sai | Native app với bốn tool: tạo/sửa/style/khóa/xóa/Undo/Redo, zoom/pan/trục giá, D/W/M, resize/Retina; đối chiếu anchors trong store | Neo ngày/giá đúng, map W/M không rewrite anchors; N nến đúng; Esc/Delete/Cmd-Z chỉ xử lý đúng focus. Ảnh/video và trace anchor trước/sau |
| Q-UX | Nút có nhưng luồng không hoàn chỉnh | Đi hết nguồn → mã → interval → indicator → vẽ/sửa → về Bảng → mở lại; thử source rỗng/bị xóa, filter rỗng, mất mạng/cache, API lỗi/Retry | Không stale chart/blank pane/mất state, viewport giữ khi toggle; loading/empty/error/loaded rõ và không giật layout |
| Q-REG | Thay chart làm hỏng tính năng cũ | Test và so sánh snapshot model cùng fixture trước/sau tại Watchlist wide, symbol sheet, Portfolio detail; kiểm tra giá trị chứ không chỉ screenshot | Bảng giữ sort/scroll/cột; portfolio totals/P&L không đổi ngoài thay đổi input thật; Last/Chg regular, Ext riêng; native currencies/FX/Japanese fund scale đúng [S1] |
| Q-VIS | UI đẹp trong mockup nhưng khó dùng ở app | Native screenshot checklist Light/Dark, resize/fullscreen, màn nhỏ nhất app hỗ trợ, chuột/trackpad, bàn phím và VoiceOver cho controls | Không che/cắt controls/nhãn giá, màu và focus đọc được, tool đang bật rõ; pane/chart được inspect ở pixel density thực |
| Q-PERF | Mở chậm, lag, giữ WebView sau đóng | Benchmark protocol PRD §6 trên Dev build cùng thiết bị/dataset/config, ghi cả app và WebKit | Mỗi mẫu warm-cache ready ≤1s (gate max trên tập mẫu, cụ thể hóa A4 từ target S1); frame p95≤33ms riêng từng pan/zoom/drawing với lịch sử 10 năm/các indicator bật [S1]. Raw log, số mẫu, median/p95/max, lỗi/timeout và profile; mẫu không render vẫn FAIL, không loại khỏi denominator. Đóng/mở 20 chu kỳ [S1], xác minh retained chart/WebView/handler chứ không suy leak từ RAM đơn lẻ |
| Q-RECOVER | Đường lui không sử dụng được | Diễn tập tắt entry Superchart → Bảng, dispose renderer, mở lại bản đang hỗ trợ; migration trên copy của dữ liệu test | Bảng hoạt động, holdings không bị sửa; drawing file/legacy được giữ. Ghi rõ thao tác phục hồi và giới hạn tương thích schema; không gọi flag-off là data rollback |

Các fixture số học nhỏ được ghi rõ là test-only theo ngoại lệ mock test của S1; app không hiển thị dữ liệu giả. Lịch sử dùng đối chiếu ghi URL/API/provider, thời điểm lấy, timezone, adjusted/unadjusted và coverage. Không bắt chart trùng pixel/giá với TradingView nếu data feed hoặc điều chỉnh corporate action khác; phải đối chiếu cùng input trước khi kết luận công thức sai.

## 3. Đa thị trường và tình huống lỗi

- US/JP/VN stock, Crypto, NAV-only fund [S1]: mỗi nhóm chạy chọn nguồn/mã, D/W/M, indicators, drawings, save/reopen và trạng thái thiếu dữ liệu phù hợp. Case không áp dụng ghi N/A kèm lý do, không tạo OHLC/volume giả để lấp thiếu.
- Theo session: regular/PRE/POST/CLOSED và tài sản không có Ext; 0% khác missing. Case timezone gồm qua nửa đêm, DST với thị trường dùng DST, tuần/tháng qua năm và ngày nghỉ.
- Input bất thường: lịch sử trùng/ngược thứ tự, NaN/Inf, OHLC không hợp lệ, thiếu Volume, warmup chưa đủ. Bộ chuẩn hóa loại/đánh dấu lỗi rõ, không để crash hoặc vẽ số bất thường.
- Sự cố I/O/network: timeout, request bị hủy, offline có/không cache, Retry, lưu thất bại, crash/restart trong ghi file. Durable drawing đã được xác nhận lưu phải khôi phục; thay đổi chưa nhận ack không được hứa còn sau force quit.
- Stress: đổi nhanh mã/nguồn, toggle indicators/panes, mở/đóng chart khi tác vụ đang chạy; xác nhận callback cũ và observer không còn cập nhật renderer mới.

## 4. Mức lỗi và quyết định bàn giao

Policy mở rộng A4, đề xuất trước triển khai:

- **P0/P1:** sai giá/công thức vượt tolerance, sai mã/phiên/tiền tệ, thay đổi valuation không đúng input, mất/hỏng drawing đã xác nhận lưu, crash hoặc core flow không hoàn thành: chặn bàn giao, commit và release. Mọi phát hiện integrity dừng ghi liên quan để bảo toàn bản còn tốt.
- **P2:** hành vi thiết yếu sai hoặc gián đoạn rõ: sửa và test lại trước bàn giao. Chỉ giảm scope nếu chủ sản phẩm duyệt và cập nhật PRD/mockup; không tự đánh dấu known issue để lách gate.
- **P3:** lỗi thẩm mỹ nhỏ ngoài core flow: ghi rõ ảnh, ảnh hưởng và workaround; chủ sản phẩm có thể chấp nhận khi user trial. Không dùng P3 cho số liệu/nhãn gây hiểu nhầm.
- Thất bại performance target: giữ nội bộ Dev để profile, chưa bàn giao như bản đạt chất lượng. Nếu cần người dùng hỗ trợ chẩn đoán thì ghi rõ build chẩn đoán và gate đang fail.
- Ca bắt buộc còn BLOCKED/NOT RUN: gate chưa đạt. Chính sách thay đổi phải có phê duyệt và lý do, không thay ngưỡng sau đo để tuyên bố pass.

Độ nhạy A4: thay số mẫu benchmark trong khoảng đã đăng ký có thể đổi độ tin cậy p95 và cần báo lại; không làm thay đổi quyết định chặn lỗi integrity. Giảm bộ tool R1A giảm số ca drawing tương ứng, không giảm kiểm tra persistence/request guard. Hiệu năng khác thiết bị phải báo riêng; không gộp để che máy fail.

## 5. Quy trình và gói bằng chứng bàn giao

1. Trước code: đóng băng acceptance/fixture oracle, chụp trạng thái Bảng hiện tại với input xác định, đo baseline trên Dev khi có instrumentation.
2. Mỗi mốc M1–M4: chạy test đúng phần thay đổi, kiểm tra native app và review diff độc lập theo checklist sai mã/dữ liệu/concurrency/lifecycle. Nếu cùng bộ fixture hoặc oracle sai thì hai lượt review vẫn có thể bỏ sót; báo giới hạn này.
3. M5: full suite/build và cross-market/manual/performance/recovery. Chỉ chạy lại phần đã pass khi có thay đổi mới hoặc lý do hồi quy cụ thể; bản cuối bàn giao phải khớp revision đã test.
4. Bàn giao kèm báo cáo: build/branch/revision và dấu vết working tree chưa commit, dataset/config/thiết bị, test command + exit status/log, bảng từng ca, ảnh/video, benchmark raw/profile, defect list và quyết định gate. Không ghi chỉ một câu “tests pass”.
5. Người dùng thử mức dễ dùng và xác nhận. Chỉ sau đó commit [S1]; push/PR/release khi có yêu cầu riêng. Không đổi phạm vi R1A/R1B chỉ vì thêm QA.

Mẫu cho từng ca: `ID | yêu cầu | precondition/input | thao tác | expected | actual | PASS/FAIL/BLOCKED/NOT RUN/N/A | evidence | build revision | issue/retest`.

## 6. Hiện trạng bằng chứng

Hiện có: kiểm tra tương tác prototype mô tả trong mockups/review-notes.md và audit PRD. **Chưa có kết quả QA runtime cho Superchart R1A mới, benchmark mới hoặc diễn tập phục hồi.** Test chart cũ không tự chứng minh phần mới đã pass. Tài liệu này không phải báo cáo kết quả thực thi.

## 7. Rà soát độc lập

Audit độc lập 2026-10-25: không có blocker integrity/provenance/scope; một P2 về performance gate chưa chốt statistic đã được sửa. Đề xuất dùng max warm≤1s trên tập mẫu, báo cả median/p95/max; frame p95 tách riêng pan/zoom/drawing; mẫu lỗi/timeout giữ trong denominator và tính FAIL. Không dùng median hoặc gộp scenario để che phần chậm. Policy này được đăng ký trong A4, chưa phải kết quả benchmark đạt. Các findings được đồng bộ vào PRD/metrics.
