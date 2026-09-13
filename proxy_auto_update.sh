#!/system/bin/sh
# ====== 补全环境变量 ======
export PATH="/product/bin:/apex/com.android.runtime/bin:/system/bin:/system/xbin:/odm/bin:/vendor/bin:$PATH"
# ====== 同步目标文件 ======
# 可通过环境变量 ENABLE_SELF_SYNC=false ./proxy_auto_update.sh 临时关闭，
# 避免调试用的副本被同步 crond 版本
: "${ENABLE_SELF_SYNC:=true}"
SRC_SCRIPT="$(realpath "$0")"
DEST_SCRIPT="/data/adb/crond/conf/proxy_auto_update.sh"
if [ "$ENABLE_SELF_SYNC" = "true" ]; then
{
    if [ -f "$SRC_SCRIPT" ] && [ "$SRC_SCRIPT" != "$DEST_SCRIPT" ]; then
        DEST_DIR="$(dirname "$DEST_SCRIPT")"
        if [ -d "$DEST_DIR" ]; then
            if [ ! -f "$DEST_SCRIPT" ] || ! cmp -s "$SRC_SCRIPT" "$DEST_SCRIPT"; then
                cp -fp "$SRC_SCRIPT" "$DEST_SCRIPT"
                chmod 755 "$DEST_SCRIPT"
            fi
        fi
    fi
} 2>/dev/null
fi
# 清理运行日志
LOG_FILE="/data/adb/crond/logs/run.log"
MAX_LINES=30
if [ -f "$LOG_FILE" ] && [ "$(wc -l < "$LOG_FILE")" -gt "$MAX_LINES" ]; then
    tail -n "$MAX_LINES" "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
fi

# ====== 主业务逻辑 ======

# ===== 配置参数 =====
SYNC_SUBSTORE_API="http://127.0.0.1:3001/djhdhd"
DOWNLOAD_URL="https://example.com/sing-box.json"
# 三个阶段各自独立可控（互不依赖）
ENABLE_SYNC=true        # 是否执行 Sub-Store 同步
ENABLE_DOWNLOAD=true      # 是否下载配置文件
ENABLE_RESTART=true          # 是否重启 boxctl

# 各阶段超时（秒）
DOWNLOAD_TIMEOUT=8
RESTART_TIMEOUT=5

# ===== 路径 =====
BOX_HOME="/data/user/0/com.boxproxy.box/files/box"
BOXCTL="$BOX_HOME/bin/boxctl"
DB="$BOX_HOME/box.db"
SINGBOX_DIR="$BOX_HOME/sing-box/"
LOCK_DIR="/data/local/tmp/sync_and_restart.lock"
STALE_LOCK_SECONDS=120

# ===== BusyBox =====
if [ -x "/data/adb/ksu/bin/busybox" ]; then
    BUSYBOX="/data/adb/ksu/bin/busybox"
elif [ -x "/data/adb/magisk/busybox" ]; then
    BUSYBOX="/data/adb/magisk/busybox"
elif [ -x "/data/adb/ap/bin/busybox" ]; then
    BUSYBOX="/data/adb/ap/bin/busybox"
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Not found busybox"
    exit 1
fi

# ===== 并发锁：防止定时任务与手动触发重叠执行 =====
LOCK_PID_FILE="$LOCK_DIR/pid"

if [ -d "$LOCK_DIR" ]; then
    OLD_PID=""
    [ -f "$LOCK_PID_FILE" ] && OLD_PID=$(cat "$LOCK_PID_FILE" 2>/dev/null)

    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        # 持锁进程确实还活着（例如同步阶段没有超时、卡住了），
        # 不管锁目录多久没更新都不能当成 stale，否则会出现两个实例同时持锁、
        # 先结束的那个把后来者的锁目录删掉的问题
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Another instance (pid $OLD_PID) is still alive, skip this run"
        exit 1
    fi

    # 走到这里说明记录的 PID 已经不在了（或读不到），再用 mtime 兜底判断是否为残留锁
    LOCK_MTIME=$(date -r "$LOCK_DIR" +%s 2>/dev/null)
    if [ -n "$LOCK_MTIME" ]; then
        LOCK_AGE=$(( $(date +%s) - LOCK_MTIME ))
        if [ "$LOCK_AGE" -gt "$STALE_LOCK_SECONDS" ]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Stale lock detected (${LOCK_AGE}s old, owner dead), removing"
            rm -f "$LOCK_PID_FILE" 2>/dev/null
            rmdir "$LOCK_DIR" 2>/dev/null
        fi
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Cannot read lock mtime, skip stale check (assume active)"
    fi
