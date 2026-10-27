# Kế hoạch nhập và kiểm chứng Custom Scripts cho Superchart

**Cập nhật 2026-10-27:** thư viện/menu bật-tắt, nhiều script độc lập, Style, 11 interval và giới hạn pane đã được tích hợp. Người dùng đã yêu cầu push/merge sau khi thử Dev. [Workflow hiện tại](../../custom-scripts-workflow.md) thay thế các bước kiểm tra/preview/thêm thủ công trong kế hoạch gốc bên dưới. Các báo cáo POC và gate bên dưới là hồ sơ lịch sử; không phải xác nhận đầy đủ TradingView parity hoặc phê duyệt release.

Ngày: 2026-10-26. Trạng thái: **POC S18 đạt numeric/budget; app có editor/library/import, helper runner và line/shape/barcolor/pane output. Runner cấp D/W/M cùng mã từ lịch sử ngày nhưng Risk Metric chưa qua kiểm chứng trong app/TradingView. Fill và alert notification chưa hỗ trợ; output giới hạn 2.500 điểm/plot; OS memory cap và UI/performance QA còn mở**. Mới nhất: [candidate report](../../custom-script-candidate-report.md) và [evidence](../../custom-script-candidate-evidence.json) [S18]; giữ [baseline report](../../custom-script-poc-report.md) [S17]. Các phần dưới là contract kế hoạch; bảng gate không tự được coi là PASS.
Opportunity: OP5. Bằng chứng: [S9]–[S16] trong [nguồn](../discovery/sources.md). Giả định: A5–A7 trong [assumptions](../backlog/assumptions.md).

## 1. Mục tiêu và ranh giới quyết định

Người dùng muốn tự thêm Pine Script mà không phải nhờ chuyển từng indicator sang Swift [S9]. Đầu ra mong muốn là luồng **Custom Scripts → dán/import source → kiểm tra → xem trước → thêm vào chart → lưu → dùng lại**. Script không hỗ trợ phải báo lý do, không bỏ qua lệnh rồi hiển thị kết quả có vẻ đúng.

Đề xuất dùng PineTS làm ứng viên runtime, giữ Lightweight Charts và dữ liệu StockDeck. Đây là giả thuyết kỹ thuật A5, không phải cam kết tương thích Pine đầy đủ. Tài liệu nhà cung cấp có hỗ trợ EMA/crossover, plot/barcolor/plotshape và alert, nhưng không thay cho kiểm chứng trên macOS [S13].

Ưu tiên **bộ chạy dùng chung và hợp đồng hiển thị dùng chung**; không hardcode tên hoặc nhận diện hai script mẫu để thay bằng công thức riêng. Hai script là trường hợp kiểm chứng đầu tiên, không đại diện cho toàn bộ Pine.

Người dùng đã nói “ok thử đi” sau phần trao đổi hiệu năng, rồi yêu cầu “tiếp đi”, được ghi nhận là duyệt POC M0/M1 và tiếp tục xử lý runtime [S17/S18]. Đã thêm công cụ thử riêng, chưa thêm runtime/editor vào app. Bản gốc fail EMA/budget ba Risk; candidate sửa chung đã đạt hai phần đó trên cùng input. M1 còn license/isolation/preflight/TradingView oracle; chưa có user acceptance hoặc phép commit/push/release.

## 2. Baseline hiện tại và phần cần xây

Static inspection tại commit `665b1ff`, working tree sạch khi bắt đầu [S11]:

| Hiện có | Khoảng trống cho Custom Scripts |
|---|---|
| `SuperchartWorkspaceView` và chart dùng chung với màn chi tiết | Chưa có editor, registry hoặc runtime cho Pine |
| `LightweightChartTrial.swift` tạo payload/indicator nền ở background; coordinator loại phản hồi cũ bằng request ID | Cần định danh script/revision/data revision và huỷ job xuyên toàn bộ runtime/renderer |
| Local HTML + Lightweight Charts trong WKWebView; có bridge tên `chart` | Không thực thi source người dùng trong WebView có bridge này |
| Dữ liệu D/W/M và intraday on-demand qua `SuperchartIntradayLoader` | Cần hợp đồng timestamp, nến đóng, coverage, nguồn giá và dữ liệu thiếu cho script |
| Built-in indicator, marker Insider, drawing và preferences theo surface | Cần plot/pane/marker/màu nến có owner theo instance, không ghi đè output cũ |
| Swift package và các test chart/alert hiện có | Cần test runtime JavaScript và native integration; `swift test` riêng lẻ chưa đủ |

