#!/bin/bash
for f in *.HEIC
do
echo "Working on file $f"
heif-convert $f $f.jpg
done

# preserve timestamps
for j in *.HEIC.jpg
do
echo "Working on timestamp for $j"
exiv2 -T rename $j
done
