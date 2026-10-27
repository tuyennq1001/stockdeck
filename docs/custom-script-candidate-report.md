# Custom Scripts — kết quả bản sửa runtime, 2026-10-26

**Hai script đã khớp phép tính tham chiếu độc lập; ba Risk hoàn thành 10/10 lượt trong giới hạn 5 giây.** Đây là bản chạy thử riêng, chưa thêm chức năng nhập script vào StockDeck. M1 còn các phần về quyền chạy, license và kiểm chứng TradingView; chưa chuyển sang UI R1/R2.

Nguồn số đo: [evidence mới](custom-script-candidate-evidence.json) [S18]. [Kết quả bản gốc](custom-script-poc-report.md) và [evidence S17](custom-script-poc-evidence.json) được giữ nguyên để đối chiếu. Người dùng duyệt thử bằng “ok thử đi”, sau đó yêu cầu “tiếp đi”; chưa có xác nhận trải nghiệm hoặc phép commit/push/release.

## Những gì đã sửa

Thay đổi ở runtime dùng chung dựa trên PineTS 0.13.0, không đổi source Pine của DCA Phoenix hoặc Risk Metric:

- EMA khởi tạo từ giá trị source đầu tiên theo công thức tham chiếu; giữ state riêng từng lời gọi và khi tính lại nến hiện tại. MACD dùng EMA chung cũng có test hồi quy.
- Giảm cấp phát khi đọc tham số/thuộc tính plot; giữ cách ưu tiên tham số đặt tên bằng phép thử so sánh parser cũ/mới.
- Tìm nến khung lớn bằng tìm kiếm nhị phân trên các khoảng thời gian có thứ tự, không chồng nhau. Adapter production phải kiểm tra điều kiện dữ liệu này.
- Tính rolling standard deviation bằng cập nhật cửa sổ, định kỳ tính lại để kiểm soát sai số; thử cả dữ liệu thiếu, đổi period, biased/unbiased và giá không đổi.
- Khi nến chạy được tính lại, thay phần đuôi plot thay vì cộng điểm trùng timestamp. Giữ lịch sử cảnh báo đã phát và cơ chế tránh phát lặp theo nến; cảnh báo không phải snapshot có thể xóa theo plot. Giữ cả tên plot do người dùng đặt bắt đầu bằng `__`.

Recipe kiểm tra cấu trúc bundle/version trước khi patch, sinh bundle riêng và manifest hash dưới thư mục local bị bỏ qua bởi Git. Không sửa package đã cài, không đưa vendor bundle hay source người dùng vào app/repository. Đây là bản sửa thử nghiệm có thể tái tạo; chưa tuyên bố tương thích toàn bộ Pine.

## Độ đúng

Cùng bộ 5.540 nến ngày BTC/USD Bitstamp, lịch tuần Monday UTC, thời điểm bắt đầu, source hash và tolerance abs `1e-8` + rel `1e-6` như S17. Không bỏ warmup hoặc đổi input để làm đạt. DCA đọc nguyên bytes attachment; Risk dùng bản source đã chép từ trang TradingView và chuẩn hóa NBSP/LF từ S17, chưa có byte-original export.

| Kiểm tra | Bản gốc S17 | Bản sửa S18 |
|---|---|---|
| DCA EMA200 | 199 sai vị trí `na`, 722 điểm vượt tolerance | PASS toàn bộ 5.540 điểm, không sai time/na; max abs error `5,82e-11` USD |
| DCA điểm mua/bán | 10 vị trí buy và 1 vị trí sell khác reference | 86 buy / 17 sell, mọi vị trí và màu nến khớp reference |
| DCA alertcondition | 98 sự kiện, reference 103 | 103/103 sự kiện |
| Risk numeric | PASS dataset D/W | Vẫn PASS: 4.081 điểm có số, 1.459 điểm warmup đúng vị trí; max abs error `2,84e-14` |
| JavaScriptCore native | Chạy được | Numeric khớp reference và Node trong tolerance; DCA signals/alerts giống Node |
| TradingView cùng input | BLOCKED | Vẫn BLOCKED: chưa có export input/output cùng feed/session/history |

Nhánh `alert()` trong source DCA gốc vẫn tạo 0 sự kiện vì so sánh với biến khởi tạo `na`; không sửa ngầm source. Số 103 ở trên là `alertcondition` được capture để kiểm thử, không phải thông báo macOS đã gửi.