Hồ sơ Superchart Essential ngày 2026-10-25 là snapshot kế hoạch cũ; không dùng câu “chưa có Superchart” trong snapshot đó làm baseline hiện tại. Có source không chứng minh mọi acceptance cũ đã đạt. Phạm vi này không tự mở rộng sang sửa toàn bộ Superchart Essential.

## 3. Phạm vi theo đợt

| Đợt | Phạm vi phải hoàn tất | Điều kiện bàn giao |
|---|---|---|
| POC — kiểm chứng trước khi làm UI đầy đủ | Pin runtime; đóng gói/offline; chạy source nguyên bản; hợp đồng dữ liệu/output; kiểm chứng DCA Phoenix và Risk Metric; thử lỗi/hủy/giới hạn | Báo cáo rõ PASS/FAIL/BLOCKED từng khả năng, chọn runtime hoặc dừng hướng này |
| R1 — tự thêm indicator cùng khung | Editor/import `.pine` hoặc `.txt`; kiểm tra, preview, lưu/sửa/nhân bản/xóa; bật/tắt instance; inputs cơ bản; overlay trên pane giá; line/shape/barcolor; nến đóng và thông báo khi app hoạt động | Luồng tự phục vụ hoàn chỉnh với DCA Phoenix, đối chiếu reference độc lập; muốn xác nhận khớp TradingView phải qua G-TV-PARITY. Không phụ thuộc chỉnh code app cho từng source thuộc phạm vi |
| R2 — indicator nhiều khung thời gian | `request.security()` cùng symbol, D/W và mapping gaps/lookahead theo phạm vi công bố; fill/màu theo điểm/hline và pane riêng cho Risk Metric | Risk Metric đạt reference độc lập; muốn xác nhận khớp TradingView phải qua G-TV-PARITY. Không bật MTF nếu mapping còn sai |

Thứ tự này dựa vào dependency thực của hai source [S10][S12], không có estimate effort giả. POC khảo sát cả hai trước; nếu chỉ R1 đạt thì phải công bố Risk Metric chưa hỗ trợ và giữ R2 riêng. Không gọi R1 là hoàn tất toàn bộ hai ví dụ.

**Must R1:** runtime cô lập, dữ liệu đúng, diagnostics, lưu bền/revision, renderer của DCA, vòng đời và khả năng tự thêm script thuộc contract. **Should R1:** export source/backup thủ công và màn chi tiết đối chiếu. **Could:** tìm kiếm/lọc trong thư viện khi lượng script thực tế cần. Should/Could không che lỗi dữ liệu hay thay thế gate Must.

**Won't trong R1/R2 — đề xuất ngày 2026-10-26:** strategy/backtest/broker/order execution; tự lấy source từ link TradingView; script đóng mã nguồn; import thư viện từ URL; API/network do script gọi; mọi tính năng Pine không nằm trong manifest đã kiểm chứng; chạy alert khi app tắt. R1 chưa nhận `overlay=false`/pane riêng: preflight báo chưa hỗ trợ, không tự đổi thành overlay; pane riêng thuộc R2. Không đổi chart sang Vela hoặc TradingView iframe để né adapter [S16]. Có thể lưu link tác giả làm metadata, không coi link là source thực thi.

## 4. Trải nghiệm người dùng và trạng thái kiểm chứng

| Hành trình | Hành vi/acceptance đề xuất |
|---|---|
| Thêm | Mở Custom Scripts từ Indicators; dán source hoặc chọn file; tự đọc tên từ `indicator()`, cho sửa tên hiển thị; giữ nguyên source gốc, không gửi lên dịch vụ bên ngoài |
| Kiểm tra | Báo phiên bản Pine, tính năng chưa hỗ trợ, lỗi dòng/cột nếu compiler cung cấp; lỗi không có vị trí phải nói rõ. Kiểm tra cú pháp không gắn nhãn kết quả đúng |
| Xem trước | Chạy trên symbol/interval hiện tại; hiển thị rõ “Đang tính”, “Thiếu lịch sử/OHLC”, “Không hỗ trợ”, “Chạy lỗi”, hoặc output. Có Hủy/Thử lại; chart nền vẫn thao tác được |
| Thêm vào chart | Chỉ thêm revision đã qua preflight và chạy thành công trong context này. Mỗi instance có bật/tắt, inputs, xóa khỏi chart, thông báo riêng. Script không có `input.*`, như DCA, không có form tham số giả |
| Sửa | Bản nháp tách revision đang dùng. Apply tạo revision mới; nếu lỗi, không thay revision đang hoạt động. Có hủy chỉnh sửa; không tự sửa logic source |
| Lưu và mở lại | Registry local dùng ID ổn định; tên trùng được phép. Gắn instance vào workspace/surface hiện có, theo context chart; chuyển symbol/interval chạy lại, không lấy output context trước |
| Xóa | “Gỡ khỏi chart” tách “Xóa khỏi thư viện”. Nếu xóa definition đang được dùng, nêu các instance bị ảnh hưởng; giữ snapshot phục hồi trước khi ghi |

