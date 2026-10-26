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
