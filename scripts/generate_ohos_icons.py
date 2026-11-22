# -*- coding: utf-8 -*-
"""生成博观在鸿蒙工程里用到的全部图标资产（r7-mist「薄雾蓝」书脊图标）。

设计：三本竖立的书脊 + 奶油色播放徽章。母图满幅、不预切圆角——桌面圆角由
系统图标蒙版裁切，只有 in-app 的 `app_logo.webp` 需要自带圆角。

用法（仓库根目录，即 app/ 的上一级）：

    python scripts/generate_ohos_icons.py             # 重新生成，覆盖已提交图片
    python scripts/generate_ohos_icons.py --preview   # 另存一张对比预览到 build/

依赖：Python 3.9+、Pillow ≥ 9.1、numpy。生成结果随源码提交，普通构建不需要
Python；只有改图标时才需要跑一次。
"""
import argparse
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

APP_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
S, W = 1024, 2048  # 输出尺寸 / 超采样画布

# r7-mist 薄雾蓝：底自上而下由浅到深
BG_TOP, BG_BOT = (233, 239, 243), (205, 216, 224)
# 浅底上略加深饱和，避免书脊被亮背景「洗白」
BOOKS = [(131, 156, 136, 255), (192, 130, 97, 255), (211, 168, 78, 255)]
PAGE_LIGHT = (252, 248, 238, 255)  # 书页块
CREAM = (250, 245, 233, 255)  # 播放徽章圆底
INK = (46, 47, 43, 255)  # 播放三角
SHADOW = (78, 92, 112)  # 冷调投影：暖褐色投影会在薄雾蓝上留一层脏晕
BLOOM_STRENGTH = 0.045

TARGETS = [
    (r"assets/branding/app_icon_source.png", "png1024"),
    (r"ohos/AppScope/resources/base/media/app_icon.png", "png512"),
    (r"ohos/entry/src/main/resources/base/media/icon.png", "png512"),
    (r"assets/images/app_logo.webp", "webp512r"),
]
# in-app logo 的像素宽，与 lib/pages/about_page.dart 的 _logoPixelWidth 保持一致
LOGO_SIZE = 512


def vertical_gradient(top, bottom):
    """128 级竖直渐变，放大会得到平滑的过渡。"""
    strip = Image.new("RGB", (1, 128))
    draw = ImageDraw.Draw(strip)
    for y in range(128):
        t = y / 127
        draw.point((0, y), tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return strip.resize((W, W), Image.BICUBIC).convert("RGBA")


def bloom(img, strength):
    """左上角柔光，让底色在书脊后面自然提亮一点。"""
    yy, xx = np.mgrid[0:W, 0:W].astype(np.float32)
    dist = np.sqrt((xx - 0.27 * W) ** 2 + (yy - 0.17 * W) ** 2) / (0.95 * W)
    falloff = np.clip(1.0 - dist, 0, 1) ** 2
    arr = np.asarray(img.convert("RGB")).astype(np.float32)
    arr += falloff[..., None] * 255.0 * strength
    return Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), "RGB").convert("RGBA")


def drop_shadows(base, mark, rgb, layers):
    """把图形层当蒙版，依次叠多层阴影：(alpha, blur 比例, 下移比例)。"""
    alpha = mark.split()[3]
    for a, blur, dy in layers:
        shadow = alpha.filter(ImageFilter.GaussianBlur(int(W * blur)))
        layer = Image.new("RGBA", (W, W), tuple(rgb) + (0,))
        layer.putalpha(shadow.point(lambda v, al=a: int(v * al / 255)))
        base.alpha_composite(layer, dest=(0, int(W * dy)))


def play_badge(draw, cx, cy, r, disc, tri):
    draw.ellipse([(cx - r) * W, (cy - r) * W, (cx + r) * W, (cy + r) * W], fill=disc)
    draw.polygon([(cx - r * 0.28) * W, (cy - r * 0.42) * W,
                  (cx - r * 0.28) * W, (cy + r * 0.42) * W,
                  (cx + r * 0.46) * W, cy * W], fill=tri)


