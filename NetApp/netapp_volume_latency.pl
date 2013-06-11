#! /usr/bin/perl -w
# nagios: -epn
#
#
# Matthew Hilton 2013-06-11
# NetApp volume latency nagios plugin
#
require 5.6.1;
use lib '/usr/share/perl5/NetApp';
use lib '/usr/share/perl5';
use strict;
use warnings;
use NaServer;
use NaElement;
use Nagios::Plugin;
use File::Basename;
use Math::Round;
#use utils qw(%ERRORS);

# IMPORTANT: Nagios plugins could be executed using embedded perl in this case
#            the main routine would be executed as a subroutine and all the
#            declared subroutines would therefore be inner subroutines
#            This will cause all the global lexical variables not to stay shared
#            in the subroutines!
#
# All variables are therefore declared as package variables...
 
use vars qw(
    $VERSION
    $PROGNAME
    $plugin
    $verbose
    $WAFL_VOL_RESERVE
);
 
$VERSION = '0.1';
$PROGNAME = basename($0);
$WAFL_VOL_RESERVE = '1.03';
 
$plugin = Nagios::Plugin->new(
    usage=> "Usage: %s --hostname=<hostname> --cliuser=<cliuser> --clipassword=<clipassword>
    --object=<objetcname> --instance=<instancename> --counter=<counter>",
    version => $VERSION,
    blurb => 'This plugin checks a single volume for it\'s occupied space',
    license => "This nagios plugin is free software, and comes with ABSOLUTELY
NO WARRANTY. It may be used, redistributed and/or modified under
the terms of the GNU General Public Licence (see
http://www.fsf.org/licensing/licenses/gpl.txt).",
    extra => "
 
    Examples:
 
    Checking the Volume read latency for vol0:
       $PROGNAME --hostname netapp --cliuser=root --clipassword=password --object=volume --instance=vol0 --counter=read_latency --critical=10 --warning=5
    Checking the Volume Write latency for vol0:
       $PROGNAME --hostname netapp --cliuser=root --clipassword=password --object=volume --instance=vol0 --counter=write_latency --critical=10 --warning=5
      "
);
 
$plugin->add_arg(
    spec => 'hostname=s',
    help => qq{--hostname=STRING
    Hostname/IP-Adress to use for the check.},
    required => 1,
);
 
$plugin->add_arg(
    spec => 'cliuser=s',
    help => qq{--cliuser=STRING
    Username for CLI/API access.},
    required => 1,
);
 
$plugin->add_arg(
    spec => 'clipassword=s',
    help => qq{--clipassword=STRING
    Password for CLI/API access.},
    required => 1,
);

$plugin->add_arg(
    spec => 'object=s',
    help => qq{--object=STRING
    Object that contains counter.},
    required => 1,
);

$plugin->add_arg(
    spec => 'instance=s',
    help => qq{--instance=STRING
    Instance that should be checked.},
    required => 1,
);

$plugin->add_arg(
    spec => 'counter=s',
    help => qq{--counter
    Counter to get stat from.},
    required => 1,
);
$plugin->add_arg(
    spec => 'warning=s',
    help => qq{--warning
    Warning threshold.},
    required => 1,
);
$plugin->add_arg(
    spec => 'critical=s',
    help => qq{--critical
    Critical threshold.},
    required => 1,
);
# Parse arguments and process standard ones (e.g. usage, help, version)
$plugin->getopts;
 
my ( $hostname, $username, $password, $object, $instance, $counter, $warning, $critical);
 
$hostname = $plugin->opts->hostname;
$username = $plugin->opts->cliuser;
$password = $plugin->opts->clipassword;
$object  = $plugin->opts->object;
$instance  = $plugin->opts->instance;
$counter  = $plugin->opts->counter;
$warning  = $plugin->opts->warning;
$critical  = $plugin->opts->critical;

sub timeconv($) {
    my $secs = shift;
    if    ($secs >= 365*24*60*60) { return sprintf '%.1f years', $secs/(365*24*60*60) }
    elsif ($secs >=     24*60*60) { return sprintf '%.1f days', $secs/(24*60*60) }
    elsif ($secs >=        60*60) { return sprintf '%.1f hours', $secs/(60*60) }
    elsif ($secs >=           60) { return sprintf '%.1f minutes', $secs/(60) }
    else                          { return sprintf '%.1f seconds', $secs }
}
#Generic output format used for Cacti compatibility
sub print_counter()
{
        my $counter_name = $_[0];
        my $counter_value = $_[1];
        print("$counter_name:$counter_value ");
}
my $s = new NaServer($hostname, 1 , 14);
$s->set_server_type('FILER');
$s->set_transport_type('HTTPS');
$s->set_port(443);
$s->set_style('LOGIN');
$s->set_admin_user($username, $password);
#print "Connecting to: $hostname\n using: $username $password\n";


my $api = new NaElement('perf-object-get-instances');
my $xi = new NaElement('counters');
$api->child_add($xi);
$xi->child_add_string('counter',$counter);
if ($counter eq 'read_latency') {
$xi->child_add_string('counter','read_ops');
}
if ($counter eq 'write_latency') {
$xi->child_add_string('counter','write_ops');
}
my $xi1 = new NaElement('instances');
$api->child_add($xi1);
$xi1->child_add_string('instance',$instance);
$api->child_add_string('objectname',$object);

my $xo = $s->invoke_elem($api);
if ($xo->results_status() eq 'failed') {
    print 'Error:\n';
    print $xo->sprintf();
    exit 1;
}

my $timestamp;
$timestamp=$xo->child_get_string("timestamp");
my $data;
$data = $xo->child_get("instances");
my @result;
    # Die if $status is unset, otherwise fill the array
    if ($data) {
        @result = $data->children_get("instance-data");
    } else {
       $plugin->nagios_exit(UNKNOWN, "Unable to process result.");
    }

my $counterdata;
my ($countername, $countervalue);
my $latency;
my $volinfo;
my $vol_name;
my $actuallatency;
$actuallatency=0;
# Walk through each array element (there should only be one, as we
# explicitly selected only a single volume)
    foreach $volinfo (@result){
        $vol_name = $volinfo->child_get_string("name");
		my $counters_list = $volinfo->child_get("counters");
		my @counters =  $counters_list->children_get();
		foreach $counter (@counters) {
			$countername = $counter->child_get_string("name");
			$countervalue = $counter->child_get_int("value");
			if ("$countername" =~/latency/) {
                $latency=$countervalue;
				}
			elsif ("$countername" =~/ops/) {
				if ($latency) {
					$actuallatency=round(($latency/$countervalue)/1000);
					#print_counter($countername, $countervalue);
					#print ("$countername $countervalue");
					}
				}
			}				
		}
#$timestamp=timeconv($timestamp);
$timestamp=localtime($timestamp);
#print ("\n");
#print ("Time stamp:         $timestamp\n");
#print ("Vol Name:           $vol_name\n");
#if ($actuallatency) {
#print ("$counter:		$actuallatency\n");}
#print 'Received:\n';
#print $xo->sprintf();
#
if (not defined($vol_name)) {$plugin->nagios_exit(UNKNOWN, "Volume Does not exist");};
$plugin->add_perfdata(label=> "$counter",value=> $actuallatency,uom=> "ms",warning=> $warning,critical=> $critical);
if ($actuallatency>$critical){$plugin->nagios_exit(CRITICAL, "$vol_name $counter: $actuallatency ms");}
if ($actuallatency>$warning){$plugin->nagios_exit(WARNING, "$vol_name $counter: $actuallatency ms");}
$plugin->nagios_exit(OK, "$vol_name $counter: $actuallatency ms");
