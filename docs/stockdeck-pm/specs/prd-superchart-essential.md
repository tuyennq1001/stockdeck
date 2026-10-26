# StockDeck Superchart Essential — đề xuất sản phẩm và kế hoạch triển khai

Trạng thái: **đề xuất để duyệt**, chưa phê duyệt phạm vi mới, chưa triển khai code app từ tài liệu này. Cập nhật: 2026-10-25. Người quyết định phạm vi/nghiệm thu: chủ sản phẩm StockDeck.

Theo yêu cầu lập plan, đã hợp nhất thành [kế hoạch triển khai](implementation-superchart-essential.md): M0–M4 khớp PRD, M5 của PRD tách thành M5 QA/M6 nghiệm thu; không đổi phạm vi R1A/R1B. Đây là tài liệu thực thi tham chiếu PRD và QA, chưa phải kết quả triển khai.

## 1. Mục tiêu và căn cứ

Job: khi rà Watchlist hoặc danh mục đang nắm giữ, người dùng muốn chọn mã, hiểu xu hướng trên nến, ghi lại mức/vùng giá, đặt nhắc giá và quay lại bảng mà không phải bố trí lại màn hình. Nhu cầu chọn nguồn, tiết kiệm diện tích và đo vùng giá có bằng chứng trực tiếp trong hội thoại [S1]; mức ưu tiên của các công cụ vẽ bổ sung là đề xuất chuyên môn cần kiểm chứng (A1/A2).

**Đề xuất:** lấy luồng phân tích của TradingView làm tham chiếu, xây một workspace phân tích dùng chung dữ liệu StockDeck. Không sao chép toàn bộ menu TradingView. TradingView hiện cũng có Portfolio [S8]; khác biệt cần giữ là nối liền các Watchlist/Portfolio đa thị trường hiện có, quy tắc định giá, cache và thao tác macOS của StockDeck [S1][S2].

Không có dữ liệu analytics, reach, effort estimate hay baseline tốc độ tác vụ đã đo. Vì vậy không tạo điểm RICE hoặc hứa lịch giao hàng giả. Thứ tự dưới đây dựa vào phụ thuộc luồng công việc và phạm vi đã yêu cầu; độ nhạy được ghi trong backlog/prioritization-2026-10-25.md.

### Kết quả cần đạt

- Hoàn thành luồng: chọn nguồn → chọn mã → phân tích → đánh dấu/đo → đặt nhắc nếu cần → quay lại bảng; không mất mã, góc nhìn hoặc nét vẽ [S1].
- Đúng mã/đúng ngày/đúng tiền tệ, không lẫn phiên chính và extended hours [S1][S2].
- Mục tiêu hiệu năng giữ từ kế hoạch đã duyệt: chart cache sẵn sàng ≤ 1 giây; p95 tương tác ≤ 33 ms với lịch sử 10 năm và các chỉ báo bật [S1]. Đây là **mục tiêu chưa đo đạt**, không phải kết quả hiện tại.
- Baseline tác vụ, thời gian render, bộ nhớ StockDeck + WebKit: **chưa đo** [S2]. Đo trước/sau trong Dev, không thêm telemetry mạng.

## 2. Hiện có, thiếu gì, và cần sửa nền tảng

| Khả năng | Hiện trạng qua code [S2] | Quyết định |
|---|---|---|
| Nến/đường fallback, D/W/M, preset khoảng xem | Đã có trong chart dùng chung | Giữ; thu gọn UI, làm rõ quan hệ interval/range |
| Volume, SMA/EMA, BB, RSI, MACD | Đã có công thức; chu kỳ SMA/EMA và màu chủ yếu cố định | Tái sử dụng bộ tính, thêm quản lý tham số |
| Insider BUY/SELL, đường giá mua mục tiêu | Đã có | Dùng lại; phân biệt rõ Insider với giao dịch cá nhân |
| Price Range lưu theo mã | Đã có bản đầu, lưu UserDefaults; chọn chủ yếu khi bật chế độ vẽ | Hoàn thiện chọn/sửa/lưu/undo theo cùng hệ thống drawing |
| Superchart và selector Watchlist/Portfolio | Chưa có trong app; mới là mockup | Là nền tảng R1 |
| Công cụ vẽ khác, undo/redo, lock/hide, snap | Chưa có trong app | Bộ vẽ/lifecycle R1A; hide all/lock all/snap R1B, không đặt icon giả |
| Pane/toolbar/độ cao | Chart 420 px; nhiều hàng điều khiển; có card Volume bổ sung | Superchart co giãn, Volume overlay; bỏ sự lặp trong Superchart |
| Sẵn sàng sản phẩm | Test Swift có báo cáo, nhưng tương tác WebKit và benchmark chưa kiểm chứng đủ | Gate nghiệm thu bắt buộc, không coi unit test là đủ |

