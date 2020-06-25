#!/usr/bin/perl -w

# Drived from https://github.com/kevineye/docker-heyu-mqtt
#
# For Mochad commands see
# https://bfocht.github.io/mochad/mochad_reference.html
#
use strict;

use Data::Dumper;
use Time::HiRes qw(usleep sleep);
use POSIX qw(strftime);
use File::stat;

use File::Basename;

use AnyEvent;
use AnyEvent::MQTT;
use AnyEvent::Socket;
use AnyEvent::Strict;

use JSON::PP;

my $mm_config = $ENV{MM_CONFIG} || '/etc/mochad-mqtt.json';

my @fromenv =
  qw(MQTT_HOST MQTT_PORT MQTT_USER MQTT_PASSWORD MQTT_PREFIX MOCHAD_HOST MOCHAD_PORT MM_TOTAL_INSTANCES MM_INSTANCE MM_DELAY);

my %config = (
    mqtt_host   => 'localhost',
    mqtt_port   => '1883',
    mqtt_prefix => 'home/x10',
    mqtt_ping   => 'ping/home/x10/_ping',
    mqtt_idle   => 300.0,
    mochad_host => 'localhost',
    mochad_port => '1100',
    mochad_idle => 300.0,
    passthru    => 0,                       # Publish all input from Mochad
    passthru_send      => 1,     # Allow commands to pass directly to Mochad
    mm_total_instances => 2,
    mm_instance        => 1,     # Instance number - offset 1
    mm_delay           => 0.2,
);

my @boolopts = qw( passthru passthru_send);

# Mapping of input commands to Mochad usage
my %cmds = (
    on        => 'on',
    off       => 'off',
    unitson   => 'all_units_on',
    unitsoff  => 'all_units_off',
    allon     => 'all_units_on',
    alloff    => 'all_units_off',
    lightson  => 'all_lights_on',
    lightsoff => 'all_lights_off',
);

# 1 => appliance, 2 => light
#
# Device types 1 == appliance, 2 == light
my %types = ( stdam => 1, stdlm => 2, appliance => 1, light => 2 );

# List of all lights
my %lights;

# List of all appliances, includes lights
my %appls;

# List of devices to ignore
my %ignore;

# house codes => alias
my %codes;

my %retain;

# device names from mochad-mqtt.json => topics from mqtt
my %alias;

my $mqtt_updated;
my $mochad_updated;
my $config_updated;
my $config_mtime;

my $handle;

sub read_config {

    return undef unless ( open CONFIG, "<" . $mm_config );
    my $conf_text = join( '', <CONFIG> );
    close CONFIG;
    my $conf = JSON::PP->new->decode($conf_text);

    %alias  = ();
    %appls  = ();
    %codes  = ();
    %lights = ();
    %retain = ();

    for my $sect ( 'mm', 'mochad', 'mqtt' ) {
        next unless ( exists $conf->{$sect} );
        my %tmp = %{ $conf->{$sect} };
        foreach my $key ( keys %tmp ) {
            $config{"${sect}_${key}"} = $tmp{$key};
        }
        delete $conf->{$sect};
    }

    for my $code ( @{ $conf->{'ignore'} } ) {
        unless ( $code =~ m{([A-Za-z])([\d,-]+)} ) {
            AE::log error => "Bad device definition: $code";
            next;
        }
        my $house = uc $1;
        my @codes = str_range($2);

        foreach my $i ( 0 .. scalar @codes ) {
            next unless ( $codes[$i] );

            $ignore{"$house$i"} = 1;
        }
    }
    delete $conf->{'ignore'};
    for my $alias ( keys %{ $conf->{'devices'} } ) {
        my %tmp = %{ $conf->{devices}{$alias} };

        my $code    = defined $tmp{'code'} ? uc $tmp{'code'} : $alias;
        my $aliased = ( lc $alias ne lc $code );
        my $type    = defined $tmp{'type'} ? lc $tmp{'type'} : '';
        my $retain  = is_true( $tmp{'retain'} );

        unless ( $code =~ m{([A-Za-z])([\d,-]+)} ) {
            AE::log error => "Bad device definition: $code => "
              . Dumper( \%tmp );
            next;
        }
        my $house = uc $1;
        my @codes = str_range($2);

        if ($aliased) {
            $alias = lc $alias;
            $alias =~ s/[^0-9a-z]+/-/g;
            $alias{$alias} = () unless defined $alias{$alias};

            $retain{$alias} = 1 if ($retain);
        }

        foreach my $i ( 0 .. scalar @codes ) {
            next unless ( $codes[$i] );

            if ($aliased) {
                $codes{ $house . $i } = $alias;
                push( @{ $alias{$alias} }, $house . $i );
            }
            else {
                $retain{"$house$i"} = 1 if ($retain);
            }

            next unless ( defined $types{$type} );

            $lights{$house}{$i} = 1 if ( $types{$type} == 2 );
            $appls{$house}{$i}  = 1 if ( $types{$type} >= 1 );
        }
    }
    delete $conf->{'devices'};

    for my $attr ( keys %{$conf} ) {
        $config{$attr} = $conf->{$attr};
    }

############################################################################
    #print "alias: ".Dumper(\%alias);
    #print "codes: ".Dumper(\%codes);
    #print "ignore: ".Dumper(\%ignore);
    #print "retain: ".Dumper(\%retain);
    #print "appliances: ".Dumper(\%appls);
    #print "lights: " .Dumper(\%lights);
    #print "config: " .Dumper(\%config);
    #
    #exit 0;
############################################################################

    $config_mtime   = stat($mm_config)->mtime;
    $config_updated = Time::HiRes::time;

    # Environment overrides config file
    foreach (@fromenv) {
        $config{ lc $_ } = $ENV{ uc $_ } || $config{ lc $_ };
    }

    # Standardize boolean options
    foreach (@boolopts) {
        $config{$_} = is_true( $config{$_} );
    }
}

sub changed_config {
    if ( stat($mm_config)->mtime > $config_mtime ) {
        AE::log alert => "Config file $mm_config changed";
        return 1;
    }
    return 0;
}

sub is_true {
    my ( $input, @special ) = @_;

    return 0 unless ( defined $input );

    if ( $input =~ /^\d+$/ ) {
        return 0 if ( $input == 0 );
        return 1;
    }

    $input = lc $input;

    for my $v ( 'true', 'on', @special ) {
        return 1 if ( $input eq $v );
    }

    for my $v ( 'false', 'off', @special ) {
        return 0 if ( $input eq $v );
    }

    AE::log error => "Invalid boolean: " . $input;

    return 0;
}

sub str_range {
    my ($str) = @_;

    my @arr;

    foreach ( split /,/, $str ) {
        if (/(\d+)-(\d+)/) {
            foreach ( $1 .. $2 ) { $arr[$_] = 1; }
        }
        elsif (/\d+/) { $arr[$_] = 1; }
    }
    return @arr;
}

read_config();

my $mqtt = AnyEvent::MQTT->new(
    host             => $config{mqtt_host},
    port             => $config{mqtt_port},
    user_name        => $config{mqtt_user},
    password         => $config{mqtt_password},
    on_error         => \&mqtt_error_cb,
    keep_alive_timer => 60,
);

sub mqtt_error_cb {
    my ( $fatal, $message ) = @_;
    AE::log error => $message;
    if ($fatal) {
        AE::log error => "Fatal error - exiting";
        exit(1);
    }
}

my @delay_timer;