Hai lớp trạng thái độc lập:
- **Khả năng chạy:** Chưa kiểm tra / Có thể chạy / Không hỗ trợ / Lỗi / Timeout / Thiếu dữ liệu. “Có thể chạy” chỉ nói source đã compile và chạy trên input hiện tại.
- **Đối chiếu:** Chưa đối chiếu / Đã đối chiếu trên bộ dữ liệu xác định / Cần đối chiếu lại. Báo cáo gắn source hash + runtime/build + inputs + dataset + timeframe; sửa một thành phần thì không tái sử dụng dấu đối chiếu. Người dùng vẫn có thể preview source mới chưa đối chiếu, với trạng thái trung thực.

Trạng thái đối chiếu phải ghi riêng **reference độc lập** và **TradingView**. Khả năng tính toán, hiển thị và thông báo cũng có verdict riêng; ví dụ hình chạy được nhưng tần suất alert chưa hỗ trợ phải hiện “Thông báo chưa hỗ trợ cho script này”, không gắn một badge PASS chung che phần thiếu.

Loading/empty/error/loaded đều giữ khung chart ổn định. Retry không nhân đôi instance. Dark/light, bàn phím, cửa sổ hẹp và tên riêng dùng `Text(verbatim:)` được kiểm tra. Tên thương hiệu, tác giả và chuỗi riêng trong source giữ nguyên.

## 5. Thiết kế kỹ thuật đề xuất

### 5.1 Runtime, đóng gói và giới hạn

Luồng dữ liệu: **Editor/Registry → compiler/preflight → runner cô lập → output được kiểm tra → adapter Lightweight Charts**. Data request đi qua StockDeck; script chỉ nhận dữ liệu giá cần thiết, không nhận holdings/credentials. PineTS là runtime, không phải chart renderer có sẵn cho StockDeck [S13][S16].

- Pin package version, commit, lockfile, artifact hash và license tại M0; vendoring bundle local, không tải runtime từ CDN khi mở app. Node chỉ là công cụ build/test, không bắt người dùng cài Node.
- Ưu tiên helper process có thể terminate, JavaScriptCore chạy ngoài main thread; host offline và process watchdog đã chạy trong POC S17/S18. Nếu thiếu Web API hoặc không thể cô lập/giới hạn đúng, ghi BLOCKED và trình phương án host thay thế trước khi làm UI đầy đủ; không fallback chạy source trên luồng chart. Production isolation/IPC/hard cap vẫn cần chứng minh [A5].
- Chỉ nhận Pine `indicator()` thuộc manifest. Parser/AST và runtime cùng thực thi policy; không dùng regex đơn lẻ để chứng minh tương thích. Chặn JavaScript đầu vào, `strategy()`, import/network và API tính toán/hiển thị không hỗ trợ; unknown call dừng instance với lỗi, không silently no-op. Khả năng gửi thông báo là contract riêng: chỉ được tắt có diagnostic rõ khi output tính toán/hiển thị vẫn được kiểm chứng, không âm thầm thay tần suất của source.
- Helper không có native bridge đọc file/Keychain/network hay eval từ renderer; chỉ IPC schema đã giới hạn. Kiểm thử escape qua source/string/import/constructor, message giả và dữ liệu output quá lớn. Watchdog nằm ngoài runner, có thể kill compile lẫn execution bị treo. Cô lập JS context không tự được coi là OS sandbox; POC phải chứng minh cấu hình quyền thực tế.
- Giới hạn đề xuất A6: source 128 KiB, 3 instance đang bật, 10.000 bars/instance, 5 giây/job và 256 MiB runner. Tính cả compile, output và bộ nhớ trung gian; vượt ngưỡng phải dừng, giữ chart nền. Không giảm dataset âm thầm để vừa giới hạn. Chốt lại trước đo theo A6; chưa có benchmark chứng minh các giá trị phù hợp.

### 5.2 Hợp đồng dữ liệu và state

