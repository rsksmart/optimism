#!/bin/sh
set -exu

DEFAULT_JVM_OPTS="-Xms4G"
RSKJ_SYS_PROPS="-Drpc.providers.web.http.bind_address=0.0.0.0 -Drpc.providers.web.http.hosts.0=localhost -Drpc.providers.web.http.hosts.1=127.0.0.1 -Drpc.providers.web.http.hosts.2=::1"
RSKJ_CLASS="co.rsk.Start"
RSKJ_OPTS="--regtest"

exec java $DEFAULT_JVM_OPTS $RSKJ_SYS_PROPS -cp rsk.jar $RSKJ_CLASS $RSKJ_OPTS \"${@}\" --
