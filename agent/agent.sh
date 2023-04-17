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

  if ! curl -s -f -k -m 4 -o "${TMP}" https://raw.githubusercontent.com/kroese/virtual-dsm/master/agent/agent.sh; then
    echo "$HEADER: update error: $?" && return
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
    echo "$HEADER: Update not needed."
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
checkNMI

echo "$HEADER v$VERSION"

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

elapsed=$((($(date +%s%N) - $ts)/1000000))
difference=$(( 5000 - elapsed ))
difference=$(echo | awk '{print ${difference} * 0.001}')

echo "Elapsed time: $elapsed, difference: $difference"
sleep $difference

# Display message in docker log output

echo "-------------------------------------------"
echo " You can now login to DSM at port 5000     "
echo "-------------------------------------------"

# Wait for NMI interrupt as a shutdown signal

while true; do

  checkNMI
  sleep 2

done
