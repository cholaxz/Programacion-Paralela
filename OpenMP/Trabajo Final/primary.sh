#!/bin/bash

#Scripts
#secondary
#secscript
script="secondary.sh"
filename="paralelo"

arg1=(10 100)
arg2=(128 256)


for i in ${arg1[@]}; do
	for j in ${arg2[@]}; do
		./$script $filename $i $j
	done
done