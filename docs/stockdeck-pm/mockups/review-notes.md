# Ghi chú duyệt mockup R1A

Ngày kiểm tra: 2026-10-25. Đây là prototype để duyệt luồng và bố cục, không phải màn app đã build.

## Phạm vi hiển thị

- Toggle Bảng/Superchart ở góc trái; chart sát danh sách, không có panel StockDeck xen giữa.
- Dropdown nguồn chia Watchlist/Portfolio, danh sách Symbol / Last / Chg% / Ext%, tìm trong nguồn.
- Dropdown D/W/M, menu Indicators/Hiển thị/Settings, preset dưới chart.
- Rail Select / Horizontal Line / Trend Line / Rectangle / Price Range / Delete; toolbar ngữ cảnh và Undo/Redo.
- Volume overlay, RSI/MACD phóng/khôi phục/đóng; không hover OHLCV legend.
- Không hiển thị snap/hide all/lock all/alert entry thuộc R1B.

## Dữ liệu và giới hạn

Chart dùng lịch sử AAPL thực từ bộ dữ liệu Yahoo đã dùng cho prototype trước, giai đoạn 2021–2025; mốc cuối được ghi là 2025-12-31. Không phải quote hiện tại. Các nguồn và mã khác minh họa cấu trúc, không đại diện holdings/watchlist đang lưu trong app; ô thiếu để dấu `—`. Không tuyên bố chuyển nguồn trong prototype đã nối StorageService. Preset 7Y/10Y bị vô hiệu hóa vì dữ liệu mẫu không phủ đủ.

Drawing và thao tác indicator của prototype minh họa tương tác. Việc lưu vào app, native dialogs, xử lý request cũ, migration và hiệu năng WebKit phải được triển khai/kiểm thử theo PRD. Prototype không dùng để xác nhận độ chính xác bộ tính Swift hay kiến trúc renderer thật.

## Kết quả kiểm tra prototype

Đã kiểm tra bằng trình duyệt Chrome chạy tự động:

1. Biên chart và list sát nhau, chỉ có divider.
2. Chuyển Bảng/Superchart.
3. Chọn interval W và nguồn Portfolio.
4. Thêm EMA trong menu Indicators.
5. Tạo Rectangle, Undo, Redo.
6. Phóng và khôi phục pane RSI.
7. Thu xuống chiều rộng 360 px: root không tràn ngang.
8. Không ghi nhận lỗi JavaScript trong các thao tác trên.

Ảnh mặc định đã được xem trực tiếp để kiểm tra bố cục. Các kết quả này chỉ áp dụng cho mockup. Chưa chạy lại `swift test` hoặc `./dev.sh` trong lượt làm kế hoạch; không có app code mới từ lượt này.