Các việc nền tảng bắt buộc trước khi thêm công cụ:

- Không dựng lại toàn bộ series/pane khi chỉ bật/tắt một overlay. Đổi configuration dùng diff, giữ visible range và tỷ lệ pane.
- Price Range hiện là canvas overlay. Đưa drawings sang series primitives để redraw bám cả trục giá và thời gian, thay vì phụ thuộc sự kiện hover [S6].
- Bridge hiện nhận lưu drawings rồi dùng symbol của parent. Thêm symbol + request/session ID trong cả hai chiều, từ chối command cũ sau đổi mã.
- Lưu drawing không ghi đồng bộ trên UI thread. Bổ sung background writer, debounce và flush khi đóng app.
- Chuỗi lịch sử phải biết độ phân giải gốc; không trộn dữ liệu tháng vào daily để tạo nến/chỉ báo ngày. Cache cũ không rõ độ phân giải phải được phân loại từ nguồn hoặc tải lại khi cần.

## 3. Phạm vi R1 — bộ Essential đề xuất để duyệt

**Khuyến nghị duyệt R1A trước:** F01–F09 và F12–F14, gồm workspace + phân tích + bộ vẽ nhỏ có vòng đời hoàn chỉnh. F08 có phần mở rộng mới cần duyệt, nhưng được khuyến nghị cùng R1A để phủ mức/xu hướng/vùng/đo. **R1B (Should, đợt kế tiếp):** F10 và entry point mới của F11; không chặn trải nghiệm R1A. Các khả năng target/alert đã có trong Bảng vẫn giữ. Mockup bàn giao chỉ hiện R1A, không treo icon R1B chưa làm. Các bổ sung ngoài yêu cầu đã chốt được đánh dấu **Đề xuất mới**; chưa phải user approval. Lý do sản phẩm là giả thuyết chuyên môn A1/A2 nếu chưa có bằng chứng người dùng trực tiếp.

