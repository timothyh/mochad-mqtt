#!/usr/bin/perl -w
#
# Simple script to check that Mochad/CM15A is functioning correctly
#
# No external configuration parameters but they can be tweaked below

use strict;
use Net::Telnet;

my $host = 'localhost';
my $port = 1099;
my $house = "P";
my $unit = 16;
my $cmd = 'off';

my $t = new Net::Telnet Timeout => 2,
	Output_record_separator => "\r",
	Input_record_separator => "\n",
	Host => $host,
        port => $port;

$t->open();

$t->print("pl $house$unit $cmd");
my $match = 0;
while ( my $line = $t->getline() ) {
	$match++ if ( $line =~ qr/HouseUnit: $house$unit/i );
	$match++ if ( $line =~ qr/House: $house Func: $cmd/i );

	exit(0) if ( $match >= 2 );
}

exit 1;

1;
