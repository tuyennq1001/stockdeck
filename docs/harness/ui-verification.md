# Cổng kiểm chứng UI bắt buộc

Mục đích: không bàn giao thay đổi UI chỉ vì unit test/build pass. Mỗi kịch bản phải có thao tác thật, kết quả quan sát và bằng chứng của bản app đã được kiểm chứng.

## 1. Chốt kế hoạch trước verify

Task mới mặc định `--ui required`. Sao chép [mẫu JSON](ui-plan.template.json) vào `.harness/ui-plan.json`, điền nội dung thật theo phương án đã được người dùng duyệt, rồi chạy:

```bash
./harness.sh ui-plan <task-id> .harness/ui-plan.json
./harness.sh verify <task-id>
```

Mẫu cố ý có ô trống: không thể dùng nguyên mẫu để qua cổng. Mỗi scenario có ID duy nhất, màn hình (`surface`), tiền điều kiện, các bước theo thứ tự và kết quả mong đợi riêng cho từng bước. Tất cả scenario/step đều bắt buộc; không có tùy chọn tự bỏ qua bước bị lỗi.

Kế hoạch phải bao phủ các nhóm dưới đây hoặc ghi lý do cụ thể trong `exclusions`. Nhóm đã test thì bỏ khỏi `exclusions`; không được vừa test vừa loại trừ. `loaded` luôn phải có ít nhất một kịch bản.

| Nhóm | Cần xem xét theo phạm vi thực tế |
| --- | --- |
| `loaded` | Luồng chính, dữ liệu/định dạng/giá trị thật đúng yêu cầu |
| `loading` | Đang tải, dự trù layout, phản hồi khi chờ |
| `empty` | Không có dữ liệu và không có kết quả sau lọc |
| `error` | Thông báo lỗi, retry, phục hồi; không giả báo API thành công |
| `appearance` | Sáng/tối; phân biệt hover, selected, focus, disabled |
| `window_size` | Kích thước cửa sổ nhỏ/lớn, overflow, cắt chữ, layout |
| `keyboard` | Tab/focus, Enter, Escape; đóng đúng dialog và trả focus |
| `parity` | Menu bar/desktop, bảng/card, màn hình tương đồng, ngôn ngữ/thị trường liên quan |

Ví dụ yêu cầu lọc bảng nên có các bước mở bảng, chọn điều kiện, kiểm tra tập dòng đúng, xóa bộ lọc, rồi chuyển màn hình/quay lại kiểm tra trạng thái. Test sort cần đối chiếu đúng thứ tự số/ngày/chữ; test dialog cần kiểm tra đóng/hủy, focus và giữ dữ liệu chưa lưu khi thích hợp. Chỉ chụp màn hình cuối không chứng minh cả chuỗi hành vi.

Nếu không có tác động UI (ví dụ sửa tài liệu hoặc chính công cụ CLI), tạo task với `--ui none --ui-reason 'lý do cụ thể'`. Cổng từ chối miễn UI nếu diff so với HEAD hoặc file mới có đường dẫn UI đã biết. Đây là kiểm tra bảo thủ theo file; thay đổi logic ở module khác vẫn có thể ảnh hưởng UI. Agent phải phân loại trung thực và người dùng review lý do miễn. Không thay đổi miễn UI chỉ để lách một luồng khó test.

## 2. Mở đúng app đã build

Khi test/build đạt, receipt lưu hash nội dung bundle DEV. Với task UI, `verify` trả mã 3 và giữ `awaiting_ui_verification` cho đến khi đủ bằng chứng. Không cần chạy lại test/build chỉ vì mã 3.

Dùng công cụ điều khiển app để mở đúng `.build/StockDeck-Dev.app` của worktree đã verify. Trong Codex, dùng công cụ computer use cho app macOS; nếu dự án đã có UI automation runner thích hợp thì có thể dùng runner đó. Không lấy ảnh qua đọc source hay dựng ảnh minh họa. Không mở app khác có cùng tên rồi coi như đã test bản sửa.

Nếu dùng `./dev.sh` để mở app sau verify, nó sẽ build/ký lại và có thể làm hash bundle thay đổi, khiến bằng chứng cũ hết hiệu lực. Hãy mở bundle đã có, hoặc verify lại rồi mở đúng bundle đó. Không đóng instance hay thay dữ liệu của công việc khác để vượt kiểm tra PID; dùng môi trường test riêng phù hợp. Không đổi Bundle ID/credential tùy tiện.

Lấy PID từ thông tin tiến trình của app đúng đường dẫn, sau đó:

```bash
./harness.sh ui-begin <task-id> --pid <pid>
```

Lệnh kiểm tra đường dẫn executable, thời điểm tiến trình được mở sau verify và hash bundle. Nó không mở app, không giả lập thao tác. Ghi lại `id` phiên trả về. Mỗi bản verify có tối đa 3 phiên UI; mỗi bước có tối đa 3 lần ghi thử. Vượt giới hạn phải xem lại bằng chứng cùng người dùng.

## 3. Thao tác và ghi nhận từng bước

Tạo thư mục ảnh `.harness/captures/` và lưu ảnh từ công cụ UI vào đó, tránh tạo file mới trong source làm fingerprint thay đổi. Sau khi bắt đầu phiên:

1. Quan sát tiền điều kiện và chụp ảnh **trước** bước.
2. Thực hiện thao tác đúng trong kế hoạch; quan sát trạng thái sau thao tác.
3. Đối chiếu với `expected`, chụp ảnh **sau** và ghi kết quả thực tế cụ thể.
4. Ghi bước đó trước khi chụp ảnh cho bước tiếp theo.

```bash
./harness.sh ui-record <task-id> <session-id> <scenario-id> <step-id> \
  --result passed --actual 'Kết quả cụ thể đã quan sát và đối chiếu' \
  --before .harness/captures/before.png --after .harness/captures/after.png
```

`passed` bắt buộc có hai file PNG riêng, hợp lệ, tối thiểu 320×200, 8-bit không interlace. Dùng ảnh toàn cửa sổ hoặc toàn vùng UI phù hợp để thấy layout và ngữ cảnh. Ảnh phải được tạo sau khi phiên bắt đầu và sau lần ghi bước trước; không tái dùng cặp ảnh một bước cho cả kịch bản. Hai ảnh có thể cùng nội dung khi kết quả mong đợi là UI giữ nguyên, nhưng phải là hai lần chụp thực tế.

Nếu sai hoặc không thực hiện được, ghi `--result failed` hoặc `blocked` cùng `--actual` giải thích nguyên nhân; ảnh không bắt buộc khi công cụ không chụp được. Không ghi pass cho điều chỉ suy đoán. Nếu app crash/đổi PID thì báo vướng mắc bằng `note` và mở phiên mới sau khi đã xử lý đúng phạm vi.

CLI lưu bản sao ảnh và hash vào `.harness/ui/<task>/<session>/`, giữ lịch sử các lần thử. Test lại bước trước làm bằng chứng các bước sau cần thực hiện lại đúng thứ tự. Sửa code/kế hoạch, đổi app bundle hoặc chạy verify mới làm phiên UI cũ không còn hợp lệ.

## 4. Cổng bàn giao

```bash
./harness.sh check <task-id>
```

Kết quả tách ba cổng: `automated_checks`, `ui`, `human_acceptance`. Chỉ khi test/build hiện hành và tất cả step trong tất cả scenario có pass + ảnh còn nguyên vẹn thì `ready_for_user_review` mới true. `human_acceptance` vẫn pending; không có lệnh tự xác nhận thay người dùng. `check` trả 0 khi đủ điều kiện trình người dùng review, 3 khi chưa đủ, 2 nếu dữ liệu/điều kiện không hợp lệ.

Bàn giao kèm scenario đã kiểm tra, receipt và ảnh then chốt; ghi rõ vướng mắc/ngoại lệ. Với task UI, không chỉ báo số unit test pass. Chờ người dùng xác nhận trải nghiệm trước commit theo `AGENTS.md`.

## Giới hạn và dữ liệu riêng

Cổng xác minh nguồn build, cấu trúc và tính toàn vẹn bằng chứng. Nó không tự hiểu nội dung ảnh, không chứng minh click đã xảy ra chỉ từ lời agent, không có mô hình thị giác độc lập và không chống người có toàn quyền filesystem cố tình sửa cả báo cáo lẫn hash. Cần kết hợp công cụ thao tác UI thật, review expected/actual và xác nhận người dùng. Các ảnh sinh trong unit test chỉ là fixture kiểm tra cơ chế cổng, không được dùng làm bằng chứng UI sản phẩm.

Ảnh/log chỉ lưu cục bộ trong `.harness/`, không tự upload hay đưa vào Git. Dùng dữ liệu thật đã được phép trong môi trường test; không dùng dữ liệu tài khoản thật để thực hiện gửi tin, thanh toán, xóa dữ liệu hoặc tác vụ ngoài phạm vi. Cổng này không cấp thêm quyền cho agent.
