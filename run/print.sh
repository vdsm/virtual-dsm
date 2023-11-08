#!/usr/bin/env bash
set -Eeuo pipefail

info () { echo -e "\E[1;34m❯\E[1;36m $1\E[0m" ; }

sleep 1

IP=$(ip address show dev eth0 | grep inet | awk '/inet / { print $2 }' | cut -f1 -d/)

if [[ "$IP" == "20.20"* ]]; then
  MSG="port 5000"
else
  MSG="http://${IP}:5000"
fi

echo ""
info "--------------------------------------------------------"
info " You can now login to DSM at ${MSG}"
info "--------------------------------------------------------"
echo ""
