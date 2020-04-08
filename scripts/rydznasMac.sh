sudo /bin/mkdir /Volumes/rydznas
#/sbin/mount -t smbfs //root@5.5.5.2/NAS /Volumes/rydznas
sudo mount_nfs -o resvport 5.5.5.2:/mnt/md0/NAS /Volumes/rydznas
