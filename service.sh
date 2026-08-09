#!/system/bin/sh
MODDIR="${0%/*}"
cronDataDir='/data/adb/crond'

MANUAL="${cronDataDir}/conf/MANUAL"
# 统一完整的启动参数
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

# 确保所需工作目录存在，防止第一次运行崩溃
mkdir -p "${cronDataDir}/spool" "${cronDataDir}/logs" "${cronDataDir}/conf"

if [ ! -f "${MANUAL}" ]; then
    # 先清理可能残留的同配置进程，防止重复拉起
    $BUSYBOX pkill -f "${CROND_ARGS}" >/dev/null 2>&1
    
    # 启动 crond 进程
    nohup $BUSYBOX ${CROND_ARGS} >/dev/null 2>&1
    sleep 0.5
    
    # 根据配置目录精准获取 PID
    PIDS=$($BUSYBOX pgrep -f "${CROND_ARGS}" | tr '\n' ' ' | xargs)
    if [ -n "${PIDS}" ]; then
        sed -Ei "s/^description=(\[.*][[:space:]]*)?/description=[✅ Running | PID:${PIDS}] /g" "${MODDIR}/module.prop"
    else
        sed -Ei "s/^description=(\[.*][[:space:]]*)?/description=[⚠ Start Failed] /g" "${MODDIR}/module.prop"
    fi
else
    sed -Ei "s/^description=(\[.*][[:space:]]*)?/description=[ ⏹ Stopped ] /g" "${MODDIR}/module.prop"
fi
