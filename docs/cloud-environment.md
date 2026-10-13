# Môi trường phát triển MQTT

Repository hiện có cấu hình môi trường phát triển, chưa có mã nguồn ứng dụng
hay bộ kiểm thử ứng dụng.

## Cài đặt

Script dành cho môi trường đám mây Debian 13 với checkout tại
`/workspace/MQTT`. Cần Bash, Python 3, GCC, APT, `dpkg-deb`, keyring Debian
và quyền truy cập HTTPS đến `deb.debian.org`; các công cụ này đã có trong
image được sử dụng để thiết lập.

```bash
cd /workspace/MQTT
bash scripts/cloud-setup.sh
```

Script tải các gói Mosquitto từ nguồn Debian có xác minh chữ ký và checksum,
rồi giải nén vào `/workspace/.mqtt-environment`. Không cần quyền root.
Mỗi task đám mây đã được cô lập; sử dụng checkout hiện có, không cần tạo Git
worktree.

## Khởi động và kiểm tra

Chạy các lệnh sau trong mỗi phiên mới:

```bash
cd /workspace/MQTT
source /workspace/.mqtt-environment/activate.sh
/workspace/.mqtt-environment/start.sh
```

Broker chỉ lắng nghe tại `127.0.0.1:1883`, cho phép kết nối cục bộ không cần
mật khẩu và không lưu trạng thái xuống đĩa. Script khởi động kiểm tra gửi/nhận
MQTT 3.1.1 và MQTT 5 với QoS 1, so sánh đúng payload rồi xóa thông điệp retained
do phép kiểm tra tạo ra. Có thể chạy lại kiểm tra độc lập:

```bash
python3 /workspace/.mqtt-environment/smoke.py
```

Kết quả cần có `PASS mqttv311` và `PASS mqttv5`. Log broker nằm tại
`/workspace/.mqtt-environment/run/broker.log`.

Để gửi/nhận thông điệp, mở hai terminal, chạy lệnh `source` ở trên trong mỗi
terminal, rồi chạy subscriber trước:

```bash
mosquitto_sub -h 127.0.0.1 -p 1883 -t demo -q 1 -C 1
```

Trong terminal còn lại:

```bash
mosquitto_pub -h 127.0.0.1 -p 1883 -t demo -q 1 -m 'hello MQTT'
```

## Dừng, khởi động lại và cập nhật

```bash
/workspace/.mqtt-environment/stop.sh
/workspace/.mqtt-environment/start.sh
```

Các script chỉ quản lý broker do cấu hình này khởi động. Chạy lại
`bash scripts/cloud-setup.sh` để cập nhật dependency; script sẽ dừng broker
này trước khi thay thế các binary. Sau đó chạy lại các lệnh khởi động.

Snapshot môi trường giữ các file và dependency, nhưng tiến trình broker cần
khởi động lại ở task mới. Script cài đặt và hướng dẫn khởi động cũng đã được
lưu trong bản nháp cấu hình môi trường Codex. Push repository lên GitHub
không thực hiện thao tác Publish của môi trường.
