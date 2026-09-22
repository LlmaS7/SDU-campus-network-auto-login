# 山东大学校园网自动登录

> Fork 自sdu前辈 [Bingtao-Wang/Srun_login](https://github.com/Bingtao-Wang/Srun_login)。感谢原作者提供基础实现与思路，致敬。respect , o7
>
> 另，本Fork 后续开发，完全借助 OpenAI Codex 完成 （包括此README）。respect , o7

用于山东大学深澜（Srun）校园网自动认证，支持 Windows 和 Linux。

## Windows

适用于 Windows 10/11。开机后由 SYSTEM 计划任务运行一次：等待有线网络就绪，完成认证后立即退出，不常驻后台。

### 安装

1. 打开 `windows` 文件夹。
2. 双击 `一键部署_Windows.bat`。
3. 接受管理员权限提示。
4. 输入学号、密码，确认登录认证网址。
5. 根据提示选择是否立即测试。

程序安装到：

```text
C:\ProgramData\SrunLogin\
├── srun_login.ps1
├── config.ini
└── logs\srun.log
```

### 日常操作

| 操作 | 文件 |
|------|------|
| 手动认证 | `windows\手动登录.bat` |
| 验证自启动 | `windows\验证自启动.bat` |
| 完整卸载 | `windows\卸载自启.bat` |

运行日志：`C:\ProgramData\SrunLogin\logs\srun.log`

## Linux

Linux 版安装为 systemd 系统级一次性服务，在开机网络就绪后执行认证，完成后退出。

进入 `linux` 目录运行：

```bash
cd linux
chmod +x 一键部署_linux.sh
./一键部署_linux.sh
```

常用命令：

```bash
systemctl status srun-login.service
sudo systemctl start srun-login.service
journalctl -u srun-login.service -f
sudo bash verify_setup.sh
sudo bash uninstall.sh
```

安装位置：

```text
/usr/local/libexec/srun-login/srun_login.sh
/etc/srun-login/config.ini
/etc/systemd/system/srun-login.service
```

## 说明

- 账号和密码以明文保存在本机配置文件中，请勿分享：Windows 位于 `C:\ProgramData\SrunLogin\config.ini`，Linux 位于 `/etc/srun-login/config.ini`。
- Windows 日志不会记录明文密码或完整认证参数。
- `ac_id` 固定使用默认值 `1`。
- 上游仓库当前未提供明确的 `LICENSE` 文件；本 Fork 不擅自为上游代码重新授权。

## 相对上游的主要改动

### 整体调整

- 保留上游的 Srun challenge、XXTEA/SRBX1、HMAC-MD5 和 SHA1 认证流程，主要重构外围运行与部署逻辑。
- 将项目拆分为独立的 `windows`、`linux` 目录，各平台的安装、运行、验证和卸载文件集中管理。
- Windows 与 Linux 均改为“启动时执行一次认证，完成后退出”，不再依赖永久常驻的五分钟轮询进程。
- 增加配置完整性检查、JSON 特殊字符转义、URL 参数编码、HTTP 超时和服务器响应校验，避免缺失字段继续参与加密计算。
- 统一使用退出码表示结果：`0` 为已在线或认证成功，`1` 为认证失败，`2` 为配置错误，`3` 为网络未就绪。

### Windows

- 将“启动文件夹 + VBS + `-keepalive`”改为 Windows 计划任务，在系统启动时以 SYSTEM 身份运行，无需等待用户登录。
- 运行文件安装到 `C:\ProgramData\SrunLogin`，移动或删除 Git 仓库不会影响已安装的任务。
- 登录前单独等待有线网卡、DHCP、有效 IPv4 和 Srun 服务器就绪；网络尚未就绪不会消耗认证次数。
- 优先查询 Srun 在线状态；未认证时最多尝试 5 次，明确的账号或密码错误会立即停止重试。
- 日志写入 `C:\ProgramData\SrunLogin\logs\srun.log`，记录运行阶段与退出码，但不记录明文密码和完整认证参数。
- 安装程序会清理旧版 VBS、自启动项和 `-keepalive` 进程，并提供手动认证、安装验证和完整卸载入口。

### Linux

- 将 user systemd 常驻服务改为 systemd 系统级 `oneshot` 服务，通过 `multi-user.target` 在无人登录时执行。
- 运行脚本、配置和服务单元分别安装到 `/usr/local/libexec/srun-login`、`/etc/srun-login` 和 `/etc/systemd/system`。
- 配置文件归 `root:root` 所有并限制为 `600` 权限；安装时会迁移并清理旧版用户级常驻服务。
- 与 Windows 版一样增加有线网络就绪等待、在线状态检查、有限重试、永久错误识别和明确退出码。
- 日志由 systemd journal 管理，可通过 `journalctl -u srun-login.service` 查看。
- 增加独立的安装、验证和卸载脚本，并加入配置解析、JSON 转义、认证流程、错误退出码及加密固定向量测试。
