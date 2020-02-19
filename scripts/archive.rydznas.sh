#!/bin/bash

DATE=`date '+%Y%m%d'`

BASEDIR="/home/robryd/rydznas/"
PICSBASEDIR="/home/robryd/rydznas/Pics/"

#use WHITELIST
#WHITELIST="Drive"
#WHITELIST="Music"
WHITELIST="organized"
#WHITELIST="Apps"
#WHITELIST="DVD_Rips"

BACKUPDIR="/home/robryd/stuff"

#use this for Pics backup
#ls $PICSBASEDIR > /tmp/all.txt
#cd $PICSBASEDIR

#use this for WHITELIST
cd $BASEDIR

#for i in `cat /tmp/all.txt`;
for i in $WHITELIST;
#normal usage for 1 tar
#   do tar -zcvf $BACKUPDIR/rydznas.$i.$DATE.tgz $i > $BACKUPDIR/rydznas.$i.backup.log ; done
#split an archive as you create it
   do tar -zcvf - $i | split --bytes=5GB - $BACKUPDIR/rydznas.$i.$DATE.tgz. > $BACKUPDIR/rydznas.$i.backup.log ; done

# upload a file
# glacier-cmd upload --name "rydznas.Drive.20170130.tgz.aa" --description "Drive backup aa 20170130" rydznas.drive rydznas.Drive.20170130.tgz.aa
# glacier-cmd listmultiparts rydznas.drive
# glacier-cmd upload --resume --uploadid "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX" --name "rydznas.Drive.20180313.tgz.aa" --description "Drive backup aa 20180313" rydznas.drive rydznas.Drive.20180313.tgz.aa --partsize 1

