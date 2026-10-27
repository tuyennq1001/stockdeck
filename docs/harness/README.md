# Harness StockDeck

Khung làm việc cục bộ để một việc có phạm vi rõ ràng, tiến độ lưu ngoài chat và kết quả kiểm chứng có thể kiểm tra lại. Dùng runtime và công cụ AI đang có; không gọi API model, không cần API key hay dịch vụ mới.

## Bắt đầu

Yêu cầu: macOS 14+, môi trường Swift của dự án, Git và Python 3.10+. Chạy từ một nhánh feature/fix riêng được tạo từ `main`. Nếu checkout đang có việc khác chưa hoàn tất, tạo worktree riêng; không chuyển nhánh mang theo thay đổi không liên quan.

1. Đọc [AGENTS.md](../../AGENTS.md) và [bản đồ dự án](project-map.md).
2. Điều tra nguyên nhân hoặc nhu cầu; dùng [mẫu giao việc](task-template.md) để trình bày phương án và xin duyệt trong chat trước khi sửa code.
3. Tạo task và ghi lại xác nhận thật của người dùng. Các ví dụ dưới đây là mẫu thao tác, không phải dữ liệu tài chính hay bằng chứng đã chạy.

```bash
./harness.sh new fix-portfolio-pnl \
  --goal 'Sửa lỗi P&L đã tái hiện và được duyệt' \
  --scope 'Các file đã xác định trong phương án được duyệt' \
  --accept 'Test hồi quy cho lỗi đã tái hiện phải pass' \
  --accept 'Toàn bộ swift test và build macOS phải pass'
./harness.sh note fix-portfolio-pnl 'Ghi nguyên văn xác nhận, quyết định và nguồn trong chat tại đây'
```

4. Task mặc định cần UI: điền [kế hoạch và kịch bản UI](ui-verification.md) rồi nhập bằng `ui-plan` trước verify. Chỉ dùng `--ui none --ui-reason 'lý do cụ thể'` cho công việc không ảnh hưởng UI. Thực hiện trong phạm vi được duyệt; ghi quyết định, lỗi gặp phải, việc còn lại bằng `note`.
5. Chạy `./harness.sh verify fix-portfolio-pnl`. Log được ghi trực tiếp ra file, không qua bộ lọc luồng build. Theo dõi đường dẫn mà lệnh in ra.
6. Nếu có UI, test/build đạt vẫn bị chặn bàn giao cho đến khi ghi đủ thao tác và bằng chứng của bản build đó. Làm theo [quy trình UI](ui-verification.md), chạy `./harness.sh check fix-portfolio-pnl`, rồi báo người dùng kết quả. Chờ xác nhận trải nghiệm trước khi commit. Chỉ push/tạo PR khi được yêu cầu riêng; merge cần xác nhận trực tiếp.

## Lệnh và dữ liệu

| Lệnh | Kết quả |
| --- | --- |
| `new <id> --goal ... --scope ... --accept ...` | Tạo contract; `--scope` và `--accept` lặp được |
| `note <id> 'nội dung'` | Thêm ghi chú có thời gian; không thay thế lịch sử cũ |
| `status <id>` | Xem task, receipt gần nhất và bằng chứng còn khớp code/contract không; dùng được cả khi verify đang chạy |
| `verify <id> [--timeout 900]` | Chạy kiểm chứng; timeout tính bằng giây cho từng bước, tối đa 3600 |
| `recover <id>` | Đánh dấu lượt chạy dở là interrupted, giữ log và số lượt đã dùng |
| `ui-plan <id> <file.json>` | Nhập kịch bản UI và lý do cho các hạng mục không áp dụng |
| `ui-begin <id> --pid <pid>` | Gắn phiên thao tác với đúng app, bản build và receipt đã pass |
| `ui-record ...` | Ghi kết quả quan sát từng bước cùng ảnh trước/sau; xem [cú pháp](ui-verification.md) |
| `check <id>` | Kiểm tra điều kiện bàn giao; mã thoát 3 nếu còn thiếu bằng chứng |

Task nằm ở `.harness/tasks/<id>.json`; mỗi lượt có `.harness/runs/<id>/<run-id>/receipt.json` cùng các file log. Contract gồm `goal`, `scope`, `acceptance`, `constraints`, `ui`. Có thể sửa các trường contract này bằng trình soạn thảo; không sửa lịch sử `runs`, `ui_sessions` hoặc trạng thái để làm đẹp kết quả. Thay đổi contract làm bằng chứng cũ hết hiệu lực. Task cũ chưa có phân loại UI mặc định được coi là cần UI, phải bổ sung kế hoạch hoặc lý do miễn phù hợp.

