# Kiểm chứng và bằng chứng

Lệnh chính: `./harness.sh verify <task-id>`. Chạy tuần tự, dừng tại bước lỗi đầu tiên:

1. `python3 -m unittest discover -s scripts/tests`: kiểm tra contract, receipt, thất bại, timeout, khóa, phục hồi và bằng chứng cũ.
2. `swift test`: toàn bộ bộ test ứng dụng.
3. `env SD_BUILD_ONLY=1 ./dev.sh`: build, đóng gói và ký bản dev theo quy trình chính thức; thoát trước khi đóng/mở app.

Suite import giao dịch cần các CSV thật trong `template/transaction/`. Thư mục này bị Git ignore nên worktree/clone mới không tự có. Trước verify, liên kết `template` tới bản cục bộ đã có của người dùng hoặc khôi phục từ nguồn được phép. Không tạo dữ liệu giả, không bỏ test và không đưa CSV riêng tư lên Git. Harness fingerprint CSV để phát hiện đầu vào thay đổi. Một test có thể đọc file backup cũ trong Application Support nếu file tồn tại; đầu vào ngoài dự án đó không thuộc fingerprint, cần ghi nhận khi so sánh kết quả giữa các máy.

Mỗi bước tối đa 900 giây mặc định; khi biết build sạch cần lâu hơn, dùng `--timeout 1800`. Timeout/hủy bằng Ctrl-C sẽ dừng nhóm tiến trình đang chạy và giữ receipt. Không chạy thêm test/build đồng thời bên ngoài harness trong cùng checkout. Verifier không có khả năng phát hiện mọi tiến trình ngoài harness.

Mã thoát verify: `0` = test/build pass và đủ điều kiện trình người dùng review; `1` = có bước lỗi hoặc source/contract đổi trong khi chạy; `2` = đầu vào/điều kiện không hợp lệ; `3` = test/build đạt nhưng còn thiếu bằng chứng UI; `130` = bị ngắt bằng Ctrl-C. Mã 3 không yêu cầu chạy lại test/build nếu code/build/contract chưa đổi. Thiếu executable cũng là lỗi, không được ghi thành pass. Receipt không có kết quả cho bước chưa chạy.

## Chọn kiểm tra hồi quy theo thay đổi

| Phạm vi | Điểm bắt đầu trong Tests |
| --- | --- |
| Giá phiên chính/ngoài giờ, thay đổi quote | StockQuoteTests, ApplyTickTests, MarketStateTests, ExtendedHoursSortTests |
| P&L và tiền tệ | DailyPnlTests, TodayPerformanceTests, MonthlyPnlTests, PortfolioPnlPersistenceTests, SecondaryCurrencyTests |
| Quỹ Nhật, giá vốn, short/leverage | JapaneseFundTests, HoldingCostBasisTests, HoldingLotAggregationTests, ShortLeverageTests |
| Hiệu suất/lịch sử | PortfolioPeriodChangeTests, PortfolioBackfillTests, PortfolioBackfillCacheTests, XIRRTests |
| Biểu đồ | ChartWebPersistenceTests, LightweightChartMathTests, LightweightChartTimeControlsTests, LightweightChartViewSelectionTests |
| Navigation/UI, persistence | WatchlistNavigationCacheTests, WatchlistScrollPositionTests, MainMenuEditCommandsTests, PersistenceWriterTests |

Có thể chạy test tập trung trong quá trình sửa. Trước khi bàn giao vẫn chạy verify đầy đủ; không thay toàn bộ suite bằng test lọc để tuyên bố hoàn thành. Nếu baseline có lỗi, ghi đúng test, output, ảnh hưởng và đối chiếu với baseline khi cần; không sửa lỗi ngoài phạm vi hoặc loại test để có kết quả xanh.

## Kiểm tra thực tế

Với task UI, làm theo [quy trình UI bắt buộc](ui-verification.md): nhập kế hoạch trước verify, mở bundle DEV đã build, gắn PID bằng `ui-begin`, thao tác và ghi ảnh từng bước bằng `ui-record`. Dùng `check` để xác định đã đủ điều kiện bàn giao hay chưa. Không suy UI đạt từ test/build pass.

Không dùng `./dev.sh` mở lại ngay sau verify cho phiên UI: script sẽ build/ký lại và có thể đổi hash bundle; ngoài ra chế độ thường có thể đóng instance StockDeck đang chạy. Mở bundle đã có bằng công cụ điều khiển app. Chế độ build-only không chạm vòng đời instance đang chạy.

Với thay đổi UI/nghiệp vụ, ghi kịch bản tái hiện, giá trị mong đợi, nguồn dữ liệu thật, kết quả quan sát và đường dẫn ảnh/log nếu có. Kiểm tra các view tương đồng, sáng/tối, loading/empty/error/loaded và biên dữ liệu phù hợp. Không đánh dấu hạng mục chưa quan sát là pass; dùng `pending` hoặc ghi rõ không áp dụng cùng lý do.

Kết quả test/build, bằng chứng UI và xác nhận trải nghiệm là ba cổng riêng. `awaiting_user_review` không cấp quyền commit. Ghi lại xác nhận thật trong task bằng `note` rồi mới làm bước Git được người dùng cho phép. Receipt luôn giữ `human_review: pending` vì CLI không xác minh danh tính hay nội dung xác nhận trong chat.

## Tiếp tục khi gián đoạn

1. Chạy `status`, đọc log/receipt và xem checkout thực tế.
2. Nếu receipt vẫn `running` nhưng verifier đã dừng, kiểm tra không còn tiến trình test/build cũ; chạy `recover`.
3. Ghi nguyên nhân và việc còn lại; sửa đúng phạm vi đã duyệt.
4. Chạy verify mới nếu còn lượt. Dừng báo người dùng nếu hết 3 lượt hoặc vướng ngoài phạm vi.

Receipt không chứa giá API, chi phí AI hay thống kê test được suy đoán. Số lượng test và chi tiết lỗi lấy từ log thực tế. Việc nâng model không làm thay đổi điều kiện pass hoặc giới hạn quyền.
