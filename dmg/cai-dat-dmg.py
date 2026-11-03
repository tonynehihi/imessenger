# Cấu hình dmgbuild cho DMG Messenger Vdk (dmgbuild tự ghi bố cục .DS_Store – không cần điều khiển Finder,
# vì AppleScript đặt ảnh nền của Finder trên macOS 27 báo lỗi -10000).
import unicodedata
format = 'UDZO'
filesystem = 'HFS+'
files = [defines['app'], defines['huongdan']]
symlinks = {'Applications': '/Applications'}
icon = defines['icon']                       # icon ổ đĩa
background = defines['nen']                  # nen.tiff (1x + 2x)
window_rect = ((200, 120), (660, 470))
default_view = 'icon-view'
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 96
text_size = 12
icon_locations = {
    'Messenger Vdk.app': (165, 150),
    'Applications': (495, 150),
    'Hướng dẫn mở lần đầu.html': (330, 318),
}
# Ổ HFS+ lưu tên file có dấu dạng NFD → khoá cũng phải NFD, không thì Finder không đặt đúng chỗ
icon_locations = {unicodedata.normalize('NFD', k): v for k, v in icon_locations.items()}
