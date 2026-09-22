#!/usr/bin/env bash
# 山东大学深澜（Srun）校园网一次性认证程序

set -uo pipefail

readonly EXIT_OK=0
readonly EXIT_AUTH_FAILED=1
readonly EXIT_CONFIG_ERROR=2
readonly EXIT_NETWORK_NOT_READY=3

readonly ENC_VER='srun_bx1'
readonly N='200'
readonly TYPE='1'
readonly STD_ALPHA='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/='
readonly SRUN_ALPHA='LVoJPiCN2R8G90yg+hmFHuacZ1OWMnrsSTXkYpUq/3dlbfKwv6xztjI7DeBE45QA='

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.ini"
READINESS_TIMEOUT_SECONDS=90
READINESS_POLL_SECONDS=1
MAX_ATTEMPTS=5
REQUEST_TIMEOUT_SECONDS=10
STATUS_TIMEOUT_SECONDS=2
CHECK_CONFIG_ONLY=0

USERNAME=''
PASSWORD=''
AC_ID='1'
SERVER='http://192.168.75.252'
WIRED_INTERFACE=''
WIRED_IP=''
JSON_BODY=''
JSON_FIELD=''
LAST_ERROR=''
LAST_PERMANENT=0

usage() {
    printf '%s\n' \
        '用法: srun_login.sh [选项]' \
        '' \
        '选项:' \
        '  --config PATH                 指定配置文件' \
        '  --readiness-timeout SECONDS  网络就绪最长等待时间（默认 90）' \
        '  --poll SECONDS               网络就绪轮询间隔（默认 1）' \
        '  --max-attempts COUNT         最大认证次数（默认 5）' \
        '  --request-timeout SECONDS    认证请求超时（默认 10）' \
        '  --status-timeout SECONDS     在线状态请求超时（默认 2）' \
        '  --check-config               仅检查配置和运行依赖' \
        '  -h, --help                   显示帮助'
}