| ID / Tính năng | Vì sao nên có | Cách hoạt động cụ thể | Bằng chứng / trạng thái |
|---|---|---|---|
| F01 Bảng ↔ Superchart | Bảng phục vụ quản lý, chart phục vụ phân tích; không buộc hi sinh một bên | Nút cố định góc trên trái cạnh sidebar. Bảng giữ UI/cột/sort/scroll hiện tại; Superchart ẩn navigation lớn, chart trái và list phải sát nhau | [S1], đã thống nhất hướng |
| F02 Chọn nguồn Watchlist/Portfolio | Một workflow cho cả theo dõi và tài sản nắm giữ | Một dropdown chia nhóm theo loại; tên lấy từ StorageService, ID ổn định. Chọn nguồn không sửa dữ liệu hay lựa chọn đang lưu của màn Bảng | [S1], đã thống nhất hướng |
| F03 List mã gọn + tìm/lướt mã | Rà nhiều mã mà không mở từng modal hoặc quay lại bảng | Cột cố định Symbol / Last / Chg% / Ext%. Tìm trong nguồn hiện tại, click hoặc ↑/↓ khi list có focus đổi chart; giữ thứ tự gốc. Tìm mã là **đề xuất mới** | [S1], tìm/lướt là A1 |
| F04 Interval/range | Tránh chọn tháng nhưng vẫn nghĩ mình đang nhìn nến ngày | Dropdown D/W/M; preset dưới chart. Đổi preset tự chọn D cho đến 1Y, W cho 3Y/5Y, M cho 7Y/10Y; All theo độ dài lịch sử thực. Đổi interval thủ công giữ khoảng thời gian, lần đổi preset tiếp theo áp dụng Auto lại | [S1] |
| F05 Điều hướng và trục giá | Cần khôi phục chart dễ dàng sau khi zoom/kéo; Log hữu ích khi xem dài hạn | Giữ gesture mặc định LW; nút Về mới nhất, Reset và Auto scale. Settings chọn Linear/Log, Candles/Line. Double-click trục giá về Auto. Các điều khiển scale/type bổ sung là **đề xuất mới** | [S4][S6], A1 |
| F06 Volume + pane | Diện tích nến là ưu tiên; chỉ báo không nên bóp nến thành một dải mỏng | Volume overlay trục độc lập ở đáy vùng giá; RSI/MACD pane dưới, resize; mỗi pane có phóng riêng/khôi phục và đóng. Bật lại lấy tỷ lệ trước đó | [S1][S4][S6] |
| F07 Quản lý Indicators | Bật/tắt chưa đủ nếu không chỉnh chu kỳ theo cách phân tích | Popover tìm và thêm SMA, EMA, BB, RSI, MACD; nhiều SMA/EMA; sửa chu kỳ và màu từng instance; remove/ẩn riêng. Không tạo pane trống khi thiếu dữ liệu | [S1], tham số/color là mở rộng proposal |
| F08 Bộ vẽ cốt lõi | Đủ diễn đạt mức, xu hướng, vùng và độ biến động | Rail trái: Select; Horizontal Line; Trend Line; Rectangle; Price Range. Horizontal/Trend/Rectangle là **đề xuất mới**. Chỉ vẽ trên pane giá R1 | [S3], A2; Price Range [S1] |
| F09 Sửa đối tượng + Undo/Redo | Một nét vẽ sai cần sửa được; không nên xóa rồi vẽ lại | Click chọn, kéo cả đối tượng hoặc handle; toolbar ngữ cảnh màu/độ dày/lock/delete; Cmd-Z và Cmd-Shift-Z cho thay đổi drawing, không tác động giao dịch | [S3], A2; **đề xuất mới** |
| F10 Hide/lock/snap | Chart cần tạm sạch và tránh kéo nhầm nét đã hoàn thành | Rail có Hide all, Lock all và Snap OHLC. Hide giữ dữ liệu, lock chặn chỉnh sửa, snap mặc định tắt. Xóa tất cả có xác nhận. **Đề xuất mới** | [S3], A2 |
| F11 Giá mục tiêu và Alert hiện có | Hoàn thành vòng phân tích → theo dõi mà không cần nhìn màn hình liên tục | Hiển thị giá mục tiêu trong menu Hiển thị; bell mở dialog PriceAlert hiện tại cho mã đang chọn. Context menu tại mức giá có Đặt giá mục tiêu / Tạo nhắc giá. Không xây alert engine mới | [S1][S2], entry point SC là **đề xuất mới** |
| F12 Lớp sự kiện Insider | Không để BUY/SELL bị hiểu là giao dịch của chính người dùng | Một toggle hiển thị Insider BUY/SELL, đồng bộ showInsiderMarkers toàn app. Tooltip ghi rõ nguồn Insider; giữ bộ lọc hiện có | [S1][S2] |
| F13 Lưu workspace và drawings | Phân tích phải còn sau khi chuyển màn hoặc mở lại app | Lưu mode/source/interval/preset/panes; góc nhìn theo symbol+interval; drawings theo canonical symbol, cùng mã ở nhiều nguồn dùng chung. Local-only R1 | [S1][S5], lifecycle mở rộng A2 |
| F14 Dữ liệu và trạng thái đáng tin | Chart đẹp nhưng sai phiên, sai lịch sử hoặc nhầm NAV thành OHLC là thất bại | Loading/Empty/Error+Retry/Loaded, cached offline, nhãn thiếu OHLC/volume/history; locale/native currency/theme của app; không tự bịa nến, % hay execution | [S1][S2] |

### Quy tắc dữ liệu F03/F14

- Last = `quote.price`, Chg% = `quote.changePercent` phiên chính. Ext% = `quote.extendedChangePercent` theo PRE/POST/CLOSED hiện có; tooltip ghi session. Không cộng Ext vào Chg hoặc P&L. Crypto hoặc không có Extended dùng `—`.
- Chg% so với phiên ngày của thị trường, không so với candle đang chọn; đổi W/M không đổi bảng Chg% [S7]. Thời điểm giá trong tooltip, giữ số 0 thật thay vì thay bằng `—`.
- Source Portfolio chỉ lấy mã từ vị thế mở hiện có; Tất cả hợp nhất và bỏ trùng theo canonical symbol, không cộng/chuyển tiền tệ để hiển thị quote. Đọc từ model hiện tại, không tính lại định giá Portfolio trong chart.
- Đổi nguồn giữ mã nếu mã thuộc nguồn mới; nếu không, chọn mã đầu tiên theo thứ tự nguồn. Nguồn rỗng: list có Empty state, chart không tiếp tục hiện mã ngoài nguồn. Xóa nguồn đang chọn quay về nguồn hợp lệ cùng loại hoặc Empty; không dùng tên làm ID.
- Không đủ lịch sử cho preset: disable và giải thích. NAV/close-only tự Line, selector Candles disabled có lý do; thiếu Volume không giả định bằng 0. Đổi symbol/interval hủy request cũ.
- Tắt Insider không được đồng thời xóa/ẩn drawings cá nhân; target, insider, indicators và drawings là các lớp độc lập.

