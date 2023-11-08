#!/usr/bin/env bash
set -Eeuo pipefail

info () { echo -e "\E[1;34m❯\E[1;36m $1\E[0m" ; }
error () { echo -e >&2 "\E[1;31m❯ ERROR: $1\E[0m" ; }

retry=true

while [ "$retry" = true ]
do

  sleep 2
  
  # Retrieve IP from guest VM
  RESPONSE=$(curl -s -m 16 -S http://127.0.0.1:2210/read?command=10 2>&1)

  if [[ ! "${RESPONSE}" =~ "\"success\"" ]] ; then
    error "Failed to connect to guest: $RESPONSE" && continue
  fi

  # Retrieve the HTTP port number
  if [[ ! "${RESPONSE}" =~ "\"http_port\"" ]] ; then
    error "Failed to parse response from guest: $RESPONSE" && continue
  fi

  rest=${RESPONSE#*http_port}
  rest=${rest#*:}
  rest=${rest%%,*}
  PORT=${rest%%\"*}

  [ -z "${PORT}" ] && continue

  # Retrieve the IP address
  if [[ ! "${RESPONSE}" =~ "eth0" ]] ; then
    error "Failed to parse response from guest: $RESPONSE" && continue
  fi

  rest=${RESPONSE#*eth0}
  rest=${rest#*ip}
  rest=${rest#*:}
  rest=${rest#*\"}
  IP=${rest%%\"*}

  [ -z "${IP}" ] && continue

  retry=false

done

if [[ "$IP" == "20.20"* ]]; then
  MSG="port ${PORT}"
else
  MSG="http://${IP}:${PORT}"
fi

echo ""
info "--------------------------------------------------------"
info " You can now login to DSM at ${MSG}"
info "--------------------------------------------------------"
echo ""
