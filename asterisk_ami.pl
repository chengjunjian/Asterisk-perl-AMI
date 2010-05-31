#!/usr/bin/perl -w

use DBI;
use strict;
use threads ('yield');
use threads::shared;
use Thread::Queue;
use Net::Telnet();
use JSON;

my $t; # Telnet AMI handle for boss thread
`mkdir -p log`;
my %cfg = (
	"log_ami" => "./log/ami_%s.log",
	"log_info" => "./log/info_%s.log",
	"log_all_ami" => 1,
	"ami_host" => "127.0.0.1",
	"ami_port" => 5038,
	"ami_user" => "mark",
	"ami_secret" => "woohoo_passwd"
);

my %fhs; # File handles for logging

&connect_ami;

# ------------------------------------------------------------
# Assigning callbacks to functions.
# In AMI this looks like: 
#   Event: Newexten
#   AppData: Netcode: 7
# Then stuff goes to @_{AppData}, etc
#

my %callbacks = ();
$callbacks{'Newstate'} = \&newstate_callback;

# This is our processing (WORKER) thread.
# Takes an AMI block from the queue (including the time) and processes it.

my $blockQueue = Thread::Queue->new();
my $thr = threads->create(sub {

    while (my $block = $blockQueue->dequeue()) {
		my %dict = ();
		foreach (split("\n", $block)) {
			if ($_ =~ m/^(.+?):(?: (.*))?$/) {
				$dict{$1} = $2;
			} else {
				print STDERR "Block does not match:\n--below--:\n$block\n--above--\n";
			}
		}
		$dict{human_now} = &human_now($dict{Timestamp});
		$block = "human_now: $dict{human_now}\n$block";

		$callbacks{$dict{'Event'}} -> (%dict) if (defined $callbacks{$dict{'Event'}});

        if ($cfg{log_all_ami}) {
            &logme('ami', $block."\n\n");
        }
    }
})->detach(); # Preventing memory leaks

# This is our BOSS thread, reads AMI and flushes queue
while (1) {
	(my $block, my $twoeols) = $t->waitfor("/\n\n/");

	next if (!$block or $block eq "" or $block eq "\n");

	# "Event:" option is always the first in block, so parse it efficiently
	if (!($block =~ /^Event: (.*)\n/)) {
		print STDERR "Block does not have EVENT handler:\n--below--:\n$block\n--above--\n";
		next;
	}

	# Will we do something with this block?
	next if (!($callbacks{$1} or $cfg{log_all_ami}));

	$blockQueue->enqueue($block);
}


sub newstate_callback {
    my (%stuff) = @_;

    if ($stuff{ChannelStateDesc} eq "Ringing") {
		my $uniq = $stuff{'Uniqueid'};

        &logme ("info", "$stuff{human_now} Ringing callback for $uniq, $stuff{'Channel'}\n");

		# Connect the jack ports

		#print STDERR "dialplan set chanvar $stuff{'Channel'} JACK_HOOK(manipulate,n,i(rec_$uniq:input),o(rec_$uniq:output),c(rec_$uniq)) on";

		#print STDERR "Action: Setvar\n";
		#print STDERR "Channel: $stuff{Channel}\n";
		#print STDERR "Variable: JACK_HOOK(manipulate,n,i(rec_$uniq:input),o(rec_$uniq:output),c(rec_$uniq))\n";
		#print STDERR "Value: on\n";
		$t->print("Action: Setvar");
		$t->print("Channel: $stuff{Channel}");
		$t->print("Variable: JACK_HOOK(manipulate,n,i(rec_$uniq:input),o(rec_$uniq:output),c(rec_$uniq))");
		$t->print("Value: on");
		$t->print("");
    }
}


sub connect_ami {
	if ($t and $t->close) {
		$t->close; # Force re-connect in this subroutine
	}
    undef $t;

	$t = new Net::Telnet(
						Host => $cfg{ami_host},
						Port => $cfg{ami_port},
						timeout => 31536000,
						Errmode => \&ami_err
						);
	$t->print("Action: login");
	$t->print("Username: $cfg{ami_user}");
	$t->print("Secret: $cfg{ami_secret}");
	$t->print('');

	(my $block, my $twoeols) = $t->waitfor("/\n\n/");
	# Wait for a greeting
	if (not ($block =~ /Message: Authentication accepted/)) {
		$t->error("Incorrect answer from Asterisk:\n$block\n");
	}
}


sub ami_err {
	chomp(my $now = `date +%s.%N`); my $human_now = &human_now($now);
	if ($t->errmsg) {
		print STDERR "$human_now ERROR IN AMI request: ".$t->errmsg()."\n";
		# Re-connect
		sleep 1;
		&connect_ami;
	}
}


sub human_now {
    my $now = scalar(@_ == 0)? reverse(substr(reverse(`date +%s.%N`),1)) : $_[0]; 
    $now =~ /(\d+)\.(\d+)/;
    my @n = localtime($1);
    return sprintf "%04d-%02d-%02d %02d:%02d:%02d.%06d ", 1900+$n[5], 1+$n[4], $n[3], $n[2], $n[1], $n[0], substr($2, 0, 9);
}

sub logme {
    (my $type, my $msg) = @_;
    my $file;
    chomp(my $now = `date +%s.%N`);
    my $human_now = &human_now($now);

    return if (not $msg); 
    
    $file = $cfg{log_ami} if ($type eq 'ami');
    $file = $cfg{log_info} if ($type eq 'info');

    if (not $file) {
        print STDERR "$human_now *** ERROR: ***\n bad error type specified: $type\n";
        return;
    }
    # --------------------------------------------------------------------------------
    # If filename has a date template, let's put it there
    # Take %Y-%m-%d from date string and replace with %s
    #
    if ($file =~ /%s/) {
        $file = sprintf ($file, substr($human_now,0,10));
    }

    if (not $fhs{$file}) {
        open $fhs{$file}, ">>$file" or print STDERR "$human_now *** ERROR while opening $file: ***\n$!\n";
        print STDERR "$human_now Opening $file for writing\n"
    }
    print { $fhs{$file} } $msg or print STDERR "$human_now *** ERROR IN FILE $file WRITING: ***\n$!\n";
}
