#!/usr/bin/env bash
set -u

# Functions

function checkNMI {

  local nmi
  nmi=$(cat /proc/interrupts | grep NMI | sed 's/[^1-9]*//g')

  if [ "$nmi" != "" ]; then

    echo "Received shutdown request through NMI.." > /dev/ttyS0

    /usr/syno/sbin/synoshutdown -s > /dev/null
    exit

  fi

}

finish() {

  echo "Shutting down guest agent.." > /dev/ttyS0
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

      BASE=$(basename "$filename" .spk)
      BASE="${BASE%%-*}"

      echo "Installing package ${BASE}.." > /dev/ttyS0
      /usr/syno/bin/synopkg install "$filename" > /dev/null

      echo "Starting package ${BASE}.." > /dev/ttyS0
      /usr/syno/bin/synopkg start "$BASE" > /dev/null

      rm "$filename"

    fi
  done
else
  
  # TODO: Auto-update agent
  echo "Checking for updates.." > /dev/ttyS0

  sleep 5

fi

# Display message in docker log output

echo "-------------------------------------------" > /dev/ttyS0
echo " You can now login to DSM at port 5000     " > /dev/ttyS0
echo "-------------------------------------------" > /dev/ttyS0

# Wait for NMI interrupt as a shutdown signal

while true; do

  checkNMI
  sleep 2

done
