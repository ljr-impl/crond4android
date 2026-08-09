#!/system/bin/sh
cronDataDir='/data/adb/crond'

if [ ! -f "${cronDataDir}/conf/KEEP_ON_UNINSTALL" ]; then
  rm -rf "${cronDataDir}"
fi

