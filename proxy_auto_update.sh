#!/system/bin/sh
# 补全环境变量，确保定时任务下 am / iptables / awk 等命令正常调用
export PATH="/product/bin:/apex/com.android.runtime/bin:/system/bin:/system/xbin:/odm/bin:/vendor/bin:$PATH"

# ===== 配置参数 =====
BOX_HOME="/data/user/0/com.boxproxy.box/files/box"
BOXCTL="$BOX_HOME/bin/boxctl"
DB="$BOX_HOME/box.db"
SINGBOX_DIR="$BOX_HOME/sing-box/"

SYNC_SUBSTORE_API="http://127.0.0.1:3000/api/sync/artifacts"
DOWNLOAD_URL="https://example.com/sing-box_root.json"
SINGBOX_SECRET=""  #  Clash API 密钥
API_HOST="127.0.0.1"
API_PORT="9090"
PROVIDER_NAME="subs"   # 多订阅用英文逗号分隔，逗号前后不要空格
BUILTIN_AUTOUPDATE=true   # true=跳过HTTP PUT重载，false=按原逻辑走

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

    resp=$($BUSYBOX nc -w 8 "$API_HOST" "$API_PORT" <<EOF
$req
EOF
)
    status_line=$(echo "$resp" | head -1 | tr -d '\r')
    # 调试用：想确认实际返回内容时取消下面注释
    # echo "DEBUG http_put resp: [$status_line]" >&2
    echo "$status_line" | grep -qE "HTTP/1\.[01] 2[0-9][0-9]"
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

# ===== 配置文件检查 =====
if [ ! -s "$TEMP_FILE" ]; then
    rm -f "$TEMP_FILE"
    echo "Config file empty"
    exit 1
fi

# ===== 替换正式配置文件 =====
if ! mv -f "$TEMP_FILE" "$TARGET_FILE"; then
    rm -f "$TEMP_FILE"
    echo "Update config file failed"
    exit 1
fi

# ===== 检查必备数据文件 =====
if [ ! -x "$BOXCTL" ]; then
    echo "BoxCTL not found"
    exit 1
fi

if [ ! -f "$DB" ]; then
    echo "Box database not found"
    exit 1
fi

# ===== 判断内核类型，决定 ACTION =====
case "$FILE_NAME" in
    *ref1nd*|*Ref1nd*|*REF1ND*|*mihomo*)
        ACTION="update"
        ;;
    *)
        ACTION="restart"
        ;;
esac

# ===== 重启/重载 Box 服务 =====
if [ "$ACTION" = "update" ]; then
    if [ "$BUILTIN_AUTOUPDATE" = "true" ]; then
        echo "$FILE_NAME skip update subscription"
        exit 0
    fi
    fail=0
    fail_list=""
    OLD_IFS="$IFS"
    IFS=','
    for p in $PROVIDER_NAME; do
        IFS="$OLD_IFS"
        if ! http_put "/providers/proxies/$p"; then
            fail=1
            fail_list="$fail_list $p"
        fi
        IFS=','
    done
    IFS="$OLD_IFS"
    if [ $fail -ne 0 ]; then
        echo "Provider update failed:$fail_list"
    fi
    [ $fail -eq 0 ]
else
   "$BOXCTL" --db "$DB" restart >/dev/null 2>&1
fi

if [ $? -ne 0 ]; then
    echo "$FILE_NAME $ACTION failed"
    exit 1
fi

echo "$FILE_NAME $ACTION success"
exit 0
