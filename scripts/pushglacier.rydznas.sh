#!/bin/bash

BASEDIR="/home/robryd/rydznas/"

BACKUPDIR="/home/robryd/stuff"

#VAULT=rydznas.drive
#VAULT=rydznas.apps
#VAULT=rydznas.pics
#VAULT=rydznas.music
VAULT=rydznas.organized

#use this for Pics backup
cd $BACKUPDIR
:> /tmp/all.txt
ls $BACKUPDIR > /tmp/all.txt

for i in `cat /tmp/all.txt`;
#normal usage for 1 tar
   do glacier-cmd upload --name "$i" --description "$i" $VAULT $i ; done

# upload a file
# glacier-cmd upload --name "rydznas.Drive.20170130.tgz.aa" --description "Drive backup aa 20170130" rydznas.drive rydznas.Drive.20170130.tgz.aa
# glacier-cmd listmultiparts rydznas.drive
# glacier-cmd upload --resume --uploadid "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX" --name "rydznas.Drive.20180313.tgz.aa" --description "Drive backup aa 20180313" rydznas.drive rydznas.Drive.20180313.tgz.aa --partsize 1

