// iMessenger by @tonynehihi — phát triển từ mã nguồn của Vduck141 (CC BY-NC 4.0)
// Học theo app "MessengerApp" của Stefan (MIT, github.com/stefanminch/messenger-mac),
// nhưng viết lại bằng Swift + WKWebView (nhân Safari) thay cho Electron (nhân Chrome).
//
// So sánh nhanh với bản gốc (main.js):
//   new BrowserWindow(...)          → NSWindow + WKWebView
//   mainWindow.loadURL(...)         → webView.load(URLRequest)
//   setWindowOpenHandler / will-navigate → WKNavigationDelegate + WKUIDelegate
//   cookie "giữ đăng nhập"          → WKWebsiteDataStore.default() (macOS tự lưu)
//   setBackgroundThrottling         → WebKit tự giảm tải khi cửa sổ bị che/ẩn

import Cocoa
import WebKit
import UserNotifications
import ServiceManagement
import CryptoKit

// Trang chính của app
let trangChu = URL(string: "https://www.messenger.com")!

// User agent (chuỗi tự giới thiệu trình duyệt) giống Safari thật.
// Không đặt thì Facebook có thể coi là "trình duyệt không hỗ trợ".
let userAgentSafari = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
// Cửa sổ cuộc gọi xưng là Chrome: Messenger chỉ cho chia sẻ màn hình trên Chrome («chỉ hỗ trợ… Chrome», 03/11).
// Lõi Safari vẫn có getDisplayMedia (ScreenCaptureEnabled bật sẵn). Cửa sổ chat chính giữ Safari.
let userAgentChrome = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36"

// Các tên miền được mở NGAY TRONG app; còn lại mở bằng trình duyệt mặc định.
// (Bản gốc chỉ giữ messenger.com; em thêm facebook.com để trang đăng nhập/2FA không bị đẩy ra ngoài.)
let tenMienTrongApp = ["messenger.com", "facebook.com", "fbcdn.net", "fbsbx.com"]

// Link chuyển hướng l.messenger.com / l.facebook.com → lấy link thật trong tham số "u"
func linkThat(_ url: URL) -> URL? {
    guard let host = url.host, host == "l.messenger.com" || host == "l.facebook.com" else { return nil }
    let u = URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?.first(where: { $0.name == "u" })?.value
    return u.flatMap(URL.init(string:))
}

// Có phải link nên ở lại trong app không
func laTrongApp(_ url: URL) -> Bool {
    // about:blank, blob:, data: … là nội bộ của trang → luôn cho phép
    guard let scheme = url.scheme, scheme == "http" || scheme == "https" else { return true }
    guard let host = url.host else { return false }
    return tenMienTrongApp.contains { host == $0 || host.hasSuffix("." + $0) }
}

// MARK: Bước 2 – Thông báo
// WKWebView KHÔNG có sẵn Notification như Chrome/Electron → trang tưởng trình duyệt không hỗ trợ.
// Cách làm: chèn đoạn JS này vào trang TRƯỚC khi trang chạy (documentStart), tạo một "Notification giả".
// Khi messenger.com gọi `new Notification(...)`, đoạn JS gửi nội dung sang Swift qua
// window.webkit.messageHandlers.vmThongBao → Swift hiện thông báo thật của macOS.
let jsThongBao = """
(function () {
  const guiSwift = (d) => window.webkit.messageHandlers.vmThongBao.postMessage(d);
  guiSwift({ nhatKy: 'Notification gốc của trang: ' + typeof window.Notification });
  const danhSach = {};   // id → đối tượng thông báo, để khi bấm thì gọi lại onclick của trang
  class ThongBao {
    constructor(tieuDe, tuyChon) {
      tuyChon = tuyChon || {};
      this.title = String(tieuDe); this.body = String(tuyChon.body || ''); this.tag = String(tuyChon.tag || '');
      this.data = tuyChon.data; this.onclick = null; this.onclose = null; this.onshow = null; this.onerror = null;
      this._id = 'vm-' + Date.now() + '-' + Math.random().toString(36).slice(2);
      danhSach[this._id] = this;
      guiSwift({ id: this._id, tieuDe: this.title, noiDung: this.body, tag: this.tag });
    }
    close() { guiSwift({ dong: this._id }); delete danhSach[this._id]; }
    addEventListener(loai, ham) { if (loai === 'click') this.onclick = ham; if (loai === 'close') this.onclose = ham; }
    removeEventListener() {}
    static requestPermission(cb) { guiSwift({ nhatKy: 'DÒ TB: trang xin quyền thông báo' }); if (cb) cb('granted'); return Promise.resolve('granted'); }
    static get permission() { if (!daHoiQuyen) { daHoiQuyen = true; guiSwift({ nhatKy: 'DÒ TB: trang đọc Notification.permission' }); } return 'granted'; }
  }
  let daHoiQuyen = false;
  Object.defineProperty(window, 'Notification', { value: ThongBao, writable: true, configurable: true });

  // Messenger có thể gửi thông báo qua service worker (registration.showNotification) thay vì new Notification
  // → chuyển luôn sang ThongBao. (Dò 03/11: tin đến khi ở app khác KHÔNG có dòng "thông báo mới" nào.)
  if (window.ServiceWorkerRegistration) {
    ServiceWorkerRegistration.prototype.showNotification = function (tieuDe, tuyChon) {
      guiSwift({ nhatKy: 'DÒ TB: showNotification của service worker' });
      new ThongBao(tieuDe, tuyChon); return Promise.resolve();
    };
    ServiceWorkerRegistration.prototype.getNotifications = function () { return Promise.resolve([]); };
  }
  guiSwift({ nhatKy: 'DÒ TB: serviceWorker ' + ('serviceWorker' in navigator ? 'có' : 'không') + ', PushManager ' + (window.PushManager ? 'có' : 'không') });

  // Tin mới đến lúc anh không nhìn app → TỰ tạo thông báo: Messenger trên nhân Safari không gọi Notification
  // (dò 03/11: tin đến khi trang hidden/hasFocus=false, không có lệnh thông báo nào; trang không có PushManager).
  // Không dựa vào số chưa đọc: số đó đếm ĐOẠN CHAT – người đang có tin chưa đọc nhắn thêm thì số không tăng (anh báo 03/11).
  // Cách làm: 2 giây/lần xem 15 dòng chat đầu; dòng chưa đọc = có chữ ĐẬM; dòng chưa đọc có DÒNG TIN (chữ thứ 2) mới → báo.
  // 15 giây đầu sau khi mở trang chỉ ghi nhớ, không báo (tránh báo nhầm lúc danh sách vừa tải – 08:19, 08:21 03/11).
  // ĐO: tổng thời gian các vòng dò chạy trên trang, 5 phút ghi 1 lần (kiểm app có làm trang nặng không)
  const ton = {}, tinhTon = (ten, f) => { const t = performance.now(); try { f(); } finally { ton[ten] = (ton[ten] || 0) + performance.now() - t; } };
  let tuLuc = performance.now();
  const ghiTon = () => { guiSwift({ nhatKy: 'ĐO JS ' + ((performance.now() - tuLuc) / 1000).toFixed(0) + 's: ' +
      Object.entries(ton).map(([k, v]) => k + ' ' + v.toFixed(0) + 'ms').join(', ') });
    Object.keys(ton).forEach(k => ton[k] = 0); tuLuc = performance.now(); };
  setTimeout(() => { ghiTon(); setInterval(ghiTon, 300000); }, 60000);   // lần đầu sau 1 phút, rồi 5 phút/lần
  const daBao = new Set();
  const batDau = Date.now();
  const laGio = t => /^(\\d+\\s*(giây|phút|giờ|ngày|tuần|tháng|năm|[smhdwy])(\\s*(trước|ago))?|vừa xong|just now|\\d+\\s*thg\\s*\\d+.*|thứ\\s+\\S+|th\\s*\\d|cn)$/i.test(t);
  const laNhan = t => t === '·' || laGio(t) || /^(đang hoạt động|active now)$/i.test(t);
  // Đọc từng ĐOẠN CHỮ THẬT trong dòng (text node) + độ đậm của chỗ chứa nó. Dò 03/11 09:19: tên / tin của dòng nhóm nằm
  // trong phần tử có con (emoji, chữ lồng) → cách cũ "span không có con" bỏ sót cả dòng → tin nhóm không báo.
  const doanChu = r => { const w = document.createTreeWalker(r, NodeFilter.SHOW_TEXT), ds = []; let n;
    while ((n = w.nextNode())) { const t = n.textContent.trim(); if (t && n.parentElement) ds.push({ t, dam: parseInt(getComputedStyle(n.parentElement).fontWeight) >= 600 }); }
    return ds; };
  const dongChuaDoc = () => [...document.querySelectorAll('[role="row"]')].slice(0, 15).map(r => {
    const a = r.querySelector('a[href*="/t/"]'); if (!a) return null;
    const ds = doanChu(r).filter(d => !laNhan(d.t));
    if (!ds.some(d => d.dam)) return null;
    // Tên chat = dòng đầu của chữ trong link; tin = phần còn lại (nhóm: «Người gửi: nội dung»), bỏ chữ giờ / nhãn
    const dong = (a.innerText || '').split('\\n').map(t => t.trim()).filter(t => t && !laNhan(t));
    const ten = dong[0] || (ds[0] && ds[0].t) || 'iMessenger';
    const tin = (dong.length > 1 ? dong.slice(1) : ds.slice(1).map(d => d.t)).join(' ').replace(/:\\s+/, ': ').trim();
    return { a, ten, tin: tin || 'Tin nhắn mới', khoa: a.getAttribute('href') + '|' + tin };
  }).filter(Boolean);
  // Anh đang nhìn app → NGHỈ (không quét, đỡ nặng – anh báo chậm 03/11); vừa rời app → quét 1 lượt chỉ để ghi nhớ.
  let vuaNhin = true;
  setInterval(() => tinhTon('dòng', () => {
    if (/groupcall/.test(location.pathname)) return;
    if (!document.hidden && document.hasFocus()) { vuaNhin = true; return; }
    const ds = dongChuaDoc(); let moi = ds.filter(d => !daBao.has(d.khoa));
    moi.forEach(d => daBao.add(d.khoa));
    if (vuaNhin) { vuaNhin = false; return; }
    if (Date.now() - batDau < 15000 || !moi.length) return;
    // Cài đặt (Swift gửi window.__vmCaiDat): tắt báo tin → im; đang/vừa có bảng gọi (8 giây) → bỏ tin "đã bắt đầu / kết thúc
    // cuộc gọi" (trùng bảng gọi, dò 09:33 có 5–6 thông báo), vẫn giữ "cuộc gọi nhỡ"
    const cd = window.__vmCaiDat || {};
    if (cd.baoTinNhan === false) return;
    if (cd.boTinGoi !== false && Date.now() - (window.__vmGoiLuc || 0) < 8000)
      moi = moi.filter(d => !/cuộc gọi|gọi video|gọi thoại|\\bcall/i.test(d.tin) || /nhỡ|bỏ lỡ|missed/i.test(d.tin));
    if (!moi.length) { guiSwift({ nhatKy: 'DÒ TB: bỏ thông báo tin về cuộc gọi (đang có bảng gọi)' }); return; }
    moi.slice(0, 3).forEach(d => {
      const tb = new ThongBao(d.ten, { body: d.tin, tag: d.a.getAttribute('href') });
      tb.onclick = () => d.a.click();
    });
    guiSwift({ nhatKy: 'TB tự tạo: ' + moi.length + ' tin mới' });
  }), 2000);

  // VM_NHIP: 20 giây/lần ghi "trang còn chạy" kèm độ trễ hẹn giờ (kiểm Safari có hãm trang ẩn không)
  if (window.__vmNhip) { let truoc = Date.now(); setInterval(() => { const bay = Date.now();
    guiSwift({ nhatKy: 'NHỊP trang ' + document.visibilityState + ', trễ ' + (bay - truoc - 20000) + 'ms, đường=' + location.pathname.replace(/[0-9]{5,}/g, 'N') +
      ', dòng=' + document.querySelectorAll('[role="row"]').length + ', dòngChat=' + document.querySelectorAll('a[href*="/t/"]').length +
      ', ds=' + !!document.querySelector('[role="navigation"][aria-label="Danh sách cuộc trò chuyện"]') }); truoc = bay; }, 20000); }

  // Swift gọi hàm này khi anh bấm vào thông báo
  window.__vmBamThongBao = function (id) {
    const tb = danhSach[id];
    if (tb && tb.onclick) tb.onclick({ target: tb, currentTarget: tb, preventDefault() {} });
  };

  // Số chưa đọc: messenger.com KHÔNG ghi số vào tiêu đề, mà gắn nhãn cho nút "Đoạn chat":
  //   aria-label = "Đoạn chat · 5 tin nhắn chưa đọc"  (tiếng Anh: "Chats · 5 unread …"), hết tin → "Đoạn chat"
  // 3 giây đọc 1 lần, chỉ báo Swift khi số thay đổi.
  let soCu = -1;
  setInterval(() => tinhTon('số chưa đọc', () => {
    let so = 0;
    document.querySelectorAll('[aria-label^="Đoạn chat"], [aria-label^="Chats"]').forEach(e => {
      const m = e.getAttribute('aria-label').match(/^(?:Đoạn chat|Chats)\\s*·\\s*(\\d+)/);
      if (m) so = Math.max(so, parseInt(m[1], 10));
    });
    if (so !== soCu) {
      soCu = so; guiSwift({ soChuaDoc: so });
    }
  }), 3000);

  // Esc trong ô "Tìm kiếm trên Messenger": Messenger chỉ đóng gợi ý, chữ vẫn còn + con trỏ kẹt trong ô
  // → xoá chữ (nút "Xóa nội dung tìm kiếm") rồi thoát ô, về lại danh sách chat.
  document.addEventListener('keydown', (e) => {
    const o = document.activeElement;
    if (e.key !== 'Escape' || !o || o.getAttribute('aria-label') !== 'Tìm kiếm trên Messenger') return;
    window.__vmTabTinNhan = false;
    const xoa = document.querySelector('[aria-label="Xóa nội dung tìm kiếm"]');
    if (xoa) xoa.click();
    setTimeout(() => o.blur(), 50);
  }, true);

  // Cmd+Shift+F bật __vmTabTinNhan: mỗi lần gõ chữ trong ô tìm chung → tự chọn tab "Tin nhắn"
  // (tab chỉ hiện khi ô có chữ). Chỉ nhận tab nằm ngay dưới ô tìm, tránh nhầm chữ "Tin nhắn" chỗ khác.
  const oTimChung = () => document.querySelector('input[aria-label="Tìm kiếm trên Messenger"], input[aria-label="Search Messenger"]');
  const tabTinNhan = () => {
    const o = oTimChung(); if (!o) return null;
    const day = o.getBoundingClientRect().bottom;
    return [...document.querySelectorAll('[role="tab"], [role="button"], [role="link"], [role="radio"]')].find(e => {
      if (e.offsetParent === null || !/^(Tin nhắn|Messages)$/.test(e.textContent.trim())) return false;
      const t = e.getBoundingClientRect().top; return t >= day - 5 && t <= day + 150;
    }) || null;
  };
  const daChon = (e) => ['aria-selected', 'aria-checked', 'aria-pressed', 'aria-current'].some(a => e.getAttribute(a) === 'true' || e.getAttribute(a) === 'page');
  let henTab = null;
  window.__vmChonTabTinNhan = () => {
    clearInterval(henTab);
    let lan = 0;
    henTab = setInterval(() => {                      // chờ tối đa 3 giây cho kết quả + tab hiện ra
      const o = oTimChung(), t = tabTinNhan();
      if (++lan > 30 || !o || !o.value) { clearInterval(henTab); return; }
      if (!t) return;
      clearInterval(henTab);
      if (!daChon(t)) { t.click(); setTimeout(() => { const i = oTimChung(); if (i && document.activeElement !== i) i.focus(); }, 50); }
      const truoc = daChon(t);
      setTimeout(() => { const t2 = tabTinNhan(); guiSwift({ nhatKy: 'tab Tin nhắn: ' + (truoc ? 'đã chọn sẵn' : 'đã bấm') + ' | sau đó chọn=' + (t2 ? daChon(t2) : '-') + ' | thuộc tính=' + (t2 ? [...t2.attributes].map(a => a.name + '=' + a.value).filter(x => x.startsWith('aria') || x.startsWith('tab')).join(',') : '-') }); }, 400);
    }, 100);
  };
  document.addEventListener('input', (e) => {
    if (window.__vmTabTinNhan && e.target === oTimChung()) window.__vmChonTabTinNhan();
  }, true);

  // Dò nhạc chuông: ghi tên file âm thanh trang phát (mỗi file 1 lần, bỏ phần sau "?")
  const lanPhat = {};   // tên âm thanh → các lần phát gần đây
  // Cuộc gọi đến lúc anh không nhìn app → thông báo + Dock nảy liên tục (Swift: goiDen) – Messenger chỉ phát chuông
  let lanBaoGoi = 0;
  const baoGoiDen = (nguon) => {
    if (!(document.hidden || !document.hasFocus()) || Date.now() - lanBaoGoi < 30000) return;
    lanBaoGoi = Date.now();
    guiSwift({ goiDen: nguon });   // Dock nảy; bảng "Cuộc gọi đến" do đoạn dò hộp bên dưới gửi
  };
  const amDangPhat = new Set();   // âm thanh trang chính đang phát (để tắt chuông còn sót khi hộp gọi đến đóng)
  const phatGoc = HTMLMediaElement.prototype.play;
  HTMLMediaElement.prototype.play = function () {
    if (this.tagName === 'AUDIO' && !/groupcall/.test(location.pathname) && !amDangPhat.has(this)) {
      amDangPhat.add(this);
      const ten = String(this.currentSrc || this.src || '').split('?')[0].split('/').pop();
      this.addEventListener('pause', () => { amDangPhat.delete(this); guiSwift({ nhatKy: 'DÒ TB: âm ' + ten + ' dừng (trang gọi pause)' }); }, { once: true });
      this.addEventListener('ended', () => { amDangPhat.delete(this); }, { once: true });
    }
    const ten = String(this.currentSrc || this.src || '').split('?')[0].split('/').pop() || '(luồng)';
    // Chuông gọi đến ở trang chat chính = taJw7SpZVz2.mp3 (dò cuộc gọi thật 03/11 08:56, 09:00).
    // XFhtdTsftOC.ogg là tiếng "ting" TIN NHẮN (kể cả tin "cuộc gọi nhỡ") → KHÔNG phải chuông, không làm Dock nảy (anh dặn 03/11).
    // Tên file có thể đổi khi Facebook cập nhật → nhận thêm âm phát lặp (loop); hộp gọi đến vẫn làm Dock nảy riêng.
    // Trang cuộc gọi đi (/groupcall/) cũng phát tút → bỏ qua.
    if (this.tagName === 'AUDIO' && !/groupcall/.test(location.pathname)) {
      const bay = Date.now(), ds = (lanPhat[ten] = (lanPhat[ten] || []).filter(t => bay - t < 8000).concat(bay));
      const laChuong = /taJw7SpZVz2/.test(ten) || this.loop;
      // Dò thêm: lúc phát, trang có nút nào về cuộc gọi (chỉ ghi nhãn nút ngắn, không ghi tên người)
      const nutGoi = [...document.querySelectorAll('[aria-label]')].map(e => e.getAttribute('aria-label'))
        .filter(t => t.length <= 30 && /chấp nhận|từ chối|trả lời|bỏ qua|tham gia|accept|decline|answer|ignore|join|gọi lại|cuộc gọi/i.test(t));
      guiSwift({ nhatKy: 'DÒ TB: phát âm thanh ' + ten + ' lần ' + ds.length + ', trang ' + document.visibilityState + ', hasFocus=' + document.hasFocus() + ', chuông=' + laChuong + ', nút=' + JSON.stringify([...new Set(nutGoi)].slice(0, 8)) });
      if (laChuong) baoGoiDen('chuông');
    }
    return phatGoc.apply(this, arguments);
  };

  // Dò cuộc gọi đến: 1 giây/lần tìm hộp thoại có nút Chấp nhận/Từ chối → ghi nhãn các nút (không ghi tên người)
  // Hộp "Cuộc gọi đến" của Messenger (dò 03/11: role=dialog, nút aria-label "Từ chối" / "Chấp nhận")
  // → gửi chữ "X đang gọi cho bạn" + ảnh đại diện cho Swift hiện BẢNG NỔI ở góc màn hình (anh chọn cách B, 03/11).
  // Không ghi tên vào nhật ký. Hộp biến mất (người kia gác / đã bấm) → báo Swift ẩn bảng.
  const nutGoiDen = (nhan) => [...document.querySelectorAll('[role="dialog"] [aria-label], [role="alertdialog"] [aria-label]')]
    .find(e => e.getAttribute('aria-label') === nhan);
  // Tên nhóm của cuộc gọi nhóm: trong 6 dòng chat đầu, dòng có NHIỀU ảnh đại diện (ảnh nhóm = 2 ảnh chồng) hoặc tên có dấu phẩy
  // (nhóm chưa đặt tên → "Tên A, Tên B"), ưu tiên dòng có tên người gọi / tin về cuộc gọi. Không chắc → để trống.
  const tenNhomGoi = (nguoiGoi) => {
    const dau = (nguoiGoi.split(/\\s+/)[0] || '').toLowerCase();
    const ung = [...document.querySelectorAll('[role="row"]')].slice(0, 6).map((r, i) => {
      const a = r.querySelector('a[href*="/t/"]'); if (!a) return null;
      const dg = (a.innerText || '').split('\\n').map(t => t.trim()).filter(t => t && !laNhan(t));
      const ten = dg[0] || '', tin = dg.slice(1).join(' ');
      const nhom = r.querySelectorAll('img, image').length >= 2 || ten.includes(',');
      if (!nhom || !ten) return null;
      const diem = (dau && ten.toLowerCase().includes(dau) ? 2 : 0) + (dau && tin.toLowerCase().includes(dau) ? 1 : 0) +
                   (/gọi|call/i.test(tin) ? 2 : 0) - i * 0.1;
      return { ten, diem };
    }).filter(d => d && d.diem >= 1.5).sort((x, y) => y.diem - x.diem);
    return ung.length ? ung[0].ten : '';
  };
  let hopCu = '', kieuGoi = 'thoai';
  setInterval(() => tinhTon('hộp gọi', () => {
    const nut = nutGoiDen('Chấp nhận') || nutGoiDen('Accept');
    const hop = nut ? nut.closest('[role="dialog"], [role="alertdialog"]') : null;
    if (hop) {
      window.__vmGoiLuc = Date.now();
      const dong = (hop.innerText || '').split('\\n').map(t => t.trim()).filter(Boolean);
      // Gọi 1-1: "X đang gọi cho bạn". Gọi NHÓM (dò 03/11 09:33): "X đã mời bạn tham gia cuộc gọi nhóm" (thoại) /
      // "… tham gia nhóm chat video" (video) – hộp KHÔNG có tên nhóm → lấy tên từ dòng chat nhóm (tenNhomGoi).
      const dongGoi = dong.find(t => /đang gọi|is calling|calling you|đã mời bạn|invited you/i.test(t)) || '';
      const laNhom = /nhóm|group/i.test(dongGoi);
      const nguoiGoi = dongGoi.replace(/\\s*(đang gọi|is calling|đã mời bạn|invited you).*$/i, '').trim();
      const tenNhom = laNhom ? tenNhomGoi(nguoiGoi) : '';
      const chu = laNhom ? (tenNhom || 'Cuộc gọi nhóm') + '\\n' + (nguoiGoi ? nguoiGoi + ' đang gọi' : 'Có người đang gọi')
                         : (dongGoi || 'Có người đang gọi cho bạn');
      const anh = [...hop.querySelectorAll('img, image')].map(x => x.getAttribute('src') || x.getAttribute('xlink:href') || x.getAttribute('href') || '').find(u => /^https?:/.test(u)) || '';
      const khoa = chu + '|' + anh;
      if (khoa !== hopCu) {
        if (!hopCu) {
          // Dò kiểu gọi: chữ trong hộp (che tên người gọi) + hình vẽ trên nút Chấp nhận (đường vẽ đầu, để phân biệt 📞 / 🎥)
          const cheTen = dong.map(t => t.replace(/^.*?(đang gọi|is calling|đã mời bạn|invited you)/i, '… $1'));
          const ve = [...nut.querySelectorAll('path')].map(x => (x.getAttribute('d') || '').slice(0, 24)).join(' | ');
          kieuGoi = /^M9 9\\.5a4 4/.test(ve) ? 'video' : 'thoai';
          guiSwift({ nhatKy: 'DÒ TB: hộp cuộc gọi đến hiện, có ảnh=' + !!anh + ', trang ' + document.visibilityState +
            ', chữ=' + JSON.stringify(cheTen) + ', hìnhNút=' + ve + ' → gọi ' + kieuGoi + (laNhom ? ' NHÓM' : '') });
        }
        if (laNhom) guiSwift({ nhatKy: 'DÒ TB: gọi nhóm – tên nhóm ' + (tenNhom ? 'đã tìm thấy (' + tenNhom.length + ' ký tự)' : 'CHƯA thấy') });
        hopCu = khoa; guiSwift({ goiDenHien: { chu, anh, video: kieuGoi === 'video', nhom: laNhom } });
      }
    } else if (hopCu) {
      hopCu = ''; window.__vmGoiLuc = Date.now(); guiSwift({ goiDenAn: true });
      // Chuông còn kêu sau khi hộp đóng (anh báo 03/11: tắt cuộc gọi rồi vẫn kêu) → chờ 1,5 giây cho trang tự tắt, còn thì tắt hộ
      // (dò 08:56: chuông XFhtdTsftOC còn bắt đầu kêu 0,5s SAU khi hộp đóng → kiểm 3 lần, bỏ qua nếu đã có cuộc gọi mới)
      [1500, 3000, 6000].forEach(ms => setTimeout(() => {
        if (hopCu) return;
        const con = [...amDangPhat].filter(a => !a.paused);
        con.forEach(a => { a.pause(); a.currentTime = 0; });
        if (con.length || ms === 1500) guiSwift({ nhatKy: 'DÒ TB: hộp gọi đến đã đóng ' + ms + 'ms, chuông còn kêu=' + con.length + (con.length ? ' → đã tắt hộ' : '') });
      }, ms));
    }
  }), 700);
  window.__vmBamGoiDen = (nhan) => {
    const e = nutGoiDen(nhan) || nutGoiDen(nhan === 'Chấp nhận' ? 'Accept' : 'Decline');
    if (!e) return 'không thấy nút ' + nhan;
    e.click(); return 'đã bấm ' + nhan;
  };

  // Nhật ký cuộc gọi (chỉ ghi BƯỚC: xin camera/micro/màn hình được hay lỗi, tắt thiết bị, trang ẩn/hiện –
  // không ghi nội dung, hình, tiếng). Xem bằng cách mở app qua `open --stdout`.
  const duongDan = () => location.pathname.replace(/[0-9]{5,}/g, 'N');
  const ghiGoi = (t) => guiSwift({ nhatKy: 'GỌI ' + duongDan() + ' – ' + t });
  const md = navigator.mediaDevices;
  if (md) {
    ['getUserMedia', 'getDisplayMedia'].forEach(ten => {
      if (!md[ten]) { ghiGoi(ten + ' KHÔNG CÓ trong trình duyệt này'); return; }
      const goc = md[ten].bind(md);
      md[ten] = (rb) => {
        const muon = rb ? Object.keys(rb).filter(k => rb[k]).join('+') : '?';
        ghiGoi(ten + ' xin ' + muon);
        return goc(rb).then(lu => {
          ghiGoi(ten + ' ĐƯỢC: ' + lu.getTracks().map(t => t.kind).join('+'));
          lu.getTracks().forEach(t => {
            const dung = t.stop.bind(t);
            t.stop = () => { ghiGoi('tắt ' + t.kind); dung(); };
            t.addEventListener('ended', () => ghiGoi(t.kind + ' kết thúc'));
          });
          return lu;
        }, loi => { ghiGoi(ten + ' LỖI ' + loi.name); throw loi; });
      };
    });
  }
  // Cửa sổ xưng Chrome (userAgentChrome) → khớp thêm navigator.vendor + window.chrome, trang khỏi nghi
  if (/Chrome[/]/.test(navigator.userAgent)) {
    try { Object.defineProperty(Navigator.prototype, 'vendor', { get: () => 'Google Inc.' }); } catch (e) {}
    if (!window.chrome) window.chrome = { runtime: {} };
  }
  ghiGoi('trình duyệt xưng ' + (/Chrome[/]/.test(navigator.userAgent) ? 'Chrome' : 'Safari'));
  if (/call/i.test(location.pathname)) ghiGoi('trang cuộc gọi mở');
  document.addEventListener('visibilitychange', () => { if (/call/i.test(location.pathname)) ghiGoi('trang ' + document.visibilityState); });

  // Một số trang hỏi quyền qua navigator.permissions → trả lời "granted"
  if (navigator.permissions && navigator.permissions.query) {
    const hoiGoc = navigator.permissions.query.bind(navigator.permissions);
    navigator.permissions.query = (q) => (q && q.name === 'notifications')
      ? Promise.resolve({ state: 'granted', status: 'granted', onchange: null })
      : hoiGoc(q);
  }
})();
"""