- Input có canonical symbol/market/provider, native price units, interval, timezone/session, timestamps mở/đóng nến, adjustment policy, data revision và trạng thái nến confirmed/provisional. Không dựng open/high/low từ close để chạy DCA khi thiếu OHLC. Không loại nến thiếu rồi nén `bar_index`; phải giữ ngữ nghĩa gaps/`na` hoặc từ chối context.
- Đừng coi `hasOHLC` hiện có là đủ: code hiện tại chỉ cần một số bar có OHLC [S11]; DCA cần coverage theo từng bar. Tải lịch sử ở background, tách visible range khỏi calculation history; không reset EMA/state khi pan/zoom.
- EMA200 không đồng nghĩa chỉ tải 200 bars. DCA dùng `var` và lần crossover trước đó nên cần lịch sử khởi tạo nhất quán. Khi history bị cắt, ghi coverage và trạng thái chưa xác minh; không khẳng định tín hiệu trùng TradingView. Đổi start history hoặc backfill phải replay từ checkpoint hợp lệ hoặc từ đầu.
- `var`, `na`, `:=`, lazy boolean Pine v6, `bar_index`, rollback nến realtime và `barstate.isconfirmed` phải được kiểm thử. Không để mutation trên tick provisional trở thành state đã chốt khi nến đóng.
- Risk Metric cần SMA/stdev 1.460 nến D, SMA 20/50 W, SMA 50 D, timestamp `time` theo milliseconds và mapping `request.security()` [S12]. Tuần theo lịch/session nguồn; không chia tuỳ tiện thành nhóm 7 bars. Khung chart khác ảnh hưởng `time` và mapping, không cố định mọi phép tính ở D rồi kéo giãn ảnh.
- Cache key gồm script ID/revision/hash, inputs, runtime version, symbol/provider/session/timezone/adjustment, timeframe, dataset revision/start/coverage và live-bar revision. Compiled artifact có cache riêng. Cancel và generation token theo mọi thay đổi context; output muộn không được xuất hiện trên mã/khung mới.
- Tính trên background, cập nhật UI trên MainActor. Không tính lại theo crosshair/hover; batch quote, debounce editor/persistence; cache không gọi lại FX hoặc định giá portfolio. Script chỉ có output phân tích, không ghi vào quote hay lịch sử nguồn.

### 5.3 Renderer, lưu bền và alert

- Schema output có owner instance/revision/context, timestamp, plot style/color/alpha, pane/scale, marker và barcolor; giữ gaps `na`, từ chối NaN/Inf hoặc timestamp ngoài input. Không stringify source vào `evaluateJavaScript`; source là dữ liệu cho runner, không chèn vào HTML.
- R1: line EMA overlay, triangle above/below bar, `color.new` alpha và barcolor. R2: pane Risk, line màu theo điểm, ngưỡng và fill. Không ép risk về 0–1: source không clamp nên kết quả ngoài khoảng phải được giữ đúng [S12].
- Merge marker theo owner với Insider/marker có sẵn, không gọi `setMarkers()` làm mất nhóm khác. Màu nến: thứ tự instance hiển thị quyết định ưu tiên, instance sau ghi đè khi có màu, `na` không ghi đè; có thao tác đổi thứ tự. Gỡ/tắt phải tính lại màu cơ sở, không để màu sót [A7]. Mở line mode vẫn giữ EMA/marker phù hợp; barcolor không có nến để tô, không biến màu đường giá thành tương đương giả.
- Registry và instance store có schemaVersion, source nguyên văn/hash, revision, inputs, metadata tác giả/link/license nếu biết. Ghi atomic/debounce background, backup trước migration; file hỏng báo lỗi và giữ file cũ. Chưa rõ quyền tái phân phối thì không đóng gói source mẫu vào bản phát hành.
- Alert mặc định tắt cho mỗi instance, opt-in trong app; thông báo hệ điều hành dùng quyền hiện có hoặc hỏi quyền theo luồng bình thường. Tách lựa chọn `alertcondition` và `alert()`; không bật cả hai ngầm gây trùng. Chỉ phát từ job/context còn active, nến đóng đã xác nhận; không phát lại lịch sử khi import/replay/reopen. Dedup bền theo instance/revision/rule/symbol/interval/bar-open-time, không dựa `bar_index` cục bộ của lần tải.
- Contract thông báo đợt đầu: hỗ trợ `alert.freq_once_per_bar_close` và `alertcondition` với lựa chọn host “khi nến đóng”. `alert.freq_all`, `alert.freq_once_per_bar`, freq mặc định/động chưa xác định là ngoài phạm vi thông báo đợt này [S15]. Preflight phải tắt route thông báo không hỗ trợ và báo rõ; vẫn cho chạy hình khi contract tính/hiển thị đạt. Không biến chúng thành once-per-bar-close ngầm; không gắn nhãn “alert tương thích” cho phần đó. Lựa chọn “khi nến đóng” của host không sửa source `alertcondition`.
- Khi app tắt/ngủ, runner chưa có dữ liệu mới hoặc mất mạng: hiển thị trạng thái theo dõi tạm dừng. Không hứa alert realtime 24/7; scope này chỉ đánh giá khi app đang hoạt động và có nến cập nhật. `alertcondition` cần host policy đóng nến rõ ràng, không suy `barstate.isconfirmed` trong một nhánh `alert()` áp dụng cho cả source.

