#!/usr/bin/env python3
"""《坦克基地》开场剧情分镜稿生成器
从当前实现重建 output/story_preview.html：
- 文案：解析 scripts/story_intro_data.gd 的 SLIDES（title/body/tip）
- 插画：sprites/story/intro_01~06.png（当前游戏使用版本，base64 内嵌，单文件可分发）
- 版式：对齐播放场景 story_intro.tscn / story_intro.gd（页眉简报号+标题、插画、正文、琥珀要点）
用法: python3 tools/gen_story_preview.py
输出: output/story_preview.html
"""
import base64
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA_PATH = os.path.join(ROOT, "scripts", "story_intro_data.gd")
IMG_DIR = os.path.join(ROOT, "sprites", "story")
OUT_PATH = os.path.join(ROOT, "output", "story_preview.html")


def parse_slides(src):
    """从 story_intro_data.gd 提取 SLIDES（title/body/tip）。"""
    slides = []
    pattern = re.compile(
        r'"title":\s*"(?P<title>[^"]*)",\s*'
        r'"body":\s*"(?P<body>(?:[^"\\]|\\.)*)",\s*'
        r'"tip":\s*"(?P<tip>(?:[^"\\]|\\.)*)"',
        re.S)
    for m in pattern.finditer(src):
        body = m.group("body").replace("\\n", "\n")
        tip = m.group("tip").replace("\\n", "\n")
        slides.append((m.group("title"), body, tip))
    return slides


def img_b64(idx):
    path = os.path.join(IMG_DIR, "intro_%02d.png" % idx)
    with open(path, "rb") as f:
        return base64.b64encode(f.read()).decode("ascii")


def main():
    with open(DATA_PATH, encoding="utf-8") as f:
        slides = parse_slides(f.read())
    if len(slides) != 6:
        print("警告: 预期 6 幕，实际解析到 %d 幕" % len(slides))

    cards = []
    for i, (title, body, tip) in enumerate(slides, 1):
        paras = "\n".join(
            '      <div class="body">%s</div>' % p for p in body.split("\n"))
        cards.append(
            '    <div class="card">\n'
            '      <div class="head"><span class="no">简报 %02d / %02d</span>'
            '<span class="title">%s</span></div>\n'
            '      <img src="data:image/png;base64,%s" width="512" height="256" alt="%s">\n'
            '%s\n'
            '      <div class="tip">▶ 要点：%s</div>\n'
            '    </div>'
            % (i, len(slides), title, img_b64(i), title, paras, tip))

    page = """<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8">
<title>《坦克基地》开场剧情分镜稿</title>
<style>
 body{background:#0C120A;color:#D8E0C8;font-family:"PingFang SC","Microsoft YaHei",monospace;max-width:600px;margin:0 auto;padding:24px 12px;}
 h1{color:#97C459;text-align:center;font-size:22px;letter-spacing:8px;margin:8px 0 2px;}
 .sub{color:#BA7517;text-align:center;font-size:12px;letter-spacing:4px;margin-bottom:24px;}
 .card{background:#182216;border:1px solid #4A5D3A;margin-bottom:28px;padding:14px;}
 .head{display:flex;justify-content:space-between;align-items:baseline;margin-bottom:10px;}
 .no{color:#7A8570;font-size:12px;}
 .title{color:#9CCC65;font-size:18px;letter-spacing:4px;}
 img{display:block;width:100%;image-rendering:pixelated;border:1px solid #2E3D28;}
 .body{font-size:14px;line-height:1.8;margin-top:10px;}
 .tip{color:#EF9F27;font-size:12px;line-height:1.7;margin-top:10px;border-top:1px dashed #2E3D28;padding-top:8px;}
 .foot{color:#7A8570;font-size:12px;text-align:center;line-height:1.8;margin:24px 0;}
</style></head><body>
<h1>坦 克 基 地</h1>
<div class="sub">TANK BASE · 开场剧情分镜稿 · 作战简报 × __COUNT__</div>

__CARDS__
<div class="foot">文案源 scripts/story_intro_data.gd · 插画 sprites/story/（256×128 逐像素程序化生成，游戏内 2x 显示）<br>
播放场景 scenes/story_intro.tscn · 本页由 tools/gen_story_preview.py 从当前实现生成</div>
</body></html>""".replace("__COUNT__", str(len(slides))).replace("__CARDS__", "\n".join(cards))

    with open(OUT_PATH, "w", encoding="utf-8") as f:
        f.write(page)
    print("生成", os.path.relpath(OUT_PATH, ROOT), "（%d 幕）" % len(slides))


if __name__ == "__main__":
    main()
