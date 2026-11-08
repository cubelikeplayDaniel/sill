# PencilDesk (iPad-Mac 专业数位板系统) 核心架构设计方案

> **项目定位**：将 iPad 与 Apple Pencil 转化为面向 macOS 平台的专业手写板 / 数位屏系统，具备毫秒级输入延迟、通用壓感与倾斜感应、双模式显示流（数位屏镜像 + 纯黑无屏手写板）与 iPadOS 原生 Scribble 手写文字输入。
>
> **工程选型定稿说明**：实际落地以 `Saffsanity/sill` 为基座并结合 `pencil-probe` 的压感注入机制——有线 USB 通道直接复用 iPad USB-C **CDC-NCM 虚拟网卡 + IPv6 链路本地直连 (`CableLink.swift`)**（而非 `usbmuxd`），Mac 端压感采用免驱动扩展的 **Quartz `CGEvent` 双路径注入（`mouseSubtypeTabletPoint = 1` + 独立 `.tabletPointer` 事件）**（无需 `IOHIDUserDevice` 特权签名），实施细则以 [`streamlined-architecture.md`](streamlined-architecture.md) 与 [`superpowers/plans/2026-11-08-ipad-mac-stylus.md`](superpowers/plans/2026-11-08-ipad-mac-stylus.md) 为准。

---

## 1. 系统整体架构全景图

系统由 **iPadOS 触控采集端 (PencilDesk Touch)** 与 **macOS 宿主驱动端 (PencilDesk Host)** 两大核心子系统构成：

```
+-----------------------------------------------------------------------------------+
|                            iPadOS Client (PencilDesk Touch)                        |
|                                                                                   |
|  +-------------------------+  +------------------------+  +--------------------+  |
|  | Apple Pencil 240Hz 采集  |  | 触控手势与防误触过滤   |  | 虚拟外设控制面板   |  |
|  | - UIEvent / UITouch     |  | - Palm Rejection       |  | - ExpressKeys      |  |
|  | - 坐标/压力/倾角/桶滚   |  | - 多指撤销/重做/缩放   |  | - Radial Menu 轮盘 |  |
|  | - M2/M4 Hover 悬停预测  |  +------------------------+  +--------------------+  |
|  +------------+------------+               |                        |             |
|               |                            v                        v             |
|               +------------------> [ 触控事件归一化打包引擎 ] <-----+             |
|                                            |                                      |
|                                            v (48-byte Binary Packet)              |
|                               +-------------------------+                         |
|                               |  双通道自适应传输客户端  |                         |
|                               |  - USB Link (usbmuxd)   |                         |
|                               |  - Wi-Fi (UDP/Bonjour)  |                         |
|                               +------------+------------+                         |
|                                            |                                      |
+--------------------------------------------|--------------------------------------+
                                             | High-Speed Link (USB ~1ms / Wi-Fi ~4ms)
+--------------------------------------------|--------------------------------------+
|                                            v                                      |
|                               +-------------------------+                         |
|                               |  双通道传输服务端       |                         |
|                               |  - usbmuxd 隧道监听器   |                         |
|                               |  - UDP Jitter Buffer    |                         |
|                               +------------+------------+                         |
|                                            |                                      |
|                                            v                                      |
|                            [ 坐标映射与压感校准计算引擎 ]                         |
|                            - 屏幕比例自适应 (Letterbox)                           |
|                            - 多显示器 / 活动画图窗口映射                          |
|                            - 8192 级贝塞尔压感曲线转换                            |
|                                            |                                      |
|               +----------------------------+----------------------------+         |
|               |                                                         |         |
|               v (优先首选通道)                                          v (免驱降级通道)
|  +--------------------------------+                     +-----------------------+ |
|  | IOHIDUserDevice 虚拟数位板驱动 |                     | Quartz CGEvent 注入   | |
|  | - HID Usage Page 0x0D          |                     | - kCGEventLeftMouse   | |
|  | - 仿真标准 Wacom 硬件数位板    |                     | - CGEventTabletPoint  | |
|  | - Tip / Eraser / Tilt / Hover  |                     |   (Pressure/TiltX/Y)  | |
|  +----------------+---------------+                     +-----------+-----------+ |
|                   |                                                 |             |
|                   v                                                 v             |
|  +------------------------------------------------------------------------------+ |
|  |                          macOS 系统事件总线 (WindowServer)                   | |
|  |    Photoshop / Clip Studio Paint / Krita / Blender / Illustrator / SAI       | |
|  +------------------------------------------------------------------------------+ |
|                                                                                   |
|                                macOS Host Engine                                  |
+-----------------------------------------------------------------------------------+
```

