# State: StockDeck

## Cập nhật hiện tại — 2026-10-27

- Custom Scripts đã tích hợp thư viện/menu bật-tắt, nhiều script có legend/Style/pane riêng, chạy trên 11 interval, hủy preparation/helper khi gỡ, và giới hạn mỗi pane trong một ô indicator. Chi tiết: [workflow](../custom-scripts-workflow.md).
- Người dùng đã thử Dev, duyệt thay đổi và yêu cầu push/merge. Không có yêu cầu release. AGPL được chọn tạm; compliance và điều kiện phân phối vẫn là gate trước release. TradingView parity đầy đủ, fill, Inputs editor và gửi alert chưa được xác nhận/hỗ trợ.
- Kiểm tra trước tích hợp: `swift test` 638 tests, 1 benchmark opt-in skipped, 0 failures; JavaScript 31/31. Build Dev được kiểm tra riêng trước commit.

## Snapshot lịch sử — 2026-10-26

Các mục dưới ghi trạng thái tại thời điểm POC/tích hợp ban đầu, không thay thế cập nhật và workflow phía trên.

open_plays:
- Custom Scripts OP5: user duyệt tiếp tục và chọn tạm PineTS AGPL miễn phí, không mua commercial license. App có editor/library/import, helper-process runner, line/shape/barcolor/pane output; runner cấp D/W/M cùng mã offline nhưng Risk Metric chưa xác minh trong app/TV. Fill chưa vẽ; alert chỉ đếm, chưa notification. Giới hạn 128 KB source, 20k bars, 5s execution, 2.5k output points/plot. OS memory cap, TradingView parity và UI/performance acceptance còn mở. AGPL compliance và Mac App Store terms là release gates.
- Checkpoint 2026-10-26 tại 665b1ff [S11]: đã có source Superchart, shared detail chart và intraday loader; working tree sạch khi bắt đầu tích hợp.
- Hồ sơ Superchart Essential/QA ngày 2026-10-25 và M0–M6 của plan đó là snapshot cũ; chưa đối soát từng milestone với code hiện tại. Không tiếp tục dùng trạng thái “chưa có Superchart” làm fact hiện tại.
- Đã đo helper cold/cache/RSS với dữ liệu thật; 18 test harness gồm primary-context live-tail/state/alert retention với fixture test-only. Chưa MTF live, chart-ready/frame p95/native UX/lifecycle hoặc TradingView export cùng input. Không suy số helper thành app mượt hoặc engine tương thích đầy đủ.

waiting_on_user:
- “ok thử đi” và “tiếp đi” đủ phê duyệt tiếp tục POC, không hỏi lại cho phần thử. Lỗi EMA/budget hai ví dụ đã qua kiểm tra candidate S18; không suy thành M1 production PASS hoặc user acceptance.
- License route tạm chọn AGPL miễn phí theo user instruction; không mua license. App Store compatibility/legal review vẫn cần trước distribution.
- Sau triển khai/QA mới xác nhận trải nghiệm Dev trước commit; push/PR/merge/release cần yêu cầu riêng.

last_session: 2026-10-26 — added PineTS bundle, standalone JavaScriptCore runner, local editor/library/import, line/shape/barcolor/pane outputs, D/W/M same-symbol offline provider and release/dev bundle inclusion. `swift test` 616/616, `./dev.sh`, Release build, JS syntax and direct helper tests PASS. Risk Metric `Risk` final value matched S18 reference (diff 0); DCA EMA and buy/sell counts matched on the visible 2,500-bar tail. Pane visual, TradingView parity, OS memory cap, UI/performance acceptance remain open. No commit/push.
