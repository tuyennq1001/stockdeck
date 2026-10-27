# Đo kết quả Superchart

## Outcome
Tác vụ R1A: chọn nguồn → chọn mã → chỉnh khoảng/indicator → đánh dấu và sửa/Undo → về Bảng → mở lại đúng state. R1B thêm tạo nhắc giá từ chart.

- Baseline completion/time: chưa đo. Không có user adoption metric hoặc lift được bịa.
- Dev acceptance: mọi bước trong kịch bản phải hoàn tất đúng dữ liệu, không mất state (policy đề xuất A4).
- Đo duration theo signpost/network/render riêng và checklist QA local; không thêm remote analytics.

## Guardrails
- Warm cached chart ready ≤1s; interaction frame p95≤33ms, 10-year history/all indicators: mục tiêu S1, chưa có số đo đạt.
- 20 close/open cycles với StockDeck+WebKit: yêu cầu kiểm tra S1; live Chart/WebView/handler phải giải phóng khi dispose. Memory MB ghi thực, không invent baseline.
- Zero critical data/drawing/valuation regressions: policy A4.
- Sources: S1/S2 và PRD mục 6.
- Protocol A4 sau audit: cùng máy/macOS/WebKit/refresh rate và dataset/config; 30 warm/10 cold; start hành động chọn mã, end frame đúng symbol+data+indicators; mỗi pan/zoom/edit 30 giây với frame measurement thực, không đo RAF idle. Xem PRD mục 6 để chạy lại.
- QA audit bổ sung: gate đề xuất A4 là max warm≤1s trên tập mẫu, báo median/p95/max cùng lỗi/timeout; cold riêng. Pan/zoom/drawing mỗi scenario p95≤33ms riêng. Mẫu lỗi/không render là FAIL và không loại khỏi denominator; chưa có benchmark đạt.

## Khoảng trống
Chưa có instrumented benchmark, browser integration test mới, kết quả manual đa thị trường. Mockup không phải app runtime test.

## Custom Scripts — 2026-10-26, đề xuất

- Outcome OP5 [S9/FB5]: người dùng tự import → kiểm tra → preview → thêm → sửa/hủy → mở lại source/instance đúng; baseline thời gian và tỷ lệ hoàn tất chưa đo. R1 dùng DCA, R2 dùng Risk Metric; chỉ có hai ví dụ không chứng minh tương thích toàn bộ Pine.
- Tách kết quả compiler, execution, numeric oracle, TradingView parity, renderer, alerts và UX. Compile thành công không phải badge “đã đúng”. Báo PASS/FAIL/BLOCKED/NOT RUN theo từng gate tại specs/implementation-custom-scripts.md.
- Guardrails mới theo A6/A7: tolerance abs 1e-8 + rel 1e-6 trên mọi bar hợp lệ, khớp hoàn toàn na/time/boolean/event; warm max≤1 giây gồm custom output, frame p95≤33ms/scenario; tài nguyên/runtime được chốt trước POC. Helper có số đo S17/S18 dưới đây; app UI chưa đo.
- Giữ protocol A4/20 vòng lifecycle S1; báo cả timeout/fail vào denominator, không thêm remote analytics. Zero lỗi lẫn mã/mất source/valuation/vượt quyền là policy A7, không phải kết quả đạt.
- Sau audit: G-NUMERIC-REFERENCE và G-TV-PARITY có kết quả riêng; Dev thử engine khi TV BLOCKED không được tính hoàn tất nghiệm thu “khớp TradingView”. Manifest tính/hiển thị/notifications cũng tách riêng, không đổi frequency source ngầm.

### POC thực nghiệm sau duyệt [S17]
- Chi tiết số đo/hashes tại docs/custom-script-poc-evidence.json và report. Native helper: DCA 10.000 H một instance cold median 0,874 giây, peak RSS 74,8 MiB; ba instance 2,523 giây / 99,1 MiB. Risk 5.000 D một instance 2,210 giây / 77,6 MiB; ba instance timeout 10/10 ở 5 giây. Mỗi scenario 10 cold, 30 cached calls; không loại fail.
- Cold/cache numbers là engine+encode, không bao gồm renderer/IPC và không chứng minh chart-ready/frame p95. Mẫu cold timeout không có CPU/RSS từ time wrapper là unavailable, không phải 0.
- DCA FAIL reference do EMA seed; Risk PASS numeric trên dataset, G-TV-PARITY BLOCKED và UI/isolation production NOT RUN. Giữ gate M1, không đổi tolerance/budget hoặc hardcode source để pass.

### Candidate sửa runtime [S18], trạng thái mới nhất
- Cùng source/dataset/tolerance/budget với S17; docs/custom-script-candidate-evidence.json chứa số đo riêng và baseline đối chiếu. DCA/Risk PASS reference, DCA 86 buy/17 sell/103 alertcondition khớp; không sửa Pine source.
- 60/60 cold jobs hoàn tất, 0 timeout; 30/30 cached calls mỗi scenario. DCA 10.000 H 1/3 instance cold median 0,771/2,189 giây, max 1,102/2,244 giây, RSS max 74,8/100,2 MiB. Risk 5.000 D 1/3 instance cold median 1,477/4,455 giây, max 1,585/4,603 giây, RSS max 80,6/163,4 MiB; ba Risk warm median/max 72/87 ms.
- Chỉ phần engine/helper budget và reference của hai ví dụ đạt trên máy/dataset đã thử; không đổi gate G-PERF tổng thành PASS. 18 test harness có primary live-tail fixtures; MTF live/UI FPS/IPC/production sandbox/hard cap chưa chứng minh, G-TV-PARITY vẫn BLOCKED. M1 chưa hoàn tất.