sub delay_write {
    my ( $handle, $message ) = @_;
    my $delay = 0.0;

    if ( defined( $config{mm_delay} ) && $config{mm_delay} > 0 ) {
        my $sum = $config{mm_instance} - 1;
        foreach my $ascval ( unpack( "C*", $message ) ) {
            $sum += $ascval;
        }

        $delay = $config{mm_delay} * ( $sum % $config{mm_total_instances} );

        AE::log debug =>
          "Instance => $config{mm_instance} Sum => $sum Delay => $delay";
    }

    if ( $delay > 0.0 ) {
        my $timer_offset = scalar @delay_timer;
        $delay_timer[$timer_offset] = AnyEvent->timer(
            after => $delay,
            cb    => sub {
                $handle->push_write($message);
                delete $delay_timer[$timer_offset];
            }
        );
    }
    else {
        $handle->push_write($message);
    }
}

sub receive_passthru_send {
    my ( $topic, $message ) = @_;

    $mqtt_updated = AnyEvent->now;

    chomp $message;

    if ( $config{passthru_send} ) {
        AE::log debug => "Received topic: \"$topic\" message: \"$message\"";

        AE::log info => "Passthru: Command => \"$message\"";
        delay_write( $handle, $message . "\r" );
    }
    else {
        AE::log debug =>
          "Passthru disabled - Ignoring  \"$topic\" message: \"$message\"";
    }
    return;
}

sub receive_mqtt_ping {
    $mqtt_updated = AnyEvent->now;
}

sub receive_mqtt_set {
    my ( $topic, $payload ) = @_;

    $mqtt_updated = AnyEvent->now;

    $topic =~ m{\Q$config{mqtt_prefix}\E/([\w-]+)/set}i;
    my $device = lc $1;

    ( $device eq '_ping' ) && return;

    chomp $payload;
    $payload = lc $payload;

    AE::log debug => "Received topic: \"$topic\" payload: \"$payload\"";

    if ( $device eq 'passthru' ) {
        AE::log info => "Passthru set: Command => \"$payload\"";
        $config{passthru} = is_true($payload);
        return;
    }

    $device =~ s/[^0-9a-z]+/-/g;

    if ( defined $cmds{$payload} ) {
        if ( defined $alias{$device} ) {
            foreach ( @{ $alias{$device} } ) {
                unless ( $ignore{$device} ) {
                    AE::log info =>
                      "Switching device $_ $payload => $cmds{$payload}";
                    delay_write( $handle,
                        "pl " . $_ . ' ' . $cmds{$payload} . "\r" );
                }
            }
        }
        elsif ( $device =~ m{^[a-z]\d*$} ) {
            $device = uc $device;
            unless ( $ignore{$device} ) {
                AE::log info =>
                  "Switching device $device $payload => $cmds{$payload}";
                delay_write( $handle, "pl $device $cmds{$payload}\r" );
            }
        }
        else {
            AE::log error =>
              "Unknown device: \"$device\" payload: \"$payload\"";
        }
    }
    else {
        AE::log error =>
          "Unknown command: device: \"$device\" payload: \"$payload\"";
    }
}

sub send_mqtt_status {
    my ( $device, $status ) = @_;

    return if ( $ignore{$device} );

    # Short form
    send_mqtt_message( "$device/state", $status->{state}, 0 )
      if ( defined( $status->{state} ) );

    # Long form
    my $retain = $retain{$device} ? 1 : 0;

    AE::log debug => "$device retain: $retain";

    my $json_text = JSON::PP->new->utf8->canonical->encode($status);

    send_mqtt_message( $device, $json_text, $retain );
}

sub send_mqtt_message {
    my ( $topic, $message, $retain ) = @_;

    $mqtt->publish(
        topic   => "$config{mqtt_prefix}/$topic",
        message => $message,
        retain  => $retain,
    );
}

my $addr_queue = {};

#01/21 13:29:09 Rx PL HouseUnit: L1
#01/21 13:29:10 Rx PL House: L Func: Off

