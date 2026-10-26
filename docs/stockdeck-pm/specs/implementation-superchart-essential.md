# Kế hoạch triển khai StockDeck Superchart Essential

Ngày lập: 2026-10-25. Trạng thái: **kế hoạch hợp nhất đã lập theo yêu cầu người dùng, chưa bắt đầu triển khai phạm vi mới**. Yêu cầu “ok thành lập plan đi” được hiểu là lập kế hoạch; không tự suy thành lệnh sửa app, commit hoặc phát hành.

## 1. Kết quả bàn giao

Một bản StockDeck Dev có hai chế độ Bảng / Superchart; có thể đi hết luồng chọn Watchlist hoặc Portfolio → chọn mã → phân tích → vẽ/sửa/lưu → về Bảng → mở lại đúng trạng thái. Bên triển khai hoàn thành QA và báo cáo bằng chứng trước khi người dùng trải nghiệm. Không chuyển chart sang nguồn dữ liệu hoặc widget ngoài app.

Tài liệu nguồn, không sao chép thành nhiều đặc tả cạnh tranh:

- [PRD: tính năng, lý do, hành vi và hợp đồng dữ liệu](prd-superchart-essential.md).
- [QA: oracle, gate, phân loại lỗi và bằng chứng](quality-superchart-essential.md).
- [Mockup R1A](../mockups/superchart-essential.png); [giới hạn prototype](../mockups/review-notes.md).
- [Ưu tiên và độ nhạy](../backlog/prioritization-2026-10-25.md), [nguồn S1–S8](../discovery/sources.md), [giả định A1–A4](../backlog/assumptions.md).
- [Handoff/rollback](../launches/launch-superchart-essential.md).

Không đặt deadline/ngày công khi chưa có estimate. Các mốc dưới là thứ tự phụ thuộc, không phải lời hứa calendar. Chỉ cập nhật estimate khi có bằng chứng triển khai; không tự giảm kiểm thử hoặc đổi gate để khớp estimate.

## 2. Ranh giới release

### R1A — triển khai trong kế hoạch này

- Bảng ↔ Superchart, nút trên trái; bảo toàn trạng thái Bảng. Superchart có chart trái và danh sách phải sát nhau.
- Dropdown chung chia Watchlist / Portfolio; tìm trong nguồn, chọn bằng click hoặc bàn phím; cột Symbol / Last / Chg% / Ext%.
- D/W/M trong dropdown, preset dưới chart và quy tắc interval tự động/thủ công của PRD.
- Candles/Line, Linear/Log, Auto/Reset/Về mới nhất; gesture mặc định khi không vẽ.
- Volume overlay; pane RSI/MACD resize, phóng/khôi phục/đóng; quản lý tham số, màu, nhiều SMA/EMA, BB/RSI/MACD.
- Rail gồm Select, Horizontal Line, Trend Line, Rectangle, Price Range và Delete. Sửa hình/handles, màu/độ dày, khóa hình được chọn, Undo/Redo, lưu theo mã.
- Hiển thị Insider Mua/Bán đồng bộ toàn app, đường target hiện có; các lớp độc lập.
- Native currency, đúng session/history, thiếu dữ liệu có giải thích, offline/cache, lifecycle và phục hồi dữ liệu.

Giữ defaults đã chốt của S1: nến ngày, khoảng 3M cho lần mở mã chưa có state; SMA20/50, Volume, RSI14, MACD12/26/9, BB tắt. Mở lại state hợp lệ ưu tiên state đã lưu. Mặc định layout lần đầu là Bảng, sau đó nhớ mode theo PRD. Các tỷ lệ pane/width/debounce là defaults thiết kế A3, không phải số đo hiệu năng.

### R1B — không kéo vào R1A

Snap OHLC, Hide all / Lock all, entry tạo native alert/target từ chart. Chỉ triển khai sau vòng trải nghiệm R1A nếu được yêu cầu; existing alert/target ngoài Superchart vẫn hoạt động. Không dựng icon hoặc menu giả của R1B.