### Quy tắc tương tác chart

- Khi người dùng pan/zoom khác preset, biểu thị khoảng xem Tùy chỉnh; không liên tục tự đổi D/W/M theo zoom.
- All: D nếu lịch sử ≤ 1 năm, W nếu ≤ 5 năm, M nếu dài hơn (quy tắc thiết kế A3). Tính indicator trên toàn lịch sử hợp lệ của interval trước khi cắt viewport; cùng ngày/interval không đổi giá trị vì đổi preset.
- Các mặc định đã chốt giữ nguyên: SMA 20/50, Volume, RSI 14, MACD 12/26/9; BB tắt [S1]. Pane giá/RSI/MACD ban đầu 70/15/15%; Volume chiếm phần đáy 18% của vùng giá (đề xuất bố cục A3, có thể resize).
- Nếu chart quá hẹp, thu tên công cụ thành icon+tooltip và gom thao tác phụ vào menu; không tự giấu giá trị quote quan trọng hay đổi nguồn. List phải có thể thu bằng nút trên trái và mở lại được.
- Không bật thêm legend OHLCV khi hover: giữ quyết định người dùng trước đó [S1]. Crosshair vẫn có nhãn trục chuẩn.
- Settings chỉ có chart type, Linear/Log và grid on/off trong R1; không làm màn tùy biến canvas/nhãn/gradient khổng lồ. Log từ chối dữ liệu ≤ 0 với giải thích.

### Quy tắc bộ công cụ vẽ F08–F10

| Công cụ | Tạo | Hiển thị / chỉnh |
|---|---|---|
| Select | Chế độ mặc định | Hit-test đối tượng, chọn 1 đối tượng; kéo thân để di chuyển, kéo handle để sửa. Click nền bỏ chọn; pan nền bình thường |
| Horizontal Line | Chọn tool, click một mức giá | Đường ngang kèm giá trên trục; kéo lên/xuống; không phải buy target hay lệnh |
| Trend Line | Click điểm đầu rồi click điểm cuối; cũng chấp nhận kéo thả | Đoạn thẳng giữa 2 mốc ngày/giá, không tự extend vô hạn; handle hai đầu |
| Rectangle | Kéo từ góc đầu đến góc đối diện | Fill mờ cố định, màu theo lựa chọn, 4 handle; không kèm dự đoán |
| Price Range | Kéo giữa 2 mốc | Box, Δ giá, Δ%, giá đầu/cuối và **N nến** trong interval hiện tại, bao gồm 2 nến neo; không gọi nến W/M là phiên. Δ% = (end-start)/start, giữ dấu theo hướng vẽ; start=0 thì `—`. Đổi interval giữ anchors/Δ, chỉ số nến theo view đổi |

- Hoàn thành một hình quay về Select; Esc hủy hình chưa xong. Gesture chart chỉ bị chặn trong lúc tạo hoặc kéo đối tượng, không tắt zoom/pan vĩnh viễn.
- Chỉ ghi history khi kết thúc gesture/nhấn Apply; không ghi mỗi pixel. Undo/Redo áp dụng tạo/sửa/xóa/style/lock/clear drawing; lịch sử trong phiên theo symbol, đổi nguồn cùng symbol không mất, khởi động lại giữ drawing nhưng không cần undo stack.
- Style tối thiểu: màu, nét thường/đậm; fill Rectangle/Range dùng độ mờ cố định. Không thêm font/text tool hoặc popup nâng cao.
- Snap chỉ bắt OHLC gần trỏ ở pane giá khi bật; không bắt indicator. Ngưỡng đề xuất 8 CSS px (A3); mặc định Off. Tài sản Line-only snap Close.
- Lock all chặn move/resize, vẫn cho chọn để mở khóa; Hide all không xóa. Xóa chọn bằng Delete/Backspace chỉ khi chart có focus và không nhập text. Cmd-Z trong editor vẫn sửa text như macOS.
- Mở cùng mã với W/M: anchor giữ ngày/giá gốc, map để vẽ vào candle chứa ngày đó, không rewrite anchor sang phiên gần nhất; phân biệt rõ view projection với dữ liệu gốc. Không kéo anchor ngoài lịch sử R1.

## 4. Bố cục R1A đề xuất và đường đi người dùng

