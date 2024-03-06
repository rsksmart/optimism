#!/bin/sh
set -exu

DEFAULT_JVM_OPTS="-Xms4G"
RSKJ_SYS_PROPS="-Dlogback.configurationFile=/etc/rsk/logback.xml -Drsk.conf.file=/etc/rsk/node.conf"
RSKJ_CLASS="co.rsk.Start"
RSKJ_OPTS="--regtest --reset"

exec java $DEFAULT_JVM_OPTS $RSKJ_SYS_PROPS -cp rsk.jar $RSKJ_CLASS $RSKJ_OPTS \"${@}\" --
