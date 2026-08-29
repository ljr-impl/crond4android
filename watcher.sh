#!/system/bin/sh
MODDIR="${0%/*}"
cronDataDir='/data/adb/crond'
CROND_ARGS="crond -b -c ${cronDataDir}/spool -L ${cronDataDir}/logs/run.log -l 8"
CTRL_FIFO="${cronDataDir}/conf/ctrl.fifo"

if [ "$KSU" = "true" ] || [ -d "/data/adb/ksu" ]; then
    BUSYBOX="/data/adb/ksu/bin/busybox"
elif [ "$MAGISK_VER" != "" ] || [ -d "/data/adb/magisk" ]; then
    BUSYBOX="/data/adb/magisk/busybox"
elif [ "$APATCH" = "true" ] || [ -d "/data/adb/ap" ]; then
    BUSYBOX="/data/adb/ap/bin/busybox"
else
    exit 1
fi

is_running() {
    $BUSYBOX pgrep -f "${CROND_ARGS}" >/dev/null 2>&1
}

start_crond() {
    if ! is_running; then
        mkdir -p "${cronDataDir}/spool" "${cronDataDir}/logs" "${cronDataDir}/conf"
        $BUSYBOX ${CROND_ARGS} >/dev/null 2>&1
        sleep 0.5
    fi
    PIDS=$($BUSYBOX pgrep -f "${CROND_ARGS}" | tr '\n' ' ' | xargs)
    if [ -n "${PIDS}" ]; then
        sed -Ei "s/^description=(\[.*][[:space:]]*)?/description=[ ✅ Running | PID:${PIDS}] /g" "${MODDIR}/module.prop"
    else
        sed -Ei "s/^description=(\[.*][[:space:]]*)?/description=[ ⚠ Start Failed ] /g" "${MODDIR}/module.prop"
    fi
}

stop_crond() {
    if is_running; then
        $BUSYBOX pkill -f "${CROND_ARGS}" >/dev/null 2>&1
        sleep 0.5
        > "${cronDataDir}/logs/run.log"
        sed -Ei "s/^description=(\[.*][[:space:]]*)?/description=[ ⏹ Stopped ] /g" "${MODDIR}/module.prop"
    fi
}

mkdir -p "${cronDataDir}/conf"
[ -p "$CTRL_FIFO" ] || { rm -f "$CTRL_FIFO"; $BUSYBOX mkfifo "$CTRL_FIFO"; }

while true; do
    if read -r cmd < "$CTRL_FIFO"; then
        case "$cmd" in
            start)   start_crond ;;
            stop)    stop_crond ;;
            restart) stop_crond; start_crond ;;
        esac
    fi
done