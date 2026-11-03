#!/usr/bin/env python3
"""Đổi HUONG-DAN-CAI.md → 1 file HTML tự chứa (ảnh nhúng base64) để bỏ vào DMG.
Chỉ hỗ trợ đúng phần Markdown file hướng dẫn dùng: # / ##/###, danh sách, >, ```, bảng, **, *, `, [link](), <img>.
Cách chạy: python3 dmg/md-sang-html.py HUONG-DAN-CAI.md <ra.html>"""
import base64, html, os, re, sys
vao, ra = sys.argv[1], sys.argv[2]; goc = os.path.dirname(os.path.abspath(vao))
def dong(t):
    t = html.escape(t, quote=False)
    t = re.sub(r'&lt;img src="([^"]+)"([^&]*)&gt;', lambda m: '<img src="data:image/png;base64,%s"%s>' % (
        base64.b64encode(open(os.path.join(goc, m.group(1)), 'rb').read()).decode(), html.unescape(m.group(2))), t)
    t = re.sub(r'`([^`]+)`', r'<code>\1</code>', t)
    t = re.sub(r'\*\*([^*]+)\*\*', r'<b>\1</b>', t)
    t = re.sub(r'\*([^*]+)\*', r'<i>\1</i>', t)
    t = re.sub(r'\[([^\]]+)\]\(([^)]+)\)', r'<a href="\2">\1</a>', t)
    return t
out, ds, ma, bang = [], None, False, []
def dongDs():
    global ds
    if ds: out.append('</%s>' % ds); ds = None
def dongBang():
    global bang
    if bang:
        h = ''.join('<th>%s</th>' % dong(c) for c in bang[0])
        r = ''.join('<tr>%s</tr>' % ''.join('<td>%s</td>' % dong(c) for c in hang) for hang in bang[2:])
        out.append('<table><tr>%s</tr>%s</table>' % (h, r)); bang = []
for l in open(vao, encoding='utf-8').read().split('\n'):
    if l.startswith('```'):
        dongDs(); out.append('</pre>' if ma else '<pre>'); ma = not ma; continue
    if ma: out.append(html.escape(l)); continue
    s = l.strip()
    if s.startswith('|'): bang.append([c.strip() for c in s.strip('|').split('|')]); continue
    dongBang()
    if not s: continue
    if re.match(r'^#{1,3} ', s):
        dongDs(); n = len(s.split(' ')[0]); out.append('<h%d>%s</h%d>' % (n, dong(s[n+1:]), n)); continue
    if s.startswith('>'): dongDs(); out.append('<blockquote>%s</blockquote>' % dong(s[1:].strip())); continue
    m = re.match(r'^(\d+\.|-) (.*)', s)
    if m and not l.startswith('   '):
        loai = 'ol' if m.group(1)[0].isdigit() else 'ul'
        if ds != loai: dongDs(); out.append('<%s>' % loai); ds = loai
        out.append('<li>%s' % dong(m.group(2))); continue
    if ds and l.startswith('   '): out.append('<div class="them">%s</div>' % dong(s)); continue
    dongDs(); out.append('<p>%s</p>' % dong(s))
dongDs(); dongBang()
css = """body{font:15px/1.6 -apple-system,sans-serif;max-width:760px;margin:30px auto;padding:0 18px;color:#1d1d1f;background:#fff}
h1{font-size:26px}h2{font-size:19px;margin-top:28px;border-bottom:1px solid #ddd;padding-bottom:4px}h3{font-size:16px;margin-top:20px;color:#0a58d0}
code{background:#f1f1f4;padding:1px 5px;border-radius:4px}pre{background:#1e1e22;color:#eee;padding:12px 14px;border-radius:8px;overflow-x:auto}
blockquote{margin:10px 0;padding:6px 12px;border-left:4px solid #f0b400;background:#fff8e1;border-radius:4px}
img{max-width:100%;border-radius:10px;margin:8px 0;box-shadow:0 2px 10px #0002}table{border-collapse:collapse;width:100%}td,th{border:1px solid #ddd;padding:6px 8px;text-align:left}
th{background:#f5f5f7}.them{margin:4px 0 4px 0}
a{color:#0a58d0}@media (prefers-color-scheme:dark){a{color:#6cb0ff}body{background:#1c1c1e;color:#eee}code{background:#333}th{background:#2a2a2d}td,th{border-color:#444}blockquote{background:#3a3220}h3{color:#5aa2ff}}"""
open(ra, 'w', encoding='utf-8').write('<!doctype html><html lang="vi"><head><meta charset="utf-8"><title>Hướng dẫn mở lần đầu – Messenger Vdk</title><style>%s</style></head><body>%s</body></html>' % (css, '\n'.join(out)))
print('ok', ra)
