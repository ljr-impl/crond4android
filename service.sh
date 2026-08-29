#!/system/bin/sh
MODDIR="${0%/*}"
cronDataDir='/data/adb/crond'

MANUAL="${cronDataDir}/conf/MANUAL"
USE_WATCHER="${cronDataDir}/conf/USE_WATCHER"
CROND_ARGS="crond -b -c ${cronDataDir}/spool -L ${cronDataDir}/logs/run.log -l 8"


if [ "$KSU" = "true" ] || [ -d "/data/adb/ksu" ]; then
    BUSYBOX="/data/adb/ksu/bin/busybox"
elif [ "$MAGISK_VER" != "" ] || [ -d "/data/adb/magisk" ]; then
    BUSYBOX="/data/adb/magisk/busybox"
elif [ "$APATCH" = "true" ] || [ -d "/data/adb/ap" ]; then
    BUSYBOX="/data/adb/ap/bin/busybox"
else
    exit 1
fi

mkdir -p "${cronDataDir}/spool" "${cronDataDir}/logs" "${cronDataDir}/conf"

if [ ! -f "${MANUAL}" ]; then
    $BUSYBOX pkill -f "${CROND_ARGS}" >/dev/null 2>&1
    $BUSYBOX ${CROND_ARGS} >/dev/null 2>&1
    sleep 0.5

    PIDS=$($BUSYBOX pgrep -f "${CROND_ARGS}" | tr '\n' ' ' | xargs)
    if [ -n "${PIDS}" ]; then
        sed -Ei "s/^description=(\[.*][[:space:]]*)?/description=[ ✅ Running | PID:${PIDS}] /g" "${MODDIR}/module.prop"
    else
        sed -Ei "s/^description=(\[.*][[:space:]]*)?/description=[ ⚠ Start Failed ] /g" "${MODDIR}/module.prop"
    fi
else
    sed -Ei "s/^description=(\[.*][[:space:]]*)?/description=[ ⏹ Stopped ] /g" "${MODDIR}/module.prop"
fi

# 仅当安装时检测出本设备不支持 cgroup 迁移，才需要常驻 watcher
if [ -f "$USE_WATCHER" ]; then
    $BUSYBOX setsid "${MODDIR}/watcher.sh" >/dev/null 2>&1 &
fi