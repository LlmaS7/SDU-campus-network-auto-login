#!/usr/bin/env bash
# Srun Linux v1 系统级安装程序

set -euo pipefail

readonly SERVICE_NAME='srun-login.service'
readonly INSTALL_ROOT='/usr/local/libexec/srun-login'
readonly CONFIG_ROOT='/etc/srun-login'
readonly INSTALLED_SCRIPT="$INSTALL_ROOT/srun_login.sh"
readonly INSTALLED_CONFIG="$CONFIG_ROOT/config.ini"
readonly SYSTEMD_UNIT="/etc/systemd/system/$SERVICE_NAME"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_SCRIPT="$SCRIPT_DIR/srun_login.sh"
SOURCE_UNIT="$SCRIPT_DIR/srun-login.service"
SOURCE_CONFIG="$SCRIPT_DIR/config.ini"
SKIP_TEST=0
INSTALLING_USER=${SRUN_INSTALL_USER:-${SUDO_USER:-${USER:-root}}}

usage() {
    printf '%s\n' \
        '用法: setup.sh [--skip-test]' \
        '' \
        '  --skip-test  安装并启用服务，但不立即运行认证测试。'
}

for argument in "$@"; do
    case $argument in
        --skip-test) SKIP_TEST=1 ;;
        -h|--help) usage; exit 0 ;;
        *) printf '[错误] 未知参数: %s\n' "$argument" >&2; usage >&2; exit 2 ;;
    esac
done

if ((EUID != 0)); then
    if ! command -v sudo >/dev/null 2>&1; then
        printf '[错误] 安装系统服务需要 root 权限，且当前系统没有 sudo。\n' >&2
        exit 1
    fi
    printf '安装系统级开机服务需要管理员权限。\n'
    exec sudo env "SRUN_INSTALL_USER=$INSTALLING_USER" bash "$0" "$@"
fi

[[ -f $SOURCE_SCRIPT ]] || {
    printf '[错误] 未找到运行脚本: %s\n' "$SOURCE_SCRIPT" >&2
    exit 1
}
[[ -f $SOURCE_UNIT ]] || {
    printf '[错误] 未找到 systemd 服务模板: %s\n' "$SOURCE_UNIT" >&2
    exit 1
}

missing_commands=()
for command_name in curl openssl base64 tr ip date head readlink systemctl install mktemp; do
    command -v "$command_name" >/dev/null 2>&1 || missing_commands+=("$command_name")
done
if ((${#missing_commands[@]} > 0)); then
    printf '[错误] 缺少运行命令: %s\n' "${missing_commands[*]}" >&2
    printf 'Ubuntu/Debian 通常可安装 curl、openssl、iproute2 和 coreutils 后重试。\n' >&2
    exit 1
fi

trim_whitespace() {
    local value=$1
    value="${value#"${value%%[!$' \t\r\n']*}"}"
    value="${value%"${value##*[!$' \t\r\n']}"}"
    printf '%s' "$value"
}

read_existing_config() {
    local path=$1 line key value
    EXISTING_USERNAME=''
    EXISTING_PASSWORD=''
    EXISTING_SERVER='http://192.168.75.252'
    EXISTING_AC_ID='1'
    [[ -f $path ]] || return 0

    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        [[ $line == *=* ]] || continue
        key=$(trim_whitespace "${line%%=*}")
        key=${key,,}
        value=$(trim_whitespace "${line#*=}")
        case $key in
            username) EXISTING_USERNAME=$value ;;
            password) EXISTING_PASSWORD=$value ;;
            server) EXISTING_SERVER=$value ;;
            ac_id) EXISTING_AC_ID=$value ;;
        esac
    done < "$path"
}

existing_config_path=''
if [[ -f $INSTALLED_CONFIG ]]; then
    existing_config_path=$INSTALLED_CONFIG
elif [[ -f $SOURCE_CONFIG ]]; then
    existing_config_path=$SOURCE_CONFIG
fi
read_existing_config "$existing_config_path"

printf '%s\n' \
    '========================================' \
    '   校园网自动登录 Linux v1 安装程序' \
    '   systemd 一次性开机认证版' \
    '========================================' \
    ''

prompt_suffix=''
[[ -z $EXISTING_USERNAME ]] || prompt_suffix=" [$EXISTING_USERNAME]"
read -r -p "学号${prompt_suffix}: " input_username
USERNAME=${input_username:-$EXISTING_USERNAME}
while [[ -z $USERNAME ]]; do
    printf '[错误] 学号不能为空。\n' >&2
    read -r -p '学号: ' USERNAME
done

if [[ -n $EXISTING_PASSWORD ]]; then
    read -r -p '密码（直接回车保留现有密码）: ' input_password
    PASSWORD=${input_password:-$EXISTING_PASSWORD}
