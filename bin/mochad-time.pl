#!/usr/bin/perl -w
#
# Simple script to get/set time with Mochad connected to a X10 CM15A 
#
# Usage: mochad-time.pl [--set [to_datetime]]
#     to_datetime can be expressed in any form acceptable to the date command
#     --date option - defaults to "now".
#
# The get time function requires that the mochad --raw-data option is set.
#
# No external configuration parameters but they can be tweaked below
# sendbuff[size++]= 0x9b;            //function code
#    sendbuff[size++]= tm->tm_sec;        //seconds
#    sendbuff[size++]= tm->tm_min + 60 * (tm->tm_hour & 1);        //0-199
#    sendbuff[size++]= tm->tm_hour >> 1;        //0-11 (hours/2)
#    sendbuff[size++]= tm->tm_yday;        //really 9 bits
#    sendbuff[size]= 1 << tm->tm_wday;        //daymask (7 bits)
#    if(tm->tm_yday & 0x100)             //
#      sendbuff[size] |= 0x80;
#    size++;
#    sendbuff[size++]= 0x60;            // house (0:timer purge, 1:monitor clear, 3:battery clear
#    sendbuff[size++]= 0x00;            // Filler (???)

use strict;
use Net::Telnet;
use Data::Dumper;

my $host = 'localhost';
my $port = 1099;

my $line;
my $settime = 0;
my $setto   = undef;

my $fmt = "+%S %M %H %w %j %s";

my $startofyear;

# Start of year local time - Epoch
{
    my $cmd = "date --date='01/01' '+%s'";
    ($startofyear) = split( ' ', qx/$cmd/ );
}

if ( defined $ARGV[0] ) {
    if ( $ARGV[0] eq '-s' || $ARGV[0] eq '--set' ) {
        $settime = 1;
        $setto   = $ARGV[1];
    }
}

my $t = new Net::Telnet
  Timeout                 => 2,
  Output_record_separator => "\r",
  Input_record_separator  => "\n",
  Host                    => $host,
  port                    => $port;

$t->open();

if ($settime) {

    my $cmd = "date "
      . ( defined($setto) ? "--date='" . $setto . "'" : "" )
      . " '$fmt'";

    my ( $sec, $min, $hour, $wday, $yday, $epoch ) = split( ' ', qx/$cmd/ );

    die "Date incorrectly formatted or out of range: $setto"
      unless ( defined($epoch)
        && $epoch > ( $startofyear - 31536000 )
        && $epoch < ( $startofyear + 31536000 ) );

    my @bytes;

    $bytes[0] = $sec;
    $bytes[1] = $min + ( 60 * ( $hour % 2 ) );
    $bytes[2] = int( $hour / 2 );
    $bytes[3] = $yday & 0xff;
    $bytes[4] = 1 << $wday;
    $bytes[4] |= 0x80 if ( $yday & 0x100 );

    $line = sprintf "%02X %02X %02X %02X %02X", @bytes;

    $t->print("pt 9B $line 60 00 ");
    print "CM15 Clock set\n";
    sleep(5);
}

$t->print("pt 8b");

while ( $line = $t->getline() ) {
    last if ( $line =~ s/^.*Raw data received:// );
}
$t->close();

my @bytes = split( ' ', $line );

my $battery = 0x7fff & hex $bytes[0] . $bytes[1];
my $secs    = hex $bytes[2];
my $mins    = hex $bytes[3];
my $hours   = 2 * hex( $bytes[4] ) + int( $mins / 60 );
$mins = $mins % 60;

my $yday = hex $bytes[5];
$yday = $yday + 0x100 if ( hex( $bytes[6] ) & 0x80 );

my $dow = hex( $bytes[6] ) & 0x7f;
for my $i ( 0 .. 6 ) {
    $dow = $i if ( $dow == ( 1 << $i ) );
}
my $cm15date = $startofyear + 7200 + ( ( $yday - 1 ) * ( 24 * 3600 ) );

my $cmd     = "date --date='@" . ${cm15date} . "' '+%Y-%m-%d'";
my $datestr = qx/$cmd/;
chomp $datestr;

printf "CM15 time: %s %02d:%02d:%02d DoW: %d battery: %d\n", $datestr, $hours,
  $mins, $secs, $dow, $battery;

exit 0;
