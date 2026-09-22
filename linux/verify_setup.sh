#!/usr/bin/env bash
# 检查 Srun Linux v1 的安装状态，不修改系统。

set -uo pipefail

readonly SERVICE_NAME='srun-login.service'
readonly INSTALLED_SCRIPT='/usr/local/libexec/srun-login/srun_login.sh'
readonly INSTALLED_CONFIG='/etc/srun-login/config.ini'
readonly SYSTEMD_UNIT="/etc/systemd/system/$SERVICE_NAME"

failures=0

show_check() {
    local success=$1 message=$2
    if ((success)); then
        printf '[OK]   %s\n' "$message"
    else
        printf '[FAIL] %s\n' "$message"
        ((failures++))
    fi
}

[[ -f $INSTALLED_SCRIPT && -x $INSTALLED_SCRIPT ]]
show_check "$((!$?))" "运行脚本存在且可执行: $INSTALLED_SCRIPT"

[[ -f $INSTALLED_CONFIG && -r $INSTALLED_CONFIG ]]
show_check "$((!$?))" "配置文件存在且可读: $INSTALLED_CONFIG"

[[ -f $SYSTEMD_UNIT ]]
show_check "$((!$?))" "systemd 单元存在: $SYSTEMD_UNIT"

if [[ -f $INSTALLED_CONFIG ]]; then
    config_mode=$(stat -c '%a' "$INSTALLED_CONFIG" 2>/dev/null || true)
    config_owner=$(stat -c '%U:%G' "$INSTALLED_CONFIG" 2>/dev/null || true)
    [[ $config_mode == 600 ]]
    show_check "$((!$?))" '配置文件权限为 600'
    [[ $config_owner == root:root ]]
    show_check "$((!$?))" '配置文件所有者为 root:root'
fi

if command -v systemctl >/dev/null 2>&1; then
    systemctl is-enabled --quiet "$SERVICE_NAME" >/dev/null 2>&1
    show_check "$((!$?))" 'systemd 服务已启用，开机时会执行'

    load_state=$(systemctl show "$SERVICE_NAME" -p LoadState --value 2>/dev/null || true)
    [[ $load_state == loaded ]]
    show_check "$((!$?))" 'systemd 已成功加载服务单元'

    last_result=$(systemctl show "$SERVICE_NAME" -p ExecMainStatus --value 2>/dev/null || true)
    active_state=$(systemctl show "$SERVICE_NAME" -p ActiveState --value 2>/dev/null || true)
    printf '       当前状态: %s；上次运行退出码: %s\n' "${active_state:-未知}" "${last_result:-尚无}"
else
    show_check 0 '系统中存在 systemctl'
fi

if ((failures > 0)); then
    printf '\n发现 %d 个安装问题。\n' "$failures"
    exit 1
fi

printf '\n安装检查通过。实际认证是否成功仍应结合上次退出码和日志确认。\n'
printf '日志命令: journalctl -u %s\n' "$SERVICE_NAME"