// MARK: Phóng to / thu nhỏ mượt hơn
// Bấm đúp thanh tiêu đề → macOS đổi cỡ cửa sổ dần trong ~0,2 giây; mỗi khung hình Messenger (trang rất nặng)
// phải dàn trang lại → hụt khung, thấy khựng. Đo 02/11 (VM_ZOOM=1, 6 lần bấm, ngưỡng 17ms): gốc hụt 9 khung,
// chậm nhất 42ms; hiệu ứng 0,1s hụt 8, 38ms; "ảnh che" (chụp ảnh trang đè lên) chậm nhất 287ms → đã bỏ.
// Cho anh chọn trong menu Cửa sổ → Hiệu ứng phóng to (lưu UserDefaults "hieuUngPhongTo"):
//   "macdinh" = của macOS · "nhanh" = 0,1s · "tat" = đổi cỡ tức thì, trang chỉ dàn lại 1 lần.
let kieuHieuUng: [(ma: String, ten: String, thoiGian: TimeInterval?)] = [
    ("macdinh", "Mặc định của macOS", nil),
    ("nhanh", "Nhanh (0,1 giây)", 0.1),
    ("tat", "Tắt – đổi cỡ tức thì", 0),
]
let hieuUngMacDinh = "tat"

final class CuaSoChinh: NSWindow {
    var thoiGianHieuUng: TimeInterval? {          // nil = mặc định của macOS
        if let s = ProcessInfo.processInfo.environment["VM_ZOOM_TG"], let t = Double(s) { return t }   // để đo thử
        let ma = UserDefaults.standard.string(forKey: "hieuUngPhongTo") ?? hieuUngMacDinh
        return kieuHieuUng.first { $0.ma == ma }?.thoiGian ?? nil
    }

    override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval {
        thoiGianHieuUng ?? super.animationResizeTime(newFrame)
    }

