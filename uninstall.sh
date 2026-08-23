#!/system/bin/sh
MODDIR="${0%/*}"
cronDataDir='/data/adb/crond'

if [ ! -f "${cronDataDir}/conf/KEEP_ON_UNINSTALL" ]; then
  # $BUSYBOX pkill -f "${MODDIR}/watcher.sh" >/dev/null 2>&1
  
  # $BUSYBOX pkill -f "crond.*${cronDataDir}" >/dev/null 2>&1

  rm -rf "${cronDataDir}"
  
fi

