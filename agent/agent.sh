#!/usr/bin/env bash
set -u

# Functions

function checkNMI {

  local nmi
  nmi=$(awk '/NMI/ {for (i=2; i<=NF; i++) if ($i ~ /^[0-9]+$/) {sum+=$i}} END {print sum}' /proc/interrupts)

  if [ "$nmi" != "" ] && [ "$nmi" -ne "0" ]; then

    echo "Received shutdown request through NMI.." > /dev/ttyS0

    /usr/syno/sbin/synoshutdown -s > /dev/null
    exit

  fi

}

finish() {

  echo "Shutting down Guest Agent.." > /dev/ttyS0
  exit

}

trap finish SIGINT SIGTERM

# Setup serialport

chmod 666 /dev/ttyS0
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

      /usr/syno/bin/synopkg install "$filename" > /dev/ttyS0

      BASE=$(basename "$filename" .spk)
      BASE="${BASE%%-*}"

      /usr/syno/bin/synopkg start "$BASE" > /dev/ttyS0

      rm "$filename"

    fi
  done
else

  sleep 5

fi

# Display message in docker log output

echo "-------------------------------------------" > /dev/ttyS0
echo " You can now login to DSM at port 5000     " > /dev/ttyS0
echo "-------------------------------------------" > /dev/ttyS0

# TODO: Auto-update agent

# Wait for NMI interrupt as a shutdown signal

while true; do

  checkNMI
  sleep 2

done
