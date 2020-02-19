#!/bin/sh
echo "local copy"
ls -l ~/Music/iTunes/iTunes*Library*
echo "rydznas copy"
ls -l /Volumes/rydznas/Music/MasterLibraryFiles/

echo "enter 1 to copy FROM PC to NAS"
echo "enter 2 to copy FROM NAS to PC"
echo "enter q to quit"
echo "which do you choose? DON'T FORGET to press q to quit when complete"
while read i; do
	case "$i" in
		1) sudo cp -v ~/Music/iTunes/*Library* /Volumes/rydznas/Music/MasterLibraryFiles/ 
                   exit 0;;
		2) sudo cp -v /Volumes/rydznas/Music/MasterLibraryFiles/* ~/Music/iTunes/ 
                   exit 0 ;;
		q) exit 0 ;;
		*) printf "try again, invalid choice\nPlease choose again: " ;;
	esac
        done
