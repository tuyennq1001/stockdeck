# Thứ tự ưu tiên — 2026-10-25

Trạng thái: provisional, để duyệt. Không có analytics Reach/Impact hoặc engineering effort; không tạo RICE score. Đây là thứ tự release/dependency cho một workflow, dùng Must/Should/Could của PRD, không xưng là xếp hạng định lượng.

| Thứ tự | Đầu tư | Vì sao trước/sau | Tính chắc chắn |
|---|---|---|---|
| Nền tảng | Request/data correctness, persistence, session | Thêm UX lên dữ liệu sai hoặc mất nét vẽ không tạo outcome | Robust theo S1/S2 |
| Workspace | Mode/source/list/range | Là đường đi đã yêu cầu rõ, mở khóa mọi bước sau | Robust theo S1 |
| Phân tích | Indicators/panes/scale + Price Range hoàn chỉnh | Phần chart đã có cần tích hợp và làm usable trước | Robust cho thành phần đã yêu cầu; scale mới cần duyệt A1 |
| Bộ vẽ nhỏ | HLine/Trend/Rectangle + lifecycle | Phủ mức/xu hướng/vùng, chia sẻ engine | Sensitive A2: nếu chỉ dùng đo thì ship Price Range trước, giữ nền tảng Undo/persist |
| Target/alert entry | Tận dụng luồng native hiện có | Không xây subsystem mới; dependency ít nhưng không chặn core chart | R1B, sau trải nghiệm R1A |
| Sau R1 | Compare, executions cá nhân, export; rồi Fib/channel nếu cần | Cần data coverage/nền tảng và nhu cầu chứng minh | Sensitive A1/A2; không là cam kết R1 |

## Sensitivity pass

- A1 ở đầu rà dài hạn: ưu tiên D/W/M, Log, đường mức. Ở đầu rà chủ động hằng ngày: search/keyboard/alert đáng làm sớm hơn tool bổ sung. Core session/data/source/drawings durability giữ nguyên ở cả hai đầu — robust.
- Nếu thực tế intraday là yêu cầu chính: lựa chọn nguồn dữ liệu và giới hạn resolution phải xem lại; không thể giải quyết bằng thêm nút giờ/phút vào UI. R1 không quảng bá như TradingView đầy đủ.
- A2 chỉ đo Price Range: HLine/Trend/Rectangle có thể lùi; select/edit/delete/undo/autosave vẫn cần vì phục vụ chính Price Range. A2 dùng nhiều annotation: cả bộ nhỏ là một release usable. Feature order sensitive, nền tảng robust.
- A3 biến thiên trong các khoảng đã ghi không đổi thứ tự release; chỉ ảnh hưởng layout/QA. Không nâng các số thiết kế thành số liệu hiệu năng.
- A4 critical integrity: không có phương án chấp nhận lỗi để đổi lấy feature count.

## Audit — 2026-10-25
Audit độc lập không thấy số liệu giả. Góp ý mọi F cùng Must làm mờ thứ tự đã xử lý: R1A gồm F01–F09/F12–F14; R1B gồm F10 và entry mới F11. R1A đề nghị gồm cả bộ vẽ nhỏ; A2 vẫn có thể làm thay đổi thứ tự nếu user chỉ cần phép đo. Các findings PRD/benchmark/alert được ghi ở specs/prd-superchart-essential.md mục 9.
