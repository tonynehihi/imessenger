# Hướng dẫn tải và cài iMessenger

## 1. Kiểm tra máy
- **Chip Apple** (M1, M2, M3…) và **macOS 14** trở lên. Xem ở menu **Apple** (logo quả táo góc trên bên trái) → **Giới thiệu về máy Mac**. Máy chip Intel không chạy được.

## 2. Cài
Hiện tại chưa có bản phát hành DMG – cài bằng cách tự build:
```bash
git clone https://github.com/tonynehihi/imessenger.git
cd imessenger
bash build.sh
```
App nằm ở `$TMPDIR/imessenger-build/iMessenger.app` – kéo vào **Applications** cho gọn.

## 3. Mở lần đầu
App chưa được Apple công chứng (cần gói Apple Developer trả phí), nên lần đầu macOS có thể chặn. Xem máy bạn thuộc trường hợp nào:
**Cài đặt hệ thống → Quyền riêng tư & Bảo mật → mục Bảo mật → «Cho phép các ứng dụng từ»**.

### Trường hợp A – đang chọn «App Store» hoặc «App Store & Nhà phát triển đã biết» (mặc định, đa số máy)
Cả 2 lựa chọn này đều chặn app, làm như sau:
1. Mở **iMessenger** trong Applications → hiện hộp *«"iMessenger" chưa được mở»* → bấm **Xong** (đừng bấm «Chuyển vào Thùng rác»).

   <img src="anh/canh-bao-lan-dau.png" width="240" alt="Hộp cảnh báo">

2. Mở **Cài đặt hệ thống → Quyền riêng tư & Bảo mật** → kéo xuống mục **Bảo mật** → dòng *«"iMessenger" đã bị chặn để bảo vệ máy Mac của bạn.»* → bấm **Vẫn mở** → nhập mật khẩu máy (hoặc Touch ID).

   <img src="anh/bao-mat-van-mo.png" width="520" alt="Mục Bảo mật – nút Vẫn mở">

3. Mở lại app. Nếu macOS hỏi lại, bấm **Mở** / **Vẫn mở**. Từ lần sau mở bình thường.

> Không thấy nút «Vẫn mở»? Nút chỉ hiện một lúc sau khi app bị chặn – mở app thêm 1 lần rồi vào lại Cài đặt.
> «Chuột phải → Mở» **không còn** tác dụng từ macOS 15.

### Trường hợp B – máy đã tắt Gatekeeper (có thêm lựa chọn thứ ba như «Mọi nơi» và đang chọn nó)
Bấm đúp là mở. Nếu macOS hỏi *«tải về từ Internet, có muốn mở không?»* → bấm **Mở**.
Không cần (và không nên) tắt Gatekeeper chỉ để cài app này – làm theo trường hợp A là đủ.

### Trường hợp C – cách nhanh bằng Terminal (dùng được cho cả A và B)
Mở **Terminal**, dán lệnh rồi Enter, sau đó mở app bình thường:
```bash
xattr -dr com.apple.quarantine "/Applications/iMessenger.app"
```
Lệnh chỉ bỏ dấu «tải từ Internet» của riêng app này, không đổi cài đặt bảo mật của máy.

## 4. Lần đầu dùng
- Đăng nhập Messenger như trên web.
- macOS hỏi **Thông báo** → **Cho phép** (để nhận tin nhắn, cuộc gọi khi ở app khác).
- Gọi video / thoại lần đầu → cho phép **Camera** và **Micrô**.
- Bộ gõ VietTelex bị lặp dấu → VietTelex: Cài đặt → Bảng cơ chế gõ → thêm `com.tonynehihi.imessenger` → **Gõ trực tiếp**. Bộ gõ Apple chạy ngay.

## 5. Cập nhật bản mới
**Cài đặt (⌘,) → Chung → Kiểm tra cập nhật** (hoặc menu **iMessenger → Kiểm tra cập nhật…**). Có bản mới → **Cập nhật ngay** → app tự tải, kiểm chữ ký số, thay bản cũ và mở lại. Không phải làm lại bước «Vẫn mở». Đăng nhập, cài đặt giữ nguyên. App không tự hỏi – chỉ kết nối GitHub khi bạn bấm.

## 6. Lỗi hay gặp
| Hiện tượng | Cách sửa |
|---|---|
| *«iMessenger bị hỏng và không thể mở»* | Dùng trường hợp C (lệnh Terminal) |
| Không thấy nút «Vẫn mở» | Mở app thêm 1 lần, vào lại Cài đặt → Quyền riêng tư & Bảo mật |
| *«Không thể tải đoạn chat»*, tin không gửi được | Có 2 bản app đang mở – thoát hết (⌘Q) rồi mở lại 1 bản |
| Không có thông báo | Cài đặt hệ thống → Thông báo → iMessenger → bật **Cho phép thông báo** |

## 7. Gỡ cài đặt
Máy dùng chung / đưa máy cho người khác: **Cài đặt → Chung → Đăng xuất và xoá dữ liệu…** (xoá đăng nhập + dữ liệu Messenger trên máy).
Gỡ app: thoát app (⌘Q) → kéo **iMessenger** trong Applications vào Thùng rác. Muốn xoá sạch cả đăng nhập: xoá thêm `~/Library/WebKit/com.tonynehihi.imessenger`, `~/Library/HTTPStorages/com.tonynehihi.imessenger*`, `~/Library/Logs/iMessenger`.
