# 图标来源

`make-icon.swift` 是本项目原创图标的完整绘制源码，使用 AppKit 绘制底板、圆环及折线，无第三方位图素材。与项目同为 MIT 许可证。

生成 1024×1024 PNG：

```sh
mkdir -p dist
xcrun swift Assets/make-icon.swift dist/icon-1024.png
```

`AppIcon.icns` 是从该图缩放成 macOS iconset 后用系统 `iconutil` 生成的资源。运行时界面使用系统提供的 SF Symbols。
