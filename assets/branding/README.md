# 应用图标

图标形态是「三本竖立的书脊 + 奶油色播放徽章」，底色为 r7-mist「薄雾蓝」
（`#E9EFF3` → `#CDD8E0`）。设计稿由脚本生成，`app_icon_source.png` 是 1024×1024 的
满幅母图——不预切圆角、不带白边，桌面圆角由系统图标蒙版裁切。

缺省资产已随源码提交，普通构建不需要 Python。要改图标时，在仓库根目录执行：

```sh
python -m pip install "Pillow>=9.1" numpy
python scripts/generate_ohos_icons.py            # 重新生成全部资产
python scripts/generate_ohos_icons.py --preview  # 另存多尺寸预览到 build/app_icon_preview.png
```

脚本一次写出四处资产：

| 文件 | 尺寸 | 用途 |
| --- | --- | --- |
| `assets/branding/app_icon_source.png` | 1024 | 设计母图（不入 assets 清单，不进包） |
| `ohos/AppScope/resources/base/media/app_icon.png` | 512 | 应用图标，`AppScope/app.json5` 的 `icon` |
| `ohos/entry/src/main/resources/base/media/icon.png` | 512 | 启动页图标，`module.json5` 的 `startWindowIcon` |
| `assets/images/app_logo.webp` | 512（圆角 23.5%） | 应用内「关于」「我的」等页面的 logo |

几何参数（书脊宽度/高度、书页块、徽章位置）改动会直接影响图标识别，修改前先看清楚
`generate_ohos_icons.py` 里的注释。底色是冷调，投影必须用冷色（`SHADOW = (78, 92, 112)`）——
暖褐投影会在薄雾蓝上留一层脏晕。

生成后需重新 `flutter build hap --debug` 并 `hdc install -r` 装机，桌面图标与启动图才会更新；
热重载不会刷新图标。桌面显示的应用名来自 `ohos/entry/src/main/resources/<locale>/element/string.json`
的 `EntryAbility_label`（当前为「博观」）。
