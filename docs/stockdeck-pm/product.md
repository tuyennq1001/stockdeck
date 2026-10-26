# StockDeck

## Định hướng
Ứng dụng macOS quản lý Watchlist/Portfolio đa thị trường. Superchart là không gian phân tích liên kết cùng nguồn dữ liệu của app, có đường trở về Bảng đầy đủ [S1][S2].

## Người dùng và bằng chứng
Người dùng hiện tại yêu cầu nến, indicators, đo/vẽ vùng giá, bố cục tiết kiệm diện tích và chuyển nguồn Watchlist/Portfolio [S1]. Chưa khảo sát một tập người dùng rộng hơn; định hướng đầu tư theo D/W/M là A1, không phải persona đã kiểm chứng.

## Ràng buộc
Lightweight Charts standalone đóng gói local, dữ liệu/cache StockService; SwiftUI + WKWebView. Không nguồn giá mới hoặc nến giả. Quy tắc regular-session valuation, native currency, quỹ Nhật và performance trong AGENTS.md giữ nguyên [S1][S2]. Phạm vi Superchart mới chờ duyệt, app code hiện có chưa commit.

## Tài liệu dẫn đường
- specs/prd-superchart-essential.md: phạm vi, tại sao, cách hoạt động, kỹ thuật và nghiệm thu.
- backlog/prioritization-2026-10-25.md: thứ tự và độ nhạy.
- discovery/sources.md: nguồn tham chiếu.
