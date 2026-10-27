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

## 2026-10-26 — Đề xuất Custom Scripts và kiểm chứng trước tích hợp
- Request/decision: theo S9/FB5, soạn specs/implementation-custom-scripts.md cho tự nhập Pine; POC M0/M1 trước R1 cùng khung (DCA) và R2 MTF/pane/fill (Risk Metric). Chưa duyệt engine/triển khai; chỉ tài liệu trên feature/custom-script-validation-plan.
- Why: chuyển từng indicator sang Swift không đáp ứng tự phục vụ. Compile thành công không chứng minh đúng số liệu, renderer hoặc alert; cần oracle độc lập, TradingView reference và manifest có version.
- Alternatives: chuyển tay từng script; bundle PineTS trực tiếp trong chart; thay chart bằng Vela; hứa full Pine ngay. Đề xuất không chọn vì lệch nhu cầu, quyền thực thi/UX hoặc thiếu bằng chứng tương thích. PineTS chỉ là ứng viên A5; license AGPL/commercial cần xác định route tại M0, không tự mua/chấp nhận.
- Dissent/correction: docs cũ nói chưa có Superchart; static checkpoint hiện tại 665b1ff đã có Superchart/shared detail/intraday [S11]. Giữ snapshot cũ là lịch sử, cập nhật product/state/README; không suy static code thành user acceptance.
- Audit: đang chờ reviewer độc lập; findings sẽ được ghi trong plan và log trước bàn giao.
- Revisit when: audit có blocker, POC không đạt host/semantics/license, không có oracle cùng input, yêu cầu alert khi app tắt/full Pine hoặc benchmark vượt limits A6. Không hạ gate/giấu unsupported để tuyên bố thành công. Chưa sửa app, chưa commit/push.

### Audit Custom Scripts và xử lý
- Reviewer độc lập không thấy P0/P1; nêu ba P2: pane R1/R2 mâu thuẫn, policy đóng nến có thể đổi frequency source và gate reference/TradingView bị gộp.
- Đã xử lý trong plan: R1 overlay, R2 pane; frequency ngoài contract tắt route có diagnostic; tách G-NUMERIC-REFERENCE/G-TV-PARITY, Dev thử engine chưa tương đương nghiệm thu khớp TradingView.
- Audit chỉ đọc tài liệu/source, không có test runtime; giữ nguyên trạng thái đề xuất và chưa duyệt viết code. Revisit khi POC có bằng chứng mới hoặc user thay phạm vi.
- Recheck độc lập xác nhận ba P2 đã xử lý, không còn blocker từ các findings của audit; không coi là runtime/test PASS.

## 2026-10-26 — Đã duyệt thử và chạy POC Custom Scripts
- Authorization: người dùng hỏi hiệu năng rồi nói “ok thử đi”; tiến hành M0/M1 riêng trên nhánh feature hiện có, giữ toàn bộ tài liệu đang sửa. Không xin lại phép đã có; chưa có phép commit/push/release.
- Result S17: pin PineTS 0.13.0; helper Swift/JavaScriptCore chạy được source. DCA FAIL documented EMA reference (199 na mismatch, 722 numeric fail/5.540 bars, 11 signal/color mismatch); Risk numeric PASS dataset D/W, chưa TradingView parity. Ba Risk 5.000 D timeout 10/10 theo budget 5 giây, không giấu các mẫu fail.
- Decision: giữ gate M1, chưa tích hợp runtime/editor vào app. Cần sửa/đổi engine chung cho EMA, profile MTF/encode và chốt license/isolation trước R1/R2; không chuyển source gốc sang bản sửa tay hoặc nới gate để gọi thành công.
- Alternatives/dissent: có thể tiếp tục UI vì compile được hoặc giảm ngầm lịch sử/số script; không chọn vì kết quả và hiệu năng chưa đạt contract đã duyệt. Các giới hạn A5/A6 được cập nhật bằng thực nghiệm, chưa tuyên bố toàn PineTS không dùng được.
- Verification: 616 app tests và ./dev.sh PASS; 9 harness tests PASS gồm khả năng phát hiện lỗi, không phải compatibility PASS. Chưa OS sandbox/hard memory cap/live update/UI FPS/native alert/TV numeric export. App code/bundle không thêm dependency này.
- Revisit when: runtime/EMA được sửa và đối chiếu lại source gốc; request.security hoặc output encoder được tối ưu rồi rerun matrix; có oracle TradingView cùng input hoặc license route rõ. Báo cáo: docs/custom-script-poc-report.md; machine-readable evidence có hash/protocol.

## 2026-10-26 — Tiếp tục sửa runtime chung và đo lại [S18]
- Authorization: “tiếp đi” tiếp tục POC đã duyệt; giữ app hiện tại và source Pine gốc. Không suy thành phép commit/push/release hoặc nghĩa vụ license mới.
- Result: candidate dựa pinets 0.13.0 sửa EMA, allocations tham số/plot options, HTF lookup và rolling stdev. DCA/Risk PASS reference cùng input; DCA 86 buy/17 sell/103 alertcondition đúng vị trí, imperative alert source gốc vẫn 0. Live-tail plot trùng timestamp được sửa; lịch sử alert giữ nguyên để tránh mất sự kiện do dedup.
- Performance: giữ 5 giây/10 cold/30 cached calls; 60/60 cold hoàn tất, ba Risk 5.000 D max 4,603 giây/peak RSS 163,4 MiB. Không chọn mẫu thành công, giảm bars hoặc nới gate. Có 18 harness + 616 app tests và dev build PASS; baseline S17 và evidence giữ nguyên, S18 riêng có hashes.
- Decision/alternatives: candidate đủ bằng chứng xử lý blocker EMA/helper budget của hai ví dụ; tiếp tục M1, chưa bật UI nhập source bất kỳ. Không hardcode hai script, sửa Pine source hoặc coi cached calls là live performance. Package/vendor không được tích hợp vào app.
- Remaining/revisit: license route, OS sandbox/hard cap/arbitrary-source preflight, MTF live/TV oracle và adapter/UI/FPS phải kiểm chứng riêng. Native helper timing không chứng minh Superchart mượt; user acceptance chưa có. Report docs/custom-script-candidate-report.md và evidence cùng tên.

## 2026-10-26 — Tạm chọn hướng AGPL miễn phí cho PineTS
- Request/decision: người dùng “ok tạm chốt agpl đi”; dùng hướng PineTS AGPL miễn phí làm cơ sở triển khai, không mua license thương mại. Đây là quyết định tạm cho implementation, không phải xác nhận pháp lý hay duyệt phát hành App Store.
- Why: cần chạy nguyên Pine v6 tại chỗ, không gửi source người dùng qua dịch vụ chuyển đổi. PyneCore là phương án thay thế nhưng khâu chuyển Pine yêu cầu dịch vụ/API key.
- Điều kiện: giữ thông báo và license AGPL, cung cấp corresponding source theo phạm vi license; trước khi App Store cần đánh giá riêng EULA/DRM/redistribution terms của Apple và yêu cầu AGPL. Mã nguồn StockDeck gốc MIT không bị âm thầm gỡ bỏ; kết hợp phân phối cần được rà soát.
- Revisit when: user đổi ý, kết luận compliance App Store chặn, hoặc chọn PyneCore/paid terms. Không mua, gửi source ngoài, phát hành hay thay đổi lịch sử license trong lượt này.
