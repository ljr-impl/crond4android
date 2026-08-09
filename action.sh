#!/system/bin/sh

cronDataDir='/data/adb/crond'
MODDIR="${0%/*}"
CROND_ARGS="crond -c ${cronDataDir}/spool -L ${cronDataDir}/logs/run.log -l 8"

# 判断 Root 环境并指定 Busybox
if [ "$KSU" = "true" ] || [ -d "/data/adb/ksu" ]; then
    BUSYBOX="/data/adb/ksu/bin/busybox"
elif [ "$MAGISK_VER" != "" ] || [ -d "/data/adb/magisk" ]; then
    BUSYBOX="/data/adb/magisk/busybox"
elif [ "$APATCH" = "true" ] || [ -d "/data/adb/ap" ]; then
    BUSYBOX="/data/adb/ap/bin/busybox"
else
    echo "⚠ 未检测到 Magisk、KernelSU 或 APatch"
    exit 1
fi

# 精准检测该模块的 crond 是否正在运行
is_running() {
    $BUSYBOX pgrep -f "${CROND_ARGS}" >/dev/null 2>&1
}

if is_running; then
    # 正在运行 → 停止（使用 busybox 精准 kill，避免 xargs 丢失及环境变量问题）
    $BUSYBOX pkill -f "${CROND_ARGS}" >/dev/null 2>&1
    sleep 0.5
    
    if is_running; then
        echo "⚠ crond 停止失败"
    else
        > "${cronDataDir}/logs/run.log"
        echo "⏹ crond 已停止, 日志已清空。"
        sed -Ei "s/^description=(\[.*][[:space:]]*)?/description=[ ⏹ Stopped ] /g" "${MODDIR}/module.prop"
    fi
else
    # 未运行 → 启动
    mkdir -p "${cronDataDir}/spool" "${cronDataDir}/logs" "${cronDataDir}/conf"
    nohup $BUSYBOX ${CROND_ARGS} >/dev/null 2>&1
    sleep 0.5

    if is_running; then
        PIDS=$($BUSYBOX pgrep -f "${CROND_ARGS}" | tr '\n' ' ' | xargs)
        sed -Ei "s/^description=(\[.*][[:space:]]*)?/description=[ ✅ Running | PID:${PIDS}] /g" "${MODDIR}/module.prop"
        echo "✅ crond 已启动 | PID:${PIDS}."
    else
        echo "⚠ crond 启动失败"
    fi
fi
