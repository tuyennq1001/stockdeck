# Launch: Superchart Essential

Class: medium · Status: proposed · Owner go/no-go: chủ sản phẩm StockDeck.
PRD: ../specs/prd-superchart-essential.md. Lần duyệt này đề nghị R1A; R1B có gate riêng sau trải nghiệm R1A, không chặn core.

Đi theo [kế hoạch triển khai hợp nhất](../specs/implementation-superchart-essential.md); mốc QA và user acceptance được tách riêng. Tài liệu đã được lập theo yêu cầu, chưa thực thi rollout.

Gate thực thi chi tiết: [kế hoạch đảm bảo chất lượng](../specs/quality-superchart-essential.md). Bên triển khai chịu trách nhiệm chạy QA trước user trial; ca bắt buộc chưa chạy/bị chặn không tính pass. P0/P1/P2 chặn bàn giao; P3 cần ghi rõ và chủ sản phẩm chấp nhận theo policy A4. Build Dev chỉ gọi đạt gate khi đúng revision đã được kiểm tra, có log và benchmark thực.

| Stage | Entry | Advance | Abort |
|---|---|---|---|
| Review | Docs và mockup đã audit | Chủ sản phẩm duyệt toàn bộ scope/defaults | Phạm vi chưa rõ hoặc user từ chối feature đề xuất |
| Dev | Scope approved, feature branch có sẵn được kiểm tra | Toàn bộ automated checks pass; mọi nhóm US/JP/VN/Crypto/NAV manual task pass; giữ các mục tiêu S1, số đo ghi thật | Bất kỳ 1 integrity/valuation regression hoặc mất/lưu nhầm drawing (A4) |
| User trial | Dev gate pass | Người dùng trải nghiệm và xác nhận đúng mong đợi | Task chưa hoàn tất hoặc state bị mất |
| Commit/review | User trial confirmed | Commit; push/PR chỉ khi được yêu cầu | Không tự commit main, không tự push/release |

Rollback đề xuất: tắt entry Superchart của build Dev và quay về Bảng, giữ cả legacy UserDefaults lẫn drawing file mới. Không xóa dữ liệu tài sản. Cần diễn tập trước handoff; hiện chưa implement flag nên chưa thể tuyên bố rollback tested.

Nếu render vượt target: giữ Dev và profile; không bỏ bớt dữ liệu hoặc thay công thức. Nếu có lỗi lưu nhầm symbol/migration: dừng mọi ghi drawing trước khi retry, giữ bản copy phục hồi.

Review sau buổi user trial đầu tiên: ghi baseline/after thực đo, cập nhật A1–A4, quyết định iterate/ship/hold. Chưa có lịch public release, không invent ngày phát hành.

Audit độc lập 2026-10-25: zero-tolerance có nguồn policy A4; trước launch vẫn cần implement và diễn tập flag/rollback. Protocol benchmark thiếu đã được bổ sung vào PRD/metrics, không gọi didFinish/RAF idle là render-ready. Không có tuyên bố launch được cho phép hoặc đã đo đạt.
