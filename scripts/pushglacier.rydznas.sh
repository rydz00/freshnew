#!/bin/bash

BASEDIR="/home/robryd/rydznas/"

BACKUPDIR="/home/robryd/stuff"

echo "which vault do you want to upload to?"
echo "drive, apps, pics, music, organized"

read subvault

VAULT=rydznas.$subvault

#make a list of what to push up
cd $BACKUPDIR

for i in *;
#normal usage for 1 tar
   do glacier-cmd upload --name "$i" --description "$i" $VAULT $i ; done
 

# upload a file
# glacier-cmd upload --name "rydznas.Drive.20170130.tgz.aa" --description "Drive backup aa 20170130" rydznas.drive rydznas.Drive.20170130.tgz.aa
# glacier-cmd listmultiparts rydznas.drive
# glacier-cmd upload --resume --uploadid "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX" --name "rydznas.Drive.20180313.tgz.aa" --description "Drive backup aa 20180313" rydznas.drive rydznas.Drive.20180313.tgz.aa --partsize 1