## 6. Bộ kiểm chứng và oracle độc lập

### 6.1 Phân biệt bằng chứng

**Compile được ≠ chạy được ≠ đúng công thức ≠ giống TradingView ≠ hiển thị/alert đúng.** Mỗi lớp có gate và báo cáo riêng. Unsupported/timeout/missing data là kết quả hữu ích, không được tính PASS tương thích.

POC cố định manifest trước khi chạy: source hash, runtime/toolchain/macOS/build, dataset immutable có SHA-256 và nguồn/thời điểm lấy, symbol/exchange, timezone/session, adjustments, start/end history, interval, inputs, bars confirmed và expected output. Dữ liệu app/demo là dữ liệu thật; fixture số học tổng hợp chỉ dùng test, ghi rõ test-only, không hiển thị như thị trường thật [S9][S11].

Oracle gồm hai lớp:
- Reference tính toán độc lập trên chính OHLC input, không dùng lại PineTS/transpiler hoặc hàm Swift app đang kiểm tra; unit fixtures nhỏ để kiểm soát crossover/equality/`na`/state/alpha/gaps. Đây chứng minh thuật toán theo input, chưa chứng minh tương đương TradingView.
- TradingView reference: lấy output numeric/marker/alert trên cùng feed, interval, cấu hình và history khởi tạo. Xác minh khả năng xuất dữ liệu hoặc reference harness hợp lệ tại M0; không mặc định tài khoản có export. Screenshot chỉ chứng minh vị trí/màu, không đủ làm numeric oracle. Nếu không lấy được input/output đủ chính xác thì ghi **BLOCKED đối chiếu TradingView**, vẫn có thể làm engine test độc lập nhưng không gắn nhãn “đã khớp TradingView”. Không dùng Yahoo và Bitstamp khác feed để quy sai số cho engine.

### 6.2 Hai script người dùng cung cấp

| Script | Các kiểm tra bắt buộc |
|---|---|
| DCA Phoenix nguyên bản [S10] | EMA200; buy sau crossover xuống, nến tăng/râu dưới dài hơn, low mới thấp hơn tín hiệu trước, reset khi close > EMA; sell nến giảm/râu trên/thân, low > EMA, high không thấp hơn tín hiệu trước, đợi 200 bars sau crossover lên và reset khi close < EMA. Kiểm tra đúng ranh giới 199/200 bars, close == EMA, high bằng đỉnh cũ, low bằng đáy cũ và state qua gaps/replay/live |
| DCA Phoenix — nhánh alert | Source gốc khởi tạo `lastBuyAlertBar`/`lastSellAlertBar` bằng `na`, so sánh `!= bar_index`, vì vậy nhánh `alert()` bị chặn theo Pine v6 [S15]. Test phải tái hiện hành vi gốc; `alertcondition()` được test riêng. Nếu sửa, tạo revision thử riêng với diff và sự đồng ý của người dùng, không âm thầm sửa source hoặc dùng bản sửa để tuyên bố source gốc tương thích |
| Risk Metric combined [S12] | Ba thành phần và trung bình đúng công thức; sample warmup quanh 1.460 nến ngày; dữ liệu tuần chưa đóng; đầu tuần/ngày; gaps/lookahead; log/time milliseconds; output `na` khi thiếu lịch sử, giữ giá trị ngoài 0–1; màu đường/ngưỡng/fill và thay inputs |

Với mỗi script: test full replay, chunked replay, nến mới, sửa tick cuối, backfill và đổi symbol/interval; output phải nhất quán trong cùng semantics/context. DCA “200” là số bars khung hiện tại [S10], không tự đổi thành 200 ngày. R1 chưa hỗ trợ MTF thì Risk phải bị chặn rõ, không vẽ bản chỉ có một phần công thức.

### 6.3 Gate và ngưỡng đề xuất trước đo

Các ngưỡng này là **policy A6/A7**, chưa phải kết quả hay cam kết tốc độ thị trường:

