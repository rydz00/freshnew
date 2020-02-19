echo "Tell me the Directory to Create(ex. \Volumes\<newname>; just enter name and I will do the rest"
read a
/bin/mkdir /Volumes/$a
echo "Now tell me the path to map to(ex. nas3/users use the slashes as shown)"
read b
echo "what is your AD mapping name? do not use US in front of it"
read user
/sbin/mount -t smbfs //$user@$b /Volumes/$a
