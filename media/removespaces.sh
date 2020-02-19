dir=$1
find $1 -depth -name "* *" -execdir rename " " "_" "{}" ";"
find $1 -depth -name "* *"
