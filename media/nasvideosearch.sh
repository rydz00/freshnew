#!/bin/bash
filter=$1
find $1 -not -path "*/.*/*" -not -name ".*" -not -name "*.db" -not -name "*.pdf" -not -name "*.rar" -not -name "*.[mM]4[vV]" -not -name "*.[mM][pP]4" -not -name "*.[sS][rR][tT]" -not -name "*.[tT][xX][tT]" -not -name "*.[jJ][pP][gG]" -not -name "*.[pP][nN][gG]" -not -type d > ~/rawvideos