### Ngoài release

Intraday/nguồn giá mới, multi-chart, Pine, Replay/backtest, broker/order entry, Fib/Gann/bộ vẽ lớn, cloud sync và hover OHLCV legend. Compare benchmark, executions cá nhân và export ảnh thuộc các đề xuất sau R1; không tự bổ sung khi “tiện tay”.

## 3. Quy trình triển khai và trách nhiệm

- Bên triển khai sở hữu code, test, review, QA native, đo hiệu năng, sửa lỗi và báo cáo. Reviewer độc lập kiểm tra diff và bằng chứng ở các mốc, không coi tác giả tự review là toàn bộ review.
- Chủ sản phẩm duyệt thay đổi phạm vi nếu phát sinh, trải nghiệm Dev và xác nhận trước commit [S1]. Push/PR/merge/release chỉ khi có yêu cầu riêng.
- Tiếp tục nhánh feature phù hợp sau preflight. Hiện workspace đang ở `feature/lightweight-chart-trial` và có thay đổi chưa commit từ phần chart trước; không reset/stash/ghi đè hoặc dựng lại từ main làm mất chúng.
- Các tên module mới bên dưới là đề xuất tổ chức code; khi triển khai có thể chỉnh tên để hợp cấu trúc, nhưng giữ các ranh giới state/background/renderer và phạm vi hành vi.

## 4. Các mốc và điều kiện chuyển mốc

Mapping với PRD: M0–M4 giữ cùng ý nghĩa; M5 của PRD được tách thành M5 QA và M6 bàn giao/nghiệm thu ở kế hoạch thực thi này để không nhầm test pass với user acceptance. Không có phần việc hay phạm vi mới từ việc tách mốc.

### M0 — Chốt đầu vào và ghi baseline

Việc làm:

- [ ] Kiểm tra branch, toàn bộ dirty files và quy tắc AGENTS; phân biệt thay đổi cũ với phần mới.
- [ ] Ghi nhận phiên bản app/build, môi trường đo, mẫu dữ liệu và các màn hiện tại. Chạy full test/build ban đầu khi bắt đầu code; nếu baseline lỗi phải ghi nguyên nhân, không gọi lỗi cũ là pass.
- [ ] Chốt fixture có nguồn, expected độc lập/tolerance và danh sách case QA; giữ kết quả Bảng/valuation với input xác định để đối chiếu hồi quy.
- [ ] Tạo danh mục báo cáo có ID từng case, revision/build, PASS/FAIL/BLOCKED/NOT RUN/N/A; chưa chạy để trạng thái đúng.

Đầu ra: baseline report, test/fixture inventory, revision và scope R1A được tham chiếu thống nhất. Gate: không có đầu vào quan trọng bị giả định ngầm; data/valuation hiện tại có thể so sánh trước/sau. Không mở rộng baseline work sang sửa tính năng ngoài chart.

### M1 — Session, dữ liệu, bridge và lưu an toàn

Việc làm:

- [ ] Tách `ChartSession`, source ID và config/state ra khỏi renderer; giữ pointer/hover/drag previews trong JavaScript.
- [ ] History có resolution/coverage thực; normalize ngày, sort/dedup/aggregate ở background, không giả daily từ monthly. Indicator cache theo symbol/data revision/interval/config, không tính trong render.
- [ ] Mỗi data/config/drawing command có session/symbol/request/revision. Hủy tác vụ cũ và reject callback sai ngữ cảnh ở cả hai chiều.
- [ ] `DrawingStore` background actor, schema version, atomic write, acknowledgment sau ghi thành công; debounce config/view state và flush theo lifecycle.
- [ ] Migrate Price Range legacy không mất ID/anchors, không xóa bản cũ trước khi xác nhận ghi thành công. Có lỗi/file hỏng thì báo và phục hồi bản hợp lệ, không silent overwrite.
- [ ] Dispose có cancel task, remove handler/listener/observer/primitives/chart; restore state khi renderer được tạo lại.

