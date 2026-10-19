#!/bin/zsh
# take.sh shoot, again until one take is clean: a spoiled or refused take (the Mac touched or busy, another window over
# the rect) is retried every 60 s, for up to 40 min.
#   takes.sh <ko|en> <first take number>     prints the clean take's number last
HERE=$(cd "$(dirname "$0")" && pwd)
L=$1; N=$2; END=$(( $(date +%s) + 2400 ))
while [ $(date +%s) -lt $END ]; do
    "$HERE/take.sh" shoot $L $N; RC=$?
    [ $RC = 0 ] && { echo "clean take $L-$N"; exit 0; }
    [ $RC = 1 ] && { echo "take.sh failed"; exit 1; }
    N=$(( N + 1 )); sleep 60
done
echo "no clean take in 40 min"; exit 6