    // Phím chia cửa sổ của macOS trên máy anh = Ctrl+Opt + mũi tên (đọc từ menu Move & Resize, 03/11).
    // macOS hỏi khung trang (WKWebView) TRƯỚC menu; WebKit giữ Ctrl/Opt + ↑/↓ làm lệnh cuộn/di con trỏ
    // → Top/Bottom không chạy, ←/→ thì chạy. Với Ctrl + mũi tên (không Cmd): cho menu xử lý trước.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let phim = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let muiTen: Set<UInt16> = [123, 124, 125, 126]           // ← → ↓ ↑
        if muiTen.contains(event.keyCode), phim.contains(.control), !phim.contains(.command),
           NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate,
                         WKScriptMessageHandler, UNUserNotificationCenterDelegate, WKHTTPCookieStoreObserver,
                         NSWindowDelegate, WKDownloadDelegate {
    var window: NSWindow!
    var webView: WKWebView!
    var cuaSoPhu: [NSWindow] = []   // cửa sổ bật lên (vd. cuộc gọi video)
    var webCuaThongBao: [String: WKWebView] = [:]   // id thông báo → trang đã tạo nó
    var daDoTim = false                             // chế độ dò VM_TIM chỉ chạy 1 lần mỗi lần mở app
    var bangPhim: NSWindow?                         // cửa sổ bảng phím tắt
    var oKhongHien: NSButton?                        // ô "Không hiện bảng này khi mở app"
    var cuaSoCaiDat: NSWindow?                       // cửa sổ Cài đặt (⌘,)
    var trangCaiDat: NSView?
    var oTrangThaiCN: NSTextField?                   // dòng trạng thái cập nhật trong Cài đặt
    var giuHanhDong: [HanhDong] = []                 // giữ các hàm xử lý công tắc trong Cài đặt
    var chongNgu: NSObjectProtocol?                  // giữ app không bị App Nap
    var goiDen: (chu: String, anh: String, video: Bool, nhom: Bool)?
    var choLuu: [() -> Void] = []                            // hộp "Lưu vào đâu" đang chờ (tải nhiều file cùng lúc)          // hộp "Cuộc gọi đến" đang hiện trên trang
    var bangGoi: BangGoiDen?                         // bảng nổi báo cuộc gọi đến
    var taiVe: [ObjectIdentifier: URL] = [:]       // file đang tải → nơi lưu
    var dangTai: [WKDownload] = []                  // giữ lượt tải (không giữ → bị huỷ giữa chừng, thử 03/11)
    var pip: [ObjectIdentifier: TrangThaiPiP] = [:]  // cửa sổ cuộc gọi → trạng thái PiP

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Không cho macOS cho app "ngủ trưa" (App Nap) khi cửa sổ bị che / ẩn – cùng lý do như trên
        chongNgu = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                                                          reason: "Nhận tin nhắn và cuộc gọi Messenger khi chạy ngầm")
        NSWindow.allowsAutomaticWindowTabbing = false   // không cần tab → bỏ các mục Tab thừa trong menu Cửa sổ
        taoMenu()
        // Đang gọi mà anh chuyển sang app khác → thu cửa sổ cuộc gọi thành PiP
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.tuDongPiP()
            self?.capNhatBangGoi()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.capNhatBangGoi()
        }
        if ["2", "3"].contains(ProcessInfo.processInfo.environment["VM_PIP"] ?? "") { DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.thuPiP2() } }
        // Mỗi lần mở app → hiện bảng phím tắt, trừ khi anh đã tích "Không hiện bảng này khi mở app" (anh chọn cách 1, 03/11)
        batLichCapNhat()
        if !UserDefaults.standard.bool(forKey: "khongHienPhimTat") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.moBangPhim() }
        }
        if ProcessInfo.processInfo.environment["VM_PIP"] == "1" { DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.thuPiP() } }
        // …hoặc bấm sang cửa sổ khác của app (vd. cửa sổ chat để nhắn người khác) → cũng thu PiP
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, let w = n.object as? NSWindow, !self.cuaSoPhu.contains(where: { $0 == w && self.laCuocGoi(w) }) else { return }
            self.tuDongPiP()
        }
        // Đổi cửa sổ đang chọn (chat ↔ cuộc gọi / PiP / bảng phím tắt) → xét lại bảng "Cuộc gọi đến"
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
            self?.capNhatBangGoi()
        }
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { _ in
            NSLog("VM: ĐO nhiệt máy đổi → %@", AppDelegate.tenNhiet())
        }

        // Xin quyền gửi thông báo (macOS chỉ hỏi 1 lần đầu)
        let trungTam = UNUserNotificationCenter.current()
        trungTam.delegate = self
        trungTam.requestAuthorization(options: [.alert, .sound, .badge]) { ok, loi in
            NSLog("VM: quyền thông báo = %@ %@", ok ? "có" : "không", loi?.localizedDescription ?? "")
            trungTam.getNotificationSettings { c in
                let kieu = [UNAlertStyle.none: "KHÔNG HIỆN", .banner: "biểu ngữ", .alert: "cảnh báo (ở lại)"][c.alertStyle] ?? "?"
                NSLog("VM: cài đặt thông báo macOS – kiểu=%@, âm thanh=%@, trung tâm thông báo=%@", kieu,
                      c.soundSetting == .enabled ? "bật" : "tắt", c.notificationCenterSetting == .enabled ? "bật" : "tắt")
            }
        }

        // Cấu hình nhân Safari
        let cauHinh = WKWebViewConfiguration()
        cauHinh.websiteDataStore = .default()          // lưu cookie lên ổ → giữ đăng nhập
        cauHinh.preferences.isElementFullscreenEnabled = true
        cauHinh.preferences.javaScriptCanOpenWindowsAutomatically = true   // bấm "Chấp nhận" từ bảng nổi → trang mở cửa sổ gọi
        // App chạy ngầm vẫn phải nghe tin nhắn / cuộc gọi: tắt kiểu Safari hãm trang bị ẩn (hẹn giờ JS chậm lại, nhân web
        // bị "ngủ") – không tắt thì ~1 phút sau khi ẩn app, tin + cuộc gọi đến không có thông báo (anh báo 03/11).
        // KVC dùng tên KHÔNG có "_" (tự tìm hàm _setXxx:) – tên có "_" làm hỏng cả lúc khởi động (trang không tải, 03/11)
        for k in ["hiddenPageDOMTimerThrottlingEnabled", "pageVisibilityBasedProcessSuppressionEnabled"] {
            let ham = "_set" + k.prefix(1).uppercased() + k.dropFirst() + ":"
            if cauHinh.preferences.responds(to: NSSelectorFromString(ham)) { cauHinh.preferences.setValue(false, forKey: k) }
            else { NSLog("VM: không có %@ – bỏ qua", ham) }
        }
        // Gắn "Notification giả" + cầu nối JS → Swift
        if ProcessInfo.processInfo.environment["VM_NHIP"] == "1" {   // chế độ thử: bật nhịp tim trước script chính
            cauHinh.userContentController.addUserScript(WKUserScript(source: "window.__vmNhip = true;", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        cauHinh.userContentController.addUserScript(
            WKUserScript(source: jsCaiDat(), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        cauHinh.userContentController.addUserScript(
            WKUserScript(source: jsThongBao, injectionTime: .atDocumentStart, forMainFrameOnly: true))

        cauHinh.userContentController.add(self, name: "vmThongBao")
        // Giữ đăng nhập: theo dõi cookie để đổi cookie phiên thành cookie 1 năm
        cauHinh.websiteDataStore.httpCookieStore.add(self)

        webView = WKWebView(frame: .zero, configuration: cauHinh)
        webView.customUserAgent = userAgentSafari
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsMagnification = true             // phóng to bằng 2 ngón
        webView.isInspectable = true                   // cho phép DevTools (chuột phải → Kiểm tra phần tử)
        webView.configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")

        // Cửa sổ chính 1200×800 (giống bản gốc), nhớ vị trí/cỡ giữa các lần mở
        window = CuaSoChinh(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = tenApp
        // Cao tối thiểu 400 (không phải 600): chia 4 góc màn hình mỗi ô chỉ cao ~530px
        window.minSize = NSSize(width: 400, height: 400)
        window.isReleasedWhenClosed = false            // bấm đỏ chỉ ẩn, không thoát app
        window.contentView = webView
        window.center()
        window.setFrameAutosaveName("CuaSoChinh")
        window.makeKeyAndOrderFront(nil)

        webView.load(URLRequest(url: trangChu))
        // Số chưa đọc trên Dock: đoạn JS trong jsThongBao đọc nhãn nút "Đoạn chat" rồi gửi { soChuaDoc } sang đây
    }

    // MARK: Giữ đăng nhập (lớp dự phòng)
    // Đã kiểm 02/11: Facebook thường tự cấp c_user/xs hạn 1 năm. Phòng khi nó cấp dạng "cookie phiên"
    // (chỉ nằm trong RAM, tắt app là mất) thì làm như bản gốc (main.js dòng 225–246): ghi lại với hạn 1 năm.
    // Không ghi giá trị cookie ra log.
    func cookiesDidChange(in store: WKHTTPCookieStore) {
        store.getAllCookies { ds in
            for c in ds where c.isSessionOnly {
                guard let u = URL(string: "https://" + c.domain.trimmingCharacters(in: ["."])), laTrongApp(u) else { continue }
                guard var p = c.properties else { continue }
                p.removeValue(forKey: .discard)
                p[.expires] = Date().addingTimeInterval(365 * 24 * 3600)
                if let moi = HTTPCookie(properties: p) {
                    store.setCookie(moi)
                    NSLog("VM: giữ đăng nhập – cookie %@ (%@) → hạn 1 năm", c.name, c.domain)
                }
            }
        }
    }

    // MARK: Thông báo – nhận từ JS, hiện bằng macOS

    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let d = message.body as? [String: Any] else { return }
        if let nk = d["nhatKy"] as? String { if ghiGoLoi || !nk.hasPrefix("DÒ") { NSLog("VM: %@", nk) }; return }
        if let g = d["goiDenHien"] as? [String: Any], message.webView == webView {
            if goiDen == nil, !NSApp.isActive, caiDat("dockNayGoi", true) { NSApp.requestUserAttention(.criticalRequest) }   // chỉ cuộc gọi mới nảy Dock
            goiDen = (g["chu"] as? String ?? "Có người đang gọi cho bạn", g["anh"] as? String ?? "", g["video"] as? Bool ?? false, g["nhom"] as? Bool ?? false); capNhatBangGoi(); return
        }
        if d["goiDenAn"] != nil, message.webView == webView { goiDen = nil; capNhatBangGoi(); return }
        if let ng = d["goiDen"] as? String {
            NSLog("VM: TB cuộc gọi đến (%@)%@", ng, caiDat("dockNayGoi", true) ? " → Dock nảy" : "")
            if caiDat("dockNayGoi", true) { NSApp.requestUserAttention(.criticalRequest) }
            return
        }
        if let so = d["soChuaDoc"] as? Int, message.webView == webView {
            NSLog("VM: số chưa đọc = %d", so)
            NSApp.dockTile.badgeLabel = so > 0 ? String(so) : nil
            return
        }
        if let id = d["dong"] as? String {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id]); return
        }
        guard let id = d["id"] as? String else { return }
        webCuaThongBao[id] = message.webView

        let nd = UNMutableNotificationContent()
        nd.title = d["tieuDe"] as? String ?? tenApp
        nd.body = d["noiDung"] as? String ?? ""
        nd.sound = .default
        if let tag = d["tag"] as? String, !tag.isEmpty { nd.threadIdentifier = tag }   // gom theo cuộc trò chuyện
        NSLog("VM: thông báo mới (không ghi nội dung)")
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: nd, trigger: nil)) { loi in
            if let loi { NSLog("VM: lỗi gửi thông báo %@", loi.localizedDescription) }
        }
    }

    // App đang mở ở trước vẫn hiện thông báo (giống Messenger chính chủ)
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler xong: @escaping (UNNotificationPresentationOptions) -> Void) {
        xong([.banner, .sound, .list])
    }

    // Anh bấm vào thông báo → đưa cửa sổ lên + báo cho trang để nó mở đúng cuộc trò chuyện
    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse,
                                withCompletionHandler xong: @escaping () -> Void) {
        let id = r.notification.request.identifier
        DispatchQueue.main.async {
            let wv = self.webCuaThongBao.removeValue(forKey: id) ?? self.webView!
            NSApp.activate(ignoringOtherApps: true)
            wv.window?.makeKeyAndOrderFront(nil)
            wv.evaluateJavaScript("window.__vmBamThongBao && window.__vmBamThongBao('\(id)')")
            xong()
        }
    }

    // Bấm biểu tượng ở Dock khi cửa sổ đang ẩn → hiện lại
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Đang có cuộc gọi thu nhỏ / bị ẩn → bấm Dock là mở lại cỡ thường
        let goi = cuaSoPhu.filter { pip[ObjectIdentifier($0)]?.dangPiP == true }
        if !goi.isEmpty { goi.forEach { raPiP($0, giuTruoc: true) }; return true }
        if !flag { window.makeKeyAndOrderFront(nil) }
        return true
    }

    // MARK: Điều hướng – link trong app hay mở ra trình duyệt

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.shouldPerformDownload { return decisionHandler(.download) }   // <a download>, blob, "Tải ảnh xuống"
        guard let url = action.request.url, action.targetFrame?.isMainFrame != false else {
            return decisionHandler(.allow)             // khung con (iframe) → để trang tự lo
        }
        if let that = linkThat(url) {
            NSWorkspace.shared.open(that); return decisionHandler(.cancel)
        }
        if laTrongApp(url) { decisionHandler(.allow) }
        else { NSWorkspace.shared.open(url); decisionHandler(.cancel) }
    }

    // MARK: Tải file / lưu ảnh → thư mục Tải về (nhân Safari KHÔNG tự tải như Chrome của bản gốc)
    // Phản hồi là file đính kèm hoặc loại trang không hiển thị được → tải về thay vì mở
    func webView(_ webView: WKWebView, decidePolicyFor r: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let dinhKem = ((r.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? "").lowercased().hasPrefix("attachment")
        decisionHandler(dinhKem || !r.canShowMIMEType ? .download : .allow)
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome d: WKDownload) { d.delegate = self; dangTai.append(d) }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome d: WKDownload) { d.delegate = self; dangTai.append(d) }

    func download(_ d: WKDownload, decideDestinationUsing r: URLResponse, suggestedFilename ten: String,
                  completionHandler: @escaping (URL?) -> Void) {
        // Hỏi lưu vào đâu (anh xin 03/11 – trước tự lưu vào Tải về). Mở sẵn thư mục lưu lần trước (lần đầu: Tải về),
        // tên file gợi ý không trùng ("ảnh (1).jpg"). Huỷ → không tải.
        let u = r.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        NSLog("VM: TẢI nguồn %@, stp=%@, loại=%@, %lld byte", u?.host ?? "?", u?.queryItems?.first { $0.name == "stp" }?.value ?? "(không)",
              r.mimeType ?? "?", r.expectedContentLength)
        // Chế độ thử VM_TAI_TU=<thư mục>: lưu thẳng, không hỏi
        if let tu = ProcessInfo.processInfo.environment["VM_TAI_TU"] {
            let dich = URL(fileURLWithPath: tu).appendingPathComponent(ten.isEmpty ? "tep" : ten)
            try? FileManager.default.removeItem(at: dich); taiVe[ObjectIdentifier(d)] = dich
            if !dangTai.contains(d) { dangTai.append(d) }
            completionHandler(dich); return
        }
        let tai = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let thuMuc = UserDefaults.standard.url(forKey: "thuMucLuu").flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? tai
        let goc = (ten.isEmpty ? "tep-messenger" : ten) as NSString
        var tenGoiY = goc as String, i = 1
        while FileManager.default.fileExists(atPath: thuMuc.appendingPathComponent(tenGoiY).path) {
            let duoi = goc.pathExtension.isEmpty ? "" : "." + goc.pathExtension
            tenGoiY = "\(goc.deletingPathExtension) (\(i))\(duoi)"; i += 1
        }
        if UserDefaults.standard.string(forKey: "noiLuu") == "thang" {     // Cài đặt → Tải file → Luôn lưu vào thư mục
            let dich = thuMuc.appendingPathComponent(tenGoiY)
            taiVe[ObjectIdentifier(d)] = dich
            if !dangTai.contains(d) { dangTai.append(d) }
            NSLog("VM: TẢI bắt đầu (lưu thẳng) → %@/%@", thuMuc.lastPathComponent, tenGoiY)
            completionHandler(dich); return
        }
        let hop = NSSavePanel()
        hop.directoryURL = thuMuc
        hop.nameFieldStringValue = tenGoiY
        hop.canCreateDirectories = true
        hop.message = "Lưu file từ \(tenApp)"
        if !dangTai.contains(d) { dangTai.append(d) }
        let xong: (NSApplication.ModalResponse) -> Void = { [weak self] kq in
            defer { self?.moHopLuuTiep() }                       // tải nhiều file cùng lúc → hộp sau hiện khi hộp trước đóng
            guard kq == .OK, let dich = hop.url else {
                NSLog("VM: TẢI huỷ (anh bấm Huỷ)"); self?.dangTai.removeAll { $0 == d }; completionHandler(nil); return
            }
            UserDefaults.standard.set(dich.deletingLastPathComponent(), forKey: "thuMucLuu")
            try? FileManager.default.removeItem(at: dich)          // anh đã đồng ý ghi đè trong hộp lưu
            self?.taiVe[ObjectIdentifier(d)] = dich
            NSLog("VM: TẢI bắt đầu → %@/%@", dich.deletingLastPathComponent().lastPathComponent, dich.lastPathComponent)
            completionHandler(dich)
        }
        choLuu.append { [weak self] in
            NSApp.activate()
            if let w = self?.window, w.isVisible, !w.isMiniaturized { hop.beginSheetModal(for: w, completionHandler: xong) }
            else { xong(hop.runModal()) }
        }
        if choLuu.count == 1 { choLuu[0]() }
    }
    // Hàng chờ hộp lưu: phần tử đầu = hộp đang mở
    func moHopLuuTiep() {
        if !choLuu.isEmpty { choLuu.removeFirst() }
        if let tiep = choLuu.first { DispatchQueue.main.async { tiep() } }
    }
    func downloadDidFinish(_ d: WKDownload) {
        dangTai.removeAll { $0 == d }
        guard let dich = taiVe.removeValue(forKey: ObjectIdentifier(d)) else { return }
        let co = NSImageRep(contentsOf: dich).map { " – ảnh \($0.pixelsWide)×\($0.pixelsHigh) px" } ?? ""
        let kb = ((try? FileManager.default.attributesOfItem(atPath: dich.path)[.size] as? Int) ?? 0) / 1024
        NSLog("VM: TẢI xong %@ (%d KB)%@", dich.lastPathComponent, kb, co)
        // Ngăn "Tải về" trên Dock nảy lên (như Safari/Chrome tải xong)
        DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: dich.path)
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }
    func download(_ d: WKDownload, didFailWithError loi: Error, resumeData: Data?) {
        dangTai.removeAll { $0 == d }
        let ten = taiVe.removeValue(forKey: ObjectIdentifier(d))?.lastPathComponent ?? "?"
        NSLog("VM: TẢI lỗi %@ – %@", ten, loi.localizedDescription)
        // Anh bấm Hủy ở hộp lưu → WebKit báo "cancelled" → im lặng (anh dặn 03/11: Hủy thì thoát, không hiện bảng)
        if (loi as NSError).code == NSURLErrorCancelled || ten == "?" { return }
        let a = NSAlert(); a.messageText = "Không tải được \(ten)"; a.informativeText = loi.localizedDescription
        if let w = NSApp.keyWindow ?? window { a.beginSheetModal(for: w) } else { a.runModal() }
    }

    // MARK: Hộp hỏi của trang (alert / confirm / prompt) – thiếu thì trang coi như anh bấm "Huỷ"
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage m: String, initiatedByFrame f: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        let a = NSAlert(); a.messageText = m; a.addButton(withTitle: "OK")
        hienHop(a, webView) { _ in completionHandler() }
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage m: String, initiatedByFrame f: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let a = NSAlert(); a.messageText = m; a.addButton(withTitle: "OK"); a.addButton(withTitle: "Huỷ")
        hienHop(a, webView) { completionHandler($0 == .alertFirstButtonReturn) }
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt m: String, defaultText chu: String?,
                 initiatedByFrame f: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let a = NSAlert(); a.messageText = m; a.addButton(withTitle: "OK"); a.addButton(withTitle: "Huỷ")
        let o = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24)); o.stringValue = chu ?? ""
        a.accessoryView = o; a.window.initialFirstResponder = o
        hienHop(a, webView) { completionHandler($0 == .alertFirstButtonReturn ? o.stringValue : nil) }
    }
    func hienHop(_ a: NSAlert, _ wv: WKWebView, _ xong: @escaping (NSApplication.ModalResponse) -> Void) {
        NSLog("VM: HỘP trang hỏi (%d nút)", a.buttons.count)
        if let w = wv.window { a.beginSheetModal(for: w, completionHandler: xong) } else { xong(a.runModal()) }
    }

    // Nhật ký tải trang (xem bằng: log show --last 5m --predicate 'process == "iMessenger"')
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Chỉ ghi tên miền + đường dẫn (bỏ phần sau "?" – link cuộc gọi chứa mã tài khoản)
        let duong = (webView.url?.host ?? "?") + (webView.url?.path ?? "").replacingOccurrences(of: "[0-9]{5,}", with: "N", options: .regularExpression)
        NSLog("VM: tải xong %@ – %@", duong, webView.title ?? "")
        if webView.url?.path.contains("/groupcall/") == true, let w = webView.window, w != window {
            if pip[ObjectIdentifier(w)] == nil { pip[ObjectIdentifier(w)] = TrangThaiPiP() }
            ghiPidDo(webView)
        }
        // Chế độ thử VM_THU2=1 (03/11): hộp hỏi của trang, tải file (blob + link file mở cửa sổ mới),
        // thông báo qua service worker. File thử tên "tony-thu-thu-…" trong Tải về – thử xong cho vào Thùng rác.
        if ProcessInfo.processInfo.environment["VM_THU2"] == "1", webView == self.webView, !daDoTim {
            daDoTim = true
            let chiTai = ProcessInfo.processInfo.environment["VM_THU2_TAI"] == "1"
            var buoc: [(Double, String, String)] = chiTai ? [] : [
                (3, "HỘP confirm", "confirm('Tony thử hộp xác nhận') ? 'bấm OK' : 'bấm Huỷ'"),
                (8, "HỘP prompt", "prompt('Tony thử hộp nhập chữ', 'chữ sẵn')"),
                (8, "HỘP alert", "alert('Tony thử hộp thông báo'); 'đã đóng'"),
            ]
            buoc += [
                (chiTai ? 3 : 8, "TẢI blob", "(() => { const a = document.createElement('a'); a.href = URL.createObjectURL(new Blob(['Tony thu tai file'], {type: 'text/plain'})); a.download = 'tony-thu-thu-tai.txt'; document.body.appendChild(a); a.click(); a.remove(); return 'đã bấm link tải'; })()"),
                (4, "TẢI file cửa sổ mới", "(() => { const u = [...document.querySelectorAll('img, image')].map(x => x.getAttribute('src') || x.getAttribute('xlink:href') || x.getAttribute('href') || '').find(x => /fbcdn/.test(x)); if (!u) return 'không có ảnh fbcdn'; window.open(u, '_blank'); return 'đã mở link ảnh'; })()"),
                (2, "TB new Notification", "(() => { new Notification('Tony thử', { body: 'thông báo thường' }); return 'đã tạo'; })()"),
            ]
            DispatchQueue.main.asyncAfter(deadline: .now() + (chiTai ? 12 : 40)) {
                self.webView.callAsyncJavaScript("const r = await navigator.serviceWorker.getRegistration(); if (!r) return 'không có service worker'; await r.showNotification('Tony thử', { body: 'qua service worker' }); return 'đã gọi showNotification';",
                    arguments: [:], in: nil, in: .page) { kq in NSLog("VM: TB service worker → %@", "\(kq)") }
            }
            var t = 0.0
            for (cho, ten, js) in buoc {
                t += cho
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { self.chayJS(ten, js, hienCuaSo: false) }
            }
        }
        // Chế độ thử VM_THU4=1: hộp "Cuộc gọi đến" GIẢ (2 nút giả, không gọi ai) → bảng nổi phải hiện; em bấm "Từ chối"
        // trên bảng bằng Cua → nút giả trên trang phải được bấm, hộp + bảng biến mất. Lần 2 (sau 25s): hộp tự đóng
        // (người kia gác máy) → bảng phải tự ẩn.
        if ["1", "2", "3", "4"].contains(ProcessInfo.processInfo.environment["VM_THU4"] ?? ""), webView == self.webView {
            let hop = """
                (() => { const d = document.createElement('div'); d.id = 'vm-hop-gia'; d.setAttribute('role', 'dialog');
                  d.style.cssText = 'position:fixed;left:-9999px;top:0';
                  d.innerHTML = '<span>Cuộc gọi đến</span><br><span>Tony thử đang gọi cho bạn</span><br>' +
                    '<div role="button" aria-label="Từ chối">x</div><div role="button" aria-label="Chấp nhận">v</div>';
                  d.querySelectorAll('[role=button]').forEach(b => b.onclick = () => {
                    window.webkit.messageHandlers.vmThongBao.postMessage({ nhatKy: 'THỬ trang nhận cú bấm: ' + b.getAttribute('aria-label') }); d.remove(); });
                  document.body.appendChild(d); return 'đã chèn hộp gọi giả'; })()
                """
            // VM_THU4=2: bỏ lần 1 (cần em bấm Cua), chỉ thử "người kia gác máy → bảng tự ẩn"
            // VM_THU4=3: lần 1 là hộp VIDEO (nút có hình camera như Messenger) → bảng ghi "Cuộc gọi video đến", tự đóng sau 6s
            if ProcessInfo.processInfo.environment["VM_THU4"] == "4" {
                let nhom = """
                    (() => { const r = document.querySelector('[role="row"]'); if (!r) return 'không có dòng chat';
                      const g = document.createElement('div'); g.id = 'vm-dong-nhom'; g.setAttribute('role', 'row');
                      g.innerHTML = '<a href="/t/vm-nhom/"><img src="data:,"><img src="data:,"><div>An Thử, Tony Thử</div><div>Tony: đang gọi video</div></a>';
                      r.parentElement.insertBefore(g, r);
                      const d = document.createElement('div'); d.id = 'vm-hop-gia'; d.setAttribute('role', 'dialog'); d.style.cssText = 'position:fixed;left:-9999px;top:0';
                      d.innerHTML = '<span>Cuộc gọi đến</span><br><span>Tony Thử đã mời bạn tham gia nhóm chat video</span><br>' +
                        '<div role="button" aria-label="Từ chối">x</div><div role="button" aria-label="Chấp nhận"><svg><path d="M9 9.5a4 4 0 0 0-4 4v9"/></svg></div>';
                      document.body.appendChild(d); return 'đã chèn hộp nhóm giả'; })()
                    """
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { self.chayJS("THỬ gọi nhóm", nhom, hienCuaSo: false) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 16) { self.chayJS("THỬ nhóm gác", "document.getElementById('vm-hop-gia')?.remove(); document.getElementById('vm-dong-nhom')?.remove(); 'đã xoá'", hienCuaSo: false) }
            }
            if ProcessInfo.processInfo.environment["VM_THU4"] == "3" {
                let video = hop.replacingOccurrences(of: "aria-label=\"Chấp nhận\">v", with: "aria-label=\"Chấp nhận\"><svg><path d=\"M9 9.5a4 4 0 0 0-4 4v9\"/></svg>")
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { self.chayJS("THỬ hộp gọi video", video, hienCuaSo: false) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 14) { self.chayJS("THỬ người kia gác", "document.getElementById('vm-hop-gia')?.remove(); 'đã xoá hộp'", hienCuaSo: false) }
            }
            if ProcessInfo.processInfo.environment["VM_THU4"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { self.chayJS("THỬ hộp gọi 1", hop, hienCuaSo: false) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 25) { self.chayJS("THỬ hộp gọi 2", hop, hienCuaSo: false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 31) { self.chayJS("THỬ người kia gác", "document.getElementById('vm-hop-gia')?.remove(); 'đã xoá hộp'", hienCuaSo: false) }
        }
        // Chế độ thử VM_THU6=1: tìm đoạn chat ĐÃ ĐỌC có ảnh (tối đa 8 dòng) → mở ảnh lớn → bấm nút Tải xuống của Messenger
        if ProcessInfo.processInfo.environment["VM_THU6"] == "1", webView == self.webView {
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                self.webView.callAsyncJavaScript("""
                    const ngu = ms => new Promise(r => setTimeout(r, ms));
                    const dam = r => [...r.querySelectorAll('*')].some(e => e.children.length === 0 && e.textContent.trim() && parseInt(getComputedStyle(e).fontWeight) >= 600);
                    const rows = [...document.querySelectorAll('[role="row"]')].filter(r => r.querySelector('a[href*="/t/"]') && !dam(r)).slice(0, 8);
                    for (const [i, r] of rows.entries()) {
                      r.querySelector('a[href*="/t/"]').click(); await ngu(4000);
                      const anh = [...document.querySelectorAll('[role="main"] img')].filter(x => /fbcdn|scontent/.test(x.src) && Math.min(x.naturalWidth, x.naturalHeight) >= 260 && !/sticker|emoji/i.test(x.alt || ''));
                      if (!anh.length) continue;
                      const a = anh[anh.length - 1]; const nho = a.naturalWidth + '×' + a.naturalHeight;
                      (a.closest('[role="button"], a') || a).click(); await ngu(3500);
                      const lon = [...document.querySelectorAll('img')].filter(x => x.naturalWidth > 0).sort((x, y) => y.naturalWidth - x.naturalWidth)[0];
                      const duong = location.pathname.replace(/\\d+/g, 'N'); const nut = [...document.querySelectorAll('[aria-label]')].find(e => /^(Tải xuống|Tải về|Download|Lưu|Save)/i.test(e.getAttribute('aria-label')));
                      if (!nut) return 'dòng ' + i + ': ảnh trong chat ' + nho + ', ảnh xem lớn ' + (lon ? lon.naturalWidth + '×' + lon.naturalHeight : '?') + ', đường ' + duong + ', KHÔNG thấy nút tải; nhãn: ' +
                        JSON.stringify([...new Set([...document.querySelectorAll('[aria-label]')].map(e => e.getAttribute('aria-label')).filter(t => t.length < 30 && /tải|download|lưu|save|chia|share|đóng|close|xem|chuyển/i.test(t)))].slice(0, 30));
                      nut.click();
                      return 'dòng ' + i + ': ảnh trong chat ' + nho + ', ảnh xem lớn ' + (lon ? lon.naturalWidth + '×' + lon.naturalHeight : '?') + ' → đã bấm ' + nut.getAttribute('aria-label');
                    }
                    return 'không tìm thấy đoạn chat đã đọc có ảnh';
                    """, arguments: [:], in: nil, in: .page) { kq in NSLog("VM: THỬ tải ảnh thật → %@", "\(kq)") }
            }
        }
        // Chế độ thử VM_THU5=1: mở đoạn chat ĐÃ ĐỌC đầu tiên (không làm mất "chưa đọc" của anh) → Cmd+S → Cmd+S
        if ProcessInfo.processInfo.environment["VM_THU5"] == "1", webView == self.webView {
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { self.chayJS("THỬ mở chat đã đọc", """
                (() => { const r = [...document.querySelectorAll('[role="row"]')].find(r => r.querySelector('a[href*="/t/"]') &&
                    ![...r.querySelectorAll('*')].some(e => e.children.length === 0 && e.textContent.trim() && parseInt(getComputedStyle(e).fontWeight) >= 600));
                  if (!r) return 'không có'; r.querySelector('a[href*="/t/"]').click(); return 'đã mở'; })()
                """, hienCuaSo: false) }
            let kiem = "/File phương tiện|Tùy chỉnh đoạn chat|Media, files|Customize chat/i.test(document.body.innerText) ? 'khung thông tin ĐANG HIỆN' : 'khung thông tin ĐANG ẨN'"
            DispatchQueue.main.asyncAfter(deadline: .now() + 18) { self.chayJS("THỬ trước Cmd+S", kiem, hienCuaSo: false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { self.doiThongTin() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 23) { self.chayJS("THỬ sau Cmd+S lần 1", kiem, hienCuaSo: false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 26) { self.doiThongTin() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 29) { self.chayJS("THỬ sau Cmd+S lần 2", kiem, hienCuaSo: false) }
        }
        // Chế độ thử VM_THU3=1: chèn 1 dòng chat GIẢ chưa đọc (chữ đậm) lên đầu danh sách sau 20s → phải có
        // "TB tự tạo: 1 tin mới"; đổi dòng tin của nó (người cũ nhắn thêm) → phải báo lần 2; 6s sau xoá dòng giả.
        if ProcessInfo.processInfo.environment["VM_THU3"] == "1", webView == self.webView {
            let chen = { (tin: String) in """
                (() => { let d = document.getElementById('vm-dong-gia');
                  if (!d) { const r = document.querySelector('[role="row"]'); if (!r) return 'không có dòng chat';
                    d = document.createElement('div'); d.id = 'vm-dong-gia'; d.setAttribute('role', 'row');
                    d.innerHTML = '<a href="/t/vm-thu/" role="link"><span style="font-weight:700">Nhóm thử</span><span style="font-weight:700">Tony:</span><span style="font-weight:700"></span><span>1 phút</span></a>';
                    r.parentElement.insertBefore(d, r); }
                  d.querySelectorAll('span')[2].textContent = '\(tin)'; return 'đã chèn: \(tin)'; })()
                """ }
            let tre = Double(ProcessInfo.processInfo.environment["VM_TRE"] ?? "") ?? 0   // VM_TRE=180: thử sau 3 phút ẩn
            DispatchQueue.main.asyncAfter(deadline: .now() + 20 + tre) { self.chayJS("THỬ dòng giả 1", chen("tin thứ nhất"), hienCuaSo: false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 26 + tre) { self.chayJS("THỬ dòng giả 2", chen("tin thứ hai"), hienCuaSo: false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 32 + tre) { self.chayJS("THỬ xoá dòng giả", "document.getElementById('vm-dong-gia')?.remove(); 'đã xoá'", hienCuaSo: false) }
        }
        // Thanh bên đang để ẩn từ lần trước → ẩn lại sau mỗi lần tải trang
        if webView == self.webView, anThanhBen { apDungThanhBen(hienCuaSo: false) }
        // Chế độ dò (VM_DO=1): 15 giây/lần ghi tiêu đề + các dấu hiệu "chưa đọc" trên trang → để tìm cách đếm đúng
        if ProcessInfo.processInfo.environment["VM_DO"] == "1", webView == self.webView {
            webView.evaluateJavaScript("""
                setInterval(() => {
                  const q = s => Array.from(document.querySelectorAll(s));
                  const aria = q('[aria-label]').map(e => e.getAttribute('aria-label'))
                    .filter(t => /chưa đọc|unread|đoạn chat|chats|tin nhắn mới|thông báo/i.test(t)).slice(0, 20);
                  const so = q('[role="navigation"] span, [role="banner"] span, a[href*="/t/"] span')
                    .map(e => e.textContent.trim()).filter(t => /^\\d+\\+?$/.test(t)).slice(0, 20);
                  // Chỉ lấy nút điều hướng – KHÔNG lấy khung tin nhắn (nhãn chứa nội dung tin nhắn riêng tư)
                  const nut = [...new Set(q('[role="navigation"] [aria-label], [role="banner"] [aria-label]')
                    .map(e => (e.getAttribute('role') || e.tagName) + ':' + e.getAttribute('aria-label')))].slice(0, 30);
                  const dong = q('[role="row"]').filter(r => r.querySelector('a[role="link"][href*="/t/"]')).length;
                  const dieuHuong = q('[role="navigation"]').map(e => e.getAttribute('aria-label'));
                  window.webkit.messageHandlers.vmThongBao.postMessage({ nhatKy:
                    'DÒ: url=' + location.pathname + ' | title=' + document.title +
                    ' | aria=' + JSON.stringify(aria) + ' | so=' + JSON.stringify(so) +
                    ' | dongChat=' + dong + ' | navigation=' + JSON.stringify(dieuHuong) + ' | nut=' + JSON.stringify(nut) });
                }, 15000);
                """)
        }
        // Chế độ dò tìm kiếm (VM_TIM=1): chỉ ghi nhãn nút/ô có chữ "Tìm/Search/Quay lại/Back/Đóng/Close/Thông tin"
        // (KHÔNG ghi nội dung tin nhắn). Mở ô tìm → dò → quay lại; mở khung thông tin → nút Tìm kiếm → dò → đóng.
        if ProcessInfo.processInfo.environment["VM_TIM"] == "1", webView == self.webView {
            let liet = """
                (() => { const re = /tìm|search|quay lại|back|đóng|close|thông tin/i;
                  const a = document.activeElement;
                  const ds = [...new Set([...document.querySelectorAll('[aria-label], input[placeholder]')]
                    .filter(e => /^(BUTTON|INPUT|DIV|SPAN|A)$/.test(e.tagName) && (e.getAttribute('role') === 'button' || e.tagName === 'INPUT' || e.getAttribute('role') === 'combobox' || e.tagName === 'BUTTON'))
                    .map(e => (e.tagName + '/' + (e.getAttribute('role') || '') + ':' + (e.getAttribute('aria-label') || e.getAttribute('placeholder') || '') + (e.getAttribute('aria-expanded') ? '[exp=' + e.getAttribute('aria-expanded') + ']' : '')))
                    .filter(t => re.test(t)))];
                  const oc = document.querySelector('input[aria-label="Tìm kiếm trên Messenger"]');
                  return 'url=' + location.pathname.replace(/\\d{6,}/g, 'N') + ' | chữ trong ô chung=' + (oc ? oc.value.length : '-') + ' | đangChọn=' + (a ? a.tagName + ':' + (a.getAttribute('aria-label') || a.getAttribute('placeholder') || '') : '-') + ' | ' + JSON.stringify(ds.slice(0, 25)); })()
                """
            let bam = { (nhan: String) in """
                (() => { const e = [...document.querySelectorAll('[aria-label="\(nhan)"]')].find(x => x.offsetParent !== null) || document.querySelector('[aria-label="\(nhan)"]');
                  if (!e) return 'không thấy'; e.click(); if (e.tagName === 'INPUT') e.focus(); return 'đã bấm ' + e.tagName; })()
                """ }
            // Gõ chữ vào ô React: phải dùng setter gốc + sự kiện input thì React mới nhận
            let go = { (chu: String) in """
                (() => { const i = document.querySelector('input[aria-label="Tìm kiếm trên Messenger"]'); if (!i) return 'không thấy ô';
                  i.focus(); Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(i, '\(chu)');
                  i.dispatchEvent(new Event('input', { bubbles: true })); return 'đã gõ "\(chu)"'; })()
                """ }
            let esc = """
                (() => { const a = document.activeElement || document.body;
                  a.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', code: 'Escape', keyCode: 27, bubbles: true }));
                  return 'đã gửi Esc vào ' + a.tagName; })()
                """
            // Ghi trạng thái 1 giây/lần trong 45 giây để thử phím thật gửi từ ngoài vào (phim.swift)
            guard !daDoTim else { return }
            daDoTim = true
            for i in 0..<45 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4 + Double(i)) { self.chayJS("TÌM t=\(i)", liet, hienCuaSo: false) }
            }
        }
        // Chế độ thử nhiều cỡ màn hình (VM_CO=1): ép cửa sổ ra từng độ rộng, đo bố cục khi hiện + ẩn thanh bên.
        // Bố cục vẫn được tính khi cửa sổ chạy ngầm → không cần hiện lên màn hình. Xong trả lại cỡ + trạng thái cũ.
        if ProcessInfo.processInfo.environment["VM_CO"] == "1", webView == self.webView {
            let w = self.window!, khungCu = w.frame, anCu = anThanhBen
            let doBoCuc = """
                (() => { const q = s => document.querySelector(s), W = document.documentElement.clientWidth;
                  const ds = q('[role="navigation"][aria-label="Danh sách cuộc trò chuyện"]');
                  const tb = q('[role="navigation"][aria-label="Chuyển hộp thư"]');
                  const tbHien = !!tb && getComputedStyle(tb).display !== 'none' && tb.getBoundingClientRect().width > 0;
                  let phai = 0; if (ds) [...ds.parentElement.children].forEach(c => phai = Math.max(phai, c.getBoundingClientRect().right));
                  const r = ds ? ds.getBoundingClientRect() : null;
                  const doc = ds ? [...document.querySelectorAll('[role="row"]')].filter(x => x.querySelector('a[role="link"][href*="/t/"]')).length : 0;
                  return 'W=' + W + ' thanhBên=' + (tb ? (tbHien ? 'hiện' : 'ẩn') : 'KHÔNG CÓ') +
                    ' danhSách=' + (r ? 'trái ' + Math.round(r.left) + ' rộng ' + Math.round(r.width) : 'KHÔNG CÓ') +
                    ' lềPhải=' + (W - Math.round(phai)) + ' tinMới=' + !!q('[aria-label="Tin nhắn mới"]') +
                    ' đoạnChat=' + doc + ' nhãnChưaĐọc=' + !!q('[aria-label^="Đoạn chat"]');
                })()
                """
            let doRong: [CGFloat] = [400, 600, 800, 1000, 1200, 1710, 2560, 3440]
            var buoc: [() -> Void] = []
            for rong in doRong {
                for an in [false, true] {
                    buoc.append {
                        w.setFrame(NSRect(x: 0, y: 0, width: rong, height: 1000), display: true)
                        self.anThanhBen = an; self.apDungThanhBen(hienCuaSo: false)
                    }
                    buoc.append { self.chayJS("CỠ \(Int(rong)) thanh bên \(an ? "ẩn" : "hiện")", doBoCuc, hienCuaSo: false) }
                }
            }
            buoc.append {
                w.setFrame(khungCu, display: true)
                self.anThanhBen = anCu; self.apDungThanhBen(hienCuaSo: false)
                NSLog("VM: CỠ – đã trả lại cỡ %@, thanh bên %@", NSStringFromRect(khungCu), anCu ? "ẩn" : "hiện")
            }
            for (i, b) in buoc.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 6 + Double(i) * 1.5, execute: b)
            }
        }
        // Chế độ dò lề (VM_LE=1): từ danh sách chat đi ngược lên 10 lớp cha, ghi vị trí + lề + khoảng đệm
        if ProcessInfo.processInfo.environment["VM_LE"] == "1", webView == self.webView {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                self.chayJS("Dò lề", """
                    (() => {
                      let e = document.querySelector('[role="navigation"][aria-label="Danh sách cuộc trò chuyện"]'), ra = [];
                      for (let i = 0; e && i < 10; i++, e = e.parentElement) {
                        const s = getComputedStyle(e), r = e.getBoundingClientRect();
                        ra.push(i + ' ' + e.tagName + ' role=' + (e.getAttribute('role') || '') + ' left=' + Math.round(r.left) +
                          ' w=' + Math.round(r.width) + ' ml=' + s.marginLeft + ' pl=' + s.paddingLeft + ' bl=' + s.borderLeftWidth +
                          ' disp=' + s.display + ' gap=' + s.columnGap + ' class=' + (e.className || '').toString().slice(0, 60));
                      }
                      // Lề phải: khoảng từ mép phải khung ngoài cùng bên phải tới mép cửa sổ
                      const W = document.documentElement.clientWidth;
                      const day = document.querySelector('[role="navigation"][aria-label="Danh sách cuộc trò chuyện"]').parentElement;
                      const con = [...day.children].map(c => { const r = c.getBoundingClientRect(), s = getComputedStyle(c);
                        return 'con left=' + Math.round(r.left) + ' right=' + Math.round(r.right) + ' top=' + Math.round(r.top) +
                          ' ml=' + s.marginLeft + ' mr=' + s.marginRight + ' disp=' + s.display; });
                      const sd = getComputedStyle(day);
                      ra.push('W=' + W + ' khungBao pr=' + sd.paddingRight + ' pt=' + sd.paddingTop, ...con);
                      return ra.join('\\n');
                    })()
                    """, hienCuaSo: false)
            }
        }
        // Chế độ đo độ mượt (VM_ZOOM=1): đếm khung hình (requestAnimationFrame) trong lúc phóng to rồi thu nhỏ.
        // Cửa sổ phải HIỆN trên màn hình (chạy ngầm thì WebKit không vẽ). Đưa lên trên nhưng KHÔNG giành bàn phím.
        if ProcessInfo.processInfo.environment["VM_ZOOM"] == "1", webView == self.webView {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                let w = self.window!
                // Anh có thể đang ở Space toàn màn hình của app khác → cho cửa sổ nổi tạm lên mọi Space để đo
                let cachCu = w.collectionBehavior
                w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                w.level = .floating
                w.orderFrontRegardless()
                DispatchQueue.main.asyncAfter(deadline: .now() + 7) { w.collectionBehavior = cachCu; w.level = .normal }
                NSLog("VM: ZOOM – cửa sổ hiện=%@ cỡ=%@ hiệu ứng=%@",
                      w.occlusionState.contains(.visible) ? "có" : "KHÔNG", NSStringFromRect(w.frame),
                      (w as? CuaSoChinh)?.thoiGianHieuUng.map { String($0) } ?? "mặc định macOS")
                let batDau = """
                    window.__vmKhung = []; window.__vmDo = true;
                    (function f(t) { if (!window.__vmDo) return; window.__vmKhung.push(t); requestAnimationFrame(f); })(performance.now());
                    true
                    """
                // Chỉ tính khung hình trong 0,4 giây sau mỗi lần bấm (lúc hiệu ứng chạy). Màn máy anh 60Hz: 1 khung = 16,7ms;
                // khung >25ms = hụt ít nhất 1 khung (mắt thấy khựng).
                let ketQua = """
                    (() => { window.__vmDo = false; const k = window.__vmKhung, m = window.__vmMoc || [];
                      let khung = 0, hut = 0, dai = 0;
                      for (const t0 of m) {
                        const ks = k.filter(t => t >= t0 && t <= t0 + 400);
                        khung += ks.length;
                        for (let i = 1; i < ks.length; i++) { const g = ks[i] - ks[i-1]; if (g > 25) hut++; dai = Math.max(dai, g); }
                      }
                      // Đối chứng: 0,4 giây ĐỨNG YÊN trước lần bấm đầu
                      const yen = m.length ? k.filter(t => t >= m[0] - 450 && t < m[0] - 50).length : 0;
                      return 'đứng yên khung/0,4s=' + yen + ' | số lần bấm=' + m.length + ' khung/0,4s TB=' + (khung / m.length).toFixed(1) +
                        ' hụt(>25ms)=' + hut + ' dài nhất=' + Math.round(dai) + 'ms'; })()
                    """
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    NSLog("VM: ZOOM – sau khi nổi lên: hiện=%@ thu nhỏ Dock=%@ app ẩn=%@ trên Space này=%@",
                          w.occlusionState.contains(.visible) ? "có" : "KHÔNG", w.isMiniaturized ? "có" : "không",
                          NSApp.isHidden ? "có" : "không", w.isOnActiveSpace ? "có" : "không")
                }
                self.chayJS("ZOOM bắt đầu đo", batDau + "; window.__vmMoc = []; true", hienCuaSo: false)
                // 6 lần bấm: phóng to ↔ thu nhỏ, cách nhau 0,9 giây
                for i in 0..<6 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2 + Double(i) * 0.9) {
                        self.webView.evaluateJavaScript("window.__vmMoc.push(performance.now()); true") { _, _ in w.zoom(nil) }
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2 + 6 * 0.9) {
                    self.chayJS("ZOOM lúc kết quả", ketQua, hienCuaSo: false)
                }
            }
        }
        // Chế độ thử phím tắt (VM_PHIM=1): Cmd+N, ẩn rồi hiện thanh bên, DevTools.
        // Cmd+1…9 chỉ ĐẾM link (không bấm – mở chat sẽ đánh dấu đã đọc, bên kia thấy).
        if ProcessInfo.processInfo.environment["VM_PHIM"] == "1", webView == self.webView {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                if ProcessInfo.processInfo.environment["VM_PHIM_N"] == "1" { self.tinNhanMoi() }   // mở khung soạn tin
                self.chayJS("Đếm Cmd+1…9", """
                    [...document.querySelectorAll('[role="row"]')]
                      .map(r => r.querySelector('a[role="link"][href*="/t/"]')).filter(Boolean).length
                    """, hienCuaSo: false)
                // Đo vị trí mép trái danh sách chat: ẩn thanh bên thì phải dịch sang trái
                let doViTri = """
                    (() => { const d = document.querySelector('[role="navigation"][aria-label="Danh sách cuộc trò chuyện"]');
                      return d ? Math.round(d.getBoundingClientRect().left) : -1; })()
                    """
                self.chayJS("Mép trái danh sách – lúc đầu", doViTri, hienCuaSo: false)
                self.doiThanhBen()                                   // ẩn
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self.chayJS("Mép trái danh sách – khi ẩn", doViTri, hienCuaSo: false)
                    self.doiThanhBen()                               // hiện lại
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        self.chayJS("Mép trái danh sách – hiện lại", doViTri, hienCuaSo: false)
                    }
                }
                let ins = self.webView.value(forKey: "_inspector") as? NSObject
                NSLog("VM: DevTools có hàm show = %@", (ins?.responds(to: Selector(("show"))) ?? false) ? "có" : "không")
            }
        }
        // Chế độ chạy thử (VM_THU=1): giả 1 thông báo + giả 3 tin chưa đọc
        if ProcessInfo.processInfo.environment["VM_THU"] == "1", webView == self.webView {
            webView.evaluateJavaScript("""
                new Notification('Tony Messenger', { body: 'Tin nhắn thử bước 2', tag: 'thu' });
                typeof Notification.requestPermission
                """) { kq, loi in NSLog("VM: chạy thử JS → %@ %@", "\(kq ?? "")", loi?.localizedDescription ?? "") }
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NSLog("VM: lỗi tải %@", error.localizedDescription)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        NSLog("VM: lỗi mở trang %@", error.localizedDescription)
    }
    // Nhân web bị sập (hết RAM…) → tự tải lại thay vì để màn hình trắng
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        NSLog("VM: nhân web bị sập, tải lại")
        webView.reload()
    }

    // Trang muốn mở cửa sổ mới (target=_blank, cuộc gọi…)
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = action.request.url else { return nil }
        if let that = linkThat(url) { NSWorkspace.shared.open(that); return nil }
        if !laTrongApp(url) { NSWorkspace.shared.open(url); return nil }
        // Bấm "Tải xuống" file đính kèm → Messenger mở link file (fbsbx/fbcdn) trong cửa sổ mới → tải thẳng về
        if let h = url.host, h.hasSuffix("fbsbx.com") || h.hasSuffix("fbcdn.net") {
            webView.startDownload(using: action.request) { [weak self] d in d.delegate = self; self?.dangTai.append(d) }
            return nil
        }
        NSLog("VM: GỌI? cửa sổ phụ mở: %@%@", url.host ?? "", url.path.replacingOccurrences(of: "[0-9]{5,}", with: "N", options: .regularExpression))

        // Link nội bộ (vd. cuộc gọi) → mở cửa sổ phụ dùng chung cookie
        let wv = WebBamNgay(frame: .zero, configuration: configuration)
        wv.customUserAgent = userAgentChrome
        wv.navigationDelegate = self
        wv.uiDelegate = self
        let w = CuaSoGoi(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650))
        w.contentView = khungCuocGoi(wv, cuaSo: w)
        w.delegate = self
        w.center()
        w.makeKeyAndOrderFront(nil)
        cuaSoPhu.append(w)
        return wv
    }

    // Trang tự đóng cửa sổ phụ (window.close())
    func webViewDidClose(_ webView: WKWebView) {
        if let w = webView.window, w != window {
            NSLog("VM: GỌI? trang tự đóng cửa sổ phụ")
            w.close(); cuaSoPhu.removeAll { $0 == w }
        }
    }

    // Nút đính kèm ảnh/file → hộp chọn file của macOS
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.begin { completionHandler($0 == .OK ? panel.urls : nil) }
    }

    // Camera/micro cho cuộc gọi: chỉ cho trang Messenger/Facebook
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let ok = tenMienTrongApp.contains { origin.host == $0 || origin.host.hasSuffix("." + $0) }
        let loai = [WKMediaCaptureType.camera: "camera", .microphone: "micro", .cameraAndMicrophone: "camera+micro"][type] ?? "khác"
        NSLog("VM: GỌI xin quyền %@ từ %@ → %@", loai, origin.host, ok ? "cho" : "TỪ CHỐI")
        decisionHandler(ok ? .grant : .deny)
    }

    // MARK: Bước 3 – Phím tắt đoạn chat (chèn JavaScript bấm nút trên trang, như bản gốc)
    // Bản gốc chỉ tìm nhãn tiếng Anh ("New message", "Inbox switcher") → không chạy với Messenger tiếng Việt.
    // Nhãn thật dò 02/11/2026 (chế độ VM_DO): "Tin nhắn mới", "Chuyển hộp thư". Giữ cả tiếng Anh dự phòng.

    func chayJS(_ ten: String, _ js: String, hienCuaSo: Bool = true) {
        if hienCuaSo { window.makeKeyAndOrderFront(nil) }   // cửa sổ đang ẩn thì hiện lên trước
        webView.evaluateJavaScript(js) { kq, loi in
            NSLog("VM: %@ → %@ %@", ten, "\(kq ?? "")", loi?.localizedDescription ?? "")
        }
    }

    // Cmd+S – ẩn / hiện khung "Thông tin về cuộc trò chuyện" bên phải (nút ⓘ đầu đoạn chat) – anh xin 03/11.
    // Không thấy nút theo nhãn → ghi nhãn các nút ở đầu đoạn chat để sửa (nhãn nút là chữ giao diện, không phải tin nhắn).
    @objc func doiThongTin() {
        chayJS("Cmd+S", """
            (() => {
              const nhan = /^(Thông tin về cuộc trò chuyện|Thông tin cuộc trò chuyện|Thông tin về đoạn chat|Conversation information|Conversation info)$/i;
              const b = [...document.querySelectorAll('[aria-label]')].find(e => nhan.test(e.getAttribute('aria-label')));
              if (b) { b.click(); return 'đã bấm: ' + b.getAttribute('aria-label'); }
              const dau = [...document.querySelectorAll('[role="main"] [aria-label]')].map(e => e.getAttribute('aria-label')).filter(t => t.length < 40);
              return 'KHÔNG thấy nút – nhãn đầu chat: ' + JSON.stringify([...new Set(dau)].slice(0, 20));
            })()
            """, hienCuaSo: false)
    }

    // Cmd+N – bấm nút "Tin nhắn mới"
    @objc func tinNhanMoi() {
        chayJS("Cmd+N", """
            (() => {
              const b = document.querySelector('[aria-label="Tin nhắn mới"], [aria-label="New message"], [aria-label="Start a new message"]');
              if (b) b.click();
              return !!b;
            })()
            """)
    }

    // Cmd+F – vào ô "Tìm kiếm trên Messenger" (tab "Tất cả": người, nhóm, tin nhắn). Ô có chữ cũ thì bôi đen để gõ đè.
    // Cmd+Shift+F – cũng ô đó nhưng tự chọn tab "Tin nhắn" (chỉ tìm nội dung tin nhắn, mọi cuộc trò chuyện).
    @objc func timKiem() { moOTim(tabTinNhan: false) }
    @objc func timTinNhan() { moOTim(tabTinNhan: true) }
    func moOTim(tabTinNhan: Bool) {
        chayJS(tabTinNhan ? "Cmd+Shift+F" : "Cmd+F", """
            (() => {
              const o = document.querySelector('input[aria-label="Tìm kiếm trên Messenger"], input[aria-label="Search Messenger"]');
              if (!o) return false;
              window.__vmTabTinNhan = \(tabTinNhan);
              o.click(); o.focus(); o.select();
              if (\(tabTinNhan) && o.value && window.__vmChonTabTinNhan) window.__vmChonTabTinNhan();
              return true;
            })()
            """)
    }

    // Cmd+1…9 – mở đoạn chat thứ n trong danh sách (tag của mục menu = n - 1)
    @objc func moDoanChat(_ sender: NSMenuItem) {
        chayJS("Cmd+\(sender.tag + 1)", """
            (() => {
              const links = [...document.querySelectorAll('[role="row"]')]
                .map(r => r.querySelector('a[role="link"][href*="/t/"]')).filter(Boolean);
              const l = links[\(sender.tag)];
              if (l) l.click();
              return l ? 'mở ' + (\(sender.tag) + 1) + '/' + links.length : 'không có, chỉ ' + links.length + ' đoạn chat';
            })()
            """)
    }

    // Cmd+Shift+S – ẩn/hiện cột biểu tượng bên trái ("Chuyển hộp thư"), nhớ qua các lần mở app.
    // Dùng thẻ <style> thay vì sửa thẳng phần tử: Messenger vẽ lại giao diện thì vẫn giữ trạng thái ẩn.
    var anThanhBen: Bool {
        get { UserDefaults.standard.bool(forKey: "anThanhBen") }
        set { UserDefaults.standard.set(newValue, forKey: "anThanhBen") }
    }
    @objc func doiThanhBen() { anThanhBen.toggle(); apDungThanhBen() }
    func apDungThanhBen(hienCuaSo: Bool = true) {
        // Ẩn cột biểu tượng; lề trái = lề phải = lề trên = 16px (dò 02/11 bằng VM_LE: khung bao pl=16 + danh sách ml=16
        // → lệch 32px; lề phải = khung bao pr=16). Giữ pl=16 của khung bao, bỏ ml=16 của danh sách.
        let css = anThanhBen
            ? #"[role="navigation"][aria-label="Chuyển hộp thư"], [role="navigation"][aria-label="Inbox switcher"] { display: none !important; } "#
              + #"[role="navigation"][aria-label="Danh sách cuộc trò chuyện"] { margin-left: 0 !important; }"#
            : ""
        chayJS("Thanh bên \(anThanhBen ? "ẩn" : "hiện")", """
            (() => {
              let s = document.getElementById('vm-thanh-ben');
              if (!s) { s = document.createElement('style'); s.id = 'vm-thanh-ben'; document.head.appendChild(s); }
              s.textContent = '\(css.replacingOccurrences(of: "'", with: "\\'"))';
              return !!document.querySelector('[role="navigation"][aria-label="Chuyển hộp thư"], [role="navigation"][aria-label="Inbox switcher"]');
            })()
            """, hienCuaSo: hienCuaSo)
    }

    // MARK: Menu – thiếu menu Edit thì Cmd+C / Cmd+V không chạy trong WKWebView

    @objc func taiLai() { webView.reload() }
    @objc func taiLaiHoanToan() { webView.reloadFromOrigin() }   // bỏ qua bộ nhớ đệm
    @objc func phongTo() { webView.pageZoom += 0.1 }
    @objc func thuNho() { webView.pageZoom = max(0.5, webView.pageZoom - 0.1) }
    @objc func coThuong() { webView.pageZoom = 1 }
    // Công cụ soi trang (DevTools của Safari). WebKit không có hàm công khai để mở bằng phím tắt
    // → gọi hàm nội bộ _inspector.show; không có thì chuột phải → "Kiểm tra phần tử" vẫn dùng được.
    @objc func moDevTools() {
        if let ins = webView.value(forKey: "_inspector") as? NSObject, ins.responds(to: Selector(("show"))) {
            ins.perform(Selector(("show")))
        } else {
            NSLog("VM: không mở được DevTools bằng phím – dùng chuột phải → Kiểm tra phần tử")
        }
    }

    // Cửa sổ → Hiệu ứng phóng to: 3 lựa chọn, dấu ✓ ở cái đang dùng
    func menuHieuUng() -> NSMenuItem {
        let goc = NSMenuItem(title: "Hiệu ứng phóng to", action: nil, keyEquivalent: "")
        let m = NSMenu(title: "Hiệu ứng phóng to")
        let dangDung = UserDefaults.standard.string(forKey: "hieuUngPhongTo") ?? hieuUngMacDinh
        for k in kieuHieuUng {
            let i = NSMenuItem(title: k.ten, action: #selector(chonHieuUng(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = k.ma
            i.state = k.ma == dangDung ? .on : .off
            m.addItem(i)
        }
        goc.submenu = m
        return goc
    }
    @objc func chonHieuUng(_ sender: NSMenuItem) {
        guard let ma = sender.representedObject as? String else { return }
        UserDefaults.standard.set(ma, forKey: "hieuUngPhongTo")
        sender.menu?.items.forEach { $0.state = ($0 == sender) ? .on : .off }
        NSLog("VM: hiệu ứng phóng to = %@", ma)
    }

    func taoMenu() {
        let menuChinh = NSMenu()

        @discardableResult
        func them(_ tieuDe: String, _ items: [NSMenuItem]) -> NSMenu {
            let goc = NSMenuItem(title: tieuDe, action: nil, keyEquivalent: "")
            let m = NSMenu(title: tieuDe)
            items.forEach { m.addItem($0) }
            goc.submenu = m
            menuChinh.addItem(goc)
            return m
        }
        func muc(_ ten: String, _ sel: Selector?, _ phim: String, _ dich: AnyObject? = nil,
                 _ phimPhu: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: ten, action: sel, keyEquivalent: phim)
            i.target = dich
            i.keyEquivalentModifierMask = phimPhu
            return i
        }

        them(tenApp, [
            muc("Giới thiệu", #selector(moGioiThieu), "", self),
            muc("Cài đặt…", #selector(moCaiDat), ",", self),
            muc("Kiểm tra cập nhật…", #selector(kiemTraCapNhatMenu), "", self),
            .separator(),
            muc("Ẩn", #selector(NSApplication.hide(_:)), "h"),
            muc("Ẩn ứng dụng khác", #selector(NSApplication.hideOtherApplications(_:)), "h", nil, [.command, .option]),
            muc("Hiện tất cả", #selector(NSApplication.unhideAllApplications(_:)), ""),
            .separator(),
            muc("Thoát", #selector(NSApplication.terminate(_:)), "q"),
        ])
        them("Sửa", [
            muc("Hoàn tác", Selector(("undo:")), "z"),
            muc("Làm lại", Selector(("redo:")), "Z"),
            .separator(),
            muc("Cắt", #selector(NSText.cut(_:)), "x"),
            muc("Sao chép", #selector(NSText.copy(_:)), "c"),
            muc("Dán", #selector(NSText.paste(_:)), "v"),
            muc("Chọn tất cả", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            muc("Tìm tin nhắn", #selector(timKiem), "f", self),
            muc("Tìm trong tin nhắn", #selector(timTinNhan), "f", self, [.command, .shift]),
        ])
        them("Xem", [
            muc("Tải lại", #selector(taiLai), "r", self),
            muc("Tải lại hoàn toàn", #selector(taiLaiHoanToan), "r", self, [.command, .shift]),
            .separator(),
            muc("Cỡ thường", #selector(coThuong), "0", self),
            muc("Phóng to", #selector(phongTo), "=", self),
            muc("Thu nhỏ", #selector(thuNho), "-", self),
            .separator(),
            // Ctrl+Cmd+F như macOS chuẩn (Cmd+F để dành cho ô tìm kiếm của trang)
            muc("Toàn màn hình", #selector(NSWindow.toggleFullScreen(_:)), "f", nil, [.command, .control]),
            .separator(),
            muc("Công cụ soi trang (DevTools)", #selector(moDevTools), "i", self, [.command, .option]),
        ])
        them("Đoạn chat", [muc("Tin nhắn mới", #selector(tinNhanMoi), "n", self), .separator()]
            + (1...9).map { n in
                let i = muc("Đoạn chat \(n)", #selector(moDoanChat(_:)), "\(n)", self)
                i.tag = n - 1
                return i
            })
        // Khai báo đây là menu Cửa sổ CHUẨN → macOS tự thêm mục chia cửa sổ (Move & Resize, Fill & Arrange…)
        // và phím tắt Fn+Ctrl+mũi tên mới chạy. Thiếu dòng này thì chia cửa sổ không được (anh báo 03/11).
        NSApp.windowsMenu = them("Cửa sổ", [
            muc("Thu nhỏ xuống Dock", #selector(NSWindow.performMiniaturize(_:)), "m"),
            muc("Phóng to cửa sổ", #selector(NSWindow.performZoom(_:)), ""),
            menuHieuUng(),
            .separator(),
            muc("Ẩn/hiện thanh bên", #selector(doiThanhBen), "s", self, [.command, .shift]),
            muc("Ẩn/hiện thông tin cuộc trò chuyện", #selector(doiThongTin), "s", self),
            muc("Thu nhỏ / phóng to cuộc gọi (PiP)", #selector(doiPiP), "p", self, [.command, .shift]),
            .separator(),
            muc("Đóng", #selector(NSWindow.performClose(_:)), "w"),
            // "Đưa tất cả lên trước" bỏ đi: macOS đã tự thêm "Arrange in Front" khi đặt windowsMenu
        ])
        NSApp.helpMenu = them("Trợ giúp", [muc("Phím tắt", #selector(moBangPhim), "/", self)])
        NSApp.mainMenu = menuChinh
    }
}

// Khởi động app
// MARK: Bảng "Cuộc gọi đến" – nổi góc trên bên phải, trên mọi app (kể cả toàn màn hình), KHÔNG giành bàn phím
// (giống FaceTime). Hiện khi trang có hộp gọi đến mà anh không đang nhìn cửa sổ Messenger.
final class BangGoiDen: NSPanel {
    let anh = NSImageView(), chu = NSTextField(labelWithString: ""), tieuDe = NSTextField(labelWithString: "")
    var bam: ((String) -> Void)?
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 132),
                   styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false; hidesOnDeactivate = false
        titleVisibility = .hidden; titlebarAppearsTransparent = true; isMovableByWindowBackground = true
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].forEach { standardWindowButton($0)?.isHidden = true }
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let nen = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 360, height: 132))
        nen.material = .hudWindow; nen.state = .active; nen.blendingMode = .behindWindow
        anh.frame = NSRect(x: 16, y: 56, width: 56, height: 56)
        anh.wantsLayer = true; anh.layer?.cornerRadius = 28; anh.layer?.masksToBounds = true
        anh.imageScaling = .scaleProportionallyUpOrDown
        anh.image = NSImage(systemSymbolName: "person.crop.circle.fill", accessibilityDescription: nil)
        tieuDe.font = .systemFont(ofSize: 12, weight: .medium); tieuDe.textColor = .secondaryLabelColor
        tieuDe.frame = NSRect(x: 84, y: 92, width: 260, height: 18)
        chu.font = .systemFont(ofSize: 15, weight: .semibold); chu.lineBreakMode = .byTruncatingTail
        chu.maximumNumberOfLines = 2; chu.cell?.wraps = true
        chu.frame = NSRect(x: 84, y: 52, width: 260, height: 40)
        [anh, tieuDe, chu].forEach { nen.addSubview($0) }
        for (i, (ten, mau)) in [("Từ chối", NSColor.systemRed), ("Chấp nhận", NSColor.systemGreen)].enumerated() {
            // Nút tô màu đỏ / xanh như hộp của Messenger (bezelColor không ăn trên nền HUD → tự tô bằng layer)
            let b = NutBamNgay(title: ten, target: self, action: #selector(bamNut(_:)))
            b.isBordered = false; b.wantsLayer = true
            b.layer?.backgroundColor = mau.cgColor; b.layer?.cornerRadius = 16
            b.attributedTitle = NSAttributedString(string: ten, attributes: [.foregroundColor: NSColor.white,
                                                                             .font: NSFont.systemFont(ofSize: 14, weight: .semibold)])
            b.frame = NSRect(x: 16 + CGFloat(i) * 168, y: 12, width: 160, height: 32)
            nen.addSubview(b)
        }
        contentView = nen
    }
    @objc func bamNut(_ b: NSButton) { bam?(b.title) }
    override var canBecomeKey: Bool { false }        // không giành bàn phím của anh
}
final class NutBamNgay: NSButton { override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true } }

extension AppDelegate {
    // Hiện bảng khi: trang có hộp gọi đến VÀ anh không đang nhìn cửa sổ chat (app ở sau / cửa sổ ẩn, thu nhỏ)
    func capNhatBangGoi() {
        // Đang nhìn cửa sổ chat = app ở trước + cửa sổ chat đang được chọn, hiện trên màn hình này → hộp của trang đã thấy
        let dangNhin = NSApp.isActive && window.isKeyWindow && window.isVisible && !window.isMiniaturized && window.isOnActiveSpace
        let canHien = goiDen != nil && !dangNhin && caiDat("bangGoiNoi", true)
        if ghiGoLoi { NSLog("VM: BẢNG xét – có hộp=%@ appTrước=%@ %@ → %@", goiDen != nil ? "có" : "không", NSApp.isActive ? "có" : "không",
              dangNhin ? "đang nhìn chat" : "không nhìn chat", canHien ? "HIỆN" : "ẩn") }
        guard canHien, let g = goiDen else {
            if bangGoi?.isVisible == true { bangGoi?.orderOut(nil); NSLog("VM: BẢNG gọi đến ẩn") }
            return
        }
        let b = bangGoi ?? BangGoiDen()
        bangGoi = b
        // Gọi nhóm: dòng 1 = tên nhóm (đậm), dòng 2 = "X đang gọi" (chữ nhỏ, xám)
        let ds = g.chu.components(separatedBy: "\n")
        let chuBang = NSMutableAttributedString(string: ds[0], attributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold),
                                                                            .foregroundColor: NSColor.labelColor])
        if ds.count > 1 {
            chuBang.append(NSAttributedString(string: "\n" + ds[1], attributes: [.font: NSFont.systemFont(ofSize: 12),
                                                                                 .foregroundColor: NSColor.secondaryLabelColor]))
        }
        b.chu.attributedStringValue = chuBang
        b.chu.lineBreakMode = .byTruncatingTail
        b.tieuDe.stringValue = g.nhom ? (g.video ? "🎥  Gọi video nhóm" : "📞  Gọi thoại nhóm")
                                      : (g.video ? "🎥  Cuộc gọi video đến" : "📞  Cuộc gọi thoại đến")
        b.bam = { [weak self] nhan in self?.bamGoiDen(nhan) }
        if let u = URL(string: g.anh), !g.anh.isEmpty, b.anh.toolTip != g.anh {
            b.anh.toolTip = g.anh
            URLSession.shared.dataTask(with: u) { du, _, _ in
                if let du, let im = NSImage(data: du) { DispatchQueue.main.async { b.anh.image = im } }
            }.resume()
        }
        if !b.isVisible {
            let man = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
            b.setFrameOrigin(NSPoint(x: man.maxX - b.frame.width - 16, y: man.maxY - b.frame.height - 12))
            b.orderFrontRegardless()
            NSLog("VM: BẢNG gọi đến hiện")
        }
    }
    func bamGoiDen(_ nhan: String) {
        webView.evaluateJavaScript("window.__vmBamGoiDen && window.__vmBamGoiDen('\(nhan)')") { kq, _ in
            NSLog("VM: BẢNG gọi đến → %@", "\(kq ?? "")")
        }
        goiDen = nil; capNhatBangGoi()
        if nhan == "Chấp nhận" { NSApp.activate() }   // anh bắt máy → đưa app lên để cửa sổ gọi hiện trước mặt
    }
}

// MARK: Bảng phím tắt – Trợ giúp → Phím tắt (Cmd+/), tự hiện lần đầu mở app (bản gốc: cửa sổ chào mừng)
let dsPhimTat: [(nhom: String, ds: [(phim: String, viec: String)])] = [
    ("Đoạn chat", [("⌘N", "Tin nhắn mới"), ("⌘1 … ⌘9", "Mở đoạn chat thứ 1–9")]),
    ("Tìm kiếm", [("⌘F", "Tìm (người, nhóm, tin nhắn)"), ("⇧⌘F", "Tìm thẳng trong tab Tin nhắn"), ("Esc", "Xoá chữ, thoát ô tìm")]),
    ("Cuộc gọi", [("⇧⌘P", "Thu nhỏ / phóng to cuộc gọi (PiP)"), ("Nút xanh", "Đang PiP → về cỡ thường")]),
    ("Cửa sổ", [("⌘S", "Ẩn / hiện thông tin cuộc trò chuyện"), ("⇧⌘S", "Ẩn / hiện thanh bên"), ("⌃⌥ ← → ↑ ↓", "Chia nửa màn hình"), ("⌃⌘F", "Toàn màn hình"),
                ("⌘M", "Thu nhỏ xuống Dock"), ("⌘W", "Đóng cửa sổ (app vẫn chạy)")]),
    ("Xem", [("⌘R / ⇧⌘R", "Tải lại / tải lại hoàn toàn"), ("⌘=  ⌘-  ⌘0", "Phóng to / thu nhỏ / cỡ thường")]),
    ("App", [("⌘/", "Mở bảng này"), ("⌘H / ⌥⌘H", "Ẩn app / ẩn app khác"), ("⌘Q", "Thoát")]),
]

extension AppDelegate {
    @objc func doiHienPhimTat(_ o: NSButton) {
        UserDefaults.standard.set(o.state == .on, forKey: "khongHienPhimTat")
        NSLog("VM: bảng phím tắt – %@", o.state == .on ? "KHÔNG hiện khi mở app" : "hiện mỗi lần mở app")
    }
    @objc func moBangPhim() {
        if let w = bangPhim { oKhongHien?.state = UserDefaults.standard.bool(forKey: "khongHienPhimTat") ? .on : .off
            w.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        let luoi = NSGridView()
        luoi.rowSpacing = 6; luoi.columnSpacing = 18
        for (i, nhom) in dsPhimTat.enumerated() {
            let tieuDe = NSTextField(labelWithString: nhom.nhom)
            tieuDe.font = .boldSystemFont(ofSize: 13)
            let hang = luoi.addRow(with: [tieuDe, NSGridCell.emptyContentView])
            hang.topPadding = i == 0 ? 0 : 10
            hang.mergeCells(in: NSRange(location: 0, length: 2))
            for p in nhom.ds {
                let phim = NSTextField(labelWithString: p.phim)
                phim.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
                phim.textColor = .secondaryLabelColor
                luoi.addRow(with: [phim, NSTextField(labelWithString: p.viec)])
            }
        }
        luoi.column(at: 0).xPlacement = .trailing
        // Tên nhóm (ô gộp 2 cột) căn trái – không thì theo cột phím, bị đẩy sang phải (ảnh kiểm 03/11)
        for v in luoi.subviews.compactMap({ $0 as? NSTextField }) where v.font == .boldSystemFont(ofSize: 13) {
            luoi.cell(for: v)?.xPlacement = .leading
        }
        luoi.translatesAutoresizingMaskIntoConstraints = false
        let o = NSButton(checkboxWithTitle: "Không hiện bảng này khi mở app (xem lại: ⌘/)", target: self, action: #selector(doiHienPhimTat(_:)))
        o.state = UserDefaults.standard.bool(forKey: "khongHienPhimTat") ? .on : .off
        o.translatesAutoresizingMaskIntoConstraints = false
        oKhongHien = o
        let nen = NSView()
        nen.addSubview(luoi); nen.addSubview(o)
        NSLayoutConstraint.activate([
            luoi.leadingAnchor.constraint(equalTo: nen.leadingAnchor, constant: 24),
            luoi.trailingAnchor.constraint(equalTo: nen.trailingAnchor, constant: -24),
            luoi.topAnchor.constraint(equalTo: nen.topAnchor, constant: 20),
            o.topAnchor.constraint(equalTo: luoi.bottomAnchor, constant: 18),
            o.leadingAnchor.constraint(equalTo: nen.leadingAnchor, constant: 24),
            o.trailingAnchor.constraint(lessThanOrEqualTo: nen.trailingAnchor, constant: -24),
            o.bottomAnchor.constraint(equalTo: nen.bottomAnchor, constant: -18),
        ])
        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Phím tắt – \(tenApp)"
        w.isReleasedWhenClosed = false
        w.contentView = nen
        w.setContentSize(nen.fittingSize)
        w.center()
        bangPhim = w
        w.makeKeyAndOrderFront(nil)
        NSLog("VM: bảng phím tắt mở (%d dòng)", dsPhimTat.reduce(0) { $0 + $1.ds.count })
        // VM_CHUP=<đường dẫn>: tự vẽ bảng ra ảnh PNG để kiểm (cửa sổ ở Space khác thì screencapture không chụp được)
        if let duong = ProcessInfo.processInfo.environment["VM_CHUP"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let v = w.contentView!, rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: duong))
                NSLog("VM: đã chụp bảng phím tắt %@", NSStringFromSize(v.bounds.size))
            }
        }
    }
}

// MARK: PiP – cửa sổ cuộc gọi thu nhỏ nổi ở góc màn hình (03/11/2026)
// Cách A anh chọn: thu nhỏ CHÍNH cửa sổ cuộc gọi (giữ nút tắt micro / gác máy của Messenger), không dùng PiP video của Safari.
// Cửa sổ luôn hiện → Safari không hãm trang đang gọi (nhật ký 03/11: trang bị ẩn ~2 phút khi chuyển app).

final class TrangThaiPiP {
    var dangPiP = false
    var khungCu = NSRect.zero
}

// Bấm được ngay cú đầu khi app đang ở sau (không phải bấm 1 lần để kích hoạt rồi mới bấm nút)
final class WebBamNgay: WKWebView { override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true } }

let coPiP = NSSize(width: 360, height: 240)

// Cửa sổ cuộc gọi = NSPanel (bảng nổi): cửa sổ thường KHÔNG lên được màn hình toàn màn hình (Space riêng)
// của chính app – anh bấm nút xanh cửa sổ chat → PiP biến mất (03/11). Bảng nổi + fullScreenAuxiliary thì được.
// Giữ đủ hành vi cửa sổ thường: không tự ẩn khi chuyển app, làm được cửa sổ chính, hiện trong menu Cửa sổ.
final class CuaSoGoi: NSPanel {
    init(contentRect r: NSRect) {
        // .nonactivatingPanel phải đặt NGAY lúc tạo (bật/tắt giữa chừng → macOS không vẽ cửa sổ nữa, thử 03/11):
        // chỉ bảng nổi loại này mới được lên màn hình toàn màn hình của app mình và app khác.
        super.init(contentRect: r, styleMask: [.titled, .closable, .miniaturizable, .resizable, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isFloatingPanel = false
        isExcludedFromWindowsMenu = false
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

extension AppDelegate {
    var tuPiP: Bool {
        get { UserDefaults.standard.object(forKey: "tuPiP") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "tuPiP") }
    }

    // Khung chứa trang web (giữ chỗ cho cửa sổ cuộc gọi) + đăng ký trạng thái PiP.
    // Không thêm nút riêng: dùng 3 nút đỏ/vàng/xanh của macOS – xanh khi đang PiP = về cỡ thường (anh duyệt 03/11).
    func khungCuocGoi(_ wv: WKWebView, cuaSo w: NSWindow) -> NSView {
        let khung = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 650))
        wv.frame = khung.bounds
        wv.autoresizingMask = [.width, .height]
        khung.addSubview(wv)
        pip[ObjectIdentifier(w)] = TrangThaiPiP()
        return khung
    }

    // Cửa sổ phụ đang là trang cuộc gọi (…/groupcall/…)
    func laCuocGoi(_ w: NSWindow) -> Bool {
        let wv = w.contentView?.subviews.first as? WKWebView
        if w.identifier?.rawValue == "vm-thu-pip" { return true }      // cửa sổ giả của chế độ thử VM_PIP
        return wv?.url?.path.contains("/groupcall/") == true
    }

    // Chế độ thử VM_PIP=1: cửa sổ giả (trang trắng, KHÔNG gọi ai) → vào PiP / phóng to / vào lại / Tắt PiP /
    // tự thu (phải bỏ qua) / Cmd+Shift+P → để ở PiP cho em bấm thử nút bằng Cua. Không đụng cửa sổ chat chính.
    func thuPiP() {
        let wv = WebBamNgay(frame: .zero, configuration: WKWebViewConfiguration())
        wv.loadHTMLString("<body style='background:#234;color:#fff;font:20px sans-serif'><p>Cửa sổ thử PiP</p></body>", baseURL: nil)
        let w = CuaSoGoi(contentRect: NSRect(x: 200, y: 200, width: 900, height: 650))
        w.identifier = NSUserInterfaceItemIdentifier("vm-thu-pip")
        w.title = "Thử PiP"
        w.contentView = khungCuocGoi(wv, cuaSo: w)
        w.delegate = self
        cuaSoPhu.append(w)
        w.orderFront(nil)
        let ghi = { (b: String) in
            let tt = self.pip[ObjectIdentifier(w)]
            NSLog("VM: THỬ PiP %@ → khung=%@ nổi=%@ PiP=%@", b, NSStringFromRect(w.frame), w.level == .floating ? "có" : "không",
                  tt?.dangPiP == true ? "có" : "không")
        }
        let buoc: [(String, () -> Void)] = [
            ("1 cửa sổ thường", {}),
            // App chạy ngầm thì cửa sổ không thành "key" được → gửi đúng thông báo macOS gửi khi anh bấm vào cửa sổ chat
            ("2 bấm sang cửa sổ chat", { NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: self.window) }),
            ("2b nút xanh khi PiP", { w.zoom(nil) }),
                        ("4 chuyển app", { self.tuDongPiP() }),
            ("5 Cmd+Shift+P", { self.doiPiP() }),
            ("6 Dock (đang thường → không đổi)", { _ = self.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true) }),
            ("7 Cmd+Shift+P", { self.doiPiP() }),
            ("8 Dock (đang PiP → về thường)", { _ = self.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true) }),
        ]
        for (i, b) in buoc.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5 * Double(i + 1)) { b.1(); ghi(b.0) }
        }
    }

    // Chế độ thử VM_PIP=2 (anh cho mượt máy ~3 phút, 03/11): cửa sổ gọi GIẢ ở PiP + 9 tình huống thật với cửa sổ chat,
    // app khác (app phụ thử, nhận lệnh qua DistributedNotification "vm.phu.lenh"), toàn màn hình, Cmd+H…
    // Mỗi bước ghi "KIỂM … hiện=có/KHÔNG" (theo danh sách cửa sổ đang hiện của macOS) + "CHỤP x,y,w,h" để script chụp vùng PiP.
    func thuPiP2() {
        let wv = WebBamNgay(frame: .zero, configuration: WKWebViewConfiguration())
        wv.loadHTMLString("<body style='background:#234;color:#fff;font:20px sans-serif'><p>Cửa sổ thử PiP</p></body>", baseURL: nil)
        let w = CuaSoGoi(contentRect: NSRect(x: 200, y: 200, width: 900, height: 650))
        w.identifier = NSUserInterfaceItemIdentifier("vm-thu-pip")
        w.title = "Thử PiP"
        w.contentView = khungCuocGoi(wv, cuaSo: w)
        w.delegate = self
        cuaSoPhu.append(w)
        w.orderFront(nil)
        let chinh = window!
        let toanManLucDau = chinh.styleMask.contains(.fullScreen), khungChinh = chinh.frame
        let viTriCu = UserDefaults.standard.string(forKey: "viTriPiP")
        UserDefaults.standard.removeObject(forKey: "viTriPiP")
        let phu = { (lenh: String) in DistributedNotificationCenter.default().postNotificationName(.init("vm.phu.lenh"), object: lenh, userInfo: nil, deliverImmediately: true) }
        let kiem = { (b: String) in
            let ds = (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]) ?? []
            let hien = w.isVisible && ds.contains { ($0["kCGWindowNumber"] as? Int) == w.windowNumber }
            let f = w.frame, H = NSScreen.screens[0].frame.height
            NSLog("VM: KIỂM %@ → hiện=%@ PiP=%@ khung=%@ toànMànChat=%@", b, hien ? "có" : "KHÔNG",
                  self.pip[ObjectIdentifier(w)]?.dangPiP == true ? "có" : "không", NSStringFromRect(f),
                  chinh.styleMask.contains(.fullScreen) ? "có" : "không")
            NSLog("VM: CHỤP %d,%d,%d,%d %@", Int(f.minX), Int(H - f.maxY), Int(f.width), Int(f.height), b.components(separatedBy: " ").first ?? "")
        }
        var buoc: [(Double, String, () -> Void)] = []   // (chờ trước, tên, việc)
        if toanManLucDau { buoc.append((1, "", { chinh.toggleFullScreen(nil) })) }
        // VM_PIP=3: chỉ 2 tình huống toàn màn hình, chờ lâu hơn, script chụp CẢ màn hình để nhìn tận mắt
        if ProcessInfo.processInfo.environment["VM_PIP"] == "3" { buoc += [
            (3, "0 vào PiP", { self.vaoPiP(w) }),
            (1, "", { phu("truoc") }), (2, "", { phu("toanman") }),
            (6, "2 app khác toàn màn hình", {}),
            (0.5, "", { phu("thuong") }),
            (4, "", { NSApp.activate(); chinh.makeKeyAndOrderFront(nil) }),
            (1, "", { chinh.toggleFullScreen(nil) }),
            (6, "4 cửa sổ chat toàn màn hình", {}),
            (0.5, "", { chinh.toggleFullScreen(nil) }),
            (4, "", { w.close(); phu("thoat"); NSLog("VM: THỬ XONG – trả lại cửa sổ chat như cũ") }),
        ] } else {
        buoc += [
            (3, "0 vào PiP", { self.vaoPiP(w) }),
            (1, "", { phu("truoc") }),
            (2.5, "1 chuyển sang app khác", {}),
            (0.5, "", { phu("toanman") }),
            (4, "2 app khác toàn màn hình", {}),
            (0.5, "", { phu("thuong") }),
            (3.5, "", { NSApp.activate(); chinh.makeKeyAndOrderFront(nil) }),
            (2, "3 bấm vào cửa sổ chat", {}),
            (0.5, "", { chinh.toggleFullScreen(nil) }),
            (4, "4 cửa sổ chat toàn màn hình", {}),
            (0.5, "", { chinh.toggleFullScreen(nil) }),
            (3.5, "", { chinh.setFrame(chinh.screen!.visibleFrame, display: true) }),
            (1.5, "5 cửa sổ chat phóng to kín", {}),
            (0.5, "", { chinh.setFrame(khungChinh, display: true); NSApp.hide(nil) }),
            (1.5, "6a Cmd+H ẩn app", {}),
            (0.5, "", { NSApp.unhide(nil); chinh.miniaturize(nil) }),
            (2, "6b cửa sổ chat thu xuống Dock", {}),
            (0.5, "", { chinh.deminiaturize(nil) }),
            // Bước 7 (đổi màn hình, Mission Control) bỏ khỏi chế độ thử: giả lập phím cần quyền Trợ năng → macOS hỏi quyền,
            // Esc không ăn → Mission Control kẹt (03/11). Cần thử thì dùng Cua Driver hoặc anh tự bấm.
            (1.5, "", { w.setFrameOrigin(NSPoint(x: 40, y: 60)) }),
            (1, "8a kéo PiP sang góc trái", {}),
            (0.5, "", { w.zoom(nil) }),
            (1.5, "8b nút xanh → cỡ thường", {}),
            (0.5, "", { self.vaoPiP(w) }),
            (1.5, "8c vào PiP lại (phải ở góc trái)", {}),
            (0.5, "", { w.close() }),
            (1.5, "9 đóng cuộc gọi khi đang PiP", {
                let ds = (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]) ?? []
                let noi = ds.filter { ($0["kCGWindowOwnerPID"] as? Int32) == getpid() && ($0["kCGWindowLayer"] as? Int ?? 0) == 3 }
                NSLog("VM: KIỂM 9 → cửa sổ nổi còn lại=%d, PiP còn trong danh sách=%@", noi.count, self.cuaSoPhu.contains(w) ? "có" : "không")
            }),
            (0.5, "", {
                phu("thoat")
                if let v = viTriCu { UserDefaults.standard.set(v, forKey: "viTriPiP") } else { UserDefaults.standard.removeObject(forKey: "viTriPiP") }
                if toanManLucDau { chinh.toggleFullScreen(nil) }
                NSLog("VM: THỬ XONG – trả lại cửa sổ chat %@", toanManLucDau ? "toàn màn hình" : "như cũ")
            }),
        ] }
        var t = 0.0
        for (cho, ten, viec) in buoc {
            t += cho
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { viec(); if !ten.isEmpty && !ten.hasPrefix("9") { kiem(ten) } }
        }
    }

    func tuDongPiP() {
        guard tuPiP else { return }
        for w in cuaSoPhu where laCuocGoi(w) && w.isVisible && !w.isMiniaturized && !w.isKeyWindow { vaoPiP(w) }
    }

    func vaoPiP(_ w: NSWindow) {
        guard let tt = pip[ObjectIdentifier(w)], !tt.dangPiP else { return }
        tt.khungCu = w.frame
        tt.dangPiP = true
        let man = (w.screen ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        // Vị trí anh kéo lần trước (nếu còn nằm trong 1 màn hình), không thì góc dưới bên phải
        var goc = NSPoint(x: man.maxX - coPiP.width - 16, y: man.minY + 16)
        if let s = UserDefaults.standard.string(forKey: "viTriPiP") {
            let p = NSPointFromString(s)
            if NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -1, dy: -1).contains(NSRect(origin: p, size: coPiP)) }) { goc = p }
        }
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        w.canHide = false                              // Cmd+H ẩn app → PiP vẫn ở lại
        w.setFrame(NSRect(origin: goc, size: coPiP), display: true, animate: false)
        w.orderFrontRegardless()
        NSLog("VM: PiP vào – %@", NSStringFromRect(w.frame))
    }

    func raPiP(_ w: NSWindow, giuTruoc: Bool) {
        guard let tt = pip[ObjectIdentifier(w)], tt.dangPiP else { return }
        tt.dangPiP = false
        w.level = .normal
        w.collectionBehavior = []
        w.canHide = true
        if tt.khungCu != .zero { w.setFrame(tt.khungCu, display: true, animate: false) }
        // Cửa sổ thử (VM_PIP) không kéo app lên trước → không cướp chuột/bàn phím của anh
        if giuTruoc && w.identifier?.rawValue != "vm-thu-pip" { NSApp.activate(); w.makeKeyAndOrderFront(nil) } else { w.orderFront(nil) }
        NSLog("VM: PiP ra – %@ (%@)", NSStringFromRect(w.frame), giuTruoc ? "phóng to" : "tắt PiP")
    }

    // Cmd+Shift+P – thu nhỏ / phóng to cuộc gọi bằng tay
    @objc func doiPiP() {
        guard let w = cuaSoPhu.first(where: laCuocGoi) else { NSLog("VM: Cmd+Shift+P – không có cuộc gọi"); return }
        if pip[ObjectIdentifier(w)]?.dangPiP == true { raPiP(w, giuTruoc: true) } else { vaoPiP(w) }
    }

    func mucTuPiP() -> NSMenuItem {
        let i = NSMenuItem(title: "Tự thu nhỏ cuộc gọi khi chuyển app", action: #selector(doiTuPiP(_:)), keyEquivalent: "")
        i.target = self
        i.state = tuPiP ? .on : .off
        return i
    }
    @objc func doiTuPiP(_ i: NSMenuItem) { tuPiP.toggle(); i.state = tuPiP ? .on : .off; NSLog("VM: tự PiP = %@", tuPiP ? "bật" : "tắt") }

    // Nút xanh: đang PiP → về cỡ thường (thay vì phóng to kín màn hình)
    func windowShouldZoom(_ w: NSWindow, toFrame f: NSRect) -> Bool {
        guard pip[ObjectIdentifier(w)]?.dangPiP == true else { return true }
        raPiP(w, giuTruoc: true)
        return false
    }

    // Anh kéo cửa sổ PiP → nhớ vị trí cho lần sau
    func windowDidMove(_ n: Notification) {
        guard let w = n.object as? NSWindow, pip[ObjectIdentifier(w)]?.dangPiP == true else { return }
        UserDefaults.standard.set(NSStringFromPoint(w.frame.origin), forKey: "viTriPiP")
    }
    func windowWillClose(_ n: Notification) {
        guard let w = n.object as? NSWindow, w != window else { return }
        if laCuocGoi(w) { NSLog("VM: ĐO cửa sổ cuộc gọi đóng") }
        pip[ObjectIdentifier(w)] = nil
        cuaSoPhu.removeAll { $0 == w }
    }

    // MARK: Đo khi gọi – ghi pid (app, nhân web, nhân đồ hoạ) để script đo CPU; nhiệt máy theo mức của macOS
    static func tenNhiet() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "bình thường"
        case .fair: return "hơi ấm"
        case .serious: return "NÓNG"
        case .critical: return "QUÁ NÓNG"
        @unknown default: return "?"
        }
    }
    func ghiPidDo(_ wv: WKWebView) {
        func soPid(_ k: String, _ o: NSObject) -> Int {
            o.responds(to: NSSelectorFromString(k)) ? ((o.value(forKey: k) as? NSNumber)?.intValue ?? 0) : 0
        }
        NSLog("VM: ĐO pid app=%d webGoi=%d webChinh=%d nhiệt=%@", getpid(),
              soPid("_webProcessIdentifier", wv), soPid("_webProcessIdentifier", webView), AppDelegate.tenNhiet())
    }
}

// MARK: Cài đặt (⌘,) – 4 tab: Thông báo · Cuộc gọi · Tải file · Chung (anh duyệt trang xem thử 03/11, bỏ phần Cập nhật – làm sau)
let ngayPhatHanh = "04/11/2026"
let tenApp = "iMessenger"           // tên app (Tony chốt 04/11: iMessenger by @tonynehihi)
let coGiMoi = """
1.0.0 – 04/11/2026
• **REBRAND** → iMessenger by @tonynehihi
• Update checker + auto-install now point to tonynehihi/imessenger releases
• Fresh Ed25519 signing key for updates

tonynehihi
"""
let thuMucNhatKy = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/\(tenApp)")
let fileNhatKy = thuMucNhatKy.appendingPathComponent("messenger.log")

// Ghi nhật ký ra file (Cài đặt → Chẩn đoán): mọi dòng NSLog vẫn ra stderr như cũ, chép thêm vào ~/Library/Logs/<tên app>
var giuOngNhatKy: Pipe?
func batGhiNhatKyRaFile() {
    try? FileManager.default.createDirectory(at: thuMucNhatKy, withIntermediateDirectories: true)
    if let co = try? FileManager.default.attributesOfItem(atPath: fileNhatKy.path)[.size] as? Int, co > 5_000_000 {
        let cu = thuMucNhatKy.appendingPathComponent("messenger.1.log")
        try? FileManager.default.removeItem(at: cu); try? FileManager.default.moveItem(at: fileNhatKy, to: cu)
    }
    if !FileManager.default.fileExists(atPath: fileNhatKy.path) { FileManager.default.createFile(atPath: fileNhatKy.path, contents: nil) }
    guard let f = try? FileHandle(forWritingTo: fileNhatKy) else { return }
    f.seekToEndOfFile()
    let goc = dup(STDERR_FILENO), ong = Pipe()
    dup2(ong.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
    ong.fileHandleForReading.readabilityHandler = { h in
        let d = h.availableData; if d.isEmpty { return }
        d.withUnsafeBytes { _ = write(goc, $0.baseAddress, d.count) }
        f.write(d)
    }
    giuOngNhatKy = ong
}

final class HanhDong: NSObject {
    let lam: (Any) -> Void
    init(_ lam: @escaping (Any) -> Void) { self.lam = lam }
    @objc func chay(_ s: Any) { lam(s) }
}

extension AppDelegate {
    func caiDat(_ k: String, _ macDinh: Bool) -> Bool { UserDefaults.standard.object(forKey: k) as? Bool ?? macDinh }
    var ghiGoLoi: Bool { caiDat("ghiGoLoi", false) || ProcessInfo.processInfo.environment.keys.contains { $0.hasPrefix("VM_") } }
    func jsCaiDat() -> String {
        "window.__vmCaiDat = { baoTinNhan: \(caiDat("baoTinNhan", true)), boTinGoi: \(caiDat("boTinGoi", true)) };"
    }
    func guiCaiDatChoTrang() { webView.evaluateJavaScript(jsCaiDat(), completionHandler: nil) }

    @objc func moGioiThieu() { moCaiDat(); (cuaSoCaiDat?.contentView?.viewWithTag(77) as? NSSegmentedControl).map { $0.selectedSegment = 3; chonTab($0) } }
    @objc func moCaiDat() {
        if let w = cuaSoCaiDat { w.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        let tab = NSSegmentedControl(labels: ["Thông báo", "Cuộc gọi", "Tải file", "Chung"], trackingMode: .selectOne,
                                     target: self, action: #selector(chonTab(_:)))
        for (i, h) in ["bell", "phone", "arrow.down.circle", "gearshape"].enumerated() {
            tab.setImage(NSImage(systemSymbolName: h, accessibilityDescription: nil), forSegment: i)
        }
        tab.segmentStyle = .automatic; tab.selectedSegment = 0; tab.tag = 77
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 400), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Cài đặt \(tenApp)"; w.isReleasedWhenClosed = false
        let goc = NSView(); tab.translatesAutoresizingMaskIntoConstraints = false; goc.addSubview(tab)
        NSLayoutConstraint.activate([tab.topAnchor.constraint(equalTo: goc.topAnchor, constant: 14),
                                     tab.centerXAnchor.constraint(equalTo: goc.centerXAnchor),
                                     goc.widthAnchor.constraint(equalToConstant: 580)])
        w.contentView = goc
        cuaSoCaiDat = w
        chonTab(tab)
        w.center(); w.makeKeyAndOrderFront(nil); NSApp.activate()
        NSLog("VM: Cài đặt mở")
    }
    @objc func chonTab(_ tab: NSSegmentedControl) {
        guard let w = cuaSoCaiDat, let goc = w.contentView else { return }
        trangCaiDat?.removeFromSuperview(); giuHanhDong.removeAll()
        let trang = [trangThongBao, trangCuocGoi, trangTaiFile, trangChung][max(0, tab.selectedSegment)]()
        trang.translatesAutoresizingMaskIntoConstraints = false
        goc.addSubview(trang); trangCaiDat = trang
        NSLayoutConstraint.activate([trang.topAnchor.constraint(equalTo: tab.bottomAnchor, constant: 8),
                                     trang.leadingAnchor.constraint(equalTo: goc.leadingAnchor, constant: 22),
                                     trang.trailingAnchor.constraint(equalTo: goc.trailingAnchor, constant: -22),
                                     trang.bottomAnchor.constraint(equalTo: goc.bottomAnchor, constant: -22)])
        goc.layoutSubtreeIfNeeded()
        let cao = goc.fittingSize.height, f = w.frame
        let moi = w.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 580, height: cao))
        w.setFrame(NSRect(x: f.minX, y: f.maxY - moi.height, width: f.width, height: moi.height), display: true, animate: w.isVisible)
        // VM_CHUP_CD=<thư mục>: tự vẽ trang ra PNG để kiểm (screencapture không chụp được cửa sổ ở Space khác)
        if let tm = ProcessInfo.processInfo.environment["VM_CHUP_CD"] {
            let so = tab.selectedSegment
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                let v = goc, rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: tm).appendingPathComponent("cd-\(so).png"))
                NSLog("VM: đã chụp trang Cài đặt %d %@", so, NSStringFromSize(v.bounds.size))
            }
        }
    }

    // ——— Khối giao diện dùng chung ———
    func chuGhi(_ s: String) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: s); t.font = .systemFont(ofSize: 11.5); t.textColor = .secondaryLabelColor
        t.preferredMaxLayoutWidth = 500; return t
    }
    func tieuDeMuc(_ s: String, _ hinh: String) -> NSView {
        let a = NSImageView(image: NSImage(systemSymbolName: hinh, accessibilityDescription: nil) ?? NSImage())
        a.contentTintColor = .secondaryLabelColor
        let t = NSTextField(labelWithString: s); t.font = .systemFont(ofSize: 14, weight: .semibold)
        let h = NSStackView(views: [a, t]); h.spacing = 6
        return h
    }
    func dong(_ trai: NSView, _ phai: NSView?) -> NSView {
        let h = NSStackView(views: phai == nil ? [trai] : [trai, NSView(), phai!]); h.distribution = .fill; h.alignment = .centerY
        h.setHuggingPriority(.defaultLow, for: .horizontal)
        h.edgeInsets = NSEdgeInsets(top: 9, left: 0, bottom: 9, right: 0)
        return h
    }
    func congTac(_ khoa: String, _ macDinh: Bool, _ tieuDe: String, doi: ((Bool) -> Void)? = nil) -> NSView {
        let sw = NSSwitch(); sw.state = caiDat(khoa, macDinh) ? .on : .off; sw.controlSize = .small
        sw.setAccessibilityLabel(tieuDe)
        let hd = HanhDong { [weak self] s in
            let bat = (s as! NSSwitch).state == .on
            UserDefaults.standard.set(bat, forKey: khoa); NSLog("VM: Cài đặt %@ = %@", khoa, bat ? "bật" : "tắt")
            doi?(bat); _ = self
        }
        giuHanhDong.append(hd); sw.target = hd; sw.action = #selector(HanhDong.chay(_:))
        return dong(NSTextField(labelWithString: tieuDe), sw)
    }
    func nut(_ tieuDe: String, _ hinh: String? = nil, xanh: Bool = false, lien: Bool = false, _ lam: @escaping () -> Void) -> NSButton {
        let hd = HanhDong { _ in lam() }; giuHanhDong.append(hd)
        let b = NSButton(title: tieuDe, target: hd, action: #selector(HanhDong.chay(_:)))
        if let hinh { b.image = NSImage(systemSymbolName: hinh, accessibilityDescription: nil); b.imagePosition = .imageLeading }
        if xanh { b.bezelColor = .controlAccentColor; b.keyEquivalent = "" }
        if lien { b.isBordered = false; b.contentTintColor = .linkColor
            b.attributedTitle = NSAttributedString(string: tieuDe, attributes: [.foregroundColor: NSColor.linkColor, .font: NSFont.systemFont(ofSize: 13)]) }
        return b
    }
    // Thẻ bo góc chứa các dòng, có vạch ngăn
    func the(_ cac: [NSView]) -> NSView {
        var ds: [NSView] = []
        for (i, v) in cac.enumerated() {
            if i > 0, !(v is NSTextField) { let vach = NSBox(); vach.boxType = .separator; ds.append(vach) }
            ds.append(v)
        }
        let st = NSStackView(views: ds); st.orientation = .vertical; st.alignment = .leading; st.spacing = 4
        st.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 10, right: 14)
        for v in ds { v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalTo: st.widthAnchor, constant: -28).isActive = true }
        st.wantsLayer = true; st.layer?.cornerRadius = 10
        st.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
        return st
    }
    func trangDoc(_ cac: [NSView]) -> NSView {
        let st = NSStackView(views: cac); st.orientation = .vertical; st.alignment = .leading; st.spacing = 8
        for v in cac { v.translatesAutoresizingMaskIntoConstraints = false; v.widthAnchor.constraint(equalTo: st.widthAnchor).isActive = true }
        return st
    }

    // ——— 4 trang ———
    func trangThongBao() -> NSView {
        trangDoc([
            tieuDeMuc("Tin nhắn", "message"),
            the([congTac("baoTinNhan", true, "Báo tin nhắn mới khi không mở app") { [weak self] _ in self?.guiCaiDatChoTrang() },
                 chuGhi("App tự xem danh sách chat 2 giây/lần khi anh ở app khác (Messenger trên Safari không tự gửi thông báo tin nhắn). Không lưu nội dung."),
                 congTac("boTinGoi", true, "Bỏ thông báo tin về cuộc gọi khi bảng gọi đang hiện") { [weak self] _ in self?.guiCaiDatChoTrang() },
                 chuGhi("Tránh thông báo «đã bắt đầu / đã kết thúc cuộc gọi» trùng với bảng gọi. Vẫn giữ thông báo «cuộc gọi nhỡ».")]),
            tieuDeMuc("Cuộc gọi đến", "phone.arrow.down.left"),
            the([congTac("bangGoiNoi", true, "Hiện bảng nổi góc màn hình") { [weak self] _ in self?.capNhatBangGoi() },
                 congTac("dockNayGoi", true, "Icon trên Dock nảy khi có cuộc gọi"),
                 chuGhi("Tin nhắn thì Dock không nảy, chỉ hiện thông báo.")]),
            dong(chuGhi("Muốn thông báo hiện cả nội dung: Cài đặt hệ thống → Thông báo → \(tenApp) → Hiện bản xem trước → Luôn luôn."),
                 nut("Mở cài đặt Thông báo") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!) }),
        ])
    }
    func trangCuocGoi() -> NSView {
        trangDoc([
            tieuDeMuc("Thu nhỏ cuộc gọi (PiP)", "pip"),
            the([congTac("tuPiP", true, "Tự thu nhỏ cuộc gọi khi chuyển app / bấm sang cửa sổ chat"),
                 chuGhi("Cửa sổ gọi thu nhỏ 360×240, nổi trên mọi app, kể cả khi chia sẻ màn hình. Nút xanh hoặc ⇧⌘P để phóng to lại.")]),
        ])
    }
    func trangTaiFile() -> NSView {
        let chon = NSPopUpButton(); chon.addItems(withTitles: ["Hỏi mỗi lần", "Luôn lưu vào thư mục bên dưới"])
        chon.selectItem(at: UserDefaults.standard.string(forKey: "noiLuu") == "thang" ? 1 : 0)
        let hd = HanhDong { s in
            let thang = (s as! NSPopUpButton).indexOfSelectedItem == 1
            UserDefaults.standard.set(thang ? "thang" : "hoi", forKey: "noiLuu"); NSLog("VM: Cài đặt nơi lưu = %@", thang ? "lưu thẳng" : "hỏi mỗi lần")
        }
        giuHanhDong.append(hd); chon.target = hd; chon.action = #selector(HanhDong.chay(_:))
        let tai = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let hienTai = UserDefaults.standard.url(forKey: "thuMucLuu") ?? tai
        let ten = NSTextField(labelWithString: FileManager.default.displayName(atPath: hienTai.path)); ten.textColor = .secondaryLabelColor
        let chonThuMuc = nut("Chọn…") { [weak self] in
            let h = NSOpenPanel(); h.canChooseDirectories = true; h.canChooseFiles = false; h.canCreateDirectories = true
            h.directoryURL = UserDefaults.standard.url(forKey: "thuMucLuu") ?? tai; h.prompt = "Chọn"
            guard let w = self?.cuaSoCaiDat else { return }
            h.beginSheetModal(for: w) { kq in
                guard kq == .OK, let u = h.url else { return }
                UserDefaults.standard.set(u, forKey: "thuMucLuu"); ten.stringValue = FileManager.default.displayName(atPath: u.path)
                NSLog("VM: Cài đặt thư mục lưu = %@", u.lastPathComponent)
            }
        }
        let phai = NSStackView(views: [ten, chonThuMuc]); phai.spacing = 8
        return trangDoc([
            tieuDeMuc("Khi bấm Tải xuống", "arrow.down.circle"),
            the([dong(NSTextField(labelWithString: "Nơi lưu"), chon),
                 dong(NSTextField(labelWithString: "Thư mục (mở sẵn / lưu thẳng)"), phai),
                 chuGhi("Ảnh tải bằng nút Tải xuống giữ độ phân giải gốc Messenger đang lưu.")]),
        ])
    }
    func trangChung() -> NSView {
        // Mở cùng macOS (Login Items)
        let sw = NSSwitch(); sw.controlSize = .small; sw.state = SMAppService.mainApp.status == .enabled ? .on : .off
        sw.setAccessibilityLabel("Mở \(tenApp) khi đăng nhập máy")
        let hd = HanhDong { s in
            let sw = s as! NSSwitch
            do { if sw.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                 NSLog("VM: Cài đặt mở cùng máy = %@", sw.state == .on ? "bật" : "tắt") }
            catch { NSLog("VM: mở cùng máy lỗi – %@", error.localizedDescription); sw.state = SMAppService.mainApp.status == .enabled ? .on : .off }
        }
        giuHanhDong.append(hd); sw.target = hd; sw.action = #selector(HanhDong.chay(_:))
        // Hiện bảng phím tắt = ngược của "khongHienPhimTat"
        let sw2 = NSSwitch(); sw2.controlSize = .small; sw2.state = UserDefaults.standard.bool(forKey: "khongHienPhimTat") ? .off : .on
        sw2.setAccessibilityLabel("Hiện bảng phím tắt khi mở app")
        let hd2 = HanhDong { [weak self] s in
            let hien = (s as! NSSwitch).state == .on
            UserDefaults.standard.set(!hien, forKey: "khongHienPhimTat"); self?.oKhongHien?.state = hien ? .off : .on
            NSLog("VM: Cài đặt hiện bảng phím tắt khi mở = %@", hien ? "bật" : "tắt")
        }
        giuHanhDong.append(hd2); sw2.target = hd2; sw2.action = #selector(HanhDong.chay(_:))
        // Giới thiệu
        let icon = NSImageView(image: NSApp.applicationIconImage); icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true; icon.heightAnchor.constraint(equalToConstant: 64).isActive = true
        let ten = NSTextField(labelWithString: tenApp); ten.font = .systemFont(ofSize: 20, weight: .semibold)
        let ban = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let pb = NSTextField(labelWithString: "Phiên bản \(ban) · \(ngayPhatHanh)"); pb.textColor = .secondaryLabelColor
        let bq = NSTextField(labelWithString: "© 2026 by @tonynehihi"); bq.font = .systemFont(ofSize: 11.5); bq.textColor = .secondaryLabelColor
        let chu = NSStackView(views: [ten, pb, bq]); chu.orientation = .vertical; chu.alignment = .leading; chu.spacing = 2
        let gt = NSStackView(views: [icon, chu]); gt.spacing = 14; gt.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        let lien = NSStackView(views: [
            nut("Phím tắt", lien: true) { [weak self] in self?.moBangPhim() },
            nut("Có gì mới", lien: true) { [weak self] in
                let a = NSAlert(); a.messageText = "Có gì mới"; a.informativeText = coGiMoi; a.addButton(withTitle: "Đóng")
                if let w = self?.cuaSoCaiDat { a.beginSheetModal(for: w) } },
            nut("Thư mục nhật ký", lien: true) { NSWorkspace.shared.activateFileViewerSelecting([fileNhatKy]) },
        ]); lien.spacing = 16
        // Cập nhật: dòng trạng thái
        let oTT = NSTextField(labelWithString: trangThaiCapNhat); oTT.textColor = .secondaryLabelColor; oTT.font = .systemFont(ofSize: 12)
        oTrangThaiCN = oTT
        // Chẩn đoán
        let cacNut = NSStackView(views: [
            nut("Chép nhật ký", "doc.on.doc") {
                let ds = ((try? String(contentsOf: fileNhatKy, encoding: .utf8)) ?? "").split(separator: "\n", omittingEmptySubsequences: false)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(ds.suffix(400).joined(separator: "\n"), forType: .string)
                NSLog("VM: đã chép %d dòng nhật ký", min(400, ds.count)) },
            nut("Lưu nhật ký…", "square.and.arrow.down") { [weak self] in
                let h = NSSavePanel(); h.nameFieldStringValue = "iMessenger-nhat-ky.log"
                h.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
                guard let w = self?.cuaSoCaiDat else { return }
                h.beginSheetModal(for: w) { kq in
                    guard kq == .OK, let u = h.url else { return }
                    try? FileManager.default.removeItem(at: u); try? FileManager.default.copyItem(at: fileNhatKy, to: u)
                    NSLog("VM: đã lưu nhật ký → %@", u.lastPathComponent) } },
            nut("Xoá", "trash") { [weak self] in
                let a = NSAlert(); a.messageText = "Xoá nhật ký?"; a.informativeText = "Xoá nội dung file nhật ký trên máy. Không ảnh hưởng tin nhắn."
                a.addButton(withTitle: "Xoá"); a.addButton(withTitle: "Hủy")
                guard let w = self?.cuaSoCaiDat else { return }
                a.beginSheetModal(for: w) { kq in
                    guard kq == .alertFirstButtonReturn else { return }
                    try? FileHandle(forWritingTo: fileNhatKy).truncate(atOffset: 0); NSLog("VM: đã xoá nhật ký") } },
        ]); cacNut.spacing = 8
        return trangDoc([
            tieuDeMuc("Khởi động", "power"),
            the([dong(NSTextField(labelWithString: "Mở \(tenApp) khi đăng nhập máy"), sw),
                 dong(NSTextField(labelWithString: "Hiện bảng phím tắt khi mở app"), sw2),
                 chuGhi("Xem lại bảng phím tắt bất cứ lúc nào: ⌘/.")]),
            tieuDeMuc("Giới thiệu", "info.circle"),
            the([gt, lien]),
            tieuDeMuc("Tài khoản & dữ liệu", "person.crop.circle"),
            the([dong(nut("Đăng xuất và xoá dữ liệu…", "rectangle.portrait.and.arrow.right") { [weak self] in self?.hoiDangXuat() }, NSTextField(labelWithString: "")),
                 chuGhi("Dùng máy chung, hoặc trước khi đưa máy cho người khác: xoá đăng nhập và dữ liệu Messenger lưu trên máy này. Tin nhắn trên tài khoản không bị xoá.")]),
            tieuDeMuc("Cập nhật", "arrow.triangle.2.circlepath"),
            the([dong(nut("Kiểm tra cập nhật", "arrow.clockwise", xanh: true) { [weak self] in self?.kiemTraCapNhat(imLang: false) }, oTT),
                 chuGhi("App không tự hỏi – bấm nút để xem có bản mới trên GitHub (\(khoGitHub)). Bản mới được kiểm chữ ký số trước khi cài; app tự thay bản cũ và mở lại. Đăng nhập, cài đặt giữ nguyên.")]),
            tieuDeMuc("Chẩn đoán", "stethoscope"),
            the([congTac("ghiGoLoi", false, "Ghi nhật ký gỡ lỗi"),
                 chuGhi("Tắt: chỉ ghi lỗi và số đo. Bật: ghi chi tiết (dò tin, cuộc gọi) để tìm lỗi – không ghi nội dung tin nhắn hay tên người."),
                 cacNut]),
        ])
    }
}

// MARK: Tự cập nhật (anh chọn mức 2, 03/11): hỏi GitHub Releases → có bản mới → tải zip + chữ ký → kiểm chữ ký Ed25519
// bằng khoá công khai gắn sẵn (khoá bí mật chỉ nằm trong Keychain máy anh, xem phat-hanh/khoa.swift) → thay app → mở lại.
// File do app tự tải không bị gắn dấu "tải từ Internet" → người dùng không phải bấm "Vẫn mở" lại.
// Public key ký cập nhật của Tony (tạo 03/11/2026, private key trong Keychain máy Tony)
let khoaCongKhaiCapNhat = "TKyrjF0Lo/97QETXDMWFJBeanwpyqqOTJzmiXOOpSzk="
let khoGitHub = "tonynehihi/imessenger"

struct BanPhatHanh { let ban: String; let ghiChu: String; let zip: URL?; let sig: URL?; let trang: URL }
enum LoiCapNhat: LocalizedError {
    case lyDo(String)
    var errorDescription: String? { if case .lyDo(let s) = self { return s }; return nil }
}
// So 2 bản dạng 0.6.1: >0 nếu a mới hơn b
func soSanhBan(_ a: String, _ b: String) -> Int {
    let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<max(x.count, y.count) { let d = (i < x.count ? x[i] : 0) - (i < y.count ? y[i] : 0); if d != 0 { return d } }
    return 0
}
var banHienTai: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

extension AppDelegate {
    var urlKiemTraCapNhat: URL {
        URL(string: ProcessInfo.processInfo.environment["VM_CAPNHAT_URL"] ?? "https://api.github.com/repos/\(khoGitHub)/releases/latest")!
    }
    var trangThaiCapNhat: String {
        get { UserDefaults.standard.string(forKey: "trangThaiCapNhat") ?? "Chưa kiểm tra" }
        set { UserDefaults.standard.set(newValue, forKey: "trangThaiCapNhat"); oTrangThaiCN?.stringValue = newValue }
    }
    // Gọi lúc mở app: báo nếu vừa cập nhật xong (không tự kiểm tra bản mới)
    func batLichCapNhat() {
        if let tu = UserDefaults.standard.string(forKey: "vuaCapNhatTu") {
            UserDefaults.standard.removeObject(forKey: "vuaCapNhatTu")
            NSLog("VM: CẬP NHẬT xong %@ → %@", tu, banHienTai)
            trangThaiCapNhat = "Đã cập nhật lên \(banHienTai)"
            let nd = UNMutableNotificationContent(); nd.title = "Đã cập nhật iMessenger \(banHienTai)"; nd.body = "Từ bản \(tu). Đăng nhập và cài đặt giữ nguyên."
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "capnhat", content: nd, trigger: nil))
        }
        // Không tự hỏi GitHub (anh chốt 03/11: người dùng tự bấm «Kiểm tra cập nhật» trong Cài đặt / menu).
        // Chạy thử: VM_CAPNHAT_URL → kiểm ngay sau 10 giây.
        if ProcessInfo.processInfo.environment["VM_CAPNHAT_URL"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.kiemTraCapNhat(imLang: true) }
        }
    }
    // Đăng xuất và xoá dữ liệu (anh duyệt 03/11): xoá MỌI dữ liệu web của app (cookie đăng nhập, bộ nhớ trang, IndexedDB…)
    // rồi tải lại messenger.com → trang đăng nhập. Không đụng cài đặt của app.
    func hoiDangXuat() {
        let a = NSAlert(); a.alertStyle = .critical
        a.messageText = "Đăng xuất và xoá dữ liệu Messenger?"
        a.informativeText = "Xoá đăng nhập, cookie và dữ liệu Messenger lưu trên máy này. Tin nhắn trên tài khoản không bị xoá. Lần sau phải đăng nhập lại."
        a.addButton(withTitle: "Đăng xuất và xoá"); a.addButton(withTitle: "Hủy")
        a.buttons.first?.hasDestructiveAction = true
        guard let w = cuaSoCaiDat else { return }
        a.beginSheetModal(for: w) { [weak self] kq in if kq == .alertFirstButtonReturn { self?.dangXuatVaXoa() } }
    }
    func dangXuatVaXoa() {
        cuaSoPhu.forEach { $0.close() }                       // đóng cửa sổ gọi đang mở
        let kho = WKWebsiteDataStore.default(), loai = WKWebsiteDataStore.allWebsiteDataTypes()
        kho.fetchDataRecords(ofTypes: loai) { truoc in
            kho.removeData(ofTypes: loai, modifiedSince: .distantPast) {
                kho.httpCookieStore.getAllCookies { banh in
                    NSLog("VM: ĐĂNG XUẤT – đã xoá dữ liệu %d trang web, còn %d cookie", truoc.count, banh.count)
                    self.webView.load(URLRequest(url: URL(string: "https://www.messenger.com/")!))
                    self.baoCapNhat("Đã đăng xuất", "Đã xoá đăng nhập và dữ liệu Messenger trên máy này.")
                }
            }
        }
    }
    @objc func kiemTraCapNhatMenu() { kiemTraCapNhat(imLang: false) }

    // imLang = kiểm ngầm khi chạy thử (không báo "đang mới nhất", không báo lỗi mạng)
    func kiemTraCapNhat(imLang: Bool) {
        trangThaiCapNhat = "Đang kiểm tra…"
        var rq = URLRequest(url: urlKiemTraCapNhat, timeoutInterval: 20)
        rq.setValue("iMessenger/\(banHienTai)", forHTTPHeaderField: "User-Agent")
        rq.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: rq) { du, _, loi in DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(Date(), forKey: "lanKiemCapNhat")
            guard let du, let j = try? JSONSerialization.jsonObject(with: du) as? [String: Any], let tag = j["tag_name"] as? String,
                  let trang = URL(string: j["html_url"] as? String ?? "https://github.com/\(khoGitHub)/releases") else {
                NSLog("VM: CẬP NHẬT – không kiểm tra được: %@", loi?.localizedDescription ?? "dữ liệu lạ")
                self.trangThaiCapNhat = "Không kiểm tra được (mất mạng?)"
                if !imLang { self.baoCapNhat("Không kiểm tra được bản mới", loi?.localizedDescription ?? "GitHub trả dữ liệu lạ.") }
                return
            }
            let ds = (j["assets"] as? [[String: Any]] ?? []).compactMap { a -> (String, URL)? in
                guard let t = a["name"] as? String, let u = URL(string: a["browser_download_url"] as? String ?? "") else { return nil }
                return (t, u)
            }
            let zip = ds.first { $0.0.hasSuffix(".zip") }
            let b = BanPhatHanh(ban: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, ghiChu: j["body"] as? String ?? "",
                                zip: zip?.1, sig: zip.flatMap { z in ds.first { $0.0 == z.0 + ".sig" }?.1 }, trang: trang)
            NSLog("VM: CẬP NHẬT – mới nhất %@, đang dùng %@", b.ban, banHienTai)
            if soSanhBan(b.ban, banHienTai) <= 0 {
                self.trangThaiCapNhat = "Đang dùng bản mới nhất (\(banHienTai))"
                if !imLang { self.baoCapNhat("Bạn đang dùng bản mới nhất", "iMessenger \(banHienTai).") }
                return
            }
            self.trangThaiCapNhat = "Có bản mới \(b.ban)"
            self.hoiCapNhat(b)
        } }.resume()
    }
    func baoCapNhat(_ tieuDe: String, _ chu: String) {
        let a = NSAlert(); a.messageText = tieuDe; a.informativeText = chu; a.addButton(withTitle: "OK")
        if let w = cuaSoCaiDat, w.isVisible { a.beginSheetModal(for: w) } else { NSApp.activate(); a.runModal() }
    }
    func hoiCapNhat(_ b: BanPhatHanh) {
        // Ghi chú Release (Markdown) → chữ thường, tối đa 14 dòng
        let ghi = b.ghiChu.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "#", with: "")
            .split(separator: "\n", omittingEmptySubsequences: true).prefix(14).joined(separator: "\n")
        let a = NSAlert(); a.messageText = "Có bản iMessenger \(b.ban)"
        a.informativeText = "Bạn đang dùng \(banHienTai).\n\n\(ghi)"
        let tuCai = b.zip != nil && b.sig != nil
        a.addButton(withTitle: tuCai ? "Cập nhật ngay" : "Mở trang tải"); a.addButton(withTitle: "Để sau")
        let tu = ProcessInfo.processInfo.environment["VM_CAPNHAT_TU"] == "1"        // chạy thử: tự chọn "Cập nhật ngay"
        NSApp.activate()
        let kq = tu ? .alertFirstButtonReturn : a.runModal()
        NSLog("VM: CẬP NHẬT – hộp hỏi %@ → %@", b.ban, kq == .alertFirstButtonReturn ? "cập nhật" : "để sau")
        if kq == .alertFirstButtonReturn { if tuCai { taiVaCai(b) } else { NSWorkspace.shared.open(b.trang) } }
    }
    func taiVaCai(_ b: BanPhatHanh) {
        let dich = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: dich.deletingLastPathComponent().path), let zipU = b.zip, let sigU = b.sig else {
            NSLog("VM: CẬP NHẬT – thư mục app không ghi được → mở trang tải")
            baoCapNhat("Không tự cập nhật được", "Thư mục chứa app không cho ghi. Mở trang tải để cài bản \(b.ban) bằng tay.")
            NSWorkspace.shared.open(b.trang); return
        }
        let cho = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 90), styleMask: [.titled], backing: .buffered, defer: false)
        cho.title = "Đang cập nhật"
        let quay = NSProgressIndicator(frame: NSRect(x: 20, y: 35, width: 20, height: 20)); quay.style = .spinning; quay.startAnimation(nil)
        let chu = NSTextField(labelWithString: "Đang tải iMessenger \(b.ban)…"); chu.frame = NSRect(x: 52, y: 36, width: 250, height: 18)
        cho.contentView?.addSubview(quay); cho.contentView?.addSubview(chu); cho.center(); cho.makeKeyAndOrderFront(nil)
        Task {
            do {
                let tam = FileManager.default.temporaryDirectory.appendingPathComponent("imessenger-cap-nhat-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: tam, withIntermediateDirectories: true)
                let (fz, _) = try await URLSession.shared.download(from: zipU)
                let (fs, _) = try await URLSession.shared.download(from: sigU)
                let zip = tam.appendingPathComponent("moi.zip"); try FileManager.default.moveItem(at: fz, to: zip)
                // 1. Chữ ký số: zip phải do khoá bí mật của anh ký
                let sigChu = try String(contentsOf: fs, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                guard let sig = Data(base64Encoded: sigChu), let kcc = Data(base64Encoded: khoaCongKhaiCapNhat),
                      let khoa = try? Curve25519.Signing.PublicKey(rawRepresentation: kcc),
                      khoa.isValidSignature(sig, for: try Data(contentsOf: zip)) else { throw LoiCapNhat.lyDo("Chữ ký số của bản tải về không khớp – không cài (có thể file bị sửa).") }
                // 2. Giải nén, kiểm đúng app, đúng bản, chữ ký mã hợp lệ
                let giai = tam.appendingPathComponent("giai")
                try chayLenh("/usr/bin/ditto", ["-x", "-k", zip.path, giai.path])
                guard let app = try FileManager.default.contentsOfDirectory(at: giai, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" }),
                      let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
                      info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
                      info["CFBundleShortVersionString"] as? String == b.ban else { throw LoiCapNhat.lyDo("File tải về không đúng app / đúng bản \(b.ban).") }
                try chayLenh("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
                await MainActor.run { self.thayVaMoLai(app, dich, tam, tuBan: banHienTai) }
            } catch {
                await MainActor.run {
                    cho.orderOut(nil)
                    NSLog("VM: CẬP NHẬT lỗi – %@", error.localizedDescription)
                    self.trangThaiCapNhat = "Cập nhật lỗi – vẫn dùng \(banHienTai)"
                    self.baoCapNhat("Cập nhật không thành công", "\(error.localizedDescription)\n\nApp vẫn dùng bản \(banHienTai).")
                }
            }
        }
    }
    func chayLenh(_ lenh: String, _ thamSo: [String]) throws {
        let p = Process(); p.executableURL = URL(fileURLWithPath: lenh); p.arguments = thamSo
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        if p.terminationStatus != 0 { throw LoiCapNhat.lyDo("Lệnh \((lenh as NSString).lastPathComponent) lỗi (\(p.terminationStatus)).") }
    }
    // Script nhỏ chờ app thoát hẳn → đổi app cũ sang bản mới (lỗi thì trả bản cũ) → mở lại
    func thayVaMoLai(_ moi: URL, _ dich: URL, _ tam: URL, tuBan: String) {
        let sh = tam.appendingPathComponent("thay.sh")
        try? """
        #!/bin/sh
        i=0; while kill -0 "$1" 2>/dev/null && [ $i -lt 150 ]; do sleep 0.2; i=$((i+1)); done
        if mv "$2" "$4"; then
          if mv "$3" "$2"; then open "$2"; exit 0; fi
          mv "$4" "$2"
        fi
        open "$2"
        """.write(to: sh, atomically: true, encoding: .utf8)
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [sh.path, "\(ProcessInfo.processInfo.processIdentifier)", dich.path, moi.path, tam.appendingPathComponent("cu.app").path]
        do { try p.run() } catch { NSLog("VM: CẬP NHẬT – không chạy được script thay: %@", error.localizedDescription); return }
        UserDefaults.standard.set(tuBan, forKey: "vuaCapNhatTu")
        NSLog("VM: CẬP NHẬT – đã kiểm chữ ký, thoát để thay bản mới")
        NSApp.terminate(nil)
    }
}

// Chỉ chạy 1 bản: 2 bản cùng dùng chung dữ liệu đăng nhập → Messenger báo "Không thể tải đoạn chat" (anh gặp 03/11 09:23).
// Mở thêm → đưa bản đang chạy lên trước rồi thoát.
if let khac = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
    .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }) {
    NSLog("VM: đã có bản đang chạy (pid %d) → đưa lên trước, bản này thoát", khac.processIdentifier)
    khac.activate()
    exit(0)
}
batGhiNhatKyRaFile()
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
