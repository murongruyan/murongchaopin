#!/system/bin/sh
# 启动 KSU WebUI 并跳转到本模块页面
am start -n "io.github.a13e300.ksuwebui/.WebUIActivity" -e id "murongchaopin" >/dev/null 2>&1
exit 0