| Gate | Tiêu chí PASS | Bằng chứng |
|---|---|---|
| G-RUNTIME | Mọi API/type/semantics được công bố hỗ trợ có test; cả valid và negative cases; source nguyên bản hai ví dụ có verdict riêng | Coverage manifest theo version, compiler logs, test report |
| G-NUMERIC-REFERENCE | Mọi bar đủ điều kiện nằm trong `abs(error) <= 1e-8 + 1e-6 * abs(reference)`; khớp hoàn toàn vị trí `na`, boolean, timestamp, marker, màu/alpha và alert event thuộc contract công bố; không bỏ sample fail | Reference tính độc lập cùng input, so sánh machine-readable và diff từng bar; không dùng PineTS làm oracle của PineTS |
| G-TV-PARITY | Cùng source/runtime/inputs/feed/session/history khởi tạo, output TradingView đáp ứng tolerance G-NUMERIC-REFERENCE và khớp signal/time/na/event được hỗ trợ. Thiếu input hoặc output đủ chính xác là BLOCKED | Dataset + export/reference harness TradingView đủ precision, không dùng số đã làm tròn 2 chữ số hoặc screenshot đơn lẻ |
| G-UX | Tự import → kiểm tra → preview → add → edit/cancel → bật/tắt → reopen → gỡ/xóa; loading/empty/error/loaded, keyboard, dark/light, resize đều hoàn tất | Checklist native trên bản Dev và ảnh cho trạng thái chính |
| G-ISOLATION | Cancel/timeout có hiệu lực, lỗi/treo/oversized output không treo chart; không đọc/ghi file, network hoặc gọi bridge ngoài contract; output sai context bị loại | Negative fixtures và trace IPC/quyền/process watchdog |
| G-ALERT | Không trùng và không replay lịch sử; đúng nến đóng; reset/reopen/offline/revision change có verdict; app tắt ghi rõ không theo dõi | Event ledger + kiểm tra thông báo native |
| G-PERSIST | Definition/revision/instance không mất sau restart, lưu lỗi, file hỏng, kill giữa ghi; phục hồi bản cũ được | Store trước/sau, recovery log |
| G-PERF | Warm cache đúng context, gồm custom output, max <=1 giây; mỗi pan/zoom/chuyển mã p95 frame <=33 ms. Job cold không quá watchdog 5 giây A6; không pass nếu bị timeout | 30 warm/10 cold, mỗi interaction 30 giây theo protocol A4; đo 1 và 3 instance với dataset thực 5.000 và 10.000 bars A6; báo median/p95/max, CPU/RSS, kể cả fail/timeouts |
| G-REGRESSION | Toàn bộ `swift test`, bộ test JS runtime/integration và build `./dev.sh` đều thành công; built-in indicators/drawing/Insider/targets, chart chi tiết, valuation/native currency/FX/quỹ Nhật không regression | Logs nguyên vẹn, checklist trước/sau; baseline failure phải xử lý/phân loại công khai, không gắn PASS giả |

Thêm 20 vòng đóng/mở chart theo yêu cầu kiểm tra đã có [S1]: job/helper/handler/output phải giải phóng, không tăng số instance còn sống; ghi RSS thực trước/sau, không đặt baseline tưởng tượng. Mọi gate bắt buộc của đợt đều phải PASS. **G-TV-PARITY là gate riêng:** bản Dev để thử engine có thể bàn giao khi các gate còn lại PASS nhưng phải ghi “chưa đối chiếu TradingView” nếu TV BLOCKED; bản đó không hoàn tất nghiệm thu tương đương TradingView của ví dụ liên quan. Muốn gắn nhãn DCA/Risk “đã khớp TradingView” bắt buộc G-TV-PARITY PASS cho đúng revision/context. FAIL/BLOCKED/NOT RUN không được hòa vào PASS tổng. Không nới tolerance hoặc bỏ test sau khi thấy kết quả để đủ gate.

## 7. Mốc triển khai, người thực hiện và điểm dừng

Người triển khai chịu trách nhiệm chạy kỹ thuật/QA và cung cấp bằng chứng; người dùng duyệt phương án, lựa chọn license nếu có nghĩa vụ/chi phí mới và xác nhận trải nghiệm Dev. Không đẩy phần tìm lỗi kỹ thuật sang người dùng. Chưa ước lượng lịch/effort trước POC; không hứa ngày hoàn thành [A5].

