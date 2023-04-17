#!/usr/bin/env bash
set -u

# Functions

function checkNMI {

  local nmi
  nmi=$(cat /proc/interrupts | grep NMI | sed 's/[^1-9]*//g')

  if [ "$nmi" != "" ]; then

    echo "Received shutdown request through NMI.."

    /usr/syno/sbin/synoshutdown -s > /dev/null
    exit

  fi

}

finish() {

  echo "Shutting down guest agent.."
  exit

}

trap finish SIGINT SIGTERM

ts=$(date +%s%N)
checkNMI

# Install packages 

first_run=false

for filename in /usr/local/packages/*.spk; do
  if [ -f "$filename" ]; then
    first_run=true
  fi
done

if [ "$first_run" = true ]; then
  for filename in /usr/local/packages/*.spk; do
    if [ -f "$filename" ]; then

      BASE=$(basename "$filename" .spk)
      BASE="${BASE%%-*}"

      echo "Installing package ${BASE}.."
      /usr/syno/bin/synopkg install "$filename" > /dev/null

      #echo "Activating package ${BASE}.."
      /usr/syno/bin/synopkg start "$BASE" &

      rm "$filename"

    fi
  done
else

  TMP="/tmp/agent.sh"
  rm -f "${TMP}"

  # Auto update the agent

  if curl -s -f -k -m 5 -o "${TMP}" https://raw.githubusercontent.com/kroese/virtual-dsm/master/agent/agent.sh; then
    if [ -f "${TMP}" ]; then
      line=$(head -1 "${TMP}")
      if [ "$line" == "#!/usr/bin/env bash" ]; then
         SCRIPT=$(readlink -f ${BASH_SOURCE[0]})
         mv -f "${TMP}" "${SCRIPT}"
         chmod +x "${SCRIPT}"
      else
         echo "Update error, invalid header: $line"
      fi
    else
      echo "Update error, file not found.."
    fi
  else
    echo "Update error, curl error: $?"
  fi

fi

elapsed=$((($(date +%s%N) - $ts)/1000000))
echo "Elapsed time: $elapsed"
    
# Display message in docker log output

echo "-------------------------------------------"
echo " You can now login to DSM at port 5000     "
echo "-------------------------------------------"

# Wait for NMI interrupt as a shutdown signal

while true; do

  checkNMI
  sleep 2

done