---

## 2. 核心工作模式划分

系统支持三种互补运行模式，满足从极致性能手写板到直观数位屏的多样化工作流：

### 模式一：纯粹数位板模式 (Digitizer / Intuos Mode - "无屏板")
* **工作机制**：iPad 屏幕不传输 Mac 画面，充当一块纯黑或仿纸磨砂质感的专业绝对坐标绘图板。
* **技术优势**：
  * **零视频流消耗**：无编解码与网络视频抖动开销，端到端延迟低至 **1.2 ~ 1.8ms**。
  * **超低能耗与发热**：iPad 处理器处于超轻负载，电池可连续工作 10 小时以上。
  * **外设功能区扩展**：iPad 屏幕侧边可配置为数位板物理快捷键（ExpressKeys）、笔刷大小滑动触控条（Touch Strip）、以及 Apple Pencil 悬停触发的径向菜单（Radial Menu）。

### 模式二：低延迟数位屏模式 (Pen Display / Cintiq Mode - "有屏板")
* **工作机制**：Mac 屏幕（或选定区域）实时流式镜像到 iPad，用户直接在 iPad 上所见即所得下笔。
* **核心挑战与突破**：传统串流（如 AirPlay/普通镜像）会导致下笔有拖尾迟滞感。
* **本地瞬时笔迹预测 (Predictive Ink Overlay)**：
  * iPad 捕获笔尖时，在本地 Metal 层立即绘制基于 Hermite/Bézier 预测样条的浅色实时墨迹。
  * 当 Mac 处理完笔迹并通过硬编视频帧传回 iPad 时，本地预测层以 Alpha 蒙版精确平滑消除，消除用户对网络回传延迟的感知（Perceived Zero Latency）。

### 模式三：绘图应用精准画布映射模式 (App-targeted Canvas Mode)
* **工作机制**：通过 macOS Accessibility / CoreGraphics API 自动检测当前前台绘图软件（如 Photoshop、Krita、CSP）的活动画布窗口。
* **映射逻辑**：iPad 物理区域 100% 对应 Mac 绘图软件的有效绘制视口，避开菜单栏和工具箱，极大提升手写板利用效率。

---

## 3. 双端关键子系统深度设计

### 3.1 iPadOS 客户端核心系统 (PencilDesk Touch)

#### 1. 高频手写笔信号采样流水线
* **数据源**：接管 `UIResponder` 的 `touchesBegan` / `touchesMoved` / `touchesEnded`，并重点提取 `coalescedTouches(for:)`（合并触摸包）与 `predictedTouches(for:)`。
* **硬件级特征采集**：
  * **坐标与时效**：`preciseLocation(in:)` 亚像素级坐标，微秒级 `timestamp`。
  * **动力学压感**：提取 `force` 并根据 `maximumPossibleForce` 进行规范化至 `[0.0, 1.0]`，保持高线性度。
  * **三维姿态倾角**：
    * `altitudeAngle`（笔身与屏幕夹角，0 ~ π/2）。
    * `azimuthAngle` / `azimuthUnitVector(in:)`（笔尖投影方位角）。
  * **Apple Pencil Pro 专属特性**：
    * `rollAngle`（笔身绕中轴旋转角度，用于精准控制书法笔刷与斜扁笔刷朝向）。
    * Squeeze 手势捕获（笔身挤压触发快捷轮盘）。
  * **M2 / M4 iPad Pro Pencil Hover（悬停感应）**：
    * 采用 `UIHoverGestureRecognizer`，采样距离屏幕 12mm 以内的悬停坐标，同步向 Mac 注入未落笔状态下的光标移动与笔刷预览环。
* **手掌误触抑制 (Hardware Palm Rejection)**：
  * 强制分流过滤：`touch.type == .pencil` 独占主绘制信道；
  * `touch.type == .direct` 进入手势识别器（仅响应双指敲击撤销、三指敲击重做、双指捏合缩放画布），彻底阻断手掌误触。

#### 2. 局部预测渲染层 (Metal Ink Renderer)
* 采用 Metal 构建轻量化即时渲染着色器，通过 Quad-strip 算法实时将笔压与坐标解算为平滑多边形带，实现 120Hz ProMotion 极速上屏。

---

### 3.2 macOS 宿主驱动与注入系统 (PencilDesk Host)