log_message() {
    local level=$1 message=$2 safe_message
    safe_message=$message
    if [[ -n $PASSWORD ]]; then
        safe_message=${safe_message//"$PASSWORD"/'<redacted>'}
    fi
    safe_message=${safe_message//$'\r'/ }
    safe_message=${safe_message//$'\n'/ }
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$safe_message"
}

trim_whitespace() {
    local value=$1
    value="${value#"${value%%[!$' \t\r\n']*}"}"
    value="${value%"${value##*[!$' \t\r\n']}"}"
    printf '%s' "$value"
}

is_uint_in_range() {
    local value=$1 minimum=$2 maximum=$3
    [[ $value =~ ^[0-9]+$ ]] && ((10#$value >= minimum && 10#$value <= maximum))
}

parse_arguments() {
    while (($# > 0)); do
        case $1 in
            --config)
                (($# >= 2)) || { log_message ERROR '--config 缺少路径。'; return 1; }
                CONFIG_FILE=$2
                shift 2
                ;;
            --readiness-timeout)
                (($# >= 2)) || { log_message ERROR '--readiness-timeout 缺少秒数。'; return 1; }
                READINESS_TIMEOUT_SECONDS=$2
                shift 2
                ;;
            --poll)
                (($# >= 2)) || { log_message ERROR '--poll 缺少秒数。'; return 1; }
                READINESS_POLL_SECONDS=$2
                shift 2
                ;;
            --max-attempts)
                (($# >= 2)) || { log_message ERROR '--max-attempts 缺少次数。'; return 1; }
                MAX_ATTEMPTS=$2
                shift 2
                ;;
            --request-timeout)
                (($# >= 2)) || { log_message ERROR '--request-timeout 缺少秒数。'; return 1; }
                REQUEST_TIMEOUT_SECONDS=$2
                shift 2
                ;;
            --status-timeout)
                (($# >= 2)) || { log_message ERROR '--status-timeout 缺少秒数。'; return 1; }
                STATUS_TIMEOUT_SECONDS=$2
                shift 2
                ;;
            --check-config)
                CHECK_CONFIG_ONLY=1
                shift
                ;;
            -h|--help)
                usage
                return 2
                ;;
            --keepalive|-keepalive)
                log_message ERROR 'Linux v1 已移除 keepalive；请直接运行一次性认证服务。'
                return 1
                ;;
            *)
                log_message ERROR "未知参数: $1"
                return 1
                ;;
        esac
    done

    is_uint_in_range "$READINESS_TIMEOUT_SECONDS" 5 600 || { log_message ERROR '网络就绪超时必须为 5–600 秒。'; return 1; }
    is_uint_in_range "$READINESS_POLL_SECONDS" 1 30 || { log_message ERROR '轮询间隔必须为 1–30 秒。'; return 1; }
    is_uint_in_range "$MAX_ATTEMPTS" 1 10 || { log_message ERROR '最大认证次数必须为 1–10。'; return 1; }
    is_uint_in_range "$REQUEST_TIMEOUT_SECONDS" 2 60 || { log_message ERROR '认证请求超时必须为 2–60 秒。'; return 1; }
    is_uint_in_range "$STATUS_TIMEOUT_SECONDS" 1 10 || { log_message ERROR '状态请求超时必须为 1–10 秒。'; return 1; }
    return 0
}

check_dependencies() {
    local command_name missing=()
    for command_name in curl openssl base64 tr ip date head readlink; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            missing+=("$command_name")
        fi
    done
    if ((${#missing[@]} > 0)); then
        log_message ERROR "缺少运行命令: ${missing[*]}"
        return 1
    fi
    return 0
}

read_config() {
    local line trimmed key value authority
    [[ -f $CONFIG_FILE && -r $CONFIG_FILE ]] || {
        log_message ERROR "配置文件不存在或不可读: $CONFIG_FILE"
        return 1
    }

    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        trimmed=$(trim_whitespace "$line")
        [[ -z $trimmed || $trimmed == \#* || $trimmed == \;* || $trimmed == \[*\] ]] && continue
        [[ $line == *=* ]] || continue

        key=$(trim_whitespace "${line%%=*}")
        key=${key,,}
        value=$(trim_whitespace "${line#*=}")
        case $key in
            username) USERNAME=$value ;;
            password) PASSWORD=$value ;;
            server) SERVER=$value ;;
            ac_id) AC_ID=$value ;;
        esac
    done < "$CONFIG_FILE"

    [[ -n $USERNAME ]] || { log_message ERROR 'config.ini 中缺少 username。'; return 1; }
    [[ -n $PASSWORD ]] || { log_message ERROR 'config.ini 中缺少 password。'; return 1; }
    [[ $AC_ID =~ ^[0-9]+$ ]] || { log_message ERROR 'ac_id 必须只包含数字。'; return 1; }

    SERVER=${SERVER%/}
    case $SERVER in
        http://*|https://*) ;;
        *) log_message ERROR 'server 必须是完整的 http:// 或 https:// 地址。'; return 1 ;;
    esac
    authority=${SERVER#*://}
    authority=${authority%%/*}
    [[ -n $authority && $authority != *[[:space:]]* ]] || {
        log_message ERROR 'server 地址无效。'
        return 1
    }
    return 0
}

json_escape() {
    local input=$1 output='' character code escaped i
    local LC_ALL=C
    for ((i = 0; i < ${#input}; i++)); do
        character=${input:i:1}
        case $character in
            '"') output+='\"' ;;
            '\') output+='\\' ;;
            $'\b') output+='\b' ;;
            $'\f') output+='\f' ;;
            $'\n') output+='\n' ;;
            $'\r') output+='\r' ;;
            $'\t') output+='\t' ;;
            *)
                printf -v code '%d' "'$character"
                if ((code < 32)); then
                    printf -v escaped '\\u%04x' "$code"
                    output+=$escaped
                else
                    output+=$character
                fi
                ;;
        esac
    done
    printf '%s' "$output"
}

# sencode: UTF-8 字节串 -> uint32 数组 V[]。
sencode() {
    local msg=$1 append_len=$2
    local LC_ALL=C
    local length=${#msg} i j byte value
    V=()
    for ((i = 0; i < length; i += 4)); do
        value=0
        for ((j = 0; j < 4; j++)); do
            if ((i + j < length)); then
                printf -v byte '%d' "'${msg:i+j:1}"
                value=$((value | (byte << (j * 8))))
            fi
        done
        V+=($((value & 0xFFFFFFFF)))
    done
    ((append_len)) && V+=("$length")
    return 0
}

lencode() {
    LENC_HEX=''
    local value
    for value in "${V[@]}"; do
        printf -v LENC_HEX '%s%02x%02x%02x%02x' \
            "$LENC_HEX" \
            $((value & 0xFF)) \
            $(((value >> 8) & 0xFF)) \
            $(((value >> 16) & 0xFF)) \
            $(((value >> 24) & 0xFF))
    done
}

xxtea_encode() {
    local msg=$1 key=$2
    if [[ -z $msg ]]; then
        XXTEA_HEX=''
        return 0
    fi

    sencode "$msg" 1
    local -a values=("${V[@]}")
    sencode "$key" 0
    local -a keys=("${V[@]}")
    while ((${#keys[@]} < 4)); do keys+=(0); done

    local n=$((${#values[@]} - 1))
    local z=${values[$((${#values[@]} - 1))]}
    local q=$((6 + 52 / (n + 1))) delta=0 e p y mix

    while ((q > 0)); do
        delta=$(((delta + 0x9E3779B9) & 0xFFFFFFFF))
        e=$(((delta >> 2) & 3))
        for ((p = 0; p < n; p++)); do
            y=${values[$((p + 1))]}
            mix=$(((z >> 5) ^ ((y << 2) & 0xFFFFFFFF)))
            mix=$((mix + (((y >> 3) ^ ((z << 4) & 0xFFFFFFFF)) ^ (delta ^ y))))
            mix=$((mix + (keys[((p & 3) ^ e)] ^ z)))
            values[$p]=$(((values[p] + mix) & 0xFFFFFFFF))
            z=${values[$p]}
        done
        y=${values[0]}
        mix=$(((z >> 5) ^ ((y << 2) & 0xFFFFFFFF)))
        mix=$((mix + (((y >> 3) ^ ((z << 4) & 0xFFFFFFFF)) ^ (delta ^ y))))
        mix=$((mix + (keys[((n & 3) ^ e)] ^ z)))
        values[$n]=$(((values[n] + mix) & 0xFFFFFFFF))
        z=${values[$n]}
        ((q--))
    done

    V=("${values[@]}")
    lencode
    XXTEA_HEX=$LENC_HEX
}

srun_base64() {
    local hex=$1 raw_base64='' index
    if ! raw_base64="$({
        for ((index = 0; index < ${#hex}; index += 2)); do
            printf '%b' "\\x${hex:index:2}"
        done
    } | base64 | tr -d '\n')"; then
        return 1
    fi
    SRUN_B64=$(printf '%s' "$raw_base64" | tr "$STD_ALPHA" "$SRUN_ALPHA")
}

hmac_md5() {
    local key=$1 message=$2 digest
    digest=$(printf '%s' "$message" | openssl dgst -md5 -hmac "$key" 2>/dev/null) || return 1
    HMAC_MD5=${digest##*= }
    [[ $HMAC_MD5 =~ ^[0-9a-fA-F]{32}$ ]]
}

sha1_hex() {
    local message=$1 digest
    digest=$(printf '%s' "$message" | openssl dgst -sha1 2>/dev/null) || return 1
    SHA1=${digest##*= }
    [[ $SHA1 =~ ^[0-9a-fA-F]{40}$ ]]
}

epoch_milliseconds() {
    local epoch_nanoseconds
    epoch_nanoseconds=$(date +%s%N) || return 1
    [[ $epoch_nanoseconds =~ ^[0-9]+$ ]] || return 1
    printf '%s' "$((10#$epoch_nanoseconds / 1000000))"
}

parse_jsonp() {
    local text trimmed
    text=$1
    trimmed=$(trim_whitespace "$text")
    [[ -n $trimmed ]] || return 1

    if [[ $trimmed == \{*\} ]]; then
        JSON_BODY=$trimmed
        return 0
    fi
    if [[ $trimmed =~ ^[A-Za-z_][A-Za-z0-9_]*\((.*)\)\;?$ ]]; then
        JSON_BODY=${BASH_REMATCH[1]}
        [[ $JSON_BODY == \{*\} ]]
        return
    fi
    return 1
}

get_json_string_field() {
    local json=$1 field=$2 pattern
    pattern="\"${field}\"[[:space:]]*:[[:space:]]*\"([^\"]*)\""
    if [[ $json =~ $pattern ]]; then
        JSON_FIELD=${BASH_REMATCH[1]}
        return 0
    fi
    JSON_FIELD=''
    return 1
}

invoke_srun_request() {
    local path=$1 timeout=$2 output_variable=$3
    shift 3
    local timestamp
    timestamp=$(epoch_milliseconds) || return 1
    local -a arguments=(
        --silent
        --show-error
        --fail
        --connect-timeout "$timeout"
        --max-time "$timeout"
        --get
        "$SERVER$path"
        --data-urlencode 'callback=srun_callback'
        --data-urlencode "_=$timestamp"
    )
    if [[ -n $WIRED_IP ]]; then
        arguments+=(--interface "$WIRED_IP")
    fi

    while (($# >= 2)); do
        arguments+=(--data-urlencode "$1=$2")
        shift 2
    done
    (($# == 0)) || return 1

    local response_body curl_status
    response_body=$(curl "${arguments[@]}" 2>/dev/null)
    curl_status=$?
    ((curl_status == 0)) || return "$curl_status"
    [[ -n $response_body ]] || return 1
    printf -v "$output_variable" '%s' "$response_body"
    return 0
}

is_valid_ipv4() {
    local ip_address=$1 octet
    local IFS=.
    local -a octets=()
    read -r -a octets <<< "$ip_address"
    ((${#octets[@]} == 4)) || return 1
    for octet in "${octets[@]}"; do
        [[ $octet =~ ^[0-9]{1,3}$ ]] || return 1
        ((10#$octet <= 255)) || return 1
    done
    return 0
}

find_ready_wired_ipv4() {
    local interface_path interface address_line cidr
    WIRED_INTERFACE=''
    WIRED_IP=''

    for interface_path in /sys/class/net/*; do
        [[ -e $interface_path ]] || continue
        interface=${interface_path##*/}
        [[ $interface != lo ]] || continue
        [[ ! -d $interface_path/wireless ]] || continue
        [[ ! -e $interface_path/phy80211 ]] || continue
        [[ $(readlink -f "$interface_path") != /sys/devices/virtual/net/* ]] || continue
        [[ -r $interface_path/operstate ]] || continue
        case $(<"$interface_path/operstate") in
            up|unknown) ;;
            *) continue ;;
        esac

        address_line=$(ip -o -4 address show dev "$interface" scope global 2>/dev/null | head -n 1) || true
        [[ -n $address_line ]] || continue
        read -r _ _ _ cidr _ <<< "$address_line"
        [[ -n ${cidr:-} ]] || continue
        WIRED_INTERFACE=$interface
        WIRED_IP=${cidr%%/*}
        is_valid_ipv4 "$WIRED_IP" || { WIRED_INTERFACE=''; WIRED_IP=''; continue; }
        [[ $WIRED_IP != 169.254.* ]] || { WIRED_INTERFACE=''; WIRED_IP=''; continue; }
        return 0
    done
    return 1
}

test_srun_server_reachable() {
    local -a arguments=(
        --silent
        --output /dev/null
        --connect-timeout "$STATUS_TIMEOUT_SECONDS"
        --max-time "$STATUS_TIMEOUT_SECONDS"
        --get
        "$SERVER/cgi-bin/rad_user_info"
        --data-urlencode 'callback=srun_callback'
    )
    [[ -z $WIRED_IP ]] || arguments+=(--interface "$WIRED_IP")
    curl "${arguments[@]}" >/dev/null 2>&1
}

wait_for_wired_network() {
    log_message INFO "最多等待 ${READINESS_TIMEOUT_SECONDS} 秒，检查有线网、IPv4 和 Srun 服务器。"
    local deadline=$((SECONDS + READINESS_TIMEOUT_SECONDS))
    local state='' previous_state=''

    while ((SECONDS < deadline)); do
        if ! find_ready_wired_ipv4; then
            state='等待已连接且取得有效 IPv4 的物理有线网卡。'
        elif ! test_srun_server_reachable; then
            state="有线网 ${WIRED_INTERFACE} (${WIRED_IP}) 已就绪，等待 Srun 服务器可访问。"
        else
            log_message INFO "有线网络已就绪: ${WIRED_INTERFACE} (${WIRED_IP})。"
            return 0
        fi

        if [[ $state != "$previous_state" ]]; then
            log_message INFO "$state"
            previous_state=$state
        fi
        sleep "$READINESS_POLL_SECONDS"
    done

    log_message ERROR '限定时间内有线网络或 Srun 服务器仍未就绪。'
    return 1
}

get_srun_online_status() {
    local response error_code='' error_message='' combined
    ONLINE_KNOWN=0
    ONLINE=0

    if ! invoke_srun_request '/cgi-bin/rad_user_info' "$STATUS_TIMEOUT_SECONDS" response; then
        log_message WARN 'Srun 在线状态接口暂时不可用；将直接尝试认证。'
        return 0
    fi
    if ! parse_jsonp "$response"; then
        log_message WARN 'Srun 在线状态接口返回了无法识别的数据；将直接尝试认证。'
        return 0
    fi

    if get_json_string_field "$JSON_BODY" 'error'; then error_code=$JSON_FIELD; fi
    if get_json_string_field "$JSON_BODY" 'error_msg'; then error_message=$JSON_FIELD; fi
    if [[ $error_code == ok || $error_code == up_pwd_alert ]]; then
        ONLINE_KNOWN=1
        ONLINE=1
        return 0
    fi

    combined="${error_code,,} ${error_message,,}"
    if [[ $combined =~ not[_[:space:]-]?online|offline|未上线|不在线 ]]; then
        ONLINE_KNOWN=1
        ONLINE=0
    fi
    return 0
}

is_permanent_authentication_error() {
    local error_text=${1,,}
    [[ $error_text =~ password[_[:space:]-]?error|username[_[:space:]-]?error|invalid[[:space:]]+(user|password|credential)|user[_[:space:]-]?not[_[:space:]-]?found|account[_[:space:]-]?not[_[:space:]-]?found|用户不存在|账号不存在|密码错误|用户名错误 ]]
}

do_login_attempt() {
    local challenge_response login_response token='' client_ip=''
    local escaped_username escaped_password escaped_ip escaped_acid
    local info_json info password_encoded checksum error_code='' error_message=''
    LAST_ERROR=''
    LAST_PERMANENT=0

    if ! invoke_srun_request '/cgi-bin/get_challenge' "$REQUEST_TIMEOUT_SECONDS" challenge_response \
        username "$USERNAME" ip ''; then
        LAST_ERROR='获取 challenge 失败：网络请求未成功。'
        return 1
    fi
    if ! parse_jsonp "$challenge_response"; then
        LAST_ERROR='获取 challenge 失败：服务器返回了无效 JSONP。'
        return 1
    fi
    if get_json_string_field "$JSON_BODY" 'challenge'; then token=$JSON_FIELD; fi
    if get_json_string_field "$JSON_BODY" 'client_ip'; then client_ip=$JSON_FIELD; fi
    if [[ -z $token || -z $client_ip ]]; then
        LAST_ERROR='challenge 响应缺少 challenge 或 client_ip。'
        return 1
    fi
    if ! is_valid_ipv4 "$client_ip"; then
        LAST_ERROR='challenge 响应包含无效 IPv4 地址。'
        return 1
    fi

    escaped_username=$(json_escape "$USERNAME")
    escaped_password=$(json_escape "$PASSWORD")
    escaped_ip=$(json_escape "$client_ip")
    escaped_acid=$(json_escape "$AC_ID")
    info_json="{\"username\":\"${escaped_username}\",\"password\":\"${escaped_password}\",\"ip\":\"${escaped_ip}\",\"acid\":\"${escaped_acid}\",\"enc_ver\":\"${ENC_VER}\"}"

    xxtea_encode "$info_json" "$token" || { LAST_ERROR='XXTEA 编码失败。'; return 1; }
    srun_base64 "$XXTEA_HEX" || { LAST_ERROR='SRBX1 Base64 编码失败。'; return 1; }
    info="{SRBX1}${SRUN_B64}"

    hmac_md5 "$token" "$PASSWORD" || { LAST_ERROR='HMAC-MD5 计算失败。'; return 1; }
    password_encoded="{MD5}${HMAC_MD5}"
    sha1_hex "${token}${USERNAME}${token}${HMAC_MD5}${token}${AC_ID}${token}${client_ip}${token}${N}${token}${TYPE}${token}${info}" \
        || { LAST_ERROR='SHA1 校验值计算失败。'; return 1; }
    checksum=$SHA1

    if ! invoke_srun_request '/cgi-bin/srun_portal' "$REQUEST_TIMEOUT_SECONDS" login_response \
        action login \
        username "$USERNAME" \
        password "$password_encoded" \
        os Linux \
        name Linux \
        double_stack 0 \
        chksum "$checksum" \
        info "$info" \
        ac_id "$AC_ID" \
        ip "$client_ip" \
        n "$N" \
        type "$TYPE"; then
        LAST_ERROR='登录请求失败：网络请求未成功。'
        return 1
    fi
    if ! parse_jsonp "$login_response"; then
        LAST_ERROR='登录失败：服务器返回了无效 JSONP。'
        return 1
    fi

    if get_json_string_field "$JSON_BODY" 'error'; then error_code=$JSON_FIELD; fi
    if get_json_string_field "$JSON_BODY" 'error_msg'; then error_message=$JSON_FIELD; fi
    if [[ $error_code == ok || $error_code == up_pwd_alert ]]; then
        LAST_ERROR="认证成功，用户 ${USERNAME}，地址 ${client_ip}。"
        return 0
    fi

    [[ -n $error_message ]] || error_message=${error_code:-未知的 Srun 响应}
    LAST_ERROR="Srun 拒绝登录: $error_message"
    if is_permanent_authentication_error "$error_code $error_message"; then
        LAST_PERMANENT=1
    fi
    return 1
}

run_main() {
    local argument_status attempt delay
    log_message INFO '认证任务启动。'

    parse_arguments "$@"
    argument_status=$?
    if ((argument_status == 2)); then return "$EXIT_OK"; fi
    ((argument_status == 0)) || return "$EXIT_CONFIG_ERROR"

    check_dependencies || return "$EXIT_CONFIG_ERROR"
    read_config || return "$EXIT_CONFIG_ERROR"
    if ((CHECK_CONFIG_ONLY)); then
        log_message INFO '配置和运行依赖检查通过。'
        return "$EXIT_OK"
    fi

    wait_for_wired_network || return "$EXIT_NETWORK_NOT_READY"
    get_srun_online_status
    if ((ONLINE_KNOWN && ONLINE)); then
        log_message INFO '有线校园网已经通过 Srun 认证，无需重复登录。'
        return "$EXIT_OK"
    fi
    if ((!ONLINE_KNOWN)); then
        log_message WARN '在线状态无法确认，将直接进行 Srun 认证。'
    fi

    for ((attempt = 1; attempt <= MAX_ATTEMPTS; attempt++)); do
        log_message INFO "认证尝试 ${attempt}/${MAX_ATTEMPTS}。"
        if do_login_attempt; then
            log_message INFO "$LAST_ERROR"
            return "$EXIT_OK"
        fi

        log_message ERROR "$LAST_ERROR"
        if ((LAST_PERMANENT)); then
            log_message ERROR '服务器已报告明确的账号、密码或配置错误，停止重试。'
            return "$EXIT_AUTH_FAILED"
        fi
        if ((attempt < MAX_ATTEMPTS)); then
            delay=$((5 * attempt))
            log_message INFO "${delay} 秒后重试。"
            sleep "$delay"
        fi
    done

    log_message ERROR "达到最大认证次数 ${MAX_ATTEMPTS}，认证失败。"
    return "$EXIT_AUTH_FAILED"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    run_main "$@"
    exit_code=$?
    log_message INFO "任务结束，退出码 ${exit_code}。"
    exit "$exit_code"
fi
