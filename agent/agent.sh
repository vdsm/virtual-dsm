#!/usr/bin/env bash
set -u

echo "Starting agent.."
chmod 666 /dev/ttyS0

first_run=false

for filename in /usr/local/packages/*.spk; do
  if [ -f "$filename" ]; then
    first_run=true
  fi
done

if [ "$first_run" = true ]; then
  for filename in /usr/local/packages/*.spk; do
    if [ -f "$filename" ]; then

      /usr/syno/bin/synopkg install "$filename" > /dev/null

      BASE=$(basename "$filename" .spk)
      BASE=$(echo "${BASE%%-*}")

      /usr/syno/bin/synopkg start "$BASE" > /dev/null

      rm "$filename"

    fi
  done
else

  sleep 4

fi

echo "" > /dev/ttyS0
echo "You can now login to DSM at http://localhost:5000/" > /dev/ttyS0
echo "" > /dev/ttyS0

while true; do

  sleep 1

  #result=$(cat /proc/interrupts | grep NMI)
  #result=$(echo "$result" | sed 's/[^0-9]*//g')
  #result=$(echo "$result" | sed 's/^0*//')
  #
  #if [ "$result" != "" ]; then
  #
  #  echo "Received shutdown request.."
  #  echo "Received shutdown request.." > /dev/ttyS0
  #
  #  /usr/syno/sbin/synopoweroff
  #  exit
  #
  #fi

done