```text
● ● ●  [Sidebar] [Bảng]                                      Superchart
┌────────────────────────────────────────────────┬────────────────────┐
│ AAPL  Apple Inc. · USD      [D ▾] [Indicators]  │ [Chọn nguồn ▾]     │
│ [Insider] [Undo] [Redo] [Settings]               │ Watchlist: Favorite│
├───┬────────────────────────────────────────────┤ [Tìm trong nguồn]  │
│ ↖ │ Nến + SMA/EMA/BB                           │ Symbol Last Chg% Ext%│
│ ─ │ Volume chồng chân nến                      │ ...                │
│ ╱ │                                            │                    │
│ □ ├────────────────────────────────────────────┤                    │
│ ↕ │ RSI                         [Phóng] [Ẩn]   │                    │
│   ├────────────────────────────────────────────┤                    │
│   │ MACD                        [Phóng] [Ẩn]   │                    │
│   ├────────────────────────────────────────────┤                    │
│ 🗑│ 1M 3M 6M YTD 1Y 3Y 5Y 7Y 10Y All  Auto Log│                    │
└───┴────────────────────────────────────────────┴────────────────────┘
```

- Chart/list sát nhau, chỉ có divider có thể kéo; không có panel thương hiệu xen giữa. Nút Bảng/Superchart ở góc trên trái luôn truy cập được khi sidebar thu gọn [S1].
- Trong Bảng: giữ navigation, bảng và màn chi tiết hiện tại; không tự bỏ cột 1M/3M hay đổi cách lưu sort.
- Dropdown nhóm Watchlist và Portfolio. Một nguồn được chọn tại một thời điểm; không bắt người dùng chọn loại rồi qua một dialog khác. Tìm mã chỉ lọc nguồn hiện tại, không query mạng.
- Thanh vẽ đứng chỉ liệt kê tool đã triển khai. Toolbar ngữ cảnh chỉ xuất hiện khi chọn đối tượng. Không hiển thị các icon Fibonacci/Replay/Trade giả.
- Attribution TradingView vẫn hiện theo yêu cầu license, kích thước gọn ở chân chart.

Story map [S1], entry alert từ chart là A1 và thuộc R1B:

| Hành trình | Mở không gian | Chọn phạm vi | Phân tích | Ghi nhận / theo dõi | Quay lại |
|---|---|---|---|---|---|
| Luồng hoàn chỉnh R1A | Toggle mode | Dropdown + list + tìm | D/W/M, indicator, panes | Drawing + Undo + lớp target/Insider hiện có | Bảng khôi phục trạng thái |
| Bổ sung R1B | Giữ workspace | Giữ nguồn | Snap/hide all/lock all | Mở native target/alert từ mức giá chart | Không sửa bảng |
| Sau R1, có điều kiện | Preset bố cục | Compare benchmark | Công cụ nâng cao | Executions cá nhân khi có dữ liệu | Export ảnh |

## 5. Kế hoạch kỹ thuật và interfaces

### Chia lớp

- SwiftUI giữ app chrome, mode, source picker, list quote và native dialogs; một `ChartSession` sở hữu activeSymbol, view state, config và lifecycle bridge.
- Lightweight Charts standalone local vẫn là renderer; interactions tần số cao và drawing previews ở JavaScript. Hover/drag không publish state lên parent/list.
- Swift background actor/service chuẩn bị history/indicators theo revision; cache theo symbol + dataset resolution + interval + indicator config. Viewport/visibility riêng không buộc tính lại series.
- `DrawingStore` actor lưu local trong Application Support; migrate có version từ keys `stockdeck.lightweightChart.priceRanges.v1.*`, giữ ID/anchors gốc, không xóa legacy trước khi file mới ghi thành công. Tài liệu R1 không thêm sync iCloud.

### Types / hợp đồng tối thiểu

