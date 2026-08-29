#!/system/bin/sh
cronDataDir='/data/adb/crond'
MODDIR="${0%/*}"
CROND_ARGS="crond -b -c ${cronDataDir}/spool -L ${cronDataDir}/logs/run.log -l 8"
CTRL_FIFO="${cronDataDir}/conf/ctrl.fifo"
CG2_FILE="${cronDataDir}/conf/cg2_path"
USE_WATCHER="${cronDataDir}/conf/USE_WATCHER"

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

start_crond_direct() {
    if ! is_running; then
        mkdir -p "${cronDataDir}/spool" "${cronDataDir}/logs" "${cronDataDir}/conf"
        $BUSYBOX ${CROND_ARGS} >/dev/null 2>&1
        sleep 0.5
    fi
    if is_running; then
        if [ -f "$CG2_FILE" ]; then
            CG2=$(cat "$CG2_FILE")
            for RPID in $($BUSYBOX pgrep -f "${CROND_ARGS}"); do
                echo "$RPID" > "${CG2}/cgroup.procs" 2>/dev/null
            done
        fi
        PIDS=$($BUSYBOX pgrep -f "${CROND_ARGS}" | tr '\n' ' ' | xargs)
        sed -Ei "s/^description=(\[.*][[:space:]]*)?/description=[ ✅ Running | PID:${PIDS}] /g" "${MODDIR}/module.prop"
        echo "✅ crond 已启动"
    fi
}

stop_crond_direct() {
    if is_running; then
        $BUSYBOX pkill -f "${CROND_ARGS}" >/dev/null 2>&1
        sleep 0.5
        > "${cronDataDir}/logs/run.log"
        sed -Ei "s/^description=(\[.*][[:space:]]*)?/description=[ ⏹ Stopped ] /g" "${MODDIR}/module.prop"
        echo "⏹ crond 已停止"
    fi
}

send_to_watcher() {
    if [ -p "$CTRL_FIFO" ]; then
        ( $BUSYBOX timeout 3 sh -c "echo '$1' > '${CTRL_FIFO}'" ) &
        sleep 0.6
    else
        case "$1" in
            start)   start_crond_direct ;;
            stop)    stop_crond_direct ;;
            restart) stop_crond_direct; start_crond_direct ;;
        esac
    fi
}

do_start()   { if [ -f "$USE_WATCHER" ]; then send_to_watcher start;   else start_crond_direct; fi; }
do_stop()    { if [ -f "$USE_WATCHER" ]; then send_to_watcher stop;    else stop_crond_direct; fi; }
do_restart() { if [ -f "$USE_WATCHER" ]; then send_to_watcher restart; else stop_crond_direct; start_crond_direct; fi; }

case "$1" in
    start)   do_start ;;
    stop)    do_stop ;;
    restart) do_restart ;;
    *)
        if is_running; then do_stop; else do_start; fi
        ;;
esac