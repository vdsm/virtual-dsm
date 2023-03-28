#!/bin/bash

function random() {

	printf "%06d" $(($RANDOM % 30000 + 1))
}

function randomhex() {

	val=$(($RANDOM % 255 + 1))
	echo "obase=16; $val" | bc
}

function generateRandomLetter() {

	for i in a b c d e f g h j k l m n p q r s t v w x y z; do
		echo $i
	done | sort -R | tail -1
}

function generateRandomValue() {

	for i in 0 1 2 3 4 5 6 7 8 9 a b c d e f g h j k l m n p q r s t v w x y z; do
		echo $i
	done | sort -R | tail -1
}

function toupper() {

	echo $1 | tr '[:lower:]' '[:upper:]'
}

permanent="PSN"
serialstart="1960"
serialnum="$(echo "$serialstart" | tr ' ' '\n' | sort -R | tail -1)$permanent"$(random)

echo $serialnum
