#!/usr/bin/env bash
# 卸载 Srun Linux v1 系统服务和稳定目录。

set -euo pipefail

readonly SERVICE_NAME='srun-login.service'
readonly INSTALL_ROOT='/usr/local/libexec/srun-login'
readonly CONFIG_ROOT='/etc/srun-login'
readonly SYSTEMD_UNIT="/etc/systemd/system/$SERVICE_NAME"
ASSUME_YES=0

for argument in "$@"; do
    case $argument in
        -y|--yes) ASSUME_YES=1 ;;
        -h|--help)
            printf '用法: uninstall.sh [--yes]\n'
            exit 0
            ;;
        *) printf '[错误] 未知参数: %s\n' "$argument" >&2; exit 2 ;;
    esac
done

if ((EUID != 0)); then
    if ! command -v sudo >/dev/null 2>&1; then
        printf '[错误] 卸载系统服务需要 root 权限，且当前系统没有 sudo。\n' >&2
        exit 1
    fi
    exec sudo bash "$0" "$@"
fi

if ((!ASSUME_YES)); then
    printf '%s\n' \
        "即将删除 $SERVICE_NAME、运行脚本和 $CONFIG_ROOT。" \
        '其中的明文校园网配置将被永久删除，无法由本程序恢复。'
    read -r -p '确认卸载？[y/N] ' answer
    [[ $answer == y || $answer == Y ]] || { printf '已取消。\n'; exit 0; }
fi

if systemctl list-unit-files "$SERVICE_NAME" >/dev/null 2>&1; then
    systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
fi

rm -f -- "$SYSTEMD_UNIT"
rm -rf -- "$INSTALL_ROOT" "$CONFIG_ROOT"
systemctl daemon-reload
systemctl reset-failed "$SERVICE_NAME" >/dev/null 2>&1 || true

printf '%s\n' \
    '已卸载 Srun Linux v1：' \
    "  - $SERVICE_NAME" \
    "  - $INSTALL_ROOT" \
    "  - $CONFIG_ROOT" \
    '' \
    '配置文件已永久删除，无法从本卸载程序恢复。'
