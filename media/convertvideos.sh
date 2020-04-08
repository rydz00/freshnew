#!/bin/bash
echo "starting video conversion. logs are in home dir"
echo `wc -l ~/testvideo` items

for i in `cat ~/testvideo`; do

/opt/handbrake/HandBrakeCLI -i "$i" -o "$i".mp4 --preset="Android Tablet"

done
