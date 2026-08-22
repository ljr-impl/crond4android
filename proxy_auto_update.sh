#!/system/bin/sh
# 补全环境变量，确保定时任务下 am / iptables / awk 等命令正常调用
export PATH="/product/bin:/apex/com.android.runtime/bin:/system/bin:/system/xbin:/odm/bin:/vendor/bin:$PATH"

# ===== 配置参数 =====
SYNC_SUBSTORE_API="http://127.0.0.1:3"      # sub store 后端
DOWNLOAD_URL="https://example.com/sing-box_ref1nd_root.json"     # 配置远程链接

# 下载配置 + 重启开关：false=只同步Sub-Store，不下载不重启（默认）；true=同步后继续下载配置并重启
ENABLE_DOWNLOAD_RESTART=false

# 各阶段超时（秒）——总和需控制在App手动运行30s限制内
SYNC_TIMEOUT=20        # Sub-Store 同步硬顶（wget --timeout本身也会顶，这里是外层timeout兜底）
DOWNLOAD_TIMEOUT=8     # 下载配置硬顶
RESTART_TIMEOUT=5      # boxctl restart 硬顶

# ===== 路径 =====
BOX_HOME="/data/user/0/com.boxproxy.box/files/box"
BOXCTL="$BOX_HOME/bin/boxctl"
DB="$BOX_HOME/box.db"
SINGBOX_DIR="$BOX_HOME/sing-box/"
LOCK_DIR="/data/local/tmp/sync_and_restart.lock"
STALE_LOCK_SECONDS=120   # 锁目录存在超过这个时间视为异常残留（kill -9/重启等），自动清理

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

# ===== 并发锁：防止定时任务与手动触发重叠执行 =====
if [ -d "$LOCK_DIR" ]; then
    LOCK_AGE=$(( $(date +%s) - $(date -r "$LOCK_DIR" +%s 2>/dev/null || echo 0) ))
    if [ "$LOCK_AGE" -gt "$STALE_LOCK_SECONDS" ]; then
        echo "Stale lock detected (${LOCK_AGE}s old), removing"
        rmdir "$LOCK_DIR" 2>/dev/null
    fi
fi

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "Another instance is running, skip this run"
    exit 1
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT INT TERM

# ===== 初始化 =====
mkdir -p "$SINGBOX_DIR"

FILE_NAME="${DOWNLOAD_URL##*/}"
TARGET_FILE="$SINGBOX_DIR/$FILE_NAME"
TEMP_FILE="${TARGET_FILE}.tmp"

# ===== 触发 Sub-Store 同步 =====
SYNC_RESP=$($BUSYBOX timeout "$SYNC_TIMEOUT" $BUSYBOX wget -q --timeout=$((SYNC_TIMEOUT - 1)) --tries=1 -O - "$SYNC_SUBSTORE_API/api/sync/artifacts" 2>&1)
SYNC_RC=$?

if [ $SYNC_RC -ne 0 ]; then
    echo "Sub-Store sync request failed or timed out (${SYNC_TIMEOUT}s)"
    exit 1
fi

echo "$SYNC_RESP" | $BUSYBOX grep -q "success" || {
    echo "Sub-Store sync reported failure: $SYNC_RESP"
    exit 1
}

echo "Sub-Store sync success"

if [ "$ENABLE_DOWNLOAD_RESTART" != "true" ]; then
    echo "ENABLE_DOWNLOAD_RESTART=false, skip download & restart"
    exit 0
fi

# ===== 下载配置（带随机参数，避免命中 CDN 旧缓存） =====
rm -f "$TEMP_FILE"
CACHE_BUST_URL="${DOWNLOAD_URL}?nocache=$(date +%s)"
$BUSYBOX timeout "$DOWNLOAD_TIMEOUT" $BUSYBOX wget -q --timeout=$((DOWNLOAD_TIMEOUT - 1)) --tries=1 -O "$TEMP_FILE" "$CACHE_BUST_URL" >/dev/null 2>&1

if [ $? -ne 0 ]; then
    rm -f "$TEMP_FILE"
    echo "Config download failed or timed out (${DOWNLOAD_TIMEOUT}s)"
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

# ===== 统一重启（不再走 Clash API 热更新） =====
$BUSYBOX timeout "$RESTART_TIMEOUT" "$BOXCTL" --db "$DB" restart >/dev/null 2>&1
RESTART_RC=$?

if [ $RESTART_RC -ne 0 ]; then
    echo "$FILE_NAME restart failed or timed out (${RESTART_TIMEOUT}s)"
    exit 1
fi

echo "$FILE_NAME restart success"
exit 0