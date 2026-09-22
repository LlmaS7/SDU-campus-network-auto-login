#!/usr/bin/env bash

set -uo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/../srun_login.sh"

tests_run=0
tests_failed=0

assert_equal() {
    local expected=$1 actual=$2 description=$3
    ((tests_run++))
    if [[ $actual == "$expected" ]]; then
        printf '[OK]   %s\n' "$description"
    else
        printf '[FAIL] %s\n       expected: %s\n       actual:   %s\n' \
            "$description" "$expected" "$actual"
        ((tests_failed++))
    fi
}

assert_status() {
    local expected=$1 description=$2
    shift 2
    "$@"
    local actual=$?
    assert_equal "$expected" "$actual" "$description"
}

assert_equal 'p a s s' "$(trim_whitespace '  p a s s  ')" '配置值只移除边界空白'
assert_equal 'a\"b\\c\t中' "$(json_escape $'a"b\\c\t中')" 'JSON 特殊字符和 UTF-8 转义'

assert_status 0 '合法 IPv4' is_valid_ipv4 '192.168.75.10'
assert_status 1 '拒绝越界 IPv4' is_valid_ipv4 '256.1.1.1'
assert_status 1 '拒绝字段不足的 IPv4' is_valid_ipv4 '10.0.1'

parse_jsonp 'srun_callback({"error":"ok","client_ip":"10.0.0.2"});'
assert_equal '{"error":"ok","client_ip":"10.0.0.2"}' "$JSON_BODY" '解析 Srun JSONP 外壳'
get_json_string_field "$JSON_BODY" 'client_ip'
assert_equal '10.0.0.2' "$JSON_FIELD" '读取 JSON 字符串字段'

test_message='{"username":"20260001","password":"p@ss word","ip":"10.0.0.8","acid":"1","enc_ver":"srun_bx1"}'
test_token='0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
xxtea_encode "$test_message" "$test_token"
assert_equal \
    '33309fb1e042468b694d2b93b6ccd1a98abda68eab3b0ae6f4729ce766bf3649b778f36ab6543adf2d404a7272b9be3585789bdfb244dce75e915294c15dfc9a3d3699524774a28e7d4d0be15de38069d7e93b8a3c3e980b064bbddcbf75697c7b1bc01c' \
    "$XXTEA_HEX" \
    'XXTEA 固定测试向量'
srun_base64 "$XXTEA_HEX"
assert_equal \
    '9zosbrVoh/f3FmKFfbzhdZd53/BlyvlU5N8MeIOA0YU7rg0dfp+B7xjLmqRxKWDjTcXW7ERP7ynrYu8Hvu74UktIUuRNn88ysHtGDu7kSCqcBFK8gJBZov1GwnxAnap4r6wLNL==' \
    "$SRUN_B64" \
    'Srun 自定义 Base64 固定测试向量'
hmac_md5 "$test_token" 'p@ss word'
assert_equal '848d935a3cd1e56ec8a0470f0044e4d6' "$HMAC_MD5" 'HMAC-MD5 固定测试向量'

timestamp=$(epoch_milliseconds)
if [[ $timestamp =~ ^[0-9]{13}$ ]]; then timestamp_shape=valid; else timestamp_shape=invalid; fi
assert_equal 'valid' "$timestamp_shape" 'Srun 请求时间戳为 13 位毫秒值'

config_temp=$(mktemp)
trap 'rm -f -- "$config_temp"' EXIT
printf '[srun]\nusername = 2026 0001\npassword = p a s s\nserver = http://192.168.75.252/\nac_id = 1\n' > "$config_temp"
CONFIG_FILE=$config_temp
USERNAME=''
PASSWORD=''
SERVER=''
AC_ID=''
read_config
assert_equal '2026 0001' "$USERNAME" '配置解析保留账号内部空格'
assert_equal 'p a s s' "$PASSWORD" '配置解析保留密码内部空格'
assert_equal 'http://192.168.75.252' "$SERVER" '配置解析规范化服务器尾部斜杠'

mock_login_mode=ok
invoke_srun_request() {
    local request_path=$1 output_name=$3 mock_body
    if [[ $request_path == '/cgi-bin/get_challenge' ]]; then
        mock_body='srun_callback({"challenge":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","client_ip":"10.0.0.8"})'
    elif [[ $mock_login_mode == ok ]]; then
        mock_body='srun_callback({"error":"ok","error_msg":""})'
    else
        mock_body='srun_callback({"error":"password_error","error_msg":"密码错误"})'
    fi
    printf -v "$output_name" '%s' "$mock_body"
}

USERNAME='special " user'
PASSWORD='p a s s\word'
AC_ID='1'
do_login_attempt
assert_equal '0' "$?" '模拟 Srun 响应下完成一次认证'

mock_login_mode=permanent_error
do_login_attempt
assert_equal '1' "$?" '服务器拒绝登录时返回失败'
assert_equal '1' "$LAST_PERMANENT" '密码错误被识别为不可重试失败'

# 替换外部环境函数，验证所有认证尝试失败时不会误报成功。
check_dependencies() { return 0; }
read_config() { USERNAME='test'; PASSWORD='test'; SERVER='http://127.0.0.1'; AC_ID='1'; return 0; }
wait_for_wired_network() { return 0; }
get_srun_online_status() { ONLINE_KNOWN=1; ONLINE=0; return 0; }
do_login_attempt() { LAST_ERROR='模拟失败'; LAST_PERMANENT=0; return 1; }
log_message() { :; }
sleep() { :; }

MAX_ATTEMPTS=5
run_main --max-attempts 2
assert_equal '1' "$?" '达到最大认证次数时返回退出码 1'

printf '\n执行 %d 项测试，失败 %d 项。\n' "$tests_run" "$tests_failed"
((tests_failed == 0))
