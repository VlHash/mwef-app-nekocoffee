# NekoCoffee for MWEF

NekoCoffee 是一款面向小米路由器原生 WebUI 的轻量 ShellClash / ShellCrash 控制插件。它通过 MWEF 的认证 LuCI 路由提供服务控制、运行模式切换、DNS 模式切换、控制面板入口和出口 IP 检测，不引入前端框架或第三方静态依赖。

## 功能

- 查看 ShellClash / ShellCrash、核心版本和运行状态
- 启动、停止、重启服务
- 在线切换 Rule / Global / Direct 代理模式
- 切换流量接管模式与 `redirect-host` / `fake-ip` DNS 模式
- 开关 IPv6 透明代理与 QUIC 代理
- 上传本地 Clash YAML、从公网 HTTPS 导入并切换配置文件
- 一键打开本机控制面板
- 通过三个固定检测源回退，分别检测路由出口与本地混合代理端口的公网 IPv4
- 简体中文与 English

## 安全设计

- 所有接口沿用小米 LuCI `;stok=` 会话，不开放额外监听端口。
- 所有写操作仅接受固定动作和枚举值；Web 参数不会作为命令或路径执行。
- IP 检测仅访问代码内固定的 HTTPS 服务，并设置超时和响应长度限制；直连与代理结果互不影响。
- 配置上传限制为 2 MiB，只接受安全的 `.yaml` / `.yml` 文件名；切换前还会调用代理核心做语义校验。
- URL 导入只接受解析到公网 IPv4 的 HTTPS 地址，禁用重定向并固定解析结果；订阅链接不会出现在状态数据或日志中。
- 配置切换只替换 ShellCrash 约定的软链接，重启失败时会恢复旧链接并尝试恢复服务。
- 不包含 MTD、块设备、Bootloader、固件分区或其他高危操作。
- 配置写入采用同目录临时文件加原子替换，并保留最近一次 `.nekocoffee.bak` 备份。
- 若控制面板未设置 secret，页面只给出安全提醒，不会擅自修改现有配置。

## 兼容性

已针对 ShellCrash `1.9.5beta3` / Meta 核心验证配置结构，并兼容常见的 `ShellCrash`、`ShellClash` 安装目录。MWEF 最低版本为 `0.2.0`。

## 构建

在 MWEF 框架仓库根目录执行，产物会写回本仓库的 `dist/`：

```powershell
.\tools\build-plugin.ps1 `
  -Source ..\mwef-app-nekocoffee `
  -OutputDirectory ..\mwef-app-nekocoffee\dist
```

也可以在本仓库执行：

```powershell
.\build.ps1
```

## 安装

在 MWEF 的“框架设置”中上传 `dist/mwef-app-nekocoffee-1.1.0.tar.gz`，审阅并授予所请求权限，然后启用插件。改变模式、IPv6/QUIC 设置或切换配置文件时，运行中的 ShellCrash 会在确认后重启一次以载入配置。

## License

[MIT](LICENSE) © 2026 VlHash