sub process_x10_line {
    my ($input) = @_;

    $mochad_updated = AnyEvent->now;

    chomp $input;

    # Raw data received:
    # Needs --raw-data opion set in Mochad

    my $raw = 0;
    if ( $input =~ m{Raw data received:\s+([\s\da-f]+)$}i ) {
        $input = $1;
        $raw   = 1;
        AE::log debug => "Raw data: $input";
    }

    send_mqtt_message( 'passthru', $input, 0 ) if ( $config{passthru} );

    if ($raw) { }
    elsif ( $input =~ m{ HouseUnit:\s+([A-Z])(\d+)}i ) {
        my $house = uc $1;
        my $unit  = $2;
        AE::log debug => "House=$house Unit=$unit";
        $addr_queue->{$house} ||= {};
        $addr_queue->{$house}{$unit} = 1;
    }
    elsif ( $input =~ m{ House:\s+([A-Z])\s+Func:\s+([\sa-z]+)}i ) {
        my $cmd   = lc $2;
        my $house = uc $1;

        AE::log debug => "House=$house Cmd=$cmd";
        if ( $cmd =~ m{^on$|^off$} ) {
            if ( $addr_queue->{$house} ) {
                for my $k ( keys %{ $addr_queue->{$house} } ) {
                    process_x10_cmd( $cmd, "$house$k" );
                }
                delete $addr_queue->{$house};
            }
        }
        elsif ( $cmd =~ m{all\s+(\w+)\s+(\w+)} ) {
            process_x10_cmd( "$1$2", $house );
        }
    }
    else {
        AE::log error => "Unmatched: $input";
    }
}

sub process_x10_cmd {
    my ( $cmd, $device ) = @_;

    AE::log info => "processing $device: $cmd";

    $cmd    = lc $cmd;
    $device = lc $device;

    unless ( defined $cmds{$cmd} ) {
        AE::log error => "unexpected command $device: $cmd";
        return;
    }

    if ( $ignore{ uc $device } ) {
        AE::log debug => "ignoring command $device: $cmd";
    }
    elsif ( $device =~ m{^([a-z])(\d+)$} ) {
        my %status;
        my $house    = uc $1;
        my $unitcode = $2;

        $status{'house'}     = $house;
        $status{'unitcode'}  = $unitcode;
        $status{'state'}     = $cmd;
        $status{'command'}   = $cmd;
        $status{'timestamp'} = strftime( "%Y-%m-%dT%H:%M:%S", localtime );
        $status{'instance'}  = $config{mm_instance};

        my $alias;
        if ( defined $codes{ uc $device } ) {
            $alias = $codes{ uc $device };
            $status{'alias'} = $alias;
        }
        else {
            $alias = $device;
        }
        send_mqtt_status( $alias, \%status );
    }
    elsif ( $device =~ m{^[a-z]$} ) {
        my %status;
        my $house = uc $device;

        $status{'house'}     = $house;
        $status{'command'}   = $cmd;
        $status{'timestamp'} = strftime( "%Y-%m-%dT%H:%M:%S", localtime );
        $status{'instance'}  = $config{mm_instance};

        send_mqtt_status( $house, \%status, 0 );

        if ( $cmd =~ m{off$} ) {
            $status{'command'} = 'off';
            $status{'state'}   = 'off';
        }
        else {
            $status{'command'} = 'on';
            $status{'state'}   = 'on';
        }
        my @unitcodes;
        if ( $cmd =~ m{lights} ) {
            @unitcodes = sort( { $a <=> $b } keys %{ $lights{$house} } );
        }
        else {
            @unitcodes = sort( { $a <=> $b } keys %{ $appls{$house} } );
        }
        for my $i (@unitcodes) {
            $status{'unitcode'} = $i;
            my $alias = "$house$i";
            $alias = $codes{$alias} if defined $codes{$alias};
            $status{'alias'} = $alias;
            send_mqtt_status( $alias, \%status );
        }
    }
    else {
        AE::log error => "unexpected $device: $cmd";

        return;
    }
}

