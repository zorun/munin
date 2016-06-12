package Munin::Master::UpdateWorker;
use base qw(Munin::Master::Worker);


use warnings;
use strict;

use Carp;
use English qw(-no_match_vars);
use Munin::Common::Logger;

use File::Basename;
use File::Path;
use File::Spec;
use IO::Socket::INET;
use Munin::Master::Config;
use Munin::Master::Node;
use Munin::Master::Utils;
use RRDs;
use Time::HiRes;
use Data::Dumper;
use Scalar::Util qw(weaken);

use List::Util qw(max shuffle);

my $config = Munin::Master::Config->instance()->{config};

# Flags that have RRD autotuning enabled.
my $rrd_tune_flags = {
	type => '--data-source-type',
	max => '--maximum',
	min => '--minimum',
};

sub new {
    my ($class, $host, $worker) = @_;

    my $self = $class->SUPER::new($host->get_full_path);
    $self->{host} = $host;

    # node addresses are optional, defaulting to node name
    # More infos in #972 & D:592213
    $host->{address} = _get_default_address($host) unless defined $host->{address};

    $self->{node} = Munin::Master::Node->new($host->{address},
                                             $host->{port},
                                             $host->{host_name},
					     $host);
    # $worker already has a ref to $self, so avoid mem leak
    $self->{worker} = $worker;
    weaken($self->{worker});

    return $self;
}


sub do_work {
    my ($self) = @_;

    my $update_time = Time::HiRes::time;
    my $host = $self->{host}{host_name};
    my $group = $self->{host}{group};
    my $path = $self->{host}->get_full_path;
    $path =~ s{[:;]}{-}g;

    my $nodedesignation = $host."/".
	$self->{host}{address}.":".$self->{host}{port};

    # No need to lock for the node. We'll use per plugin locking, and it will be
    # handled directly in SQL. This will enable node-pushed updates.

    my %all_service_configs = (
		data_source => {},
		global => {},
	);

	# Try Connecting to the Carbon Server
	$self->_connect_carbon_server() if $config->{carbon_server};

	# Having a local handle looks easier
	my $node = $self->{node};

    INFO "[INFO] starting work in $$ for $nodedesignation.\n";
    my $done = $node->do_in_session(sub {

	# A I/O timeout results in a violent exit.  Catch and handle.
	eval {
		# Create the group path
		my $grp_id = $self->_db_mkgrp($group);

		# Fetch the node name
		my $node_name = $self->{node_name} || $self->{host};

		# Create the node
		my $node_id = $self->_db_mknode($grp_id, $node_name);

		my @node_capabilities = $node->negotiate_capabilities();


            # Handle spoolfetch, one call to retrieve everything
	    if (grep /^spool$/, @node_capabilities) {
		    my $spoolfetch_last_timestamp = $self->get_spoolfetch_timestamp();
		    local $0 = "$0 -- spoolfetch($spoolfetch_last_timestamp)";

		    # We do inject the update handling, in order to have on-the-fly
		    # updates, as we don't want to slurp the whole spoolfetched output
		    # and process it later. It will surely timeout, and use a truckload
		    # of RSS.
		    my $timestamp = $node->spoolfetch($spoolfetch_last_timestamp, sub { $self->uw_handle_config( @_ ); } );

		    # update the timestamp if we spoolfetched something
		    $self->set_spoolfetch_timestamp($timestamp) if $timestamp;

		    # Note that spoolfetching hosts is always a success. BY DESIGN.
		    # Since, if we cannot connect, or whatever else, it is NOT an issue.

		    # No need to do more than that.
		    return;
	    }

	    # Note: A multigraph plugin can present multiple services.
	    my @plugins = $node->list_plugins();

	    # Shuffle @plugins to avoid always having the same ordering
	    # XXX - It might be best to preorder them on the TIMETAKEN ASC
	    #       in order that statisticall fast plugins are done first to increase
	    #       the global throughtput
	    @plugins = shuffle(@plugins);

	    for my $plugin (@plugins) {
		DEBUG "[DEBUG] for my $plugin (@plugins)";
		if (%{$config->{limit_services}}) {
		    next unless $config->{limit_services}{$plugin};
		}

		DEBUG "[DEBUG] config $plugin";

		local $0 = "$0 -- config($plugin)";
		my $last_timestamp = $node->fetch_service_config($plugin, sub { $self->uw_handle_config( @_ ); });

		# Ignoring if $last_timestamp is undef, as we don't have config
		if (! defined ($last_timestamp)) {
			INFO "[INFO] $plugin did emit no proper config, ignoring";
			next;
		}

		# Done with this plugin on dirty config (we already have a timestamp for data)
		# --> Note that dirtyconfig plugin are always polled every run,
		#     as we don't have a way to know yet.
		next if ($last_timestamp);

		my $update_rate = 300; # XXX - hard coded

		my $is_fresh_enough = $self->is_fresh_enough($update_rate, $last_timestamp);

		next if ($is_fresh_enough);

		DEBUG "[DEBUG] fetch $plugin";
		local $0 = "$0 -- fetch($plugin)";

		$last_timestamp = $node->fetch_service_data($plugin, sub { $self->uw_handle_fetch( @_ , $update_rate, $last_timestamp); });

	    } # for @plugins

	    # Send "quit" to node
	    $node->quit();

	}; # eval

	$self->_disconnect_carbon_server();

	# kill the remaining process if needed
	# (useful if we spawned an helper, as for cmd:// or ssh://)
	# XXX - investigate why this leaks here. It should be handled directly by Node.pm
	my $node_pid = $node->{pid};
	if ($node_pid && kill(0, $node_pid)) {
		INFO "[INFO] Killing subprocess $node_pid";
		kill 'KILL', $node_pid; # Using SIGKILL, since normal termination didn't happen
	}

	if ($EVAL_ERROR =~ m/^NO_SPOOLFETCH_DATA /) {
	    INFO "[INFO] No spoofetch data for $nodedesignation";
	    return;
	} elsif ($EVAL_ERROR) {
	    ERROR "[ERROR] Error in node communication with $nodedesignation: "
		.$EVAL_ERROR;
	    return;
	}

FETCH_OK:
	# Everything went smoothly.
	DEBUG "[DEBUG] Everything went smoothly.";
	return 1;

    }); # do_in_session

    # This handles failure in do_in_session,
    return undef if ! $done || ! $done->{exit_value};

    return {
        time_used => Time::HiRes::time - $update_time,
    }
}

