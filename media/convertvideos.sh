#!/bin/bash
echo "starting video conversion. logs are in home dir"
echo `wc -l ~/testvideo` items

for i in `cat ~/testvideo`; do

/opt/handbrake/HandBrakeCLI -i "$i" -o "$i".roku.mp4 --preset="Roku 1080p30 Surround"

echo "Your video conversion is complete"

done