| Mốc | Việc thực hiện sau duyệt | Đầu ra/điểm dừng |
|---|---|---|
| M0 — baseline và điều kiện tích hợp | Giữ nhánh feature, kiểm tra local changes; baseline test/build; pin runtime; kiểm tra API coverage/host và license; cố định hai source/hash, dataset/oracle acquisition và limits | Báo cáo baseline + license route + manifest. License hiện tại là AGPL-3.0/commercial [S14]; chưa kết luận StockDeck được phép bundle. Không mua/chấp nhận hợp đồng hoặc thay license app nếu chưa được yêu cầu. Chưa rõ quyền thì thử nghiệm riêng theo điều kiện phù hợp, không phân phối runtime/source |
| M1 — POC runner | Bundle local, runner/IPC/watchdog, preflight và output fixtures; chạy cả hai source; reference độc lập, kiểm tra NaN/na/rollback/cancel | Báo cáo khả thi: dùng được / cần thu hẹp / không phù hợp. Host hoặc semantics fail thì dừng tích hợp UI, ghi nguyên nhân và lựa chọn thay thế; không chuyển sang hardcode hai script để gọi là thành công |
| M2 — dữ liệu và adapter | Runtime nhận dữ liệu StockDeck; registry/revision/cache; line/shape/barcolor; test context race/missing OHLC; bắt đầu DCA trên native chart | G-NUMERIC-REFERENCE/G-ISOLATION của R1 PASS; lưu/store và output owners đúng |
| M3 — luồng R1 | Editor/import, diagnostics, preview/apply/cancel, quản lý instance, inputs, persistence, native alerts theo scope | G-UX/G-ALERT/G-PERSIST PASS; DCA source gốc và bản sửa nếu được duyệt ghi riêng |
| M4 — mở rộng R2 | `request.security` D/W cùng mã, pane/fill/colors, reference Risk Metric | R2 chỉ bật khi các gate MTF/numeric/renderer đều PASS; không ghép dữ liệu giả |
| M5 — QA và Dev handoff | Chạy regression/build/benchmarks/recovery trên bản Dev thực; tổng hợp coverage, unsupported features và lỗi còn lại | G-PERF/G-REGRESSION và mọi gate engine của đợt bàn giao PASS; báo G-TV-PARITY riêng. Nếu TV BLOCKED, chỉ bàn giao Dev thử engine có nhãn chưa đối chiếu; nghiệm thu khớp TradingView vẫn bị chặn |
| M6 — người dùng trải nghiệm | Người dùng tự thêm source, đổi mã/khung, mở lại, kiểm tra cách báo unsupported | Sau xác nhận trải nghiệm mới commit theo AGENTS.md. Push/PR/merge/release chỉ khi được yêu cầu riêng |

Không có gate ngầm yêu cầu người dùng đánh giá mọi script mới. Manifest và diagnostics phục vụ tự kiểm tra; chỉ feature ngoài contract hoặc sai lệch mới cần kỹ thuật xem thêm.

## 8. Vị trí dự kiến thay đổi và phạm vi ngang

| Điểm hiện tại | Dự kiến |
|---|---|
| `Services/LightweightChartTrial.swift` | Thêm context/output contract; tách runtime khỏi coordinator lớn, giữ built-in calculation cache và request guard |
| `Resources/LightweightChartTrial.html` | Adapter custom series/markers/barcolor/panes; owner cleanup; không nhét compiler/source execution vào HTML chart |
| `Views/SuperchartWorkspaceView.swift` | Entry Custom Scripts và instance scope; editor state cô lập khỏi symbol list/crosshair |
| `Services/SuperchartIntradayLoader.swift` và history model | Chỉ bổ sung metadata/coverage cần thiết sau audit; không đổi provider hay valuation nhằm làm script trông giống TradingView |
| Module mới, tên đề xuất | `CustomScriptStore`, `CustomScriptRunner`, `CustomScriptDataContext`, `CustomScriptOutput`, `CustomScriptManagerView`; helper/resources và lockfile riêng |
| `Package.swift`, `dev.sh`, pipeline release hiện có | Đóng gói resources/helper, ký thành phần mới nếu cần; smoke test offline. Không phát hành trong công việc lập plan |
| `Tests/` và bộ test JS mới | Oracle/fixtures được version, runner/state/IPC/adapter/integration; full regression suite hiện có |

R1/R2 entry chỉ ở Superchart; detail chart không tự kích hoạt custom instance, nhưng phải test vì cùng renderer. Không phá preferences hoặc built-in style giữa hai surface. Các thị trường/mã không đủ OHLC vẫn xem chart nền được, script báo thiếu dữ liệu. Regular/Ext, native currency, FX cadence và tỷ lệ quỹ Nhật tiếp tục tuân AGENTS.md.

## 9. Độ nhạy của lựa chọn và đường lui