sub _db_mkgrp {
	my ($self, $group) = @_;
	my $dbh = $self->{dbh};

	DEBUG "group:".Dumper($group);

	return -42;
}

# This should go in a generic DB.pm
sub _get_last_insert_id {
	my ($dbh) = @_;
	return $dbh->last_insert_id("", "", "", "");
}

sub _db_mknode {
	my ($self, $grp_id, $node_name) = @_;
	my $dbh = $self->{dbh};

	my $sth_node_id = $dbh->prepare("SELECT id FROM node WHERE grp_id = ? AND name = ?");
	$sth_node_id->execute($grp_id, $node_name);
	my ($node_id) = $sth_node_id->fetchrow_array();

	if (! defined $node_id) {
		# Create the node
		my $sth_node = $dbh->prepare('INSERT INTO node (grp_id, name, path) VALUES (?, ?, ?)');
		my $path = "";
		$sth_node->execute($grp_id, $node_name, $path);
		$node_id = _get_last_insert_id($dbh);
	} else {
		# Nothing to do, the node doesn't need any updates anyway.
		# Removal of nodes is *unsupported* yet.
	}


}

sub _db_service {
	my ($self, $plugin, $service_attr, $fields) = @_;
	my $dbh = $self->{dbh};
	my $node_id = $self->{node_id};

	DEBUG "_db_service($node_id, $plugin)";
	DEBUG "_db_service.service_attr:".Dumper($service_attr);
	DEBUG "_db_service.service_attr:".Dumper($fields);

	# Save the whole service config, and drop it.
	my $sth_service_id = $dbh->prepare("SELECT service_id FROM service WHERE node_id = ? AND name = ?");
	$sth_service_id->execute($node_id, $plugin);
	my ($service_id) = $sth_service_id->fetchrow_array();

	# Save the existing values
	my (%service_attrs_old, %fields_old);
	{
		my $sth_service_attrs = $dbh->prepare("SELECT name, value FROM service_attr WHERE id = ?");
		$sth_service_attrs->execute($service_id);

		while (my ($_name, $_value) = $sth_service_attrs->fetchrow_array()) {
			$service_attrs_old{$_name} = $_value;
		}

		my $sth_fields_attr = $dbh->prepare("SELECT ds.name as field, ds_attr.name as attr, ds_attr.value FROM ds
			LEFT OUTER JOIN ds_attr ON ds.id = ds.attr WHERE ds.service_id = ?");
		$sth_fields_attr->execute($service_id);

		my %fields_old;
		while (my ($_field, $_name, $_value) = $sth_fields_attr->fetchrow_array()) {
			$fields_old{$_field}{$_name} = $_value;
		}
	}

	DEBUG "_db_service.%service_attrs_old:" . Dumper(\%service_attrs_old);
	DEBUG "_db_service.%fields_old:" . Dumper(\%fields_old);

	# Leave room for refresh
	# XXX - we might only update DB with diff.
	my $sth_service_attrs_del = $dbh->prepare("DELETE FROM service_attr WHERE id = ?");
	$sth_service_attrs_del->execute($service_id);

	return ($service_id, \%service_attrs_old);
}

sub _db_service_attr {
	my ($self, $service_id, $name, $value) = @_;
	my $dbh = $self->{dbh};

	DEBUG "_db_service_attr($service_id, $name, $value)";

	# Save the whole service config, and drop it.
	my $sth_service_attr = $dbh->prepare("INSERT INTO service (id, name, value) VALUES (?, ?, ?)");
	$sth_service_attr->execute($service_id, $name, $value);
}

sub _db_ds_update {
	my ($self, $service_id, $field, $attr, $value) = @_;
	my $dbh = $self->{dbh};

	my $node_id = $self->{node}{node_id};

	DEBUG "_db_ds_update($service_id, $field, $attr, $value)";

	my $sth_service_attr = $dbh->prepare("INSERT INTO service (id, name, value) VALUES (?, ?, ?)");
}

sub get_global_service_value {
	my ($service_config, $service, $conf_field_name, $default) = @_;
	foreach my $array (@{$service_config->{global}{$service}}) {
		my ($field_name, $field_value) = @$array;
		if ($field_name eq $conf_field_name) {
			return $field_value;
		}
	}

	return $default;
}

sub is_fresh_enough {
	my ($self, $nodedesignation, $service, $update_rate_in_seconds) = @_;

	DEBUG "is_fresh_enough asked for $service with a rate of $update_rate_in_seconds";

	my $last_updated = $self->{state}{last_updated}{$service} || "0 0";
	DEBUG "last_updated{$service}: " . $last_updated;
	my @last = split(/ /, $last_updated);

	use Time::HiRes qw(gettimeofday tv_interval);
	my $now = [ gettimeofday ];

	my $age = tv_interval(\@last, $now);
	DEBUG "last: [" . join(",", @last) . "], now: [" . join(", ", @$now) . "], age: $age";
	my $is_fresh_enough = ($age < $update_rate_in_seconds) ? 1 : 0;
	DEBUG "is_fresh_enough  $is_fresh_enough";

	if (! $is_fresh_enough) {
		DEBUG "new value: " . join(" ", @$now);
		$self->{state}{last_updated}{$service} = join(" ", @$now);
	}

	return $is_fresh_enough;
}

sub get_spoolfetch_timestamp {
	my ($self) = @_;

	my $last_updated_value = $self->{state}{spoolfetch} || "0";
	return $last_updated_value;
}

sub set_spoolfetch_timestamp {
	my ($self, $timestamp) = @_;
	DEBUG "[DEBUG] set_spoolfetch_timestamp($timestamp)";

	# Using the last timestamp sended by the server :
	# -> It can be be different than "now" to be able to process the backlock slowly
	$self->{state}{spoolfetch} = $timestamp;
}

sub parse_update_rate {
	my ($update_rate_config) = @_;

	my ($is_update_aligned, $update_rate_in_sec);
	if ($update_rate_config =~ m/(\d+[a-z]?)( aligned)?/) {
		$update_rate_in_sec = to_sec($1);
		$is_update_aligned = $2;
	} else {
		return (0, 0);
	}

	return ($update_rate_in_sec, $is_update_aligned);
}

sub round_to_granularity {
	my ($when, $granularity_in_sec) = @_;
	$when = time if ($when eq "N"); # N means "now"

	my $rounded_when = $when - ($when % $granularity_in_sec);
	return $rounded_when;
}

sub handle_dirty_config {
	my ($self, $service_config) = @_;

	my %service_data;

	my $services = $service_config->{global}{multigraph};
	foreach my $service (@$services) {
		my $service_data_source = $service_config->{data_source}->{$service};
		foreach my $field (keys %$service_data_source) {
			my $field_value = $service_data_source->{$field}->{value};
			my $field_when = $service_data_source->{$field}->{when};

			# If value not present, this field is not dirty fetched
			next if (! defined $field_value);

			DEBUG "[DEBUG] handle_dirty_config:$service, $field, @$field_when";
			# Moves the "value" to the service_data
			$service_data{$service}->{$field} ||= { when => [], value => [], };
	                push @{$service_data{$service}{$field}{value}}, @$field_value;
			push @{$service_data{$service}{$field}{when}}, @$field_when;

			delete($service_data_source->{$field}{value});
			delete($service_data_source->{$field}{when});
		}
	}

	return %service_data;
}

# For the uw_handle_* :
# The $data has been already sanitized :
# * chomp()
# * comments are removed
# * empty lines are removed

# This handles one config part.
# - It will automatically call uw_handle_fetch to handle dirty_config
# - In case of multigraph (or spoolfetch) the caller has to call this for every multigraph part
# - It handles empty $data, and just does nothing
#
# Returns the last updated timestamp
sub uw_handle_config {
	my ($self, $plugin, $now, $data, $last_timestamp) = @_;

	# Build FETCH data, just in case of dirty_config.
	my @fetch_data;

	# Parse the output to a simple HASH
	my %service_attr;
	my %fields;
	for my $line (@$data) {
		DEBUG "uw_handle_config: $line";
		# Barbaric regex to parse the output of the config
		next unless ($line =~ m{^([^\.]+)(?:\.(\S+))?\s+(.+)$});
		my ($arg1, $arg2, $value) = ($1, $2, $3);

		if (! $arg2) {
			# This is a service config line
			$service_attr{$arg1} = $value;
			next; # Handled
		}

		# Handle dirty_config
		if ($arg2 && $arg2 eq "value") {
			push @fetch_data, $line;
			next; # Handled
		}

		$fields{$arg1}{$arg2} = $value;

		# TODO - Update the DB with the updated plugin config
		DEBUG "update DB with plugin:$plugin, $arg1.$arg2 = $value";
	}

	# Sync to database
	# Create/Update the service
	my ($service_id, $service_attrs_old, $fields_old) = $self->_db_service($plugin, \%service_attr, \%fields);


	# timestamp == 0 means "Nothing was updated". We only count on the
	# "fetch" part to provide us good timestamp info, as the "config" part
	# doesn't contain any, specially in case we are spoolfetching.
	#
	# Also, the caller can override the $last_timestamp, to be called in a loop
	$last_timestamp = 0 unless defined $last_timestamp;

	# Delegate the FETCH part
	my $update_rate = "300"; # XXX - should use the correct version
	my $timestamp = $self->uw_handle_fetch($plugin, $now, $update_rate, \@fetch_data) if (@fetch_data);
	$last_timestamp = $timestamp if $timestamp && $timestamp > $last_timestamp;

	return $last_timestamp;
}

# This handles one fetch part.
# Returns the last updated timestamp
sub uw_handle_fetch {
	my ($self, $plugin, $now, $update_rate, $data) = @_;

	# timestamp == 0 means "Nothing was updated"
	my $last_timestamp = 0;

	my ($update_rate_in_seconds, $is_update_aligned) = parse_update_rate($update_rate);

	# Process all the data in-order
	for my $line (@$data) {
		next unless ($line =~ m{\A ([^\.]+)(?:\.(\S)+)? \s+ ([\S:]+) }xms);
		my ($field, $arg, $value) = ($1, $2, $3);

		my $when = $now; # Default is NOW, unless specified
		if ($value =~ /^(\d+):(.+)$/) {
			$when = $1;
			$value = $2;
		}

		# Always round the $when if plugin asks for. Rounding the plugin-provided
		# time is weird, but we are doing it to follow the "least surprise principle".
		$when = round_to_granularity($when, $update_rate_in_seconds) if $is_update_aligned;

		# Update last_timestamp if the current update is more recent
		$last_timestamp = $when if $when > $last_timestamp;

		# Update all data-driven components: State, RRD, Graphite
		# TODO
	}

	return $last_timestamp;
}

sub uw_fetch_service_config {
    my ($self, $plugin) = @_;

    # Note, this can die for several reasons.  Caller must eval us.
    my %service_config = $self->{node}->fetch_service_config($plugin);
    my $merged_config = $self->uw_override_with_conf($plugin, \%service_config);

    return %$merged_config;
}

sub uw_override_with_conf {
    my ($self, $plugin, $service_config) = @_;

    if ($self->{host}{service_config} &&
	$self->{host}{service_config}{$plugin}) {

        my %merged_config = (%$service_config, %{$self->{host}{service_config}{$plugin}});
	$service_config = \%merged_config;
    }

    return $service_config;
}


sub _compare_and_act_on_config_changes {
    my ($self, $nested_service_config) = @_;

    # Kjellm: Why do we need to tune RRD files after upgrade?
    # Shouldn't we create a upgrade script or something instead?
    #
    # janl: Upgrade script sucks.  This way it's inline in munin and
    #  no need to remember anything or anything.

    my $just_upgraded = 0;

    my $old_config = Munin::Master::Config->instance()->{oldconfig};

    if (not defined $old_config->{version}
        or ($old_config->{version}
            ne $Munin::Common::Defaults::MUNIN_VERSION)) {
        $just_upgraded = 1;
    }

    for my $service (keys %{$nested_service_config->{data_source}}) {

        my $service_config = $nested_service_config->{data_source}{$service};

	for my $data_source (keys %{$service_config}) {
	    my $old_data_source = $data_source;
	    my $ds_config = $service_config->{$data_source};

	    my $group = $self->{host}{group}{group_name};
	    my $host = $self->{host}{host_name};

	    my $old_host_config = $old_config->{groups}{$group}{hosts}{$host};
	    my $old_ds_config = undef;

	    if ($old_host_config) {
		$old_ds_config =
		    $old_host_config->get_canned_ds_config($service,
							   $data_source);
	    }

	    if (defined($old_ds_config)
		and %$old_ds_config
		and defined($ds_config->{oldname})
		and $ds_config->{oldname}) {

		$old_data_source = $ds_config->{oldname};
		$old_ds_config =
		    $old_host_config->get_canned_ds_config($service,
							   $old_data_source);
	    }

	    if (defined($old_ds_config)
		and %$old_ds_config
		and not $self->_ds_config_eq($old_ds_config, $ds_config)) {
		$self->_ensure_filename($service,
					$old_data_source, $data_source,
					$old_ds_config, $ds_config)
		    and $self->_ensure_tuning($service, $data_source,
					      $ds_config);
		# _ensure_filename prints helpful warnings in the log
	    } elsif ($just_upgraded) {
		$self->_ensure_tuning($service, $data_source,
				      $ds_config);
	    }
	}
    }
}


sub _ds_config_eq {
    my ($self, $old_ds_config, $ds_config) = @_;

    $ds_config = $self->_get_rrd_data_source_with_defaults($ds_config);
    $old_ds_config = $self->_get_rrd_data_source_with_defaults($old_ds_config);

    # We only compare keys that are autotuned to avoid needless RRD tuning,
    # since RRD tuning is bad for perf (flush rrdcached)
    for my $key (keys %$rrd_tune_flags) {
	my $old_value = $old_ds_config->{$key};
	my $value = $ds_config->{$key};

        # if both keys undefined, look no further
        next unless (defined($old_value) || defined($value));

	# so, at least one of the 2 is defined

	# False if the $old_value is not defined
	return 0 unless (defined($old_value));

	# if something isn't the same, return false
        return 0 if (! defined $value || $old_value ne $value);
    }

    # Nothing different found, it has to be equal.
    return 1;
}


sub _ensure_filename {
    my ($self, $service, $old_data_source, $data_source,
        $old_ds_config, $ds_config) = @_;

    my $rrd_file = $self->_get_rrd_file_name($service, $data_source,
                                             $ds_config);
    my $old_rrd_file = $self->_get_rrd_file_name($service, $old_data_source,
                                                 $old_ds_config);

    my $hostspec = $self->{node}{host}.'/'.$self->{node}{address}.':'.
	$self->{node}{port};

    if ($rrd_file ne $old_rrd_file) {
        if (-f $old_rrd_file and -f $rrd_file) {
            my $host = $self->{host}{host_name};
            WARN "[WARNING]: $hostspec $service $data_source config change "
		. "suggests moving '$old_rrd_file' to '$rrd_file' "
		. "but both exist; manually merge the data "
                . "or remove whichever file you care less about.\n";
	    return '';
        } elsif (-f $old_rrd_file) {
            INFO "[INFO]: Config update, changing name of '$old_rrd_file'"
                   . " to '$rrd_file' on $hostspec ";
            unless (rename ($old_rrd_file, $rrd_file)) {
                ERROR "[ERROR]: Could not rename '$old_rrd_file' to"
		    . " '$rrd_file' for $hostspec: $!\n";
                return '';
            }
        }
    }

    return 1;
}


sub _ensure_tuning {
    my ( $self, $service, $data_source, $ds_config ) = @_;
    my $fqn = sprintf( "%s:%s", $self->{ID}, $service );

    my $success = 1;

    my $rrd_file
        = $self->_get_rrd_file_name( $service, $data_source, $ds_config );

    return unless -f $rrd_file;

    $ds_config = $self->_get_rrd_data_source_with_defaults($ds_config);

    for my $rrd_prop ( keys %$rrd_tune_flags ) {
        RRDs::tune( $rrd_file, $rrd_tune_flags->{$rrd_prop},
            "42:$ds_config->{$rrd_prop}" );
        if ( RRDs::error() ) {
            $success = 0;
            ERROR(
                sprintf(
                    "fqn=%s, ds=%s, Tuning %s to %s failed: %s\n",
                    $fqn,      $data_source,
                    $rrd_prop, $ds_config->{$rrd_prop},
                    RRDs::error()
                )
            );
        }
        else {
            INFO(
                sprintf(
                    "fqn=%s, ds=%s, Tuning %s to %s\n",
                    $fqn,      $data_source,
                    $rrd_prop, $ds_config->{$rrd_prop}
                )
            );
        }
    }

    return $success;
}

sub _connect_carbon_server {
	my $self = shift;

	DEBUG "[DEBUG] Connecting to Carbon server $config->{carbon_server}:$config->{carbon_port}...";

	$self->{carbon_socket} = IO::Socket::INET->new (
		PeerAddr => $config->{carbon_server},
		PeerPort => $config->{carbon_port},
		Proto    => 'tcp',
	) or WARN "[WARN] Couldn't connect to Carbon Server: $!";
}

sub _disconnect_carbon_server {
	my $self = shift;

	if ($self->{carbon_socket}) {
		DEBUG "[DEBUG] Closing Carbon socket";
		delete $self->{carbon_socket};
	}
}

sub _update_carbon_server {
	my ($self, $nested_service_config, $nested_service_data) = @_;

	my $metric_path;

	return unless exists $self->{carbon_socket};

	if ($config->{carbon_prefix} ne "") {
		$metric_path .= $config->{carbon_prefix};
		if ($config->{carbon_prefix} !~ /\.$/) {
			$metric_path .= '.';
		}
	}

	$metric_path .= (join ".", reverse split /\./, $self->{host}{host_name}) . ".";

	for my $service (keys %{$nested_service_config->{data_source}}) {
		my $service_config = $nested_service_config->{data_source}{$service};
		my $service_data   = $nested_service_data->{$service};

		for my $ds_name (keys %{$service_config}) {
			my $ds_config = $service_config->{$ds_name};

			unless (defined($ds_config->{label})) {
				# _update_rrd_files will already have warned about this so silently move on
				next;
			}
			
			if (defined($service_data) and defined($service_data->{$ds_name})) {
				my $values = $service_data->{$ds_name}{value};
				next unless defined ($values);
				for (my $i = 0; $i < scalar @$values; $i++) {
					my $value = $values->[$i];
					my $when  = $service_data->{$ds_name}{when}[$i];

					if ($value =~ /\d[Ee]([+-]?\d+)$/) {
						# Looks like scientific format. I don't know how Carbon
						# handles that, but convert it anyway so it gets the same
						# data as RRDtool
						my $magnitude = $1;
						if ($magnitude < 0) {
							# Preserve at least 4 significant digits
							$magnitude = abs($magnitude) + 4;
							$value = sprintf("%.*f", $magnitude, $value);
						} else {
							$value = sprintf("%.4f", $value);
						}
					}

					DEBUG "[DEBUG] Sending ${metric_path}$service.$ds_name to Carbon";
					$self->{carbon_socket}->print("${metric_path}$service.$ds_name $value $when\n");

				}

			} else {
				# Again, _update_rrd_files will have warned
			}
		}
	}
}



sub _update_rrd_files {
    my ($self, $nested_service_config, $nested_service_data) = @_;

    my $nodedesignation = $self->{host}{host_name}."/".
	$self->{host}{address}.":".$self->{host}{port};

    my $last_timestamp = 0;

    for my $service (keys %{$nested_service_config->{data_source}}) {

	my $service_config = $nested_service_config->{data_source}{$service};
	my $service_data   = $nested_service_data->{$service};

	for my $ds_name (keys %{$service_config}) {
	    my $ds_config = $service_config->{$ds_name};

	    unless (defined($ds_config->{label})) {
		ERROR "[ERROR] Unable to update $service on $nodedesignation -> $ds_name: Missing data source configuration attribute: label";
		next;
	    }

	    # Sets the DS resolution, searching in that order :
	    # - per field
	    # - per plugin
	    # - globally
            my $configref = $self->{node}{configref};
	    $ds_config->{graph_data_size} ||= get_config_for_service($nested_service_config->{global}{$service}, "graph_data_size");
	    $ds_config->{graph_data_size} ||= $config->{graph_data_size};

	    $ds_config->{update_rate} ||= get_config_for_service($nested_service_config->{global}{$service}, "update_rate");
	    $ds_config->{update_rate} ||= $config->{update_rate};
	    $ds_config->{update_rate} ||= 300; # default is 5 min

	    DEBUG "[DEBUG] asking for a rrd of size : " . $ds_config->{graph_data_size};

	    # Avoid autovivification (for multigraphs)
	    my $first_epoch = (defined($service_data) and defined($service_data->{$ds_name})) ? ($service_data->{$ds_name}->{when}->[0]) : 0;
	    my $rrd_file = $self->_create_rrd_file_if_needed($service, $ds_name, $ds_config, $first_epoch);

	    if (defined($service_data) and defined($service_data->{$ds_name})) {
			$last_timestamp = max($last_timestamp, $self->_update_rrd_file($rrd_file, $ds_name, $service_data->{$ds_name}));
	    }
           elsif (defined $ds_config->{cdef} && $ds_config->{cdef} !~ /\b${ds_name}\b/) {
               DEBUG "[DEBUG] Service $service on $nodedesignation label $ds_name is synthetic";
           }
	    else {
		WARN "[WARNING] Service $service on $nodedesignation returned no data for label $ds_name";
	    }
	}
    }

    return $last_timestamp;
}

sub get_config_for_service {
	my ($array, $key) = @_;

	for my $elem (@$array) {
		next unless $elem->[0] && $elem->[0] eq $key;
		return $elem->[1];
	}

	# Not found
	return undef;
}


sub _get_rrd_data_source_with_defaults {
    my ($self, $data_source) = @_;

    # Copy it into a new hash, we don't want to alter the $data_source
    # and anything already defined should not be overridden by defaults
    my $ds_with_defaults = {
	    type => 'GAUGE',
	    min => 'U',
	    max => 'U',

	    update_rate => 300,
	    graph_data_size => 'normal',
    };
    for my $key (keys %$data_source) {
	    $ds_with_defaults->{$key} = $data_source->{$key};
    }

    return $ds_with_defaults;
}


sub _create_rrd_file_if_needed {
    my ($self, $service, $ds_name, $ds_config, $first_epoch) = @_;

    my $rrd_file = $self->_get_rrd_file_name($service, $ds_name, $ds_config);
    unless (-f $rrd_file) {
        $self->_create_rrd_file($rrd_file, $service, $ds_name, $ds_config, $first_epoch);
    }

    return $rrd_file;
}


sub _get_rrd_file_name {
    my ($self, $service, $ds_name, $ds_config) = @_;

    $ds_config = $self->_get_rrd_data_source_with_defaults($ds_config);
    my $type_id = lc(substr(($ds_config->{type}), 0, 1));

    my $path = $self->{host}->get_full_path;
    $path =~ s{[;:]}{/}g;

    # Multigraph/nested services will have . in the service name in this function.
    $service =~ s{\.}{-}g;

    my $file = sprintf("%s-%s-%s-%s.rrd",
                       $path,
                       $service,
                       $ds_name,
                       $type_id);

    $file = File::Spec->catfile($config->{dbdir},
				$file);

    DEBUG "[DEBUG] rrd filename: $file\n";

    return $file;
}


sub _create_rrd_file {
    my ($self, $rrd_file, $service, $ds_name, $ds_config, $first_epoch) = @_;

    INFO "[INFO] creating rrd-file for $service->$ds_name: '$rrd_file'";

    munin_mkdir_p(dirname($rrd_file), oct(777));

    my @args;

    $ds_config = $self->_get_rrd_data_source_with_defaults($ds_config);
    my $resolution = $ds_config->{graph_data_size};
    my $update_rate = $ds_config->{update_rate};
    if ($resolution eq 'normal') {
	$update_rate = 300; # 'normal' means hard coded RRD $update_rate
        push (@args,
              "RRA:AVERAGE:0.5:1:576",   # resolution 5 minutes
              "RRA:MIN:0.5:1:576",
              "RRA:MAX:0.5:1:576",
              "RRA:AVERAGE:0.5:6:432",   # 9 days, resolution 30 minutes
              "RRA:MIN:0.5:6:432",
              "RRA:MAX:0.5:6:432",
              "RRA:AVERAGE:0.5:24:540",  # 45 days, resolution 2 hours
              "RRA:MIN:0.5:24:540",
              "RRA:MAX:0.5:24:540",
              "RRA:AVERAGE:0.5:288:450", # 450 days, resolution 1 day
              "RRA:MIN:0.5:288:450",
              "RRA:MAX:0.5:288:450");
    }
    elsif ($resolution eq 'huge') {
	$update_rate = 300; # 'huge' means hard coded RRD $update_rate
        push (@args,
              "RRA:AVERAGE:0.5:1:115200",  # resolution 5 minutes, for 400 days
              "RRA:MIN:0.5:1:115200",
              "RRA:MAX:0.5:1:115200");
    } elsif ($resolution =~ /^custom (.+)/) {
        # Parsing resolution to achieve computer format as defined on the RFC :
        # FULL_NB, MULTIPLIER_1 MULTIPLIER_1_NB, ... MULTIPLIER_NMULTIPLIER_N_NB
        my @resolutions_computer = parse_custom_resolution($1, $update_rate);
        foreach my $resolution_computer(@resolutions_computer) {
            my ($multiplier, $multiplier_nb) = @{$resolution_computer};
	    # Always add 10% to the RRA size, as specified in
	    # http://munin-monitoring.org/wiki/format-graph_data_size
	    $multiplier_nb += int ($multiplier_nb / 10) || 1;
            push (@args,
                "RRA:AVERAGE:0.5:$multiplier:$multiplier_nb",
                "RRA:MIN:0.5:$multiplier:$multiplier_nb",
                "RRA:MAX:0.5:$multiplier:$multiplier_nb"
            );
        }
    }

    # Add the RRD::create prefix (filename & RRD params)
    my $heartbeat = $update_rate * 2;
    unshift (@args,
        $rrd_file,
        "--start", ($first_epoch - $update_rate),
	"-s", $update_rate,
        sprintf('DS:42:%s:%s:%s:%s',
                $ds_config->{type}, $heartbeat, $ds_config->{min}, $ds_config->{max}),
    );

    DEBUG "[DEBUG] RRDs::create @args";
    RRDs::create @args;
    if (my $ERROR = RRDs::error) {
        ERROR "[ERROR] Unable to create '$rrd_file': $ERROR";
    }
}

sub parse_custom_resolution {
	my @elems = split(',\s*', shift);
	my $update_rate = shift;

	DEBUG "[DEBUG] update_rate: $update_rate";

        my @computer_format;

	# First element is always the full resolution
	my $full_res = shift @elems;
	if ($full_res =~ m/^\d+$/) {
		# Only numeric, computer format
		unshift @elems, "1 $full_res";
	} else {
		# Human readable. Adding $update_rate in front of
		unshift @elems, "$update_rate for $full_res";
	}

        foreach my $elem (@elems) {
                if ($elem =~ m/(\d+) (\d+)/) {
                        # nothing to do, already in computer format
                        push @computer_format, [$1, $2];
                } elsif ($elem =~ m/(\w+) for (\w+)/) {
                        my $nb_sec = to_sec($1);
                        my $for_sec = to_sec($2);

			my $multiplier = int ($nb_sec / $update_rate);
                        my $multiplier_nb = int ($for_sec / $nb_sec);

			DEBUG "[DEBUG] $elem"
				. " -> nb_sec:$nb_sec, for_sec:$for_sec"
				. " -> multiplier:$multiplier, multiplier_nb:$multiplier_nb"
			;
                        push @computer_format, [$multiplier, $multiplier_nb];
                }
	}

        return @computer_format;
}

# return the number of seconds
# for the human readable format
# s : second,  m : minute, h : hour
# d : day, w : week, t : month, y : year
sub to_sec {
	my $secs_table = {
		"s" => 1,
		"m" => 60,
		"h" => 60 * 60,
		"d" => 60 * 60 * 24,
		"w" => 60 * 60 * 24 * 7,
		"t" => 60 * 60 * 24 * 31, # a month always has 31 days
		"y" => 60 * 60 * 24 * 365, # a year always has 365 days
	};

	my ($target) = @_;
	if ($target =~ m/(\d+)([smhdwty])/i) {
		return $1 * $secs_table->{$2};
	} else {
		# no recognised unit, return the int value as seconds
		return int $target;
	}
}

sub to_mul {
	my ($base, $target) = @_;
	my $target_sec = to_sec($target);
	if ($target %% $base != 0) {
		return 0;
	}

	return round($target / $base);
}

sub to_mul_nb {
	my ($base, $target) = @_;
	my $target_sec = to_sec($target);
	if ($target %% $base != 0) {
		return 0;
	}
}

sub _update_rrd_file {
    my ($self, $rrd_file, $ds_name, $ds_values) = @_;

    my $values = $ds_values->{value};

    # Some kind of mismatch between fetch and config can cause this.
    return if !defined($values);

    my ($previous_updated_timestamp, $previous_updated_value) = @{ $self->{state}{value}{"$rrd_file:42"}{current} || [ ] };
    my @update_rrd_data;
	if ($config->{"rrdcached_socket"}) {
		if (! -e $config->{"rrdcached_socket"} || ! -w $config->{"rrdcached_socket"}) {
			WARN "[WARN] RRDCached feature ignored: rrdcached socket not writable";
		} elsif($RRDs::VERSION < 1.3){
			WARN "[WARN] RRDCached feature ignored: perl RRDs lib version must be at least 1.3. Version found: " . $RRDs::VERSION;
		} else {
			# Using the RRDCACHED_ADDRESS environnement variable, as
			# it is way less intrusive than the command line args.
			$ENV{RRDCACHED_ADDRESS} = $config->{"rrdcached_socket"};
		}
	}

    my ($current_updated_timestamp, $current_updated_value) = ($previous_updated_timestamp, $previous_updated_value);
    for (my $i = 0; $i < scalar @$values; $i++) {
        my $value = $values->[$i];
        my $when = $ds_values->{when}[$i];

	# Ignore values that is not in monotonic increasing timestamp for the RRD.
	# Otherwise it will reject the whole update
	next if ($current_updated_timestamp && $when <= $current_updated_timestamp);

        if ($value =~ /\d[Ee]([+-]?\d+)$/) {
            # Looks like scientific format.  RRDtool does not
            # like it so we convert it.
            my $magnitude = $1;
            if ($magnitude < 0) {
                # Preserve at least 4 significant digits
                $magnitude = abs($magnitude) + 4;
                $value = sprintf("%.*f", $magnitude, $value);
            } else {
                $value = sprintf("%.4f", $value);
            }
        }

        # Schedule for addition
        push @update_rrd_data, "$when:$value";

	$current_updated_timestamp = $when;
	$current_updated_value = $value;
    }

    DEBUG "[DEBUG] Updating $rrd_file with @update_rrd_data";
    if ($ENV{RRDCACHED_ADDRESS} && (scalar @update_rrd_data > 32) ) {
        # RRDCACHED only takes about 4K worth of commands. If the commands is
        # too large, we have to break it in smaller calls.
        #
        # Note that 32 is just an arbitrary choosed number. It might be tweaked.
        #
        # For simplicity we only call it with 1 update each time, as RRDCACHED
        # will buffer for us as suggested on the rrd mailing-list.
        # https://lists.oetiker.ch/pipermail/rrd-users/2011-October/018196.html
        for my $update_rrd_data (@update_rrd_data) {
            RRDs::update($rrd_file, $update_rrd_data);
            # Break on error.
            last if RRDs::error;
        }
    } else {
        RRDs::update($rrd_file, @update_rrd_data);
    }

    if (my $ERROR = RRDs::error) {
        #confess Dumper @_;
        ERROR "[ERROR] In RRD: Error updating $rrd_file: $ERROR";
    }

    # Stores the previous and the current value in the state db to avoid having to do an RRD lookup if needed
    $self->{state}{value}{"$rrd_file:42"}{current} = [ $current_updated_timestamp, $current_updated_value ];
    $self->{state}{value}{"$rrd_file:42"}{previous} = [ $previous_updated_timestamp, $previous_updated_value ];

    return $current_updated_timestamp;
}

sub dump_to_file
{
	my ($filename, $obj) = @_;
	open(DUMPFILE, ">> $filename");

	print DUMPFILE Dumper($obj);

	close(DUMPFILE);
}

sub _get_default_address
{
	my ($host) = @_;

	# As suggested by madduck in D:592213
	#
	# Might I suggest that the address parameter became optional and that
	# in its absence, the node's name is treated as a FQDN?
	#
	# If the node is specified with a group name, then one could use the
	# following heuristics : $node, $group.$node
	#
	# relative names might well work but should be tried last

	my $host_name = $host->{host_name};
	my $group_name = $host->{group}->{group_name};
	if ($host_name =~ m/\./ && _does_resolve($host_name)) {
		return $host_name;
	}

	if ($group_name =~ m/\./ && _does_resolve("$group_name.$host_name")) {
		return "$group_name.$host_name";
	}

	# Note that we do NOT care if relative names resolves or not, as it is
	# our LAST chance anyway
	return $host_name;
}

sub _does_resolve
{
	my ($name) = @_;

	use Socket;

	# evaluates to "True" if it resolves
	return gethostbyname($name);
}


1;


__END__

=head1 NAME

Munin::Master::UpdateWorker - FIX

=head1 SYNOPSIS

FIX

=head1 METHODS

=over

=item B<new>

FIX

=item B<do_work>

FIX

=back

=head1 COPYING

Copyright (C) 2002-2009  Jimmy Olsen, et al.

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; version 2 dated June, 1991.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License along
  with this program; if not, write to the Free Software Foundation, Inc.,
  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.


