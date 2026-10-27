# Bản đồ dự án cho agent

Ưu tiên source hiện tại và test tương ứng. Tài liệu thiết kế nêu ý định; không tự coi đó là bằng chứng tính năng đã hoàn tất.

| Cần biết | Đọc ở đâu |
| --- | --- |
| Quy tắc bắt buộc, phê duyệt và nghiệp vụ | [AGENTS.md](../../AGENTS.md) |
| Tổng quan sản phẩm và cách cài | [README.md](../../README.md) |
| Build, package và phiên bản | [Package.swift](../../Package.swift), [dev.sh](../../dev.sh), [Info.plist](../../StockDeck/Info.plist) |
| Điểm vào ứng dụng, cửa sổ, menu bar | [AppDelegate.swift](../../StockDeck/AppDelegate.swift) |
| Quote, giá phiên chính, giá ngoài giờ | [StockQuote.swift](../../StockDeck/Models/StockQuote.swift), [StockService.swift](../../StockDeck/Services/StockService.swift), [WebSocketService.swift](../../StockDeck/Services/WebSocketService.swift) |
| Portfolio, persistence và cache | [PortfolioViewModel.swift](../../StockDeck/Models/PortfolioViewModel.swift), [StorageService.swift](../../StockDeck/Services/StorageService.swift), [PortfolioMonitor.swift](../../StockDeck/Services/PortfolioMonitor.swift) |
| Thống kê và lịch sử | [DailyPnl.swift](../../StockDeck/Models/DailyPnl.swift), [MonthlyPnl.swift](../../StockDeck/Models/MonthlyPnl.swift), [PortfolioBackfill.swift](../../StockDeck/Models/PortfolioBackfill.swift), [XIRR.swift](../../StockDeck/Models/XIRR.swift) |
| Giao diện cần rà soát đồng bộ | [Views](../../StockDeck/Views): WatchlistView/WatchlistWideView, PortfolioOverview/PortfolioWindowView, HomeView/HomeWideView, SymbolDetailSheet/HoldingDetailView |
| Biểu đồ | [LightweightChartTrial.swift](../../StockDeck/Services/LightweightChartTrial.swift), [SuperchartWorkspaceView.swift](../../StockDeck/Views/SuperchartWorkspaceView.swift), [báo cáo chart](../lightweight-chart-trial-report.md) |
| Product decisions, yêu cầu và backlog | [workspace sản phẩm](../stockdeck-pm/README.md), [decisions](../stockdeck-pm/decisions.md), [state](../stockdeck-pm/state.md) |
| Hiệu năng | [báo cáo hiệu năng](../performance-optimization-2026-08-02.md), [PerformanceSignposts.swift](../../StockDeck/Services/PerformanceSignposts.swift) |
| Phát hành khi được yêu cầu | [release-workflow.md](../release-workflow.md) |
| Kiểm chứng và lưu bằng chứng | [testing.md](testing.md), [scripts/harness.py](../../scripts/harness.py), [Tests](../../Tests) |

Khi điều tra, dùng tìm kiếm tên model/hàm trong source và Tests để xác định chỗ sở hữu logic. Rà soát các biến thể menu bar/desktop, bảng/card, sáng/tối, ngôn ngữ, thị trường và bốn trạng thái dữ liệu phù hợp với thay đổi. Không tải toàn bộ tài liệu vào context cho mọi task.