#### 1. 双通道输入注入体系 (Input Injection Pipeline)

##### 首选核心方案：基于 `IOHIDUserDevice` 的真实数位板仿真
为了使 Photoshop、CSP、SAI 等行业绘画工具识别出真正的数位板硬件，Mac 端通过 `IOHIDUserDevice` 注册符合 **USB HID 规范 Usage Page 0x0D (Digitizers)** 的报告描述符（Report Descriptor）：
* **Usage (0x01): Digitizer / Usage (0x02): Pen**
* **Collections & Logical Limits**：
  * `Tip Switch` (Usage 0x42): 笔尖落笔状态
  * `Barrel Switch` (Usage 0x44): 笔身按键 / 橡皮按键
  * `Invert` (Usage 0x3C): 橡皮擦反转状态
  * `In Range` (Usage 0x32): 笔尖进入感应范围 (Hover)
  * `X, Y Coordinates`: 逻辑范围 `0 ~ 65535` 16位高精度绝对坐标
  * `Tip Pressure`: 逻辑范围 `0 ~ 8191`（标准 8192 级硬件压感）
  * `X Tilt / Y Tilt`: 物理倾斜角度转换
  * `Twist / Azimuth`: 旋转角度支持
* **效果**：系统将其枚举为一个真实的免驱数位板外设，所有专业绘图软件直接激活专业压感笔刷引擎，免除任何辅助功能权限模拟的兼容性问题。

##### 备用轻量级方案：Quartz CGEvent 仿真
* 对于无需安装或快速体验场景，通过 `CGEventCreateMouseEvent` 合成并在事件字段中注入：
  * `CGEventSetDoubleValueField(event, kCGTabletEventPointPressure, normalizedPressure)`
  * `CGEventSetIntegerValueField(event, kCGTabletEventPointTiltX, tiltX)`
  * `CGEventSetIntegerValueField(event, kCGTabletEventPointTiltY, tiltY)`
  * `CGEventSetIntegerValueField(event, kCGTabletEventDeviceID, virtualDeviceID)`

#### 2. 坐标映射与自适应引擎 (Coordinate Mapping Engine)
* **纵横比自适应 (Aspect Ratio Guard)**：
  * iPad 常见比例为 4:3 或 ~1.43:1；Mac 屏幕为 16:10 或 16:9。
  * 提供 **等比限制映射 (Proportional Mapping)**：在 iPad 边缘保留对称无感映射边界，杜绝“iPad 上画正圆，Mac 屏幕变成椭圆”的几何形变。
  * 提供 **全屏拉伸映射 (Stretch Mapping)**：满足无须绝对几何保真的快速速写。
* **多显示器管理**：支持指定映射到 Display 1 (MacBook 内置屏)、Display 2 (外接 4K/5K 显示器) 或由快捷键一键循环切换屏幕。
* **压感曲线微调器 (Bézier Pressure Curve Shaping)**：
  * 用户可调节输入点与输出压力的三次贝塞尔曲线控制点（$P_1, P_2$）。
  * 支持自定义 **启动最小死区 (Min Threshold)**（防止悬停蹭碰）与 **饱和压力 (Max Threshold)**（保护屏幕不过度用力）。

---

### 3.3 低延迟双链路传输系统 (Dual-Link Transport Layer)

```
[ iPadOS Client ]                                       [ macOS Host ]
       |                                                      |
       +=== 有线优先通道: usbmuxd (Lightning / Type-C) =======+  (RTT: 1.0~1.5ms)
       |   (Unix Domain Socket / TCP 隧道转发, 端口 52100)    |
       |                                                      |
       +--- 无线自愈通道: UDP + Bonjour 局域网广播 ----------+  (RTT: 3.5~6.0ms)
           (mDNS: _pencildesk._udp, Sequence+Timestamp 剔除)
```

1. **有线 USB 极速通道 (USB-C CDC-NCM IPv6 Link-Local)**:
   * 采用 iPad 通过 USB-C 接入 Mac 时由系统自动枚举的 **CDC-NCM 虚拟以太网接口**（无需 `usbmuxd` 或第三方 `PeerTalk`）。
   * Mac 与 iPad 在 USB NCM 接口上通过 IPv6 链路本地地址（`fe80::/10`）与 Bonjour 自动发现并建立低延迟直连（见 `CableLink.swift`）。
   * **优势**：0 驱动依赖、抗射频干扰、零丢包、抖动 < 0.2ms、边画边充电。
