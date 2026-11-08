# PencilDesk (iPad-Mac 高效手写与触控系统) 精简实施架构方案

> **核心原则**：最大化复用系统原生能力与成熟开源资产，**拒绝重复造轮子**，**不针对个别绘图软件做定制开发**，直接打通通用系统级事件与功能。

---

## 1. 用户核心需求精准映射与方案选型

| 用户核心需求 | 选型与技术实现策略 | 为什么最省时间/最可靠 |
| :--- | :--- | :--- |
| **1. 手写文字识别发送到电脑**<br>*(直接用系统自带)* | **iPadOS 原生 Scribble (随手写) + Unicode 文本注入**<br>• iPad 端内置带有系统 Scribble 功能的交互输入条（或浮动文字手写板）。<br>• 利用 iPadOS 系统级笔迹手写识别自动转为文本字符串。<br>• 经由既有通道发送 `.text(String)`，Mac 端通过 `CGEventKeyboard` 直接注入光标位置。 | **零 OCR 模型依赖**：无需训练或集成第三方 Tesseract/Vision 模型，系统级 Scribble 支持中英文、标点符号及笔势删除，延迟为零。 |
| **2. 镜像电脑界面操控** | **ScreenCaptureKit + VideoToolbox 硬编流 (借鉴 Sill)**<br>• Mac 端使用 `ScreenCaptureKit` 60~120fps 捕获屏幕或指定窗口。<br>• VideoToolbox HEVC/H.264 硬件直编，iPad 端 `AVSampleBufferDisplayLayer` 硬解。<br>• 触控/笔尖点击、拖拽、滚轮双向实时响应。 | **成熟可用**：开源项目 Sill 已经跑通了整套 USB/Wi-Fi 传输、配对和零延迟流式渲染框架，无需重构推流栈。 |
| **3. 数位板 / 数位屏通用功能**<br>*(不单独适配特定软件)* | **通用的 macOS Quartz Tablet 事件注入 (借鉴 pencil-probe)**<br>• **数位屏模式**：在 Mac 镜像画面上直接绘制，Apple Pencil 笔尖下笔即画。<br>• **数位板模式**：一键关闭视频流，iPad 变为磨砂纯黑手写板，延迟降至 1~2ms，超长续航。<br>• **通用压感注入**：基于系统标准 `CGEvent` 注入 `mouseSubtypeTabletPoint` 与 `kCGTabletEventPointPressure`。 | **系统级通配**：Photoshop、Clip Studio Paint、Krita、Affinity、Blender、Sketchbook 均原生监听系统 Tablet 事件，一次注入即可全通用，彻底省去软件专配时间。 |

---

## 2. 系统整体交互与流转架构

```
+-----------------------------------------------------------------------------------------+
|                                    iPadOS 客户端                                         |
|                                                                                         |
|  [ 模式 1: 镜像数位屏模式 ]               [ 模式 2: 纯手写板模式 ]                        |
|  - 实时接收 Mac 视频帧 (Metal/AVSample)   - 纯黑磨砂背景 (关闭视频解码，延迟 < 2ms)      |
|  - 全屏交互与触控反馈                    - 绝对坐标 1:1 映射至 Mac 显示器              |
|                                                                                         |
|  +-----------------------------------------------------------------------------------+  |
|  | [ 特色组件: 系统随手写输入栏 (Scribble Input Zone) ]                                 |  |
|  | - 调起系统原生 Scribble / PKCanvasView 识别中英文手写                                |  |
|  | - 识别出的字符串直接打包为 .text(string) 发送至 Mac                                 |  |
|  +-----------------------------------------------------------------------------------+  |
|                                            |                                            |
|                       Apple Pencil 240Hz 采样流水线                                     |
|                       - (X, Y 归一化坐标, 压力 Pressure, 倾斜角度 TiltX/Y, Hover)        |
|                                            |                                            |
|                                            v                                            |
|                                [ 二进制通信协议流 (USB / Wi-Fi) ]                       |
+--------------------------------------------|--------------------------------------------+
                                             |  USB-C CDC-NCM (IPv6 链路本地直连) 或 Wi-Fi
+--------------------------------------------|--------------------------------------------+
|                                            v                                            |
|                                     macOS 宿主端                                         |
|                                                                                         |
|  +---------------------------+  +-------------------------------+                       |
|  | 文本事件分发器            |  | 通用 Tablet 事件注入引擎      |                       |
|  | - 接收 .text(String)      |  | - CGEvent(mouseType: ...)     |                       |
|  | - CGEvent(keyboard: ...)  |  | - subtype = TabletPoint       |                       |
|  | - 模拟击键或直接粘贴      |  | - 设置 tabletEventPointPressure|                       |
|  +-------------+-------------+  | - 双路径 postStandaloneTablet |                       |
|                |                +---------------+---------------+                       |
|                v                                v                                       |
|  +-----------------------------------------------------------------------------------+  |
|  |                           macOS WindowServer 事件总线                             |  |
|  |   - 光标文本输入区 (任意文本框、IDE、办公软件)                                     |  |
|  |   - 绘图应用 (Photoshop, CSP, Krita, Affinity, Blender, 备忘录等通用免适配响应)   |  |
|  +-----------------------------------------------------------------------------------+  |
|                                            ^                                            |
|                                            |                                            |
|  +-----------------------------------------+-----------------------------------------+  |
|  | 屏幕捕获与硬件编码器 (ScreenCaptureKit + VideoToolbox HEVC)                         |  |
|  +-----------------------------------------------------------------------------------+  |
+-----------------------------------------------------------------------------------------+
```