- `ChartSource`: watchlist(UUID), portfolio(UUID), allPortfolios; tên là display metadata. Không thay đổi selectedWatchlistId của màn Bảng khi chỉ duyệt Superchart.
- `ChartSessionState`: layoutMode, source, activeSymbol, interval, rangePreset/customVisibleRange, paneRatios, selectedDrawingID. Selection ephemeral, không lưu như dữ liệu tài sản.
- `IndicatorConfig`: stableID, kind, parameters, color, visible; SMA/EMA có nhiều instances; RSI/MACD cùng loại chỉ một pane trong R1. Tham số dương, MACD fast < slow; invalid edit không Apply.
- `ChartDrawing`: schemaVersion, id, canonicalSymbol, kind, anchors(time,price), style, locked, updatedAt. Collection có revision; drawing count không ảnh hưởng quote cache.
- `ChartDataEnvelope`: sessionID, requestID, canonicalSymbol, dataRevision, resolution, bars, indicators, eventLayers. `ChartConfigEnvelope` độc lập với data; drawing mutation gửi expectedRevision và symbol.
- `ChartHistorySnapshot` phải mang resolution/coverage thực. Không tuyên bố nến daily dựa trên chuỗi coarse không biết frequency.
- R1B native alert interface: bổ sung optional `initialThreshold` vào `PriceAlertSheet(symbol:suggestedSymbols:editing:onDismiss:)`; context menu truyền mức giá tại điểm click, đúng currency/scale của symbol, không lưu trước xác nhận. Bell mở form không prefill mức chart; condition vẫn do người dùng chọn trong dialog hiện có. Nếu trùng editing, giá của alert đang sửa ưu tiên hơn initialThreshold.
- Bridge events: ready/error, drawingCommit, viewStateCommit, toolState. Commands: setData, setConfig, restoreView, setDrawings, dispose. Validate schema + finite prices + known date/symbol, từ chối request/revision cũ; web content local, không quyền network mới.

### Giữ trạng thái/lifecycle

- Chuyển mode có thể giữ cùng WebView nếu chart vẫn visible; không bắt buộc giữ WebView khi về Bảng mà không mở chi tiết. Khi bỏ renderer, snapshot view state trong memory; recreate restore state khi mở lại.
- Dispose thật: cancel task, invalidate request token, remove message handler/listener/observer, detach primitives, remove chart và giải phóng WebView. Đổi mode không được nhầm thành xóa drawings.
- Persist config/view state có debounce (đề xuất 300 ms, A3), không lưu mỗi pointermove; commit drawing xong gửi một mutation, flush khi đóng. Recovery dùng file ghi atomically; lỗi lưu hiển thị trạng thái Chưa lưu và Retry, không báo giả đã lưu.

## 6. Triển khai theo cổng nghiệm thu

Không gắn số tuần/ngày công khi chưa có estimate kỹ thuật. Các mốc là thứ tự phụ thuộc, **toàn bộ R1A chỉ được coi hoàn thành khi luồng cuối pass**; R1B không chặn bàn giao R1A.

| Mốc | Phần việc | Cổng hoàn thành |
|---|---|---|
| M0 — Duyệt | Duyệt phạm vi R1A, defaults, mockup, Won't list | Chủ sản phẩm duyệt phương án mới; hiện tại chỉ viết tài liệu/mockup |
| M1 — Nền tảng/session | Types, resolution, store migration, request guard, config/data diff | Unit cho migration/date/aggregation/stale response; renderer không nhận sai mã |
| M2 — Workspace | Mode toggle, source/list/search/keyboard, DWM/range, scaled layout | Đi hết chọn Watchlist/Portfolio → mã → về bảng; state giữ đúng |
| M3 — Phân tích | Volume overlay, panes, indicator manager, scales, lớp target/Insider hiện có | Data/indicator đối chiếu, pane toggles giữ viewport |
| M4 — Drawings | Primitives, 4 tools, hit-test/handles/style, history, selected-object lock | Tạo → sửa → undo/redo → đổi mã/interval → mở lại không mất dữ liệu |
| M5 — Dev handoff | Test toàn bộ + ./dev.sh + real-data manual QA + đo local | Chủ sản phẩm trải nghiệm; chỉ commit sau xác nhận; push/PR khi được yêu cầu |

R1B thực hiện sau buổi trải nghiệm R1A, nếu vẫn được duyệt: snap/lock all/hide all và entry target/alert từ chart; cùng các cổng dữ liệu/lifecycle. Không thêm vào mockup R1A để tránh lẫn phạm vi.

### Acceptance/test plan cụ thể

Gate chất lượng, oracle độc lập, phân loại lỗi và gói bằng chứng được cụ thể hóa tại [kế hoạch đảm bảo chất lượng](quality-superchart-essential.md). Bên triển khai chạy và báo cáo trước user trial; prototype pass không thay cho native app QA.