Đầu ra: contracts/types và storage/data path dùng chung. Gate: Q-DATA, Q-SESSION, Q-STORE theo QA doc có test cho phần nền; không còn đường ghi drawing chỉ dựa vào parent symbol đang thay đổi. Migration chạy trên bản sao dữ liệu test trước.

### M2 — Bảng / Superchart và danh sách nguồn

Việc làm:

- [ ] Tích hợp mode tại cửa sổ desktop thật `PortfolioWindowView`; không dùng `ContentView` menu-bar 462×520 làm root Superchart.
- [ ] Nút chuyển mode trên trái, giữ sidebar/navigation Bảng. Về Bảng khôi phục scope, sort, scroll và row; không để `.id(selection)` vô tình xóa session mới.
- [ ] Thêm workspace và list phải dùng nguồn model hiện tại; group source bằng stable ID, giữ order gốc, All Portfolios dedup canonical symbol từ vị thế mở.
- [ ] Last/Chg regular, Ext riêng; snapshot/precompute quote row, lazy list, không fetch hoặc tính valuation từng row.
- [ ] Search chỉ trong source; keyboard theo focus. Nguồn rỗng/xóa/không có mã hiện tại xử lý theo PRD, không giữ chart ngoài nguồn.
- [ ] Chia chart/list bằng divider; đảm bảo sử dụng được tại minimum desktop window hiện tại và fullscreen, theo Light/Dark/locale app.

Đầu ra: một luồng mỏng nhưng đi hết chọn nguồn/mã → chart hiện có → về Bảng. Gate: Q-UX/Q-REG phần navigation và quotes pass; đổi mode/source không thay dữ liệu Portfolio hoặc selected source của Bảng ngoài ý muốn.

### M3 — Điều khiển phân tích và panes

Việc làm:

- [ ] D/W/M dropdown và preset, Auto interval khi đổi preset, manual interval giữ khoảng; custom view sau pan/zoom.
- [ ] Diff config/series thay vì dựng lại tất cả; ẩn/hiện overlay/pane giữ visible range và tỷ lệ pane trước đó.
- [ ] Volume overlay với scale riêng; RSI/MACD resize/phóng/khôi phục/đóng, không tạo pane rỗng khi thiếu warmup.
- [ ] Indicator manager: stable instance ID, nhiều SMA/EMA, sửa tham số/màu, validation trước Apply, tính/cache từ lịch sử hợp lệ trước viewport.
- [ ] Auto/Reset/Về mới nhất, Candles/Line, Linear/Log và grid; Line-only/giá không hợp lệ phải có guard/giải thích.
- [ ] Insider/target/indicators tách lớp; giữ attribution/license. Không thêm hover OHLCV legend.

Đầu ra: bộ phân tích đủ R1A trong layout mới. Gate: Q-DATA, Q-UX, Q-VIS phần chart pass; số liệu cùng ngày/interval không đổi do chọn preset; toggle pane không nhảy viewport.

### M4 — Bộ vẽ hoàn chỉnh

Việc làm:

- [ ] Drawing engine trên series primitives, hit-test và coordinate projection; không phụ thuộc redraw theo hover.
- [ ] Bốn tool, chế độ Select mặc định, create/edit/move/resize, selected-object lock, color/width và delete.
- [ ] Undo/Redo theo symbol, chỉ ghi history cuối gesture; Esc hủy hình chưa hoàn tất, hoàn tất quay về Select; text input giữ phím tắt native.
- [ ] Price Range có mức đầu/cuối, Δ giá, Δ%, N nến; giữ hướng vẽ/anchor gốc, không chia 0 hoặc hiện NaN.
- [ ] W/M project ngày neo vào candle chứa ngày đó; không ghi lại anchor gốc khi chỉ đổi interval. Không tự kéo neo ra ngoài coverage R1.
- [ ] Save/reopen, lỗi lưu/Retry và migration tương thích Price Range cũ.