2. **无线局域网高敏通道 (Wireless Low-Latency UDP)**:
   * 基于 Bonjour (`_pencildesk._udp`) 自动零配置配对发现。
   * **触控数据传输**：严格采用轻量级 UDP 单向推流。每包携带单调递增 `uint32` 序号与微秒级时间戳。
   * **丢包处理原则（Freshness First）**：对于 120Hz~240Hz 的高频绘图事件，任何晚于当前处理帧的迟到包直接就地丢弃，绝对不执行 TCP 阻塞重传，从根源消灭“卡顿后突然画出一长串乱画”的重传洪峰。
3. **热插拔自适应无缝漂移 (Seamless Link Failover)**:
   * 启动双心跳链路检测。插线瞬间平滑将输入路由切至 USB，拔出即刻无缝回退到 Wi-Fi，用户画笔无需停顿。

---

## 4. 二进制传输协议规约 (Binary Wire Protocol Specification)

所有高频触控数据采用紧凑的 **48 字节固定大小对齐结构体**，内存零拷贝（Zero-Copy Direct Casting）：

```c
// 内存 4 字节严格对齐，总大小 48 字节
#pragma pack(push, 4)
typedef struct {
    uint32_t magic;           // 协议标识: 0x50454E44 ("PEND" - PencilDesk)
    uint16_t version;         // 协议版本: 0x0100
    uint16_t packet_type;     // 0x0001: 触控帧, 0x0002: 控制帧, 0x0003: 心跳
    uint32_t sequence;        // 单调递增序号，用于服务端乱序消除
    uint64_t timestamp_us;    // iPad 采集时刻精确微秒时间戳 (mach_continuous_time)

    // 空间与压力核心动力学参数 (均为 0.0 ~ 1.0 归一化浮点数，保持最高物理精度)
    float    norm_x;          // 归一化 X 坐标 (0.0 ~ 1.0)
    float    norm_y;          // 归一化 Y 坐标 (0.0 ~ 1.0)
    float    pressure;        // 归一化有效笔压 (0.0 ~ 1.0 对应 0 ~ 8192 级)
    float    altitude;        // 倾斜高度角 (0.0 ~ 1.5707 rad)
    float    azimuth;         // 倾斜方位角 (0.0 ~ 6.2831 rad)
    float    roll;            // 笔身轴向自旋角 (Apple Pencil Pro, 0.0 ~ 6.2831 rad)

    // 状态标志位
    uint8_t  phase;           // 0: Hover, 1: Began, 2: Moved, 3: Ended, 4: Cancelled
    uint8_t  tool_type;       // 0: Pen Tip, 1: Eraser (反转/快捷切换), 2: Finger Touch
    uint16_t buttons_flags;   // 位域掩码:
                              // Bit 0: Barrel Switch / Double Tap
                              // Bit 1: Squeeze (轻捏)
                              // Bit 2: ExpressKey 1
                              // Bit 3: ExpressKey 2 ...
} StylusPacket;
#pragma pack(pop)
```

---

## 5. 端到端延迟预算分解 (End-to-End Latency Budget)

在 USB 有线模式下的典型延迟预算分解表：

| 处理阶段 | 耗时 | 实现细节与优化策略 |
| :--- | :--- | :--- |
| **iPad 触控事件捕获** | 0.4 ms | `UIEvent` 高优先级线程直读，利用 ProMotion 240Hz 扫描极速抽取 |
| **协议打包与内存序列化** | 0.05 ms | 结构体内存对齐零分配（Zero-allocation），避免堆分配与 GC |
| **usbmuxd USB 物理传输** | 0.6 ms | Lightning/USB-C 硬件 DMA 批量传输，无 Wi-Fi 射频调度等待 |
| **Mac 接收与 Jitter 整理** | 0.1 ms | 环形缓冲区快速出队，剔除旧包，解包无拷贝映射 |
| **坐标投影与贝塞尔压感变换**| 0.05 ms | SIMD 指令加速坐标缩放与三次贝塞尔多项式拟合 |
| **IOHIDUserDevice 驱动注入** | 0.3 ms | 原生用户态 IOHIDFamily 事件管道提交至 WindowServer |
| **端到端总延迟 (Total Input Latency)** | **~1.5 ms** | 远低于 60Hz 帧间隔 (16.6ms) 及 120Hz 帧间隔 (8.3ms)，达到专业外设水准 |

---

## 6. 系统工程模块划分与实现技术栈

