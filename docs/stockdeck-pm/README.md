# StockDeck — hồ sơ đề xuất Superchart Essential

Cập nhật 2026-10-27. **Custom Scripts đã tích hợp vào Superchart; người dùng đã yêu cầu push và merge.** Cách dùng, phạm vi và giới hạn hiện tại: [Custom Scripts workflow](../custom-scripts-workflow.md). Hồ sơ Superchart Essential bên dưới ghi trạng thái tại 2026-10-25; không suy hồ sơ cũ thành kết quả acceptance hiện tại.

Kế hoạch gốc: [Nhập và kiểm chứng Custom Scripts](specs/implementation-custom-scripts.md). Báo cáo POC lịch sử: [bản sửa runtime](../custom-script-candidate-report.md) [S18], đối chiếu [baseline](../custom-script-poc-report.md) [S17]. Numeric reference và TradingView parity là hai verdict riêng. AGPL đã được người dùng chọn tạm; compliance và điều kiện phân phối vẫn là gate trước release. Yêu cầu push/merge không bao gồm release.

Kế hoạch hợp nhất đã được lập theo yêu cầu người dùng và rà độc lập. Điểm bắt đầu đọc: [kế hoạch triển khai từng mốc, đầu ra và gate](specs/implementation-superchart-essential.md). Chưa có lệnh bắt đầu sửa app từ yêu cầu lập plan.

- [PRD, lý do từng tính năng, hành vi, kế hoạch và tiêu chí nghiệm thu](specs/prd-superchart-essential.md)
- [Kế hoạch đảm bảo chất lượng và bằng chứng bàn giao](specs/quality-superchart-essential.md)
- [Mockup R1A](mockups/superchart-essential.png) và [ghi chú kiểm tra prototype](mockups/review-notes.md)
- [Thứ tự ưu tiên và kiểm tra độ nhạy](backlog/prioritization-2026-10-25.md)
- [Giả định cần kiểm chứng](backlog/assumptions.md)
- [Nguồn và giới hạn bằng chứng](discovery/sources.md)
- [Mục tiêu đo lường — chưa có baseline](strategy/metrics.md)
- [Kế hoạch thử Dev và rollback](launches/launch-superchart-essential.md)
- [Quyết định và phương án đã cân nhắc](decisions.md)

Khuyến nghị duyệt **R1A**: hai layout, nguồn Watchlist/Portfolio, danh sách gọn, D/W/M và khoảng xem, indicator/pane/scale, bốn công cụ vẽ cùng sửa/Undo/Redo/lưu an toàn. **R1B**: snap/hide all/lock all và mở target/alert từ chart, xét sau vòng trải nghiệm R1A. Mockup chỉ hiển thị R1A.

Các đề xuất mới chưa được coi là yêu cầu đã phê duyệt. Không lấy bản mockup làm bằng chứng tính năng app hoặc mục tiêu hiệu năng đã đạt.
