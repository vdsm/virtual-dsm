#!/usr/bin/env bash
set -u

VERSION="4"
HEADER="VirtualDSM Agent"

# Functions

finish() {

  echo "$HEADER: Shutting down.."
  exit

}

function checkNMI {

  local nmi
  nmi=$(cat /proc/interrupts | grep NMI | sed 's/[^1-9]*//g')

  if [ "$nmi" != "" ]; then

    echo "$HEADER: Received shutdown request through NMI.."

    /usr/syno/sbin/synoshutdown -s > /dev/null
    finish

  fi
}

function downloadUpdate {

  TMP="/tmp/agent.sh"
  rm -f "${TMP}"

  # Auto update the agent

  URL="https://raw.githubusercontent.com/kroese/virtual-dsm/master/agent/agent.sh"
  remote_size=$(curl -sIk -m 4 "${URL}" | grep -i "content-length:" | tr -d " \t" | cut -d ':' -f 2)

  [ remote_size -eq 0 ] && return
  [ "$remote_size" == "" ] && return

  SCRIPT=$(readlink -f ${BASH_SOURCE[0]})
  local_size=$(stat -c%s "$SCRIPT")

  [ remote_size -eq local_size ] && return

  if ! curl -sfk -m 10 -o "${TMP}" "${URL}"; then
    echo "$HEADER: curl error" && return
  fi

  if [ ! -f "${TMP}" ]; then
    echo "$HEADER: update error, file not found.." && return
  fi

  line=$(head -1 "${TMP}")

  if [[ "$line" != "#!/usr/bin/env bash" ]]; then
    echo "$HEADER: update error, invalid header: $line" && return
  fi

  if cmp --silent -- "${TMP}" "${SCRIPT}"; then
    echo "$HEADER: update file is already equal? (${local_size} / ${remote_size})" && return
  fi

  mv -f "${TMP}" "${SCRIPT}"
  chmod +x "${SCRIPT}"

  echo "$HEADER: succesfully installed update, please reboot."

}

function installPackages {

  for filename in /usr/local/packages/*.spk; do
    if [ -f "$filename" ]; then

      BASE=$(basename "$filename" .spk)
      BASE="${BASE%%-*}"

      echo "$HEADER: Installing package ${BASE}.."

      /usr/syno/bin/synopkg install "$filename" > /dev/null
      /usr/syno/bin/synopkg start "$BASE" > /dev/null &

      rm "$filename"

    fi
  done

}

trap finish SIGINT SIGTERM

ts=$(date +%s%N)
echo "$HEADER v$VERSION"

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

delay=5000
elapsed=$((($(date +%s%N) - ts)/1000000))

if (( delay > elapsed )); then
  difference=$((delay-elapsed))
  float=$(echo | awk -v diff="${difference}" '{print diff * 0.001}')
  sleep "$float"
fi

# Display message in docker log output

echo "-------------------------------------------"
echo " You can now login to DSM at port 5000     "
echo "-------------------------------------------"

# Wait for NMI interrupt as a shutdown signal

while true; do

  checkNMI
  sleep 2

done