---

## 3. 三大核心功能的具体实现细节

### 3.1 功能一：系统级手写文字识别与发送 (Handwriting to Mac)
* **实现方案**：
  * 在 iPad 界面顶部或底部提供一个可一键折叠/展开的 **手写悬浮栏 (Scribble Bar)**，内嵌开启了 Apple Pencil Scribble 的 `UITextField`，或者利用 `PencilKit` 的 `PKDrawing` 结合系统原生手写识别器。
  * **用户体验**：
    1. 用户用 Apple Pencil 在手写栏直接写字（支持连笔汉字、英文、数字、标点）；
    2. iPadOS 系统原生输入法在行内瞬间转为纯文本；
    3. 文本生成后，客户端立即向 Mac 发送：
       ```swift
       InputEvent.text(recognizedText)
       ```
    4. Mac 端的 `InputInjector` 在收到文本包时：
       - 若字符为标准 ASCII，合成按下/松开键盘事件；
       - 若字符为多字节中文或复杂符号，调用 `CGEventKeyboardSetUnicodeString` 批量注入到 Mac 当前聚焦的输入框中。
  * **优点**：无需安装第三方识别库，完全零配置，系统原生支持各种自然语言。

### 3.2 功能二：镜像电脑界面与低延迟操控 (Screen Mirroring & Control)
* **实现方案**：
  * 提取 **Sill** 的核心管道：
    * **Mac 采集端**：基于 macOS `ScreenCaptureKit` 抓取全屏或指定 App 窗口，交付 `VideoToolbox` 调用硬件编码器输出 HEVC 关键帧与增量帧。
    * **网络传输**：通过 USB 数据线直连（iPad USB-C CDC-NCM 虚拟网卡 + IPv6 链路本地地址与 Bonjour 发现，见 `CableLink.swift`）或同一局域网 Wi-Fi，保持画面高清晰度且帧率自适应（最高 120fps）。
    * **iPad 渲染端**：利用 `AVSampleBufferDisplayLayer` 硬件解码直出，延迟降低至 10ms 级别。
    * **直接触控操控**：单指滑动为鼠标移动，单指轻敲为左键点击，双指滑动为原生平滑滚动。

### 3.3 功能三：通用数位板与数位屏功能（无需单独适配软件）
* **实现方案**：
  * **数位屏模式 vs 数位板模式开关**：
    * **数位屏模式 (Screen Mode)**：iPad 显示 Mac 画面，在画面上直接下笔，适合插画精细描线与直接涂鸦。
    * **数位板模式 (Pad Mode)**：iPad 界面切为纯黑磨砂背景，关闭屏幕捕获流。延迟瞬间压缩至 **1.5ms 极限性能**，Apple Pencil 的绝对坐标精准映射到 Mac 屏幕。
  * **系统级压感注入（通用兼容性保障）**：
    参考 `pencil-probe` 的技术精髓，绝大多数专业绘图软件（Photoshop、CSP、Krita、Blender 等）在 macOS 上均通过系统标准的 `NSEvent` / `CGEvent` 获取平板信息。注入代码结构如下：
    ```swift
    // 注入带有标准平板特性的系统事件
    let event = CGEvent(mouseEventSource: source, mouseType: mouseType, mouseCursorPosition: point, mouseButton: .left)
    event.setIntegerValueField(.mouseEventSubtype, value: 1) // mouseSubtypeTabletPoint
    event.setDoubleValueField(.tabletEventPointPressure, value: normalizedPressure) // 0.0 ~ 1.0 压感
    event.setDoubleValueField(.mouseEventPressure, value: normalizedPressure)       // 备用兼容字段
    event.setDoubleValueField(.tabletEventTiltX, value: tiltX)                      // 倾角 X
    event.setDoubleValueField(.tabletEventTiltY, value: tiltY)                      // 倾角 Y
    event.post(tap: .cghidEventTap)

    // Clip Studio Paint 等绘图软件监听的独立 Tablet 路径
    let standaloneEvent = event.copy()
    standaloneEvent.type = .tabletPointer
    standaloneEvent.post(tap: .cghidEventTap)
    ```
  * **免驱动与免适配收益**：通过系统基础 `cghidEventTap` 注入标准事件，所有绘图软件均能开箱即用，无需编写特定驱动扩展（无需 DriverKit 签名），极大压缩研发周期。

---

## 4. 落地工程规划

```
PencilDesk 极简工程布局
├── PencilDeskMac/                 # macOS 宿主 (菜单栏轻量应用)
│   ├── Capture/ScreenStreamer.swift  # 屏幕捕获与硬编
│   ├── Input/TabletInjector.swift    # 通用压感/倾角事件注入 (CGEvent)
│   ├── Input/TextInputInjector.swift # 文本输入模拟
│   └── Network/CableLink.swift       # USB CDC-NCM (IPv6 link-local) + Wi-Fi 服务端
│
└── PencilDeskiOS/                 # iPadOS 客户端
    ├── Views/MirrorView.swift        # 镜像显示层
    ├── Views/BlankPadView.swift      # 纯手写板纯净绘图层
    ├── Views/ScribbleBar.swift       # 系统随手写输入悬浮条
    ├── Capture/PencilTracker.swift   # 240Hz 笔尖坐标/压力采样
    └── Network/LinkClient.swift      # 连接客户端
```
