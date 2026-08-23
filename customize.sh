#!/system/bin/sh
if [ "$BOOTMODE" != true ]; then
  ui_print "------------------------------"
  ui_print "! Please install in Magisk Manager or KernelSU Manager or APatch Manager"
  ui_print "! Install from recovery is NOT supported"
  abort "------------------------------"
fi

cronDataDir='/data/adb/crond'

if [ "$KSU" = true ]; then
  BUSYBOX="/data/adb/ksu/bin/busybox"
elif [ "$APATCH" = true ]; then
  BUSYBOX="/data/adb/ap/bin/busybox"
else
  BUSYBOX="/data/adb/magisk/busybox"
fi

if [ -d "${cronDataDir}" ]; then
  ui_print "- Upgrading: checking directories and migrating legacy files..."
  mkdir -p "${cronDataDir}/spool" "${cronDataDir}/logs" "${cronDataDir}/conf"

  # 兼容旧版本文件路径自动迁移
  [ -f "${cronDataDir}/root" ] && mv "${cronDataDir}/root" "${cronDataDir}/spool/root"
  [ -f "${cronDataDir}/run.log" ] && mv "${cronDataDir}/run.log" "${cronDataDir}/logs/run.log"
  [ -f "${cronDataDir}/MANUAL" ] && mv "${cronDataDir}/MANUAL" "${cronDataDir}/conf/MANUAL"
  [ -f "${cronDataDir}/KEEP_ON_UNINSTALL" ] && mv "${cronDataDir}/KEEP_ON_UNINSTALL" "${cronDataDir}/conf/KEEP_ON_UNINSTALL"
  [ ! -f "${cronDataDir}/spool/root" ] && touch "${cronDataDir}/spool/root"
else
  ui_print "- Fresh install: Creating ${cronDataDir} directories..."
  mkdir -p "${cronDataDir}/spool" "${cronDataDir}/logs" "${cronDataDir}/conf"
  touch "${cronDataDir}/spool/root"
fi

# ============ 检测本设备是否支持 cgroup v2 迁移 ===============
ui_print "- Detecting cgroup v2 escape support on this device..."

test_cgroup2_escape() {
  CG2=$($BUSYBOX awk '$3=="cgroup2"{print $2; exit}' /proc/mounts 2>/dev/null)
  [ -z "$CG2" ] && return 1
  [ -w "${CG2}/cgroup.procs" ] || return 1

  $BUSYBOX sleep 5 &
  TEST_PID=$!
  sleep 0.2

  echo "$TEST_PID" > "${CG2}/cgroup.procs" 2>/dev/null
  RESULT=$($BUSYBOX awk -F: '$1=="0"{print $3}' /proc/${TEST_PID}/cgroup 2>/dev/null)
  kill "$TEST_PID" 2>/dev/null

  if [ "$RESULT" = "/" ]; then
    echo "$CG2" > "${cronDataDir}/conf/cg2_path"
    return 0
  fi
  return 1
}

if test_cgroup2_escape; then
  ui_print "  -> Supported, use the lightweight cgroup v2 solution"
  rm -f "${cronDataDir}/conf/USE_WATCHER"
else
  ui_print "  -> Not supported, use the permanent watcher solution"
  touch "${cronDataDir}/conf/USE_WATCHER"
fi
# ================================================================

install_crontab(){
  ui_print "- Installing crontab command"
  mkdir -p "${MODPATH}/system/bin"
  {
    echo "#!/system/bin/sh"
    if [ "$KSU" = true ]; then
      echo "/data/adb/ksu/bin/busybox crontab -c '${cronDataDir}/spool'"' $@'
    elif [ "$APATCH" = true ]; then
      echo "/data/adb/ap/bin/busybox crontab -c '${cronDataDir}/spool'"' $@'
    else
      echo "/data/adb/magisk/busybox crontab -c '${cronDataDir}/spool'"' $@'
    fi
  } > "${MODPATH}/system/bin/crontab"
}

ui_print ""
ui_print "------------------------------"
ui_print "- Do you want install crontab command?"
ui_print "- This operation will not affect the operation of background services."
ui_print "- You can manage it through the UI or by setting up an alias to run it."
ui_print "- You can create the /sdcard/crond4android.setup file to automatically install the crontab command. Write 0 to skip installation, or write 1 to proceed with installation."
ui_print ""

if [ -f /sdcard/crond4android.setup ]; then
  ui_print "- Detected file /sdcard/crond4android.setup ."
  if [ "$(sed -n 1p /sdcard/crond4android.setup)" = "1" ]; then
    ui_print "- Auto install crontab command."
    install_crontab
  else
    ui_print "- Skip installation crontab command."
  fi
else
  ui_print "- Skip installation crontab command."
fi

# ============ 拓展 ===============
boxScriptsDir="/data/user/0/com.boxproxy.box/files/box/scripts"
scriptName="proxy_auto_update.sh"
confDataDir="${cronDataDir}/conf"

if [ -f "${MODPATH}/${scriptName}" ]; then
  if [ -d "${boxScriptsDir}" ]; then
    if [ -f "${boxScriptsDir}/${scriptName}" ]; then
      ui_print "- ${boxScriptsDir}/${scriptName} existing, skip copy"
    else
      ui_print "- Copying ${scriptName} to ${boxScriptsDir}..."
      cp -f "${MODPATH}/${scriptName}" "${boxScriptsDir}/${scriptName}"
      chmod 0755 "${boxScriptsDir}/${scriptName}"
    fi
    exampleScriptPath="${boxScriptsDir}/${scriptName}"
  else
    exampleScriptPath="${confDataDir}/${scriptName}"
  fi

  ui_print "- Moving ${scriptName} to ${confDataDir}..."
  mv -f "${MODPATH}/${scriptName}" "${confDataDir}/${scriptName}"
  chmod 0755 "${confDataDir}/${scriptName}"
else
  ui_print "- 未检测到 ${scriptName}"
fi

webuiHtml="${MODPATH}/webroot/index.html"

if [ -n "${exampleScriptPath}" ] && [ -f "${webuiHtml}" ]; then
  ui_print "- Updating example path in WebUI..."
  escapedPath=$(printf '%s' "${exampleScriptPath}" | sed 's/[&\\#]/\\&/g')
  sed -i "s#/data/adb/crond/conf/proxy_auto_update.sh#${escapedPath}#g" "${webuiHtml}"
fi
# ===================================

ui_print "- Setting permissions"
set_perm_recursive $MODPATH 0 0 0755 0755
ui_print "- The background service installation is complete."