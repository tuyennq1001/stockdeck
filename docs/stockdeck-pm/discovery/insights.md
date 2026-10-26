# Insights

## I1 — Hai công việc cần hai bố cục
- Evidence: S1 yêu cầu giữ bảng hiện tại và bật/tắt Superchart.
- Interpretation: mode khác nhau nhưng cùng source và symbol.
- Status: evidenced ở người dùng hiện tại; chưa kiểm chứng diện rộng.
- Confidence: cao cho phiên này.

## I2 — Tính nhẹ và độ tin cậy là điều kiện nền
- Evidence: S1 từ chối iframe TradingView do nặng; yêu cầu dữ liệu/cache thật; S2 có WebView local.
- Interpretation: ưu tiên state/lifecycle/performance trước số lượng công cụ.
- Status: evidenced.
- Confidence: cao.

## I3 — Một bộ vẽ cần vòng đời hoàn chỉnh
- Evidence: S1 yêu cầu Price Range; S3 mô tả drawing lifecycle. Yêu cầu sửa/undo chưa được người dùng chốt.
- Interpretation: horizontal/trend/rectangle và lifecycle có thể giảm thao tác vẽ lại.
- Status: hypothesis A2.
- Confidence: cần nghiệm thu mockup/Dev.