Đầu ra: bộ vẽ sử dụng được từ tạo đến phục hồi. Gate: Q-DRAW/Q-STORE/Q-SESSION pass trên app native; zoom, kéo trục giá, resize và đổi khung không làm lệch giá neo.

### M5 — Hồi quy, hiệu năng và phục hồi

Việc làm:

- [ ] Full `swift test`, JS/WebKit integration và `./dev.sh`; final build khớp revision đã test.
- [ ] Đi toàn bộ task trên US/JP/VN/Crypto/NAV, đúng trạng thái applicable/N/A, và các ca mất mạng/lỗi cache/I/O/callback cũ.
- [ ] Native screenshots/video Light/Dark, minimum window/fullscreen, chuột/trackpad, keyboard/focus; thử cả Watchlist wide, holding detail và symbol sheet.
- [ ] Đo protocol đã chốt: 30 warm/10 cold, mỗi pan/zoom/drawing 30 giây (sample design A4); dataset thật 10 năm với toàn bộ indicator bật [S1].
- [ ] Gate đề xuất A4: từng mẫu warm≤1s (max≤1s); frame p95≤33ms riêng từng scenario [S1]. Báo median/p95/max, lỗi/timeout, không bỏ mẫu lỗi khỏi denominator. Cold/network báo riêng.
- [ ] Đóng/mở 20 chu kỳ [S1], profile app+WebKit và retained references. Không suy leak chỉ từ RAM cache tăng; phải xác nhận Chart/WebView/handler được giải phóng khi dispose.
- [ ] Diễn tập tắt Superchart về Bảng và recovery trên copy của store, ghi giới hạn schema. Không coi feature flag là rollback dữ liệu.
- [ ] Review độc lập final diff và evidence, sửa lỗi rồi retest phần bị ảnh hưởng; không lấy prototype/browser-only pass thay native WebKit.

Đầu ra: QA report + raw benchmark/profile + known issues + runbook recovery. Gate: mọi ca bắt buộc pass, không P0/P1/P2 mở; P3 ghi rõ để chủ sản phẩm quyết định. Mục nào BLOCKED/NOT RUN hoặc performance fail thì chưa bàn giao như bản đạt chất lượng.

### M6 — Bàn giao Dev và nghiệm thu

- [ ] Mở đúng StockDeck Dev đã kiểm chứng, chỉ rõ nút vào Superchart và cách quay về Bảng.
- [ ] Kèm revision/build, scope thực tế, evidence, giới hạn dữ liệu và lỗi còn lại; không ghi “đã hoàn tất” khi gate chưa đạt.
- [ ] Người dùng trải nghiệm tác vụ đọc/phân tích/vẽ, xác nhận hoặc phản hồi. Phản hồi được triage; sửa lỗi trong scope, đề xuất ngoài scope ghi riêng.
- [ ] Chỉ commit sau xác nhận trải nghiệm [S1]. Push/PR/merge/release chờ yêu cầu riêng; chưa có lịch public release.

Đầu ra: bản Dev reviewable và quyết định accept/iterate/hold. Gate: user confirmation trước commit, không dùng phê duyệt tài liệu thay xác nhận app chạy đúng.

## 5. Bản đồ thay đổi code dự kiến

