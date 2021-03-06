#!/bin/sh
set -x

# If dlv runs as PID 1 in the container it will not properly kill metrictank during shutdown
# when it receives SIGTERM (docker stop / docker-compose stop / etc...). So, instead we leave
# this script running in an endless sleep loop and trap SIGTERM, SIGINT, and SIGHUP. Then we can
# kill both metrictank and dlv and exit this script which will shutdown the container.
kill_metrictank() {
  echo "Killing metrictank"
  pkill metrictank
  sleep 1
  echo "Killing dlv"
  pkill dlv
  sleep 1
  exit 0
}

trap 'kill_metrictank' SIGTERM
trap 'kill_metrictank' SIGINT
trap 'kill_metrictank' SIGHUP

export MT_SWIM_BIND_ADDR="${POD_IP}:7946"
export MT_CLUSTER_MODE
export MT_PROFTRIGGER_PATH=${MT_PROFTRIGGER_PATH:-/var/metrictank/$HOSTNAME}
if ! mkdir -p $MT_PROFTRIGGER_PATH; then
	echo "failed to create dir '$MT_PROFTRIGGER_PATH'"
	exit 1
fi

# set any GO environment variables (which we allow to be passed in as MT_GO<foo>

for line in $(env | sed -n '/^MT_GO/s/MT_//p'); do
	export $line
done

# set offsets
if [ x"$MT_KAFKA_MDM_IN_OFFSET" = "xauto" ] && [ x"$MT_KAFKA_MDM_IN_ENABLED" = "xtrue" ]; then
  export MT_KAFKA_MDM_IN_OFFSET=$(/getOffset.py $MT_KAFKA_MDM_IN_TOPICS)
fi

if [ x"$MT_KAFKA_CLUSTER_OFFSET" = "xauto" ] && [ x"$MT_KAFKA_CLUSTER_ENABLED" = "xtrue" ]; then
  export MT_KAFKA_CLUSTER_OFFSET=$(/getOffset.py $MT_KAFKA_CLUSTER_TOPIC)
fi

# set cluster PEERs
if [ ! -z "$LABEL_SELECTOR" ]; then
	export MT_CLUSTER_MODE=${MT_CLUSTER_MODE:-shard}
	POD_NAMESPACE=${POD_NAMESPACE:-default}
	SERVICE_NAME=${SERVICE_NAME:-metrictank}
	if [ ! -z $KUBERNETES_SERVICE_PORT_HTTP ]; then
		PROTO="http"
		PORT=$KUBERNETES_SERVICE_PORT_HTTP
		HOST=$KUBERNETES_SERVICE_HOST
	fi
	if [ ! -z $KUBERNETES_SERVICE_PORT_HTTPS ]; then
		PROTO="https"
		PORT=$KUBERNETES_SERVICE_PORT_HTTPS
		HOST=$KUBERNETES_SERVICE_HOST
	fi

	if [ -z $HOST ]; then
		echo "ERROR: No kubernetes API host found."
		exit 1
	fi

	if [ ! -d /var/run/secrets/kubernetes.io/serviceaccount ]; then
		echo "ERROR: serviceAccount volume not mounted."
		exit 1
	fi

	echo "querying service $SERVICE_NAME for other metrictank nodes"
	CA="--cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
	AUTH="Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"

	_PODS=$(curl -s $CA -H "$AUTH" $PROTO://${HOST}:${PORT}/api/v1/namespaces/${POD_NAMESPACE}/pods?labelSelector=$LABEL_SELECTOR|jq .items[].status.podIP|sed -e "s/\"//g")
	LIST=
	for server in $_PODS; do
	 LIST="${LIST}$server,"
	done
	export MT_CLUSTER_PEERS=$(echo $LIST | sed 's/,$//')
fi

# can't use exec if we want to trap signals here
$@ &

while [ 1 ]
do
  # sleep until killed
  sleep 1
done