```
PencilDesk 仓库结构规划
├── PencilDesk-iOS/               # iPadOS App
│   ├── Core/
│   │   ├── PencilCaptureEngine.swift      # 240Hz 笔尖数据与手势采集
│   │   ├── PalmRejectionFilter.swift      # 硬件级防误触与多点手势隔离
│   │   └── MetalInkCanvas.swift           # 本地低延迟预测墨迹渲染器
│   ├── Transport/
│   │   ├── USBMuxClient.swift             # usbmuxd 隧道通信客户端
│   │   └── NetworkUDPClient.swift         # 低延迟 UDP 发送与 Bonjour 注册
│   └── UI/
│       ├── CanvasView.swift               # 磨砂手写板视口
│       ├── ExpressKeysOverlay.swift       # 侧边虚拟快捷键面板
│       └── SettingsView.swift             # 压感灵敏度与映射设置
│
├── PencilDesk-macOS/             # macOS MenuBar 宿主 App
│   ├── Driver/
│   │   ├── VirtualHIDDigitizer.swift      # IOHIDUserDevice 虚拟数位板包装器
│   │   ├── HIDReportDescriptor.h          # Wacom 兼容 0x0D 描述符定义
│   │   └── QuartzEventInjector.swift      # CGEventTabletPoint 降级注入器
│   ├── Mapping/
│   │   ├── CoordinateMapper.swift         # 屏幕比例约束 (Letterbox/Stretch)
│   │   ├── WindowTargetFinder.swift       # Photoshop/CSP 活动画布智能捕获
│   │   └── PressureCurveCalculator.swift  # 8192 级贝塞尔曲线转换
│   ├── Transport/
│   │   ├── USBMuxServer.swift             # 本地 usbmuxd 监听绑定 (52100)
│   │   └── UDPServerListener.swift        # UDP 触控包接收与乱序消除
│   └── Streaming/ (数位屏模式选配)
│       ├── ScreenCapturePipeline.swift    # ScreenCaptureKit 120fps 抓屏
│       └── VideoEncoder.swift             # VideoToolbox HEVC/H.264 硬件低延迟直编
└── Shared/
    └── Protocol/
        └── StylusPacket.h                 # 双端共享 C 头文件协议定长结构体
```

---

## 7. 权限清单与合规要求 (Entitlements & Privileges)

* **macOS 侧所需系统权限**：
  * **Accessibility (辅助功能权限)**：用于读取绘图软件窗口几何坐标及在必要时执行 CGEvent 事件注入。
  * **Screen Recording (屏幕录制权限)**：（仅在开启数位屏模式时需要）ScreenCaptureKit 捕获 Mac 绘图区域。
  * **User Client / DriverKit 权限**：若采用 `IOHIDUserDevice`，需配置 `com.apple.developer.hid.virtual.device` 或通过合法的开发者证书签名启用用户态 HID 仿真。
* **iPadOS 侧**：
  * **Local Network (本地网络访问)**：用于 Bonjour 局域网广播与 UDP 配对通信。
  * 保持屏幕常亮 (`isIdleTimerDisabled = true`)。

---

## 8. 开发实施演进路线图 (Milestones)

* **阶段 1：有线极速数位板最小可行性验证 (USB Minimum Viable Product)**
  * 完成 `StylusPacket` 协议定义与双端共享。
  * 实现 iPad 端基础 Apple Pencil 采样（坐标、压力、倾角）。
  * 实现 Mac 端 usbmuxd 通信服务与基于 `IOHIDUserDevice` 的虚拟数位板驱动原型。
  * 达成在 Photoshop 中画出第一根具备 8192 级真实压感的线条。
* **阶段 2：精度调优、手势与防误触 (Refinement & Precision)**
  * 完善 M2/M4 Apple Pencil 悬停感应（Hover Cursor 注入）。
  * 引入等比例映射（Letterbox）与活动窗口检测（Window Mapping）。
  * 增加参数化贝塞尔压感曲线调节界面。
  * 完善防误触与双指撤销/三指重做手势。
* **阶段 3：无线传输与双链路热切换 (Wireless & Link Management)**
  * 实现 Bonjour 局域网配对与无连接 UDP 传输。
  * 引入 USB 插入/拔出无缝热切换（零丢帧漂移）。
* **阶段 4：数位屏与预测墨迹渲染 (Display Mode & Metal Prediction)**
  * 集成 ScreenCaptureKit 局部捕获与 VideoToolbox 硬件硬编硬解。
  * 实现 iPad 端 Metal 本地瞬时笔迹预测覆盖层，彻底消除视觉延迟。
