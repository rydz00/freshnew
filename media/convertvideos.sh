#!/bin/bash
echo "starting video conversion. logs are in home dir"
echo `wc -l /home/robryd/testvideo` items

for i in `cat /home/robryd/testvideo`; do

/opt/handbrake/HandBrakeCLI -i "$i" -o "$i".mp4 --preset="Android Tablet"

done
