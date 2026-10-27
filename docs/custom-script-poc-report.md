# Custom Scripts POC — kết quả 2026-10-26

**Snapshot bản gốc S17.** Bản sửa runtime tiếp theo có [báo cáo S18 riêng](custom-script-candidate-report.md); các số đo và lỗi dưới đây được giữ làm baseline, không phải trạng thái mới nhất.

**Kết luận: đã thử được source trong helper macOS, nhưng chưa đủ điều kiện tích hợp UI Custom Scripts.** PineTS 0.13.0 sai khác reference EMA của DCA; ba instance Risk vượt budget chạy lần đầu. Dừng tại gate M1 của [plan](stockdeck-pm/specs/implementation-custom-scripts.md), giữ app hiện tại chưa tích hợp runtime.

Mọi số liệu thực nghiệm dưới đây lấy từ [evidence JSON](custom-script-poc-evidence.json) [S17 trong hồ sơ PM]. Đây là POC, không phải thông báo phát hành hoặc chứng nhận tương thích Pine. Người dùng đã duyệt thử POC bằng lời nhắn “ok thử đi”; chưa có phê duyệt commit/push/release.

## Môi trường và phương pháp

- Apple M1 Pro / arm64, macOS 27.0, Swift 6.4, Node 24.13.1. Native host là helper Swift dùng JavaScriptCore; Node chỉ tải dữ liệu, chuẩn bị và giám sát thử nghiệm. Không bắt người dùng cuối cài Node.
- `pinets@0.13.0`, npm lockfile/integrity và SHA-256 bundle/helper/harness được lưu trong evidence. Dependency nằm trong công cụ POC riêng, không có trong Package.swift/resources hoặc app bundle. License package là AGPL-3.0-only; chưa chọn/mua commercial license và chưa thay license StockDeck.
- Dữ liệu thật từ public OHLC Bitstamp BTC/USD: 5.540 nến D và 10.000 nến H. Dataset/URLs/thời điểm tải/timezone/coverage/SHA-256 được cố định trong manifest local và evidence. DCA benchmark dùng H 5.000/10.000 bars; Risk benchmark dùng D 5.000 bars với W gom theo Monday UTC. Không dựng lịch sử BTC 10.000 ngày để hoàn thành matrix.
- DCA: đọc nguyên bytes attachment, SHA-256 `af9ef05e6c47f1a7ba3c32b5f34b75e89a32657bfafd701eb2b0a6b9debd7ae4`. Risk: đọc source công khai từ giao diện TradingView, chép lại và chuẩn hóa NBSP/LF; logic không đổi, hash bản thử được ghi riêng. Chưa có byte-original export/reference numeric từ tài khoản TradingView.
- Reference tính toán độc lập không dùng lại PineTS hoặc hàm tính toán StockDeck. EMA dùng cách seed từ source đầu tiên trong [ví dụ `pine_ema` chính thức](https://www.tradingview.com/pine-script-reference/v6/#fun_ta.ema). Risk có phép gom tuần và rolling mean/stdev độc lập với provider thử nghiệm.
- Tolerance giữ nguyên plan A6: abs `1e-8` + rel `1e-6`; vị trí dữ liệu thiếu/time/boolean phải đúng. Không thay tolerance để che sai khác.

## Tương thích: kết quả thực tế

| Kiểm tra | Kết quả | Bằng chứng/giới hạn |
|---|---|---|
| Compile và chạy hai source | PASS trong POC | Node và JavaScriptCore đều thực thi được; chưa bao gồm renderer StockDeck |
| DCA EMA200 | **FAIL reference** | Trên 5.540 bars: 199 bars đầu runtime trả `na`, 722 bars có số nhưng vượt tolerance; max abs error khoảng 0,72517 USD |
| DCA marker/màu | **FAIL reference** | Reference có 86 buy / 17 sell; runtime có 80 buy / 18 sell. Khác 10 vị trí buy + 1 vị trí sell; 11 màu nến khác. Đây không phải kết quả TradingView export |
| DCA nhánh `alert()` gốc | Hành vi đã tái hiện | Không có imperative alert vì biến alert khởi tạo `na` và điều kiện `!=` không mở được nhánh; `alertcondition` runtime có 98 sự kiện, reference có 103 do sai khác tín hiệu. Chỉ capture sự kiện test, không gửi thông báo |
| Risk Metric numeric | PASS reference trên dataset này | 4.081 điểm có số và 1.459 điểm warmup cùng vị trí; max abs error khoảng `2,84e-14`; không có numeric/time/na mismatch. Chưa chứng minh mọi khung/timezone/live update |
| Native JavaScriptCore so với Node | PASS tolerance | DCA numeric giống trong tolerance, signals/alerts giống; Risk sai số numeric khoảng `2,42e-14`, nằm trong tolerance |
| Khớp TradingView | **BLOCKED** | Chưa có input/output numeric TradingView cùng feed/session/history khởi tạo. Tài liệu công thức + reference độc lập không thay thế gate G-TV-PARITY |
| Renderer/pane/fill/marker native | NOT RUN | Không tích hợp vào chart khi gate semantics còn fail; chưa chứng minh hình khớp dù runtime tạo được output |

Nguyên nhân DCA đã xác định từ source map package 0.13.0: `ta.ema` gom đủ period rồi seed bằng SMA; ví dụ công thức TradingView seed từ source đầu tiên. Một số sai khác tín hiệu lan tới sau warmup vì script lưu state theo crossover. Không được xóa 199 bars đầu khỏi denominator hoặc đổi source DCA để gọi engine tương thích. POC không patch vendor và không sửa source người dùng.

## Hiệu năng đo được

Mỗi scenario có 10 process mới (cold), sau đó một helper riêng đo 30 lượt lấy lại cache và chuẩn hóa/encode output. Các instance chạy tuần tự trong cùng một helper; không chia thành các helper song song. CPU là thời gian CPU của process, không phải phần trăm CPU kéo dài. RAM là peak RSS của helper, không phải toàn bộ StockDeck/OS hay mức tăng chính xác của app tương lai.

| Script / dữ liệu | Instance | Cold median / max | Cache + encode median / max | Peak RSS ghi nhận |
|---|---:|---:|---:|---:|
| DCA / 5.000 H | 1 | 0,465 / 0,476 giây | 4 / 5 ms | 59,8 MiB |
| DCA / 5.000 H | 3 | 1,297 / 1,393 giây | 12 / 16 ms | 70,5 MiB |
| DCA / 10.000 H | 1 | 0,874 / 0,930 giây | 9 / 12 ms | 74,8 MiB |
| DCA / 10.000 H | 3 | 2,523 / 2,632 giây | 25 / 33 ms | 99,1 MiB |
| Risk / 5.000 D | 1 | 2,210 / 2,265 giây | 27 / 47 ms | 77,6 MiB |
| Risk / 5.000 D | 3 | **10/10 timeout tại ngưỡng 5 giây** | 76 / 84 ms | 166,4 MiB, từ warm-series riêng |

- Các scenario còn lại đều hoàn thành 10/10 cold jobs; không loại mẫu fail. Với ba Risk, cả 10 cold jobs bị kill, CPU/RSS của các process bị kill không có số đo từ time wrapper, không được thay bằng 0. Warm-series có guard tổng riêng và cho thấy replay mất 6,54 giây; lượt này phục vụ phân tích, **không làm PASS lại gate job 5 giây**.
- CPU median của các cold job hoàn tất: DCA 5.000 bars 1/3 instance khoảng 0,49/1,44 CPU-giây; DCA 10.000 bars khoảng 0,94/2,96; Risk 5.000 bars 1 instance khoảng 2,66 CPU-giây. Không suy thành tải CPU liên tục khi app để yên.
- Cache chỉ áp dụng cùng source/inputs/data/context. Các số cache trên **không** đo thêm nến mới, đổi mã/khung, IPC qua Swift, vẽ chart hoặc frame p95. Chưa thể tuyên bố đạt chart-ready ≤1 giây hay frame p95≤33 ms trong app.
- Bản đo sơ bộ dùng để sửa harness khởi tạo cache và tách cold/warm đã được giữ ở local, không dùng làm số nghiệm thu. Bảng này là matrix cuối với protocol/hash đã ghi trong evidence.

**Hàm ý:** DCA nhẹ hơn trường hợp Risk trong matrix đã đo; lần chạy đầu nhiều script vẫn cần trạng thái đang tính và hủy được. Không dùng một ngưỡng “3 script” để bảo đảm mọi source đều nhẹ. Cần ngân sách theo công việc thực và cache/MTF execution tốt hơn trước R1/R2. Chưa thay ngưỡng 5 giây hoặc tự đổi scope để pass.

## Cô lập và các kiểm tra khác

- Watchdog ngoài process đã kill được fixture cố ý lặp vô hạn; job tiếp theo vẫn chạy. Realm JavaScript thử nghiệm không có `fetch`, `XMLHttpRequest`, `WebSocket`, `process`, `require`, `webkit`, `readFile`, `load`.
- Đây **chưa phải** OS sandbox, hard memory cap, preflight AST/manifest hoàn chỉnh hoặc chứng minh chống source bất kỳ. G-ISOLATION chỉ có bằng chứng cho killability/host exports, chưa PASS đầy đủ.
- Bộ test harness: 9/9 PASS; có fixture kiểm tra công cụ phát hiện đúng sai khác EMA đã biết. Số này không được dùng để nói PineTS tương thích DCA.
- Baseline app `swift test`: 616/616 PASS; `./dev.sh`: build/sign/launch Dev thành công. Chỉ công cụ POC/docs thay đổi; chưa thêm runtime vào app.
- Live rollback, streaming replay/chunking, update bar, 20 vòng lifecycle chart, native alerts, persistence/migration và performance UI: NOT RUN. Không có regression claim mới cho các phần chưa tích hợp.

## Việc tiếp theo cụ thể

1. Xem xét sửa/đổi runtime ở cấp engine cho seed EMA và kiểm chứng lại toàn bộ source gốc; không chuyển tay từng indicator hoặc thay input để né lỗi.
2. Profile đường `request.security`/secondary contexts và việc encode nhiều output; giữ cache compile/data dùng chung phù hợp. Chạy lại matrix sau thay đổi, giữ cả timeout trong báo cáo.
3. Chốt license route, sandbox/resource controls và nguồn oracle TradingView trước khi bật luồng người dùng nhập source bất kỳ.
4. Chỉ khi gate M1 đạt mới tiếp tục adapter/editor R1. Hiện **chưa có chức năng nhập custom script trong StockDeck**; app chưa bị thêm tải runtime này.

Công cụ tái lập và giới hạn: [tools/custom-script-poc/README.md](../tools/custom-script-poc/README.md). Không có commit/push/PR/release trong lượt thử này.
