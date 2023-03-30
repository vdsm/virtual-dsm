#!/bin/bash

permanent="DSM"
serialstart="2000"
serialnum="$(echo "$serialstart" | tr ' ' '\n' | sort -R | tail -1)"$permanent""$(printf "%06d" $((RANDOM % 30000 + 1)))

echo $serialnum