fi

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Another instance is running, skip this run"
    exit 1
fi
echo "$$" > "$LOCK_PID_FILE" 2>/dev/null
trap 'rm -f "$LOCK_PID_FILE" 2>/dev/null; rmdir "$LOCK_DIR" 2>/dev/null' EXIT INT TERM

# ===== 初始化 =====
mkdir -p "$SINGBOX_DIR"

FILE_NAME="${DOWNLOAD_URL##*/}"
FILE_NAME="${FILE_NAME%%\?*}"
TARGET_FILE="$SINGBOX_DIR/$FILE_NAME"
TEMP_FILE="${TARGET_FILE}.tmp"

# ===== 阶段一：触发 Sub-Store 同步 =====
if [ "$ENABLE_SYNC" = "true" ]; then
    SYNC_RESP=$($BUSYBOX wget -q -O - "$SYNC_SUBSTORE_API/api/sync/artifacts")
    SYNC_RC=$?

    if [ $SYNC_RC -ne 0 ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Sub-Store sync failed (rc=$SYNC_RC)"
        exit 1
    fi

    # 成功响应固定为 {"status":"success"}，用精确匹配而非子串匹配，
    # 避免响应体里恰好带有这个子串时被误判成功
    if [ "$SYNC_RESP" != '{"status":"success"}' ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Sub-Store sync reported failure: $SYNC_RESP"
        exit 1
    fi

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Sub-Store sync success"
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Skip sync (ENABLE_SYNC=false)"
fi

# ===== 阶段二：下载配置 =====
if [ "$ENABLE_DOWNLOAD" != "true" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Skip download (ENABLE_DOWNLOAD=false)"
else
    rm -f "$TEMP_FILE"

    case "$DOWNLOAD_URL" in
        *\?*) SEP="&" ;;
        *)    SEP="?" ;;
    esac
    CACHE_BUST_URL="${DOWNLOAD_URL}${SEP}nocache=$(date +%s)"

    $BUSYBOX timeout "$DOWNLOAD_TIMEOUT" $BUSYBOX wget -q --timeout=$((DOWNLOAD_TIMEOUT - 1)) --tries=1 -O "$TEMP_FILE" "$CACHE_BUST_URL" >/dev/null 2>&1

    if [ $? -ne 0 ]; then
        rm -f "$TEMP_FILE"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Config download failed or timed out (${DOWNLOAD_TIMEOUT}s)"
        exit 1
    fi

    if [ ! -s "$TEMP_FILE" ]; then
        rm -f "$TEMP_FILE"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Config file empty"
        exit 1
    fi

    if ! mv -f "$TEMP_FILE" "$TARGET_FILE"; then
        rm -f "$TEMP_FILE"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Update config file failed"
        exit 1
    fi

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Config file updated: $TARGET_FILE"
fi

# ===== 阶段三：重启 =====
if [ "$ENABLE_RESTART" != "true" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Skip restart (ENABLE_RESTART=false)"
    exit 0
fi

if [ ! -x "$BOXCTL" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] BoxCTL not found"
    exit 1
fi

if [ ! -f "$DB" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Box database not found"
    exit 1
fi

$BUSYBOX timeout "$RESTART_TIMEOUT" "$BOXCTL" --db "$DB" restart >/dev/null 2>&1
RESTART_RC=$?

if [ $RESTART_RC -ne 0 ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $FILE_NAME restart failed or timed out (${RESTART_TIMEOUT}s)"
    exit 1
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] $FILE_NAME restart success"
exit 0