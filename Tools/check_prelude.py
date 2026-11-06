#!/usr/bin/env python3
"""校验 JSRunner.swift 里的 prelude 能否通过 JS 语法检查。

关键：不能直接拿源码里的文本去跑 node --check。
Swift 多行字符串会解释这些转义：
    \\n -> 换行      \\t -> tab      \\r -> 回车
    \\"  -> 双引号    \\\\ -> 反斜杠    \\( -> 插值
所以 JS 里写 split('\\n') 编译后变成 split('<真换行>')，
字符串被拆断 → "SyntaxError: Unexpected EOF"。

这个脚本先按 Swift 规则还原，再交给 node --check。
上一轮就是漏了这一步，真机上炸了才发现。
"""
import re
import subprocess
import sys

import os
SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'LINGVERSE', 'Engine', 'JSRunner.swift')


def extract_multiline_string(path, name):
    """取出 let <name> = 三引号字符串 的正文。"""
    src = open(path).read()
    pat = re.compile(r'let\s+' + re.escape(name) + r'\s*=\s*"""\n(.*?)\n\s*"""', re.S)
    m = pat.search(src)
    return m.group(1) if m else None


def swift_unescape(text):
    """按 Swift 多行字符串规则还原转义。"""
    out = []
    i = 0
    while i < len(text):
        c = text[i]
        if c == '\\' and i + 1 < len(text):
            nxt = text[i + 1]
            mapping = {'n': '\n', 't': '\t', 'r': '\r', '"': '"', "'": "'",
                       '\\': '\\', '0': '\0'}
            if nxt in mapping:
                out.append(mapping[nxt])
                i += 2
                continue
            if nxt == '(':
                out.append('<INTERPOLATION>')
                i += 2
                continue
            out.append(c)
            i += 1
            continue
        out.append(c)
        i += 1
    return ''.join(out)


def main():
    raw = extract_multiline_string(SRC, 'prelude')
    if raw is None:
        print('❌ 未找到 prelude')
        return 1

    print(f'源码文本: {len(raw)} 字符')
    # 找所有会被 Swift 解释的转义
    escapes = []
    for m in re.finditer(r'\\(.)', raw):
        escapes.append((m.group(1), m.start()))
    if escapes:
        print(f'含 {len(escapes)} 处 Swift 转义（会改变 JS 内容）：')
        for ch, pos in escapes:
            line = raw[:pos].count('\n') + 1
            ctx = raw[max(0, pos - 40):pos + 20].replace('\n', ' ')
            print(f'  第 {line} 行  \\{ch}   … {ctx.strip()[:70]}')
    else:
        print('无转义')

    js = swift_unescape(raw)
    open('/tmp/prelude_check.js', 'w').write(js)

    r = subprocess.run(['node', '--check', '/tmp/prelude_check.js'],
                       capture_output=True, text=True)
    if r.returncode == 0:
        print(f'\n✅ 还原后语法正确（{len(js)} 字符）')
        return 0

    print('\n❌ 还原后有 JS 语法错误：')
    print(r.stderr[:1000])
    return 1


if __name__ == '__main__':
    sys.exit(main())
