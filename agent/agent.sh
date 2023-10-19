#!/usr/bin/env bash
set -u

VERSION="8"
HEADER="VirtualDSM Agent"

# Functions

error () { echo -e "\E[1;31m❯ ERROR: $1\E[0m" ; }
info () { echo -e "\E[1;34m❯\E[1;36m $1\E[0m" ; }

finish() {

  echo "❯ $HEADER: Shutting down.."
  exit

}

function checkNMI {

  local nmi
  nmi=$(cat /proc/interrupts | grep NMI | sed 's/[^1-9]*//g')

  if [ "$nmi" != "" ]; then

    info "Received shutdown request through NMI.."

    /usr/syno/sbin/synoshutdown -s > /dev/null
    finish

  fi
}

function downloadUpdate {

  TMP="/tmp/agent.sh"
  rm -f "${TMP}"

  # Auto update the agent

  URL="https://raw.githubusercontent.com/vdsm/virtual-dsm/master/agent/agent.sh"
  
  remote_size=$(curl -sIk -m 4 "${URL}" | grep -i "content-length:" | tr -d " \t" | cut -d ':' -f 2)
  remote_size=${remote_size//$'\r'}

  [[ "$remote_size" == "" || "$remote_size" == "0" ]] && return

  SCRIPT=$(readlink -f "${BASH_SOURCE[0]}")
  local_size=$(stat -c%s "$SCRIPT")

  [[ remote_size -eq local_size ]] && return

  if ! curl -sfk -m 10 -o "${TMP}" "${URL}"; then
    error "$HEADER: curl error ($?)" && return
  fi

  if [ ! -f "${TMP}" ]; then
    error "$HEADER: update error, file not found.." && return
  fi

  line=$(head -1 "${TMP}")

  if [[ "$line" != "#!/usr/bin/env bash" ]]; then
    error "$HEADER: update error, invalid header: $line" && return
  fi

  if cmp --silent -- "${TMP}" "${SCRIPT}"; then
    error "$HEADER: update file is already equal? (${local_size} / ${remote_size})" && return
  fi

  mv -f "${TMP}" "${SCRIPT}"
  chmod 755 "${SCRIPT}"

  info "$HEADER: succesfully installed update..."

}

function installPackages {

  for filename in /usr/local/packages/*.spk; do
    if [ -f "$filename" ]; then

      BASE=$(basename "$filename" .spk)
      BASE="${BASE%%-*}"

      [[ $BASE == "ActiveInsight" ]] && continue

      info "Installing package ${BASE}.."

      /usr/syno/bin/synopkg install "$filename" > /dev/null
      /usr/syno/bin/synopkg start "$BASE" > /dev/null &

      rm "$filename"

    fi
  done

}

trap finish SIGINT SIGTERM

ts=$(date +%s%N)

echo ""
echo "❯ Started $HEADER v$VERSION..."

checkNMI

# Install packages 

first_run=false

for filename in /usr/local/packages/*.spk; do
  if [ -f "$filename" ]; then
    first_run=true
  fi
done

if [ "$first_run" = true ]; then

  installPackages

else

  downloadUpdate

fi

delay=500
elapsed=$((($(date +%s%N) - ts)/1000000))

if [[ delay -gt elapsed ]]; then
  difference=$((delay-elapsed))
  float=$(echo | awk -v diff="${difference}" '{print diff * 0.001}')
  sleep "$float"
fi

# Display message in docker log output

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

# Wait for NMI interrupt as a shutdown signal

while true; do

  checkNMI
  sleep 2 & wait $!

done