else
    read -r -p '密码: ' PASSWORD
fi
while [[ -z $PASSWORD ]]; do
    printf '[错误] 密码不能为空。\n' >&2
    read -r -p '密码: ' PASSWORD
done

read -r -p "确认登录验证地址 [$EXISTING_SERVER]: " input_server
SERVER=${input_server:-$EXISTING_SERVER}
SERVER=${SERVER%/}
case $SERVER in
    http://*|https://*) ;;
    *) printf '[错误] 服务器必须是完整的 http:// 或 https:// 地址。\n' >&2; exit 2 ;;
esac

AC_ID=${EXISTING_AC_ID:-1}
[[ $AC_ID =~ ^[0-9]+$ ]] || AC_ID=1

cleanup_legacy_user_service() {
    local user_name=$INSTALLING_USER user_home user_id legacy_unit legacy_wants
    [[ -n $user_name && $user_name != root ]] || return 0
    command -v getent >/dev/null 2>&1 || return 0
    user_home=$(getent passwd "$user_name" | cut -d: -f6)
    [[ -n $user_home ]] || return 0
    legacy_unit="$user_home/.config/systemd/user/$SERVICE_NAME"
    legacy_wants="$user_home/.config/systemd/user/default.target.wants/$SERVICE_NAME"
    [[ -f $legacy_unit ]] || return 0
    if ! grep -Eq 'Srun Campus Network Auto Login|srun_login\.sh[[:space:]]+--keepalive' "$legacy_unit"; then
        printf '[警告] 发现同名用户服务，但内容不像本项目旧版，未自动删除: %s\n' "$legacy_unit"
        return 0
    fi

    user_id=$(id -u "$user_name")
    if [[ -d /run/user/$user_id ]] && command -v runuser >/dev/null 2>&1; then
        runuser -u "$user_name" -- env "XDG_RUNTIME_DIR=/run/user/$user_id" \
            systemctl --user disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
    fi
    rm -f -- "$legacy_wants" "$legacy_unit"
    printf '[迁移] 已移除旧版常驻 user service。\n'
}

cleanup_legacy_user_service

if systemctl list-unit-files "$SERVICE_NAME" >/dev/null 2>&1; then
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
fi

install -d -m 0755 "$INSTALL_ROOT"
install -d -m 0700 "$CONFIG_ROOT"
install -m 0755 "$SOURCE_SCRIPT" "$INSTALLED_SCRIPT"

config_temp=$(mktemp "$CONFIG_ROOT/.config.ini.XXXXXX")
cleanup_temp_files() {
    rm -f -- "${config_temp:-}"
}
trap cleanup_temp_files EXIT

umask 077
printf '[srun]\nusername=%s\npassword=%s\nserver=%s\nac_id=%s\n' \
    "$USERNAME" "$PASSWORD" "$SERVER" "$AC_ID" > "$config_temp"
chmod 0600 "$config_temp"
chown root:root "$config_temp"
mv -f -- "$config_temp" "$INSTALLED_CONFIG"
config_temp=''

install -m 0644 "$SOURCE_UNIT" "$SYSTEMD_UNIT"

systemctl daemon-reload
systemctl enable "$SERVICE_NAME" >/dev/null

printf '%s\n' \
    '[完成] 运行脚本已安装到:' \
    "         $INSTALLED_SCRIPT" \
    '[完成] 配置已保存到:' \
    "         $INSTALLED_CONFIG" \
    '[完成] 已创建 systemd 开机服务:' \
    "         $SYSTEMD_UNIT"

if ((SKIP_TEST)); then
    printf '[跳过] 未立即执行认证测试；服务将在下次开机运行。\n'
else
    printf '[测试] 正在执行一次认证任务，最长可能等待约 5 分钟……\n'
    if systemctl start "$SERVICE_NAME"; then
        exit_status=$(systemctl show "$SERVICE_NAME" -p ExecMainStatus --value)
        printf '[成功] 认证服务执行完成，退出码 %s。\n' "${exit_status:-0}"
    else
        exit_status=$(systemctl show "$SERVICE_NAME" -p ExecMainStatus --value 2>/dev/null || true)
        printf '[失败] 认证服务退出码 %s。最近日志如下：\n' "${exit_status:-未知}" >&2
        journalctl -u "$SERVICE_NAME" -n 20 --no-pager >&2 || true
        exit 1
    fi
fi

printf '%s\n' \
    '' \
    '常用命令:' \
    '  查看状态: systemctl status srun-login.service' \
    '  手动认证: sudo systemctl start srun-login.service' \
    '  查看日志: journalctl -u srun-login.service' \
    '  验证安装: sudo bash linux/verify_setup.sh' \
    '  卸载服务: sudo bash linux/uninstall.sh'
