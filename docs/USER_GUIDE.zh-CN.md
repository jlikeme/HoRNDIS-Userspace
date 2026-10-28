# HoRNDIS Userspace 中文使用手册

## 系统要求

- macOS 11 或更高版本，支持 Apple 芯片与 Intel Mac。
- Android 设备能够提供 RNDIS USB 控制和数据接口。
- 支持数据传输的 USB 线缆。
- 安装或升级后台网络服务时进行一次管理员认证。

HoRNDIS 运行在用户态，而不是作为内核扩展运行，因此用户无需降低启动安全性或关闭 SIP。

## 安装

```sh
brew install --cask jlikeme/tap/horndis
```

或直接安装 PKG：

1. 从 [GitHub Releases](https://github.com/jlikeme/HoRNDIS-Userspace/releases) 下载通用 `.pkg` 安装包。
2. 先尝试打开下载的 `.pkg`。
3. 如果 macOS 阻止打开，进入“**系统设置 → 隐私与安全性**”。
4. 找到 HoRNDIS 安装包的提示，点击“**仍要打开**”。
5. 根据提示输入管理员密码，然后完成安装。

> [!IMPORTANT]
> 本项目目前使用免费 Apple Developer 账户，无法获得公开分发安装包所需的付费 Developer ID 证书，因此不能对安装包进行签名和公证。macOS 可能会阻止首次打开，需要按上述步骤点击“**仍要打开**”。此过程不需要关闭 SIP 或降低系统安全级别。

如果系统缺少 `/Library/PrivilegedHelperTools`，安装程序会先按标准的 root
所有权和权限重新创建该目录，再安装 helper；用户无需手动准备目录。

在 Android 设置中打开 **USB 网络共享**。服务会自动发现 RNDIS 接口；如果手机还提供独立的 ADB 接口，ADB 可以同时使用。

## 菜单栏

App 使用 macOS 标准 Bundle 本地化，并跟随系统语言或 App 单独语言设置。内置英语、简体中文、繁体中文、日语、韩语、法语、德语、西班牙语、巴西葡萄牙语、意大利语和俄语。可前往“**系统设置 → 通用 → 语言与地区 → 应用程序**”为 HoRNDIS 状态栏选择语言，然后重新打开 App。

菜单默认保持精简，并使用 Apple SF Symbols 显示：

- 连接状态；
- 合并在同一行的 Android 设备名称与连接时长；
- 本次连接累计发送和接收流量；
- 仅在需要安装或修复时显示的管理员授权状态；
- 带勾选状态的“USB 网络共享”菜单项；
- 带勾选状态的“登录时启动”菜单项；
- 从侧边打开系统子菜单的“详细信息”菜单项。

打开“详细信息”后，系统会在侧边展开原生子菜单，显示 DHCP 地址、feth 接口、设备 MAC、服务 PID、后台状态和服务日志，并可保存诊断报告或进入引导式 Bug 反馈流程。

状态栏使用 macOS 原生模板图标，菜单使用动态系统颜色；两者会自动跟随浅色或深色外观，即使菜单栏外观与 App 外观不同也能保持正确对比度。

从 macOS 11 起的所有受支持系统统一使用 AppKit 原生 `NSStatusItem`、`NSMenu` 和 `NSMenuItem`。菜单外框、材质、阴影、间距、选区强调色、勾选状态、键盘操作、辅助功能、深浅色外观以及“详细信息”子菜单动画均由系统负责。HoRNDIS 不会自行绘制或裁剪替代菜单，菜单打开时也不会抢占前台应用焦点。

授权有效时，精简摘要不会显示授权行。如果 root 所有的网络 helper 或 LaunchDaemon 配置缺失、所有者错误、可被非 root 用户写入或配置无效，菜单会用盾牌显示“授权状态：需要授权”，并在其正下方增加不重复该图标的纯文字“授权并安装…”操作。点击后由 macOS 标准管理员认证对话框执行 App 内置且固定的 `horndis service install` 命令；HoRNDIS 不会接触或保存密码。命令行可以使用 `horndis install` 完成同一操作。

两个勾选命令只依靠 AppKit 系统勾选，不叠加第二个左侧图标；“详细信息”依靠原生子菜单箭头，退出项依靠 `⌘Q` 快捷键。根菜单摘要的 SF Symbols 使用 AppKit 的关闭状态图片槽，因此会与下方系统勾选对齐，同时信息行仍保持非勾选语义，也不会再创建独立图片列。“详细信息”子菜单在自己的独立菜单中继续使用普通语义图标。流量行的首个符号直接作为上传箭头，标题从上传量开始并保留后面的 `↓` 下载标记。

取消勾选 **USB 网络共享** 只会暂停 RNDIS 桥接，后台服务仍保持运行；再次选择该菜单项会恢复勾选状态和设备扫描。可另外使用 **自动开启USB网络共享**，通过已授权的 ADB 尝试打开手机共享。

设备连接期间，HoRNDIS 还会监测桥接接口的 IPv4 地址。如果 macOS 移除了该地址——例如 VPN 连接或断开后重排网络配置——HoRNDIS 会在大约十五秒内自动重新获取 DHCP 地址，无需手动重启。

菜单关闭时每两秒读取一次 `/var/run/horndis/status.json`，菜单显示期间则每秒刷新一次；打开菜单时只原位更新现有菜单项文字、可用状态、勾选状态和子菜单内容，不会反复重建菜单。程序不会读取网络数据内容，也没有遥测。运行目录、状态文件和控制 socket 只允许当前控制台用户及 root 访问；连接控制通过 `/var/run/horndis/control.sock` 完成，并额外校验请求方 UID。

## 自动开启USB网络共享（可选）

在手机上开启 USB 调试并授权这台 Mac 后，勾选菜单中的 **自动开启USB网络共享**。
此项默认关闭，独立于 Surge 联动总开关。HoRNDIS 会查找 Homebrew 或 Android SDK 中的
`adb`；无法找到时，可在 **详细信息 → 选择 ADB…** 中选择可执行文件。

后台只处理已授权的 USB ADB 手机；无线设备、模拟器、多台手机或未授权状态不会触发启动。
发现尚未启用共享的手机后，使用固定的 `svc usb setFunctions rndis` 命令，并等待实际
RNDIS、DHCP 和 DNS 配置。只有命令返回成功不会显示网络已就绪。ROM 不支持该命令、
拒绝权限或三十秒内未建立网络时，会在详细信息中提示原因，需手动开启或点击 **重试USB启动**。

每个新的 ADB USB 连接编号都会获得一次启动机会，即使使用同一台手机快速重插。
自身命令引起的 USB 重新枚举在新连接确认 RNDIS 前保留防重复保护；旧版 ADB 缺少连接编号时，
才使用八秒离线保护。手动暂停 **USB 网络共享** 会立即
阻止自动尝试；此功能不会自动恢复 HoRNDIS 的暂停状态，也不会自动授权 USB 调试或提权。
诊断状态会保存实际开启命令的次数、时间和触发原因，便于区分“已经共享”与“自动开启成功”。
关闭自动启动选项只停止后续尝试，已经建立的连接仍由 **USB 网络共享** 控制。

可只读检查 ADB 路径、授权状态和 USB 功能，不执行启动：

```sh
"/Applications/HoRNDIS Status.app/Contents/Helpers/horndis-surge-agent" --inspect-adb
```

## 本地网络访问权限

macOS 15 及更新版本会检查用户后台的本地网络权限。HoRNDIS 需要向手机 DHCP 提供的
DNS 发送验证请求；请在系统提示中允许 **HoRNDIS 状态栏** 访问本地网络。若已经拒绝，
可使用 **Surge 联动 → 打开本地网络设置…**，或前往
**系统设置 → 隐私与安全性 → 本地网络** 手动开启。

权限拒绝时会明确显示“请允许本地网络访问”，保留 DHCP 地址/DNS 信息并自动重试，
不会因 EPIPE/SIGPIPE 反复退出，也不会在探测失败时启用 SIM DNS 或切到 SIM-Route。
前台终端探测成功不代表用户后台已获授权。

后台的启动、状态变化、DNS 探测错误和状态文件写入失败记录在
`~/Library/Application Support/HoRNDIS/Surge/agent.log`，最大 1 MiB，并保留一份轮转日志。
安装包要求使用 Apple 证书和固定的辅助程序标识签名；本地开发可通过 `SIGNING_IDENTITY`
指定相同身份。临时签名构建（包括 v0.3.12 发布包）在替换后可能无法匹配权限，
需升级到证书签名版本，并在系统提示时重新允许 HoRNDIS 状态栏访问本地网络。
重复 App 副本也可能影响权限显示。详见
[Apple 本地网络隐私说明](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)。

## Surge 联动（可选）

需要 Surge Mac 6.8 或更新版本。在菜单的 **Surge 联动** 子菜单选择现有的
`SIM DNS` 模块，然后勾选 **启用联动**。默认关闭。模块须为当前 Surge 配置目录内的
本地 `.sgmodule`，包含 `#!name=SIM DNS` 和 `[Host]` 中的数字 IP `server:` 映射。
默认自动匹配该目录中的当前活动 `.conf`，也可手动选择同一目录下的当前配置文件；
其 `[Proxy]` 中应有且只有一个 `SIM = direct, ...` 策略。

联动根据 HoRNDIS 实际接口读取 DHCP DNS 与网关，等待有效 IPv4 地址，并通过该接口
向 DHCP DNS 查询 `example.com`。就绪后更新 DNS 映射及 `SIM` 的接口字段并启用模块。
DNS 探测不会回退到 Wi-Fi。网关不作为缺失 DNS 的替代值。

**只有目标值与原文件不一致时才写入对应文件。** 内容一致时保留文件、时间戳和格式，
不生成备份、不重载配置。变更前保存旁边的 `.horndis-backup`，保留其他规则、注释和文件权限；
模块启停独立判断，实际更新或启停后清除 Surge DNS 缓存。支持多个 DHCP DNS。
当前仅管理 `[Host]` 中的 IPv4、53 端口映射；`server:system` 等其他映射保留。
遇到重复名称、重复 SIM 策略、符号链接或检测到并发编辑时会提示错误。

拔线、暂停共享、丢失网络配置或停止网络服务后会自动停用模块。Surge 未运行时显示等待并
自动重试（最长间隔 30 秒）。关闭总开关也会先完成停用；若暂时无法连接 Surge，待停用任务
会保留至下次恢复。**立即重试** 可提前检查。错误详情可在提示行的悬停说明中查看。

独立的普通用户 LaunchAgent 在首次启用时注册，退出菜单栏（包括 `horndis stop`）不会
停止联动。通常每秒检查连接状态，稳定时每五秒核对 Surge；服务状态超过十秒未更新按断开处理。
设置、状态与待处理任务保存在 `~/Library/Application Support/HoRNDIS/Surge/`。
卸载前需完成模块停用；如果提示清理待完成，请保持 App 安装、启动 Surge 后重试卸载。

子菜单中还可勾选 **自动切换 Intelligence**（新增选项默认关闭，受联动总开关控制）。
USB 共享及 DNS 就绪、`SIM DNS` 已启用后，将 `Intelligence` 选择为 `SIM-Route`；
断开、暂停、网络/DNS 未就绪或停止服务后恢复 `新加坡节点`。关闭此选项或联动总开关时，
也会先完成恢复。两个成员必须已存在且可用，名称按此处原样匹配。

策略切换使用 Surge 的策略组命令，不改写配置文件。已经选中目标时不重复切换、
不重载、不清缓存；真正切换后会回读确认并清理 DNS 缓存。DNS 模块停用与策略恢复各自尝试，
其中一个失败不会阻止另一个执行。Surge 未运行时保留待恢复任务；若曾控制的配置暂未激活，
会提示等待该配置，切回后自动恢复，不会主动切换 Surge 的活动配置。

可运行以下只读检查，查看识别结果及哪些文件需要更新；该命令不会改变文件或模块状态：

```sh
"/Applications/HoRNDIS Status.app/Contents/Helpers/horndis-surge-agent" --inspect
```

## 系统“网络”设置

系统“网络”设置会显示 **HoRNDIS USB**，对应真正承载 DHCP 和 USB 流量的 `bridge<number>` 接口，菜单“详细信息”和 `horndis status` 显示同一个接口名。暂停或断开时清除地址，重连时重新获取 DHCP；断开时保留条目，服务重启时复用，卸载时移除。

注册依赖运行时动态解析的 macOS 私有网桥配置 API。如果不可用或无法安全应用，HoRNDIS 会记录原因并回退到原有的直接 feth 通路；回退通路不显示在系统网络设置中。这项功能仍需在各受支持 macOS 版本上实测。网桥只接入新创建的 feth 成员，不会加入 Wi-Fi、雷雳或实体网卡；已有成员的网桥不能被复用或删除。请用 HoRNDIS 菜单暂停或恢复连接，系统网络设置不能打开 Android 的 USB 网络共享开关。

可以用以下命令或菜单栏确认状态：

```sh
horndis status
horndis diagnostics ~/Desktop/HoRNDIS-Diagnostics.txt
scutil --nwi
tail -f /var/log/horndis.log
```

`horndis status` 和菜单“详细信息”会显示实际选择的 macOS 端接口；请把这个名称用于 `ifconfig` 或 `ipconfig getsummary`。

如果已经退出菜单栏 App，可以从“应用程序”、Launchpad 或 Spotlight 重新打开，
也可以运行 `horndis start`。`horndis stop` 会关闭菜单栏但保留登录时启动设置，
`horndis restart` 可用于排障后重启。完整命令请运行 `horndis help` 或
`man horndis`。

## 一直停在“正在配置 DHCP”

当前版本会在每次 USB/RNDIS 成功连接后重新启用实际选择的 macOS 端 feth 接口，并重启 DHCP 客户端。这同时覆盖开机、登录、睡眠、换线以及 Android 网络共享状态变化后的重连，不需要再次进行管理员认证。

如果旧版安装在显示设备名称后仍一直停在“正在配置 DHCP”，通常是 macOS 在手机连接前清除了开机时创建的一次性 DHCP 状态。可以用以下命令恢复当前会话：

```sh
sudo ifconfig feth99 up
sudo ipconfig set feth99 DHCP
```

然后在 Android 上关闭并重新打开 USB 网络共享。升级或重新安装 HoRNDIS 后，会自动在每次连接时完成这个修复。如果当前版本仍无法获得地址，请把 `horndis status` 显示的接口代入 `ipconfig getsummary <接口>`，并检查 `/var/log/horndis.log`；如果特权 DHCP 刷新失败，菜单应显示明确错误，而不是无限停留在配置状态。

## 升级

修复版将 UUID、配置和各网络位置的 UUID 序列保存在 root 私有文件
`/Library/Application Support/HoRNDIS/network-service.plist`，以首次运行时的当前设置为基线，
每秒检查已提交的手动调整，停止前再保存一次。它独立于系统升级可能清除的桥登记。

首次新建的网络服务名称为 HoRNDIS USB，IPv4 默认启用 DHCP、IPv6 默认自动配置，位置放在末尾。
启动优先复用或恢复原 UUID；必须重建时优先替换当前仍存在的旧槽位，否则寻找最近存活的
原前驱，其次原后继。邻居顺序已交换时跟随前驱，不交换其他服务；没有锚点时放到末尾并
记录原因。保存完整旧序列只用于找锚点，不会整表覆盖当前排序。普通重启尊重最新的手动
排序和网络位置成员变化。完整卸载会清除恢复记录，避免重新安装时复活已删除的服务。

```sh
brew update
brew upgrade --cask jlikeme/tap/horndis
```

配合 `Packaging/horndis.rb.in` 生成的新 cask 定义，升级和重装只停止后台并替换程序，
保留 **HoRNDIS USB** 网络服务、服务 UUID、自定义网络配置和原有服务顺序，
也保留 Surge 与 ADB 的联动设置。安装后复用同一个服务。
`brew uninstall` 或 `horndis uninstall` 完整卸载时，才删除所属网络服务和桥。

卸载脚本在实际执行时读取调用它的 Homebrew 进程参数，区分替换和完整卸载，
避免把安装时的参数固化在 Homebrew 的 JSON 记录中；无法识别的操作默认保留网络配置。
从旧版本首次更新时，还需要先迁移 Homebrew 保存的旧卸载记录，仅更新 tap 定义不够。
`Scripts/homebrew-maintenance.py` 提供带备份和失败条件恢复的一次性适配，
只处理 HoRNDIS 的安装记录，不改写系统网络配置或排序。
`Scripts/generate-homebrew-cask.py` 根据实际 PKG 的版本、URL 和校验和生成配套定义；
发布产物包含 `horndis.rb`，tap 应使用与安装包匹配的定义。

只有重新安装后台网络服务需要管理员认证。开机启动、USB 重连和菜单栏操作都不会再次询问密码。常驻 root 进程只是最小监督器，USB 与 RNDIS 数据处理在当前登录用户权限下运行，详见[权限模型](PRIVILEGE_MODEL.md)。

## 卸载

```sh
horndis uninstall
brew uninstall --cask jlikeme/tap/horndis
```

## 网络测试与 VPN

Mac 同时保留 Wi-Fi 或 VPN 时，可把测试绑定到 USB 接口：

```sh
ping -b <接口> 8.8.8.8
```

请把 `<接口>` 替换为 `horndis status` 显示的名称。

部分 VPN/代理使用 Fake-IP DNS，系统解析得到的地址可能只能通过对应的 VPN 隧道访问。绑定所选 feth 接口后访问该虚拟地址失败，不代表 USB 驱动异常；排障时应对比系统 DNS 与 Android DHCP 提供的 DNS 结果。

提交 Bug 时，请先复现问题，随后立即从菜单“详细信息”保存新诊断报告，或运行 `horndis diagnostics 文件`。检查文件后，把它上传到 GitHub Bug 表单中的必填附件栏。完整流程与隐私说明请参阅[反馈 Bug](BUG_REPORTING.zh-CN.md)；提交兼容性问题前也请先阅读[已知限制](LIMITATIONS.md)。
