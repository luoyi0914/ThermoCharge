#!/system/bin/sh
# 开机早期: 只做目录准备, 不碰充电节点 (此时 xm_power 还没起来)
MODDIR=${0%/*}
mkdir -p /data/adb/thermocharge/log
chmod 700 /data/adb/thermocharge
chmod 700 /data/adb/thermocharge/log