- **Robust:** cần registry + diagnostics + data/output contract dù đổi runtime; chuyển từng script thủ công không giải quyết nhu cầu tự phục vụ [S9].
- **Sensitive A5:** nếu PineTS không qua host/semantics/license, lựa chọn PineTS đảo; giữ đặc tả UI/contract, báo blocker và phương án engine khác trước đầu tư UI đầy đủ. Không suy docs support thành compatibility test PASS.
- **Sensitive A6:** trong khoảng 1–5 instance/5.000–20.000 bars, thứ tự POC trước vẫn giữ; khả năng đáp ứng cache/CPU/memory có thể đảo quyết định limit. Báo actuals và đề xuất limit mới để duyệt trước đợt đo mới; không âm thầm truncate hoặc đổi gate sau đo.
- **Sensitive A7:** nếu người dùng cần alert khi app tắt hoặc mọi API Pine, kiến trúc/phạm vi phải xem lại; không hứa mở rộng bằng một toggle. Xung đột barcolor/input phức tạp có thể đổi phạm vi renderer.
- Đường lui Dev: tắt custom feature, terminate helper/jobs, gỡ custom output theo owner, khôi phục màu nến nền; built-in chart tiếp tục hoạt động. Giữ definitions/revisions và store backup để phục hồi; flag off không được gọi là data rollback.
- Bất kỳ 1 lỗi lẫn mã, mất source/store, valuation thay đổi hoặc thực thi vượt quyền đều chặn bàn giao và tắt custom feature cho tới khi sửa/test lại [A7]. Không remote analytics, không upload source/dữ liệu portfolio để “kiểm tra”.

## 10. Trạng thái bằng chứng và audit

- Cập nhật sau duyệt thử [S17]: đã pin PineTS 0.13.0, chạy source trong Node và Swift/JavaScriptCore, reference độc lập và benchmark helper. Alert `na` DCA đã tái hiện; EMA khác reference nên DCA FAIL. Risk PASS numeric trên dataset D/W đã thử; ba Risk cold timeout 10/10 theo budget A6.
- Đã chạy baseline 616 tests/dev build, 9 test harness; hiện có app integration/renderer/editor ở mức đầu tiên. Chưa có native alert/OS memory sandbox/TV parity/UI FPS PASS. Báo cáo thực nghiệm là nguồn hiện tại, không dùng audit kế hoạch dưới đây thay cho test runtime.
- Cập nhật tiếp tục [S18]: bản sửa engine chung PASS reference DCA/Risk, native Node/JSC tolerance; giữ nguyên Pine source/dataset/ngưỡng. 60/60 cold jobs hoàn tất; ba Risk max 4,603 giây trong watchdog 5 giây, 30 cached calls/scenario. 18 harness + 616 app tests/dev build PASS. Primary live-tail/state/alert retention có fixture hồi quy; chưa MTF live, production isolation/license/preflight/TV oracle/UI FPS. S17 là baseline lịch sử, S18 là kết quả mới nhất.
- Audit độc lập ngày 2026-10-26: reviewer chỉ đọc tài liệu/source, không chạy app; không thấy P0/P1. Ba P2 đã chỉnh trong bản này:
  - Pane R1/R2 mâu thuẫn: R1 chỉ overlay pane giá, `overlay=false` bị preflight chặn; pane riêng ở R2.
  - Alert policy có thể đổi semantics ngầm: manifest tách khả năng gửi thông báo, frequency ngoài contract báo rõ/tắt route, không đổi source hoặc mặc định chuyển thành đóng nến.
  - Numeric/TradingView gate bị gộp: tách G-NUMERIC-REFERENCE và G-TV-PARITY; Dev thử engine chưa phải nghiệm thu khớp TradingView.
- Các chỉnh sửa audit này không chứng minh runtime PASS; số liệu compatibility/benchmark chỉ lấy từ thực nghiệm S17/S18 và giữ đúng giới hạn scope.
- Reviewer đã đọc lại bản chỉnh, xác nhận cả ba P2 được xử lý và không còn blocker từ các findings của lượt audit này.

- Cập nhật app integration ngày 2026-10-26: thêm PineTS bundle, `PineScriptRunner` executable, local editor/library/import, run/preview/save, line/shape/barcolor/pane output và release/dev bundle wiring. Runner giới hạn source 128 KB, 20.000 nến, output 4 MB, 2.500 điểm/plot và watchdog 5 giây tại app process. D/W/M same-symbol offline provider chạy Risk Metric fixture; `Risk` cuối cùng khớp reference S18 chính xác (diff 0), DCA EMA cuối cùng khớp và 44/5 buy/sell shapes trong 2.500 bar tail khớp reference. Fill chưa được vẽ, alert chỉ đếm. 616 app tests, dev build, Release build, JS syntax/helper smoke tests và `git diff --check` PASS. Còn thiếu visual app/TV parity, OS memory cap và UI/performance QA.

Điểm dừng hiện tại: **M1/R1/R2 chưa nghiệm thu hoàn tất**. Candidate S18 đạt numeric/budget trên fixture; app runner, D/W/M same-symbol provider và pane renderer đã được thêm nhưng Risk Metric chưa qua kiểm tra app/reference/TradingView. Fill, native notification, OS memory limit và UI/performance QA vẫn còn. Không coi helper PASS là nghiệm thu app.
