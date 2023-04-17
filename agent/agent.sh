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
    exit

  fi
}

function downloadUpdate {

  TMP="/tmp/agent.sh"
  rm -f "${TMP}"

  URL="https://raw.githubusercontent.com/kroese/virtual-dsm/master/agent/agent.sh"

  # Auto update the agent

  remote_size=$(curl -s -I -k -m 3 "${URL}" | awk '/Content-Length/ {sub("\r",""); print $2}')
  
  echo "remote size: $remote_size"
  [ "$remote_size" == "0" ] && return

  if ! curl -s -f -k -m 10 -o "${TMP}" "${URL}"; then
    echo "$HEADER: curl error" && return
  fi

  if ! curl -s -f -k -m 3 -o "${TMP}" https://raw.githubusercontent.com/kroese/virtual-dsm/master/agent/agent.sh; then
    #echo "$HEADER: curl error" && return
    return
  fi

  if [ ! -f "${TMP}" ]; then
    echo "$HEADER: update error, file not found.." && return
  fi

  line=$(head -1 "${TMP}")

  if [ "$line" != "#!/usr/bin/env bash" ]; then
    echo "$HEADER: update error, invalid header: $line" && return
  fi
  
  SCRIPT=$(readlink -f ${BASH_SOURCE[0]})

  if ! cmp --silent -- "${TMP}" "${SCRIPT}"; then

    mv -f "${TMP}" "${SCRIPT}"
    chmod +x "${SCRIPT}"

    echo "$HEADER: succesfully installed update."

  else
    echo "$HEADER: update not needed."
  fi
  
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
difference=0
elapsed=$((($(date +%s%N) - $ts)/1000000))

if (( delay > elapsed )); then
  difference=$((delay-elapsed))
  float=$(echo | awk -v diff=\""$difference"\" '{print diff * 0.001}')
  echo "Elapsed time: $elapsed, sleep: $float"
  sleep $difference
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