Receipt lưu commit, nhánh, SHA-256 của file được Git theo dõi và file mới chưa bị ignore, SHA-256 contract, lệnh thực tế, mã thoát, thời gian và kết quả. CSV trong `template/transaction/` được fingerprint riêng dù bị ignore; receipt chỉ giữ hash tổng, không giữ nội dung. Các file ignored khác không được fingerprint; không đặt source đầu vào cần kiểm chứng trong đó. Môi trường, API thị trường và dữ liệu người dùng ngoài dự án có thể thay đổi độc lập: receipt không chứng minh các yếu tố đó giữ nguyên.

`.harness/` bị Git ignore vì log có thể chứa dữ liệu riêng. Trạng thái tồn tại qua việc mở lại chat/khởi động lại máy **trong cùng worktree**; không tự đồng bộ sang máy hoặc worktree khác. Trước khi xóa/archive worktree, giữ bản sao cần thiết ở nơi riêng phù hợp hoặc ghi bản tổng kết đã loại dữ liệu nhạy cảm vào tài liệu dự án. Không đưa token, mật khẩu hoặc dữ liệu portfolio vào contract/ghi chú.

## Trạng thái và phục hồi

`planned → verifying → awaiting_ui_verification → awaiting_user_review` cho việc có UI. Việc không ảnh hưởng UI có lý do miễn hợp lệ có thể chuyển thẳng từ verify sang chờ người dùng kiểm tra. Lỗi, timeout hoặc gián đoạn chuyển sang `needs_attention`. `status` hiển thị `verification_stale` nếu bằng chứng test/build không còn khớp code hoặc contract. `gates` tách test/build, UI và chấp nhận của người dùng; `ready_for_user_review` chỉ true nếu test/build hiện hành và cổng UI đạt/không áp dụng hợp lệ. Không có trạng thái tự động xác nhận người dùng đã duyệt.

Mỗi task có tối đa 3 lượt verify, kể cả lượt lỗi hoặc gián đoạn. Sau giới hạn, cùng người dùng xem bằng chứng và quyết định kế hoạch tiếp theo; không tự lặp vô hạn. Một khóa theo checkout chặn hai harness chạy chồng nhau. Khóa được hệ điều hành giải phóng khi tiến trình kết thúc; file `lock` còn tồn tại không có nghĩa đang bị khóa. Nếu bị tắt cưỡng bức, kiểm tra tiến trình test/build con trước khi `recover`; `recover` chỉ sửa trạng thái, không tự giết tiến trình còn sót.

## Phạm vi bảo vệ

CLI chỉ tạo trạng thái cục bộ và chạy tập lệnh kiểm chứng cố định. Không có lệnh commit, push, merge, release, triển khai, gửi tin hay ghi Jira. Các điều kiện duyệt và phạm vi file vẫn là quy trình phải tuân thủ, không phải một sandbox: công cụ terminal/agent khác vẫn có thể hoạt động bên ngoài CLI. Nếu cần cưỡng chế cho cả môi trường, cấu hình quyền công cụ, credential và branch protection ở hệ thống sở hữu quyền; không coi văn bản `AGENTS.md` là cơ chế cấp quyền.

`scope` và `acceptance` là thỏa thuận để review; CLI không tự chứng minh mọi yêu cầu nghiệp vụ trong đó. Cổng UI kiểm tra đủ kịch bản, thứ tự, nguồn build và tính toàn vẹn bằng chứng; không tự hiểu ảnh hay xác nhận lời quan sát là đúng. Agent vẫn phải thao tác thật bằng công cụ UI và người dùng review kết quả. Chưa bổ sung lịch chạy nền, dashboard hoặc nhiều agent.

## Áp dụng cho dự án khác

Giữ cấu trúc contract, trạng thái và receipt. Thay bản đồ tài liệu, quy tắc nghiệp vụ và danh sách lệnh trong `Harness.verify`; thêm test cho lệnh mới. Mỗi dự án tự chỉ rõ môi trường chạy, điều kiện duyệt và giới hạn. Bản này chủ đích dành cho StockDeck/macOS.

Tham khảo khái niệm: [hướng dẫn harness được người dùng cung cấp](https://x.com/0xwhrrari/article/2093685107534000560), [OpenAI: Codex harness](https://developers.openai.com/blog/codex-as-a-platform). Các lệnh/quyền trong dự án tuân theo `AGENTS.md` và xác nhận của người dùng, không lấy quyền từ bài tham khảo.
