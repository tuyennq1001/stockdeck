# StockDeck

## Định hướng
Ứng dụng macOS quản lý Watchlist/Portfolio đa thị trường. Superchart là không gian phân tích liên kết cùng nguồn dữ liệu của app, có đường trở về Bảng đầy đủ [S1][S2].

## Người dùng và bằng chứng
Người dùng hiện tại yêu cầu nến, indicators, đo/vẽ vùng giá, bố cục tiết kiệm diện tích và chuyển nguồn Watchlist/Portfolio [S1]. Chưa khảo sát một tập người dùng rộng hơn; định hướng đầu tư theo D/W/M là A1, không phải persona đã kiểm chứng.

## Ràng buộc
Lightweight Charts standalone đóng gói local, dữ liệu/cache StockService; SwiftUI + WKWebView. Không nguồn giá mới hoặc nến giả. Quy tắc regular-session valuation, native currency, quỹ Nhật và performance trong AGENTS.md giữ nguyên [S1][S2]. Checkpoint 2026-10-26: source tại `665b1ff` đã có Superchart và intraday loader [S11]; hồ sơ 2026-10-25 là snapshot đề xuất, không chứng minh acceptance/runtime hiện tại.

Custom Scripts: người dùng muốn tự nhập source Pine [S9/FB5]. Đã tích hợp thư viện, menu bật/tắt, nhiều script/pane độc lập và Style; dùng PineTS 0.13.0 theo lựa chọn AGPL tạm của người dùng. Workflow hiện tại và các giới hạn được ghi tại [Custom Scripts workflow](../custom-scripts-workflow.md). POC [S17/S18] là bằng chứng trên dataset/máy thử, không xác nhận tương đương đầy đủ với TradingView. Compliance và điều kiện phân phối vẫn cần hoàn tất trước release.

## Tài liệu dẫn đường
- specs/prd-superchart-essential.md: phạm vi, tại sao, cách hoạt động, kỹ thuật và nghiệm thu.
- backlog/prioritization-2026-10-25.md: thứ tự và độ nhạy.
- discovery/sources.md: nguồn tham chiếu.
- ../custom-scripts-workflow.md: hành vi hiện tại; specs/implementation-custom-scripts.md: kế hoạch gốc và các gate chưa được coi mặc định là PASS.
