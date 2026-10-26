# Decision log: StockDeck

Append-only. Every entry: decision, alternatives considered, why,
dissent (if any), and a revisit-when trigger. Schema in
references/pm-discipline.md.

## 2026-10-25 — workspace initialized

## 2026-10-25 — Đề xuất bộ Superchart Essential để duyệt
- Decision: soạn PRD + roadmap + mockup cho một workflow hoàn chỉnh, không thêm code app trong lượt này.
- Đã có yêu cầu trực tiếp: hai mode, source Watchlist/Portfolio, list Last/Chg/Ext, D/W/M dropdown và rail vẽ; S1.
- Đề xuất cần duyệt mới: bộ vẽ HLine/Trend/Rectangle, sửa/Undo/Redo, snap/lock, indicator params, scale và native alert entry.
- Alternatives: copy toàn bộ TradingView hoặc chỉ tiếp tục sửa từng icon. Đề xuất chọn workflow nhỏ nhưng đủ vòng đời vì constraints S1/S2; các claims chuyên môn gắn A1/A2.
- Dissent/correction: TradingView cũng đã có Portfolio (S8); không dùng nhận định ngược lại làm lợi thế cạnh tranh.
- Revisit when: user duyệt/từ chối scope, audit phát hiện thiếu ràng buộc, hoặc QA chứng minh A1/A2 không đúng.
- State: draft, không phải phê duyệt triển khai hay phát hành.

## 2026-10-25 — Audit và bàn giao phương án để duyệt
- Decision: đề nghị R1A trước; đưa snap/hide all/lock all và entry alert/target mới sang R1B. Bản duyệt chỉ có R1A, không treo icon ngoài phạm vi.
- Why: giữ luồng phân tích/vẽ đầy đủ nhưng tách tiện ích bổ sung khỏi cổng bàn giao đầu tiên; không dùng giả định nhu cầu hoặc effort chưa đo làm số liệu ưu tiên.
- Alternatives/dissent: audit độc lập yêu cầu protocol benchmark tái lập, tên N nến cho phép đo W/M, initialThreshold cho native alert; các điểm này đã được bổ sung vào đặc tả. Recheck không còn blocker mới.
- Validation: prototype qua chuyển mode/nguồn/interval, thêm indicator, tạo Rectangle và Undo/Redo, phóng pane, kiểm tra chiều hẹp và JavaScript. Không coi là app integration hoặc benchmark pass.
- Revisit when: chủ sản phẩm duyệt mockup/phạm vi hoặc kết quả Dev cho thấy cần giảm/tăng phạm vi. Hiện chưa có approval mới, chưa sửa app code, chưa commit/push.

## 2026-10-25 — Bổ sung cổng đảm bảo chất lượng theo câu hỏi người dùng
- Decision: đề xuất kế hoạch QA riêng, trách nhiệm bên triển khai chạy và sửa trước user trial; từng gate có oracle/bằng chứng, BLOCKED/NOT RUN không tính PASS.
- Why: danh sách test trong PRD chưa đủ làm hợp đồng bàn giao; cần kiểm tra đúng dữ liệu, request/state, lưu bền/migration, UX native, hồi quy và hiệu năng/khôi phục.
- Alternatives: chỉ full unit test/build hoặc nhờ người dùng tìm lỗi sau khi nhận Dev. Không chọn vì không kiểm chứng renderer thật và có thể bỏ sót sai mã/mất drawing.
- Policy A4: P0/P1/P2 chặn bàn giao, P3 ghi rõ và chỉ nhận khi user chấp nhận; target S1 giữ nguyên, không đổi số sau đo để pass.
- Revisit when: audit tìm loophole, fixture/provider khác precision, hoặc kết quả benchmark chỉ ra gate/thiết bị cần được làm rõ trước phê duyệt. Chưa có kết quả thực thi QA app mới và chưa thay đổi scope R1A/R1B.

### Audit QA bổ sung
- Finding P2: statistic cache-ready chưa chốt, có thể dùng median để che latency tail.
- Resolution đề xuất A4: max warm≤1s trên tập mẫu, báo median/p95/max và lỗi/timeout; frame p95≤33ms cho từng pan/zoom/drawing, không gộp. Mẫu không render tính FAIL và giữ trong denominator. Đồng bộ PRD, quality, metrics, assumptions.
- Không có blocker khác; QA gate vẫn là đề xuất chưa có số đo thực, chưa có phê duyệt triển khai app mới.

## 2026-10-25 — Lập kế hoạch thực thi hợp nhất
- Request/decision: người dùng đồng ý lập plan; tạo specs/implementation-superchart-essential.md làm đầu mối các mốc M0–M6, liên kết PRD/QA/mockup/launch. Không suy yêu cầu lập tài liệu thành lệnh sửa app hoặc user acceptance.
- Why: cần một checklist thực thi có đầu ra/gate, thay vì tách rời danh sách tính năng và yêu cầu chất lượng. M5 PRD tách thành M5 QA/M6 handoff, không đổi scope.
- Alternatives: viết lại PRD thứ hai hoặc bắt đầu code ngay. Không chọn để giữ một nguồn hành vi và đúng yêu cầu hiện tại.
- Audit: reviewer độc lập không thấy P0/P1/P2 mới; xác minh root desktop, scope, dirty-branch safeguards và benchmark. Ghi chú mapping mốc đã xử lý và hiển thị trong plan.
- Revisit when: có yêu cầu triển khai, thay scope/gate, phát hiện baseline regression hoặc estimate có bằng chứng cần đổi thứ tự. Hiện chỉ tài liệu được cập nhật, chưa có app code mới/commit/push.