| Khu vực | Vai trò trong kế hoạch | Ranh giới cần giữ |
|---|---|---|
| `Views/PortfolioWindowView.swift` | Entry mode và desktop shell | Giữ navigation, dialogs và state Bảng; menu-bar app không thành Superchart |
| `Views/SuperchartWorkspaceView.swift` / `SuperchartSymbolList.swift` (mới, tên đề xuất) | Layout/chart host/source/quote list | List chỉ quan sát state cần thiết, không re-render theo crosshair |
| `Models/ChartSession.swift`, config/source/drawing types (mới, tên đề xuất) | Contract và state | Canonical symbol và stable source ID; không đặt valuation logic mới tại đây |
| `Services/LightweightChartTrial.swift` | Bộ tính/bridge/shared renderer hiện có | Refactor theo trách nhiệm, không duy trì hai bộ math khác nhau |
| `Services/ChartDrawingStore.swift` (mới, tên đề xuất) | Durable local persistence/migration | Background/atomic/versioned, không sửa dữ liệu holdings |
| `Resources/LightweightChartTrial.html` + drawing module nếu cần | Renderer config diff/primitives/input | Library local; hover/drag ở JS, bridge chỉ commit cần thiết |
| `Views/PriceChartCard.swift` | Host shared chart trên các detail surfaces | Dùng chung calculation/config/drawings; không đổi portfolio performance charts ngoài scope |
| `Views/WatchlistWideView.swift`, `HoldingDetailView.swift`, `SymbolDetailSheet.swift` | Kiểm tra parity ba điểm dùng chart | Giữ UI Bảng và hành vi native; không tự xóa card ngoài phạm vi Superchart |
| `Tests/LightweightChartMathTests.swift`, `DetailChartHistoryTests.swift` và test mới theo domain | Math/state/store/regression | Expected độc lập; integration harness thực sự kiểm tra WKWebView, không chỉ mock bridge |

## 6. Kịch bản nghiệm thu sản phẩm

| Kịch bản | Given / When | Then / gate liên quan |
|---|---|---|
| Rà watchlist rồi về Bảng | Bảng có sort/scroll và row đang chọn; mở SC, chọn nguồn/mã, quay lại | Bảng giữ đúng state; SC không sửa nguồn Bảng — Q-UX/Q-REG |
| Phân tích holding đa thị trường | Chọn Portfolio, đổi mã US/JP/VN/NAV/Crypto và W/M | Quote/tiền tệ/session/coverage đúng, thiếu OHLC có giải thích; valuation không đổi — Q-DATA/Q-REG |
| Ghi một phân tích | Vẽ/sửa Price Range/Trend/Rectangle/HLine, Undo/Redo, đổi interval rồi mở lại app | Hình/anchors đúng mã được khôi phục; phép đo đúng khung; chưa lưu phải báo — Q-DRAW/Q-STORE |
| Chịu lỗi và thao tác nhanh | Đổi mã khi load, offline, lỗi ghi hoặc callback trả muộn | Không stale chart/ghi nhầm/mất bản tốt, Retry có hiệu lực — Q-SESSION/Q-STORE/Q-RECOVER |
| Chart lớn và sử dụng liên tục | Dữ liệu thật đủ coverage, indicators bật, thao tác và đóng/mở theo protocol | Gate latency/frame, lifecycle và profile có bằng chứng đúng build — Q-PERF |

## 7. Theo dõi thay đổi và tiến độ

Tất cả checkbox hiện **chưa thực thi**; việc lập tài liệu/mockup không đánh dấu mốc code/QA pass. Mỗi cập nhật tiến độ phải ghi mốc hoàn thành, evidence, lỗi còn mở và bước kế tiếp. Không cần hỏi lại các lựa chọn thường lệ đã có PRD; chỉ xin quyết định khi thay phạm vi, quy tắc dữ liệu, gate hoặc phát sinh hành động cần phê duyệt.

## 8. Audit kế hoạch hợp nhất

Rà độc lập 2026-10-25: không phát hiện P0/P1/P2 mới. Đã đối chiếu R1A/R1B, dependency/gate, QA ownership, benchmark statistic, migration/dirty branch safeguards và trạng thái chưa code. Source thực tế xác nhận root desktop là PortfolioWindowView, không phải ContentView menu-bar; cảnh báo reset state ở `.id(selection)` có căn cứ. Ghi chú biên tập: tên mốc M5 của PRD so với M5/M6 của execution plan đã được giải thích bằng mapping ở mục 4. Đây là audit tài liệu, không phải code review hoặc kết quả app QA.
