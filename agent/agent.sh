#!/usr/bin/env bash
set -u

echo "Starting agent.."
chmod 666 /dev/ttyS0
echo "Starting agent.." > /dev/ttyS0

first_run=false

for filename in /usr/local/packages/*.spk; do
  first_run=true
done

if [ "$first_run" = true ]; then

  for filename in /usr/local/packages/*.spk; do
    /usr/syno/bin/synopkg install "$filename" > /dev/null
    rm "$filename"
  done

  /usr/syno/bin/synopkg start FileStation > /dev/null
  /usr/syno/bin/synopkg start SMBService > /dev/null
  /usr/syno/bin/synopkg start SynoFinder > /dev/null
  /usr/syno/bin/synopkg start DhcpServer > /dev/null
  /usr/syno/bin/synopkg start SecureSignIn > /dev/null
  /usr/syno/bin/synopkg start Python2 > /dev/null
  /usr/syno/bin/synopkg start ScsiTarget > /dev/null
  /usr/syno/bin/synopkg start OAuthService > /dev/null

else
  sleep 5
fi

echo "" > /dev/ttyS0
echo "You can now login to DSM at http://localhost:5000/" > /dev/ttyS0
echo "" > /dev/ttyS0

while true; do

  sleep 1

  result=$(cat /proc/interrupts | grep NMI)
  result=$(echo "$result" | sed 's/[^0-9]*//g')
  result=$(echo "$result" | sed 's/^0*//')

  if [ "$result" != "" ]; then

    echo "Received shutdown request.."
    echo "Received shutdown request.." > /dev/ttyS0

    /usr/syno/sbin/synopoweroff
    exit

  fi

done
