#!/usr/bin/env python3
"""List SFM profile paths and local proxy ports without displaying credentials."""
import json
from pathlib import Path
import sqlite3
import sys


def find_profiles(root):
    for folder in sorted(root.glob('*io.nekohasekai.sfa*')):
        db = folder / 'settings.db'
        if not db.is_file():
            continue
        try:
            with sqlite3.connect(db.resolve().as_uri() + '?mode=ro', uri=True) as conn:
                profiles = conn.execute('SELECT name, path FROM profiles').fetchall()
        except (OSError, sqlite3.Error) as error:
            print('无法读取配置目录:', folder.name, type(error).__name__, file=sys.stderr)
            continue
        for name, raw_path in profiles:
            if not raw_path:
                continue
            path = Path(raw_path).expanduser()
            if not path.is_absolute():
                path = folder / path
            try:
                config = json.loads(path.read_text())
                ports = [x['listen_port'] for x in config.get('inbounds', [])
                         if x.get('type') in ('http', 'mixed') and x.get('listen') == '127.0.0.1'
                         and isinstance(x.get('listen_port'), int)]
            except (OSError, ValueError, TypeError, AttributeError):
                ports = []
            yield name, path, ports


def main():
    profiles = list(find_profiles(Path.home() / 'Library/Group Containers'))
    if not profiles:
        print('未找到 SFM 配置。请确认已安装 SFM 并导入配置，或检查 macOS 隐私权限。')
        return 1
    for name, path, ports in profiles:
        print('配置名称:', name)
        print('配置路径:', path)
        print('本地代理端口:', ', '.join(map(str, ports)) if ports else '未找到')
        print()
    print('请根据 SFM 中当前选中的配置名称选择；不要上传或分享配置文件。')
    return 0


if __name__ == '__main__':
    sys.exit(main())
