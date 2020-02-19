#!/bin/bash

sudo mkdir /mnt/rydznas

#samba mount
#sudo smbmount //wwp-ldnrr01/Share /mnt/rydznas -o user=,domain=

#CIFS mount
#sudo mount -t cifs //wwp-ldnrr01/Share /mnt/rydznas -o user=,domain=
#sudo mount -t cifs '\\5.5.5.2\NAS' /mnt/rydznas -o username=,password=,rw,iocharset=utf8,uid=500,gid=50

#nfs mount
sudo mount.nfs 5.5.5.2:/mnt/md1/NAS /mnt/rydznas