Các test sống dùng fixture số học ghi rõ test-only: tính lại cùng nến ba lần và thêm một nến mới, đối chiếu EMA/stdev/var/plot với replay đầy đủ; kiểm tra cảnh báo không mất/không nhân đôi. Chưa kiểm chứng live secondary contexts MTF, mọi frequency cảnh báo hoặc mọi hàm Pine.

## Hiệu năng

Cùng máy Apple M1 Pro arm64/macOS 27.0/Swift 6.4/Node 24.13.1 và helper JavaScriptCore. Mỗi dòng gồm 10 process mới, sau đó 30 lượt cache trong helper riêng; 1 hoặc 3 instance chạy tuần tự trong cùng helper. Cold gồm khởi động process, compile/chạy, chuẩn hóa/encode. Giữ nguyên watchdog cold 5 giây; không giảm số nến hoặc loại mẫu lỗi.

| Script / dữ liệu | Instance | Cold median / max | Cache + encode median / max | Peak RSS ghi nhận |
|---|---:|---:|---:|---:|
| DCA / 5.000 H | 1 | 0,405 / 0,421 giây | 4 / 6 ms | 58,8 MiB |
| DCA / 5.000 H | 3 | 1,118 / 1,143 giây | 12 / 16 ms | 70,4 MiB |
| DCA / 10.000 H | 1 | 0,771 / 1,102 giây | 7 / 10 ms | 74,8 MiB |
| DCA / 10.000 H | 3 | 2,189 / 2,244 giây | 23 / 25 ms | 100,2 MiB |
| Risk / 5.000 D | 1 | 1,477 / 1,585 giây | 23 / 25 ms | 80,6 MiB |
| Risk / 5.000 D | 3 | 4,455 / 4,603 giây | 72 / 87 ms | 163,4 MiB |

Tất cả 60/60 cold jobs hoàn tất, 0 timeout; đủ 30/30 cached calls mỗi scenario. Ba Risk trước đây timeout 10/10; nay đạt riêng phần cold budget trên máy/dataset này. Mức chậm nhất 4,603 giây còn ít khoảng trống tới 5 giây; chưa suy thành bảo đảm mọi máy, mọi source hay chế độ tiết kiệm pin.

Peak RSS là bộ nhớ helper được đo, không phải hard cap 256 MiB hoặc tổng RAM StockDeck. CPU median ba Risk khoảng 6,49 CPU-giây/process, có thể lớn hơn wall time do nhiều luồng trong JavaScriptCore. Không suy số này thành tải CPU liên tục khi app để yên.

Cache là cùng source/input/context/dữ liệu không đổi; chưa đo chi phí nến mới trong app, IPC, vẽ pane/fill, frame p95 hoặc chart-ready. Có thể kết luận tải chạy thử đã giảm và hoàn tất budget đã thử; chưa thể kết luận Superchart mượt hoặc không ảnh hưởng hiệu năng.

## Kiểm tra và phần còn thiếu

- 18/18 test công cụ PASS: semantics bản sửa, parser/HTF differential, live tail, tên output, watchdog và baseline guards. Test baseline cố ý phát hiện lỗi EMA gốc vẫn được giữ, không coi bản gốc đã sửa.
- `swift test`: 616/616 PASS; `./dev.sh`: build/sign/launch Dev thành công. Không thêm dependency hoặc thay source app trong đợt POC.
- Watchdog và realm không có file/network exports đã được thử; chưa có OS sandbox, hard memory cap, preflight source bất kỳ hoặc contract IPC production. Hai trusted examples không đủ để bật nhập source tùy ý.
- PineTS package khai báo AGPL-3.0-only; commercial route chưa mua/chọn. Không tự quyết nghĩa vụ phân phối mới cho StockDeck.
- Renderer/editor/persistence/native notification và QA UX/FPS: NOT RUN vì chưa tích hợp app. G-TV-PARITY vẫn BLOCKED; phép tính tham chiếu độc lập không thay cho output TradingView thật.

Bước tiếp theo trong M1 là hoàn thiện runner có giới hạn/quyền thực tế và kiểm tra source, xác định license route, bổ sung oracle TradingView cùng input; sau đó mới đưa adapter/editor vào Superchart. Hiện người dùng chưa thể dán custom script trong app. Công cụ tái lập: [README](../tools/custom-script-poc/README.md).