- Source/session: chọn nguồn trùng tên khác loại; portfolio hợp nhất trùng mã; source rỗng/bị xóa; filter không kết quả; đổi mã/nguồn liên tục khi request chưa xong. Kết quả cuối phải thuộc lựa chọn cuối, không ghi drawing vào mã khác.
- Price/session: Last/Chg chính xác từ quote regular; PRE/POST/CLOSED đúng Ext; 0% khác missing; Crypto không có Ext; NAV Nhật scale giữ quy tắc app. Không thay đổi portfolio totals/P&L/FX.
- History: daily/weekly/monthly, tuần qua năm, ngày theo US/JP/VN/Crypto; coarse cache không giả daily; duplicates không nhân Volume; indicator warmup trống, flat RSI=50, BB population deviation, EMA seed SMA [S1].
- Drawing: cả hướng trái/phải và lên/xuống; zero width/zero price; zoom/pan/price-scale drag; Resize/Retina; hit testing khi drawing tool tắt; editing handles; selected-object lock; delete+undo; clear cancel; snapshot trên W/M không đổi anchor gốc; N nến đếm theo interval bao gồm hai đầu, gaps/ngày nghỉ không cộng thành nến; save failure+Retry; migration legacy không mất hình. Hide/lock all/snap kiểm thử ở R1B.
- R1B alert: mức context-click thật sự xuất hiện trong initialThreshold; mở bell không tự lấy mức crosshair; Cancel không tạo alert; xác nhận mới vào engine native, đúng giá gốc/scale.
- UX: chuột và trackpad; Light/Dark; window resize/fullscreen; danh sách dài dùng lazy; tooltip/keyboard focus; Esc/Cmd-Z không nuốt text input; list arrow keys không xử lý khi đang nhập search/native dialog.
- Regression: cả Watchlist wide, symbol sheet và Portfolio holding detail dùng shared chart; bảng cũ không đổi cột/sort/scroll, return đúng nguồn và row.
- Integration WebKit: ready/error/Retry, dispose/reopen, source change với request cũ, event drawingCommit sai symbol/revision bị reject, renderer không tạo thêm chart instance sau mỗi toggle.
- Automated gate: toàn bộ `swift test` pass, JS/browser integration pass, `./dev.sh` thành công. Mockup interactions không thay thế các test này.
- Manual gate: complete task trên US stock, JP stock, VN stock, Crypto và NAV-only fund; dùng dữ liệu cache thật. Mỗi nhóm phải có kết quả và lỗi còn lại ghi lại; không dùng dữ liệu mô phỏng để tuyên bố pass [S1].
- Performance: tách network khỏi chart-ready; cold/warm cache; 10-year data + all indicators; p95 frame ≤33 ms, warm cache ≤1s [S1]. Đóng/mở 20 chu kỳ và ghi cả StockDeck+WebKit [S1]; không có live Chart/WebView/handler rò sau dispose; bộ nhớ ghi số thực, chưa đặt ngưỡng MB giả.

### Protocol benchmark có thể lặp lại

Protocol đề xuất A4, không phải benchmark đã thực hiện: ghi model máy, chip/RAM, macOS/WebKit, refresh rate và size cửa sổ; dùng cùng bộ lịch sử cache thật, cùng symbol/coverage và config ở trước/sau. Tách lần khởi tạo cold renderer khỏi warm cache.

- Warm ready: đo từ hành động chọn mã được UI nhận đến frame đầu hoàn chỉnh có đúng symbol, bars và indicators; không dùng didFinish của HTML làm điểm kết thúc. Đo 30 lần warm và 10 lần cold (sample design A4), báo median/p95/max/sample count và lỗi. Gate A4 cụ thể hóa target S1: mỗi mẫu warm phải ≤1s, tức max warm≤1s trên tập mẫu; cold báo riêng. Lần không render hoặc lỗi/timeout tính FAIL, giữ trong denominator, không đo lại thay mẫu để che lỗi.
- Interaction: pan 30 giây, zoom 30 giây, chỉnh drawing 30 giây (protocol A4); dùng Instruments/Core Animation hoặc tương đương để đo frame thực trong thao tác. Mỗi scenario phải có p95≤33ms riêng, không gộp pan/zoom/drawing để pass. Không dùng RAF idle để tuyên bố render p95. CPU/RAM báo cả app+WebKit.
- Dispose: 20 chu kỳ theo S1, đợi tác vụ/WebKit settle có ghi điều kiện đo; ghi profile retained Chart/WebView/handler và xu hướng memory từng chu kỳ. Không gọi memory cache tăng tạm thời là leak nếu chưa kiểm chứng retained references.
- Nếu dữ liệu thật không đủ coverage 10 năm cho asset mẫu, chọn asset khác đủ và ghi nguồn; không sinh nến để đủ bài đo. Nếu máy/refresh khác, báo kết quả riêng thay vì trộn percentile.

## 7. Sau R1: nên thêm gì, và vì sao chưa làm ngay

