#!/system/bin/sh
# 开发侧入口。正式副本随模块发布：
#   module/tools/identify-thermal.sh  ->  /data/adb/modules/thermocharge/tools/
# 这里只做转发，避免两份实现各自漂移。
exec sh "$(dirname "$0")/../module/tools/identify-thermal.sh" "$@"
