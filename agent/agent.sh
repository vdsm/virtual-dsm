#!/usr/bin/env bash
set -u

declare nmi

function checkNMI {

  nmi=$(cat /proc/interrupts | grep NMI)
  nmi=$(echo "$nmi" | sed 's/[^0-9]*//g')
  nmi=$(echo "$nmi" | sed 's/^0*//')

  if [ "$nmi" != "" ]; then

    echo "Received shutdown request through NMI.." > /dev/ttyS0

    /usr/syno/sbin/synoshutdown -s > /dev/null
    exit 0

  fi

}

chmod 666 /dev/ttyS0
checkNMI

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
      BASE="${BASE%%-*}"

      /usr/syno/bin/synopkg start "$BASE" > /dev/null

      rm "$filename"

    fi
  done
else

  sleep 5

fi

echo "-------------------------------------------" > /dev/ttyS0
echo " You can now login to DSM at port 5000     " > /dev/ttyS0
echo "-------------------------------------------" > /dev/ttyS0

while true; do

  checkNMI
  sleep 2

done