$mqtt->subscribe(
    topic    => "$config{mqtt_prefix}/+/set",
    callback => \&receive_mqtt_set
  )->cb(
    sub {
        AE::log note => "subscribed to MQTT topic $config{mqtt_prefix}/+/set";
    }
  );

if ( $config{'mqtt_idle'} > 0.0 ) {
    $mqtt->subscribe(
        topic    => "$config{mqtt_ping}",
        callback => \&receive_mqtt_ping,
      )->cb(
        sub {
            AE::log note => "subscribed to MQTT topic $config{mqtt_ping}";
        }
      );
}

if ( $config{passthru_send} ) {
    $mqtt->subscribe(
        topic    => "$config{mqtt_prefix}/passthru/send",
        callback => \&receive_passthru_send,
      )->cb(
        sub {
            AE::log note =>
              "subscribed to MQTT topic $config{mqtt_prefix}/passthru/send";
        }
      );
}

#print Dumper \%config, \%lights, \%appls, \%codes, \%alias;
AE::log debug => Dumper( \%config );

# first, connect to the host
$handle = new AnyEvent::Handle
  connect  => [ $config{'mochad_host'}, $config{'mochad_port'} ],
  on_error => sub {
    my ( $hdl, $fatal, $msg ) = @_;
    AE::log error => $msg;
    if ($fatal) {
        AE::log error => "Fatal error - exiting";
        exit(1);
    }
  },
  keepalive => 1,
  no_delay  => 1;

$handle->on_read(
    sub {
        for ( split( /[\n\r]/, $_[0]->rbuf ) ) {
            next unless length $_;

            AE::log debug => "Received line: \"$_\"";
            process_x10_line($_);
        }
        $_[0]->rbuf = "";
    }
);

# Watch config file for changes

my $dirname  = dirname($mm_config);
my $basename = basename($mm_config);

AE::log debug => "Watch config file $dirname $basename";

my $conf_monitor = AnyEvent->timer(
    after    => 30.0,
    interval => 60.0,
    cb       => sub {
        if ( changed_config() ) {
            AE::log error => "$mm_config updated - Exiting";

            # Safer to just restart
            exit(10);
        }
    },
);

$mqtt_updated = AnyEvent->now;
my $mqtt_health;
if ( $config{'mqtt_idle'} > 0.0 ) {
    $mqtt_health = AnyEvent->timer(
        after    => 0.1,
        interval => ( $config{'mqtt_idle'} / 2.0 ) - 1.0,
        cb       => sub {
            my $inactivity = AnyEvent->now - $mqtt_updated;
            if ( $inactivity >= ( $config{'mqtt_idle'} - 0.2 ) ) {
                AE::log error =>
                  "No MQTT activity for $inactivity secs. Exiting";
                exit(0);
            }
            $mqtt->publish(
                topic   => "$config{mqtt_ping}",
                retain  => 0,
                message => '{"instance":"'
                  . $config{mm_instance}
                  . '","timestamp":"'
                  . strftime( "%Y-%m-%dT%H:%M:%S", localtime ) . '"}',
            );
        },
    );
}

$mochad_updated = AnyEvent->now;
my $mochad_health;
if ( $config{'mochad_idle'} > 0.0 ) {
    $mochad_health = AnyEvent->timer(
        after    => 0.2,
        interval => ( $config{'mochad_idle'} / 2.0 ) - 1.0,
        cb       => sub {
            my $inactivity = AnyEvent->now - $mochad_updated;
            if ( $inactivity >= ( $config{'mochad_idle'} - 0.2 ) ) {
                AE::log error =>
                  "No mochad activity for $inactivity secs. Exiting";
                exit(0);
            }
        },
    );
}

$handle->push_write("rftopl 0\r");

# use a condvar to return results
my $cv = AnyEvent->condvar;

$cv->recv;