def draw_icon():
    """画 2048px 画布，缩到 1024px 输出。几何与已验收的版本一致，改动会影响图标识别。"""
    base = bloom(vertical_gradient(BG_TOP, BG_BOT), BLOOM_STRENGTH)
    mark = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    draw = ImageDraw.Draw(mark)

    base_y = 0.800  # 三本书共用的底边
    widths = (0.170, 0.178, 0.168)
    heights = (0.560, 0.705, 0.520)
    gap = 0.014
    x = 0.5 - (sum(widths) + gap * 2) / 2
    for w, h, color in zip(widths, heights, BOOKS):
        draw.rounded_rectangle([x * W, (base_y - h) * W, (x + w) * W, base_y * W],
                               radius=int(W * 0.026), fill=color)
        # 书页块：书脊顶上露出的一小段纸边
        draw.rounded_rectangle([(x + 0.012) * W, (base_y - h - 0.022) * W,
                                (x + w - 0.012) * W, (base_y - h + 0.012) * W],
                               radius=int(W * 0.010), fill=PAGE_LIGHT)
        # 书脊下部的压印横带
        draw.rounded_rectangle([(x + 0.018) * W, (base_y - h * 0.22) * W,
                                (x + w - 0.018) * W, (base_y - h * 0.22 + 0.020) * W],
                               radius=int(W * 0.008), fill=(0, 0, 0, 46))
        x += w + gap
    play_badge(draw, 0.770, 0.775, 0.074, CREAM, INK)

    drop_shadows(base, mark, SHADOW, [(22, 0.020, 0.012), (12, 0.006, 0.003)])
    base.alpha_composite(mark)

    arr = np.asarray(base.convert("RGB")).astype(np.float32)
    noise = np.random.default_rng(29).normal(0, 1.4, arr.shape[:2])[..., None]
    return Image.fromarray(np.clip(arr + noise, 0, 255).astype(np.uint8), "RGB").resize(
        (S, S), Image.LANCZOS)


def rounded(img, ratio=0.225):
    out = img.convert("RGBA")
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, img.size[0] - 1, img.size[1] - 1],
                                           radius=int(img.size[0] * ratio), fill=255)
    out.putalpha(mask)
    return out


def main(argv=None):
    parser = argparse.ArgumentParser(description="生成鸿蒙工程的博观图标资产")
    parser.add_argument("--preview", action="store_true",
                        help="另存一张 1024 / 216 / 96 / 64 / 44px 的对比预览到 build/")
    args = parser.parse_args(argv)

    img = draw_icon()
    for rel, kind in TARGETS:
        path = os.path.join(APP_DIR, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        if kind == "png1024":
            img.save(path, "PNG", optimize=True)
        elif kind == "png512":
            img.resize((512, 512), Image.LANCZOS).save(path, "PNG", optimize=True)
        elif kind == "webp512r":
            rounded(img.resize((LOGO_SIZE, LOGO_SIZE), Image.LANCZOS), 0.235).save(
                path, "WEBP", quality=92, method=6)
        print("wrote", os.path.relpath(path, APP_DIR))

    if args.preview:
        out_dir = os.path.join(APP_DIR, "build")
        os.makedirs(out_dir, exist_ok=True)
        sheet = Image.new("RGB", (760, 300), (245, 243, 238))
        x = 30
        for size in (216, 96, 64, 44):
            tile = rounded(img.resize((size, size), Image.LANCZOS))
            paper = Image.new("RGB", (size, size), (245, 243, 238))
            paper.paste(tile, (0, 0), tile)
            sheet.paste(paper, (x, (300 - size) // 2))
            x += size + 30
        preview = os.path.join(out_dir, "app_icon_preview.png")
        sheet.save(preview)
        print("wrote", os.path.relpath(preview, APP_DIR))
    return 0


if __name__ == "__main__":
    sys.exit(main())
