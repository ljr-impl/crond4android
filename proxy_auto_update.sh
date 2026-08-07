#!/system/bin/sh
# 补全环境变量，确保定时任务下 am / iptables / awk 等命令正常调用
export PATH="/product/bin:/apex/com.android.runtime/bin:/system/bin:/system/xbin:/odm/bin:/vendor/bin:$PATH"

# ===== 配置参数 =====

SYNC_SUBSTORE_API="http://127.0.0.1:3000/api/sync/artifacts"

DOWNLOAD_URL="https://examplet.com/sing-box_ref1nd_root.json"

BOX_HOME="/data/user/0/com.boxproxy.box/files/box"
SINGBOX_DIR="$BOX_HOME/sing-box/"

SINGBOX_SECRET=""  # 这里改成你的 Clash API 密钥，改完只需维护这一处
API_HOST="127.0.0.1"
API_PORT="9090"

# ===== BusyBox =====

if [ -x "/data/adb/ksu/bin/busybox" ]; then
    BUSYBOX="/data/adb/ksu/bin/busybox"
elif [ -x "/data/adb/magisk/busybox" ]; then
    BUSYBOX="/data/adb/magisk/busybox"
elif [ -x "/data/adb/ap/bin/busybox" ]; then
    BUSYBOX="/data/adb/ap/bin/busybox"
else
    BUSYBOX="busybox"
fi

# ===== 函数定义 =====

http_put() {
    local path="$1"
    local token="${2:-$SINGBOX_SECRET}"
    local req resp status_line

    req=$(printf "PUT %s HTTP/1.1\r\nHost: %s:%s\r\nAuthorization: Bearer %s\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" \
        "$path" "$API_HOST" "$API_PORT" "$token")

    resp=$($BUSYBOX nc -w 5 "$API_HOST" "$API_PORT" <<EOF
$req
EOF
)
    status_line=$(echo "$resp" | head -1)
    # 调试用：想确认实际返回内容时取消下面注释
    # echo "DEBUG http_put resp: $status_line" >&2
    
    # 放宽匹配：任意 2xx 都算成功（200/204等）
    echo "$status_line" | grep -qE "HTTP/1\.[01] 2[0-9][0-9]"
}

clean_firewall() {
    sleep 20
    # echo "开始清理 IPv4 和 IPv6 链中防火墙拦截规则..."

    local chains="fw_INPUT fw_OUTPUT fw_OUTPUT_oplus_dns zte_fw_gms"
    local chain proto table cmd line_numbers deleted_count line_num full_rule

    for chain in $chains; do
        for proto in ipv4 ipv6; do
            table="filter"
            cmd=""

            case "$proto" in
                ipv4) cmd="iptables" ;;
                ipv6) cmd="ip6tables" ;;
            esac

            if ! command -v "$cmd" > /dev/null 2>&1; then
                # echo "跳过 $proto：$cmd 命令不存在"
                continue
            fi

            line_numbers=$(
                $cmd -t "$table" -nvL "$chain" --line-numbers 2>/dev/null \
                    | awk '/REJECT|DROP/ {print $1}' \
                    | sort -rn
            )

            if [ -z "$line_numbers" ]; then
                # echo "$proto: $chain 中未发现防火墙拦截规则"
                continue
            fi

            deleted_count=0

            for line_num in $line_numbers; do
                if $cmd -t "$table" -D "$chain" "$line_num" 2>/dev/null; then
                    deleted_count=$((deleted_count + 1))
                else
                    :
                    # echo "删除失败 ($proto) $chain 第 ${line_num} 行"
                fi
            done

            # echo "$proto: $chain 中共删除 ${deleted_count} 条防火墙拦截规则"
        done
    done

    # echo "IPv4 和 IPv6 链中防火墙拦截规则清理完成"
}

# ===== 初始化 =====

mkdir -p "$SINGBOX_DIR"

FILE_NAME="${DOWNLOAD_URL##*/}"
TARGET_FILE="$SINGBOX_DIR/$FILE_NAME"
TEMP_FILE="${TARGET_FILE}.tmp"

# ===== 触发 Sub-Store 同步 =====

SYNC_RESP=$($BUSYBOX wget -q --timeout=180 --tries=1 -O - "$SYNC_SUBSTORE_API" 2>&1)
SYNC_RC=$?


if [ $SYNC_RC -ne 0 ]; then
    echo "Sub-Store sync request failed"
    exit 1
fi

echo "$SYNC_RESP" | $BUSYBOX grep -q "success" || {
    echo "Sub-Store sync reported failure: $SYNC_RESP"
    exit 1
}

# ===== 下载配置（带随机参数，避免命中 CDN 旧缓存） =====

rm -f "$TEMP_FILE"
CACHE_BUST_URL="${DOWNLOAD_URL}?nocache=$(date +%s)"
$BUSYBOX wget -q --timeout=15 --tries=2 -O "$TEMP_FILE" "$CACHE_BUST_URL" >/dev/null 2>&1


if [ $? -ne 0 ]; then
    rm -f "$TEMP_FILE"
    echo "Config download failed"
    exit 1
fi

# ===== 文件检查 =====

if [ ! -s "$TEMP_FILE" ]; then
    rm -f "$TEMP_FILE"
    echo "Config file empty"
    exit 1
fi

# ===== 替换正式文件 =====

if ! mv -f "$TEMP_FILE" "$TARGET_FILE"; then
    rm -f "$TEMP_FILE"
    echo "Update config file failed"
    exit 1
fi

# ===== 判断内核类型，决定 ACTION =====

case "$FILE_NAME" in
    *ref1nd*|*Ref1nd*|*REF1ND*|*Re*|*re*|*mihomo*)
        ACTION="update"
        ;;
    *)
        ACTION="restart"
        ;;
esac

# ===== 重启/重载 Box 服务 =====

if [ "$ACTION" = "update" ]; then
    http_put "/providers/proxies/subs" 
else
    am broadcast -a com.boxproxy.box.notification.ACTION_RESTART -p com.boxproxy.box >/dev/null 2>&1
fi

if [ $? -ne 0 ]; then
    echo "$FILE_NAME $ACTION failed"
    exit 1
fi

# clean_firewall >/dev/null 2>&1 &

echo "$FILE_NAME $ACTION success"
exit 0