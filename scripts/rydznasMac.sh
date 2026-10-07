sudo /bin/mkdir /Volumes/rydznas
#/sbin/mount -t smbfs //root@192.168.168.2/NAS /Volumes/rydznas
sudo mount_nfs -o resvport 192.168.168.2:/mnt/md0/NAS /Volumes/rydznas