| Ưu tiên | Tính năng | Lý do / cách hoạt động | Điều kiện bắt đầu |
|---|---|---|---|
| Should — R2 | So sánh benchmark trên cùng % scale | Trả lời mã/position đang tốt hơn thị trường không; dùng nguồn benchmark đã có, chuẩn hóa từ cùng phiên chung | Kiểm chứng nhu cầu A1; dữ liệu phủ khoảng xem, không dựng lịch sử thiếu |
| Should — R2 | Đường giá vốn và executions cá nhân | Phân biệt mức giá đầu tư cá nhân với Insider; toggle riêng, theo nguồn Portfolio đang chọn | Chỉ dùng transaction/date/price thật và rules scale/fees sẵn có; không suy từ quote hoặc vị thế tổng |
| Should — R2 | Snapshot ảnh chart | Lưu phân tích vào tài liệu/ghi chú mà không thêm tính năng xã hội | Drawing/view persistence R1 ổn định; export không lộ dữ liệu riêng ngoài lựa chọn |
| Could — sau xác nhận | Fibonacci retracement, parallel channel | Hữu ích cho nhóm dùng phân tích sâu; thêm vào drawing engine hiện có | Người dùng chứng minh workflow cần; không chỉ để rail giống TradingView |
| Could — sau xác nhận | Preset chỉ báo có tên, object list | Giảm thao tác khi có nhiều cấu hình/hình | R1 đủ dữ liệu sử dụng để thấy menu/current selection thiếu |

**Won't have R1 — 2026-10-25:** intraday/ETH candles, nguồn giá mới, streaming mới, multi-chart grid, Pine Script/custom scripts, strategy backtest, Replay, order entry/broker, order book/DOM, AI signals, social feed, corporate actions tự dựng, chart events chưa có data, drawing trên RSI/MACD, cloud drawing sync, font/text/Fib/Gann/hàng chục tool chưa có workflow. Không thêm OHLCV hover legend đã được từ chối [S1].

## 8. Cách phát hành và giới hạn

- Risk: medium improvement vì shared chart và lưu drawing bị tác động; dữ liệu tài sản tài chính không migrate. Bảng là đường lui luôn có sẵn.
- Dev opt-in trước, default lần đầu là Bảng; lần sau nhớ mode. Chỉ công bố hoàn tất R1 sau M5 và chủ sản phẩm xác nhận.
- Abort ngay nếu có bất kỳ 1 trường hợp lưu drawing sai mã, mất hình khi migrate, sai regular/Ext hoặc regression P&L (ngưỡng zero tolerance đề xuất A4). Tắt entry Superchart của build Dev, trở lại Bảng; giữ file drawing và legacy keys nguyên, không rollback dữ liệu tài sản.
- Nếu target render/frame chưa đạt: giữ ở Dev, profile và sửa trước khi commit. Không giảm độ chính xác dữ liệu để đạt latency.
- Sau buổi nghiệm thu Dev đầu tiên: đi lại task checklist, ghi baseline/after đo được và cập nhật A1–A4; chưa có ngày public release nên không bịa mốc calendar.

## 9. Judge audit — 2026-10-25

Audit độc lập đã đọc PRD, assumptions, prioritization, metrics, launch và đối chiếu code chart/quote/PriceAlert. Không có blocker provenance hoặc luận điểm TradingView sai. Các phát hiện được giữ công khai:

1. **P2 — thiếu protocol đo tái lập:** đã bổ sung mốc start/end, thiết bị, cold/warm sample count và thao tác/frame thực; chưa có kết quả đo.
2. **P2 — số phiên Price Range trên W/M gây hiểu nhầm:** đã đổi thành N nến theo interval, giữ anchors gốc và thêm test gaps/ngày nghỉ.
3. **P2 — native alert chưa có initialThreshold:** đã ghi rõ interface cần thêm, precedence editing và Cancel/Save contract; thuộc R1B.
4. **Ưu tiên — tất cả cùng Must che mất thứ tự:** đã tách R1A core và R1B bổ sung, giữ phần mới cần duyệt. Mockup chỉ hiển thị R1A.

Recheck độc lập xác nhận ba findings gốc đã được xử lý, không có blocker mới; một dòng M4 còn nhắc hide/lock/snap đã được sửa để không kéo R1B ngược vào R1A.

Mọi phát hiện được xử lý trong **đặc tả**, không có nghĩa app code đã được sửa hoặc hiệu năng đã đạt. Rủi ro còn mở: A1/A2 cần user thử; effort/cross-market/performance thực đo chưa có.
