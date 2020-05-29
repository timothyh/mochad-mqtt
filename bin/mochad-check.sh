#!/bin/bash

MYDIR=$(dirname $0)
MYNAME=$(basename $0 .sh)

systemctl is-active mochad > /dev/null || exit 1

for loop in 1 2 ; do
	$MYDIR/$MYNAME.pl && exit 0

	systemctl restart mochad &

	sleep 20
done

reboot

exit 0
