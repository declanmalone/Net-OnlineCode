package Net::OnlineCode::GraphDecoder;

use strict;
use warnings;

use Carp;

use vars qw($VERSION);

$VERSION = '0.02';

use constant DEBUG => 0;
use constant TRACE => 0;
use constant ASSERT => 1;	# Enable extra-paranoid checks

# Implements a data structure for decoding the bipartite graph (not
# needed for encoding). Note that this does not store Block IDs or any
# actual block data and, consequently, does not do any XORs. Those
# tasks are left to the calling object/programs. The reason for this
# separation is to allow us to focus here on the graph algorithm
# itself and leave the implementation details (ie, synchronising the
# random number generator and storing and XORing blocks) to the user.

# Simple low-level operations to improve readability (and allow for
# single debugging points)

sub mark_as_unsolved {
  my ($self,$node) = @_;

  print "Marking block $node as unsolved\n" if DEBUG;
  $self->{solved}->[$node] = 0;
}

sub mark_as_solved {
  my ($self,$node) = @_;

  if (0 and DEBUG) {		# wasn't a bug after all
    my ($parent,$line) = (caller(1)) [3,2];
    print "mark_as_solved called from sub $parent, line $line\n";
  }

  print "Marking block $node as solved\n" if DEBUG;

  $self->{solved}->[$node] = 1;
}


sub add_edge {

  my ($self,$high,$low) = @_;

  # moving to up and down edges means order is important
  if (ASSERT) {
    die "add_edge: from must be greater than to" unless $high > $low;
  }

  my $mblocks = $self->{mblocks};

  $self->{n_edges}->[$low]->{$high} = undef;
  push @{$self->{v_edges}->[$high-$mblocks]}, $low;
  
}

sub delete_up_edge {

  my ($self,$high,$low) = @_;

  print "Deleting edge $high, $low\n" if DEBUG;

  # I might also want to incorporate updates to the count of unsolved
  # edges here, and that would require that $high is greater than $low:
  if (ASSERT and $low >= $high) {
    die "delete_edge: 1st arg $high not greater than 2nd arg $low\n";
  }

  delete $self->{n_edges}->[$low]->{$high};

  # my counting arrays don't include entries for message blocks
  my $mblocks = $self->{mblocks};
  if ($high >= $mblocks) {
    die "Count for node $high went negative\n" unless
      ($self->{edge_count}->[$high - $mblocks])--;
  }

}


# Rather than referring to left and right neighbours, I used the
# ordering of the array and higher/lower to indicate the relative
# positions of check, auxiliary and message blocks, respectively. The
# ordering is:
#
#   message < auxiliary < check	
#
# Using this ordering, message blocks are "lower" than auxiliary and
# check blocks and vice-versa. Equivalently, message blocks have no
# "lower" nodes and check blocks have no "higher" nodes, while
# auxiliary blocks have both.
#
# This can be used as a mnemonic: there is nothing lower than message
# blocks since without them, the sender would not be able to construct
# auxiliary or check blocks and the receiver would not be able to
# receive anything. Equivalently, think of aux and check blocks as
# "higher-level" constructs moving "up" the software stack.

sub new {
  my $class = shift;

  # constructor starts off knowing only about auxiliary block mappings
  # my ($mblocks, $ablocks, $auxlist, $expand_aux) = @_;
  my ($mblocks, $ablocks, $auxlist) = @_;

  unless ($mblocks >= 1) {
    carp "$class->new: argument 1 (mblocks) invalid\n";
    return undef;
  }

  unless ($ablocks >= 1) {
    carp "$class->new: argument 2 (ablocks) invalid\n";
    return undef;
  }

  unless (ref($auxlist) eq "ARRAY") {
    carp "$class->new: argument 3 (auxlist) not a list reference\n";
    return undef;
  }

  unless (@$auxlist == $mblocks + $ablocks) {
    carp "$class->new: auxlist does not have $mblocks + $ablocks entries\n";
    return undef;
  }

  my $self =
    {
     mblocks    => $mblocks,
     ablocks    => $ablocks,
     coblocks   => $mblocks + $ablocks, # "composite"
#     edges          => [],	# stores both check, aux block mappings

     # Replace single edges list with egdes_n (up) and v_edges (down)
     # lists. Up edges will continue to be tracked as a list of
     # hashes, but down edges will move to being a list of lists since
     # we never need to delete single edges from it. These lists will
     # also be indexed differently: the up edge list starts with
     # message blocks (as before) but the down edge list starts with
     # aux blocks (since message blocks have no down edges)
     v_edges        => [],	# down: mnemonic "v" points down
     n_edges        => [],	# up: mnemonic "n" is like upside-down "v"

     
     edge_count     => [],	# count unsolved "v" edges (aux, check only)
     edge_count_x   => [],	# "transparent" edge count (check only)
     solved         => [],
     nodes          => $mblocks + $ablocks, # running count
     xor_list       => [],
     unresolved     => [],      # queue of nodes needing resolution

     unsolved_count => $mblocks,# count unsolved message blocks
     done           => 0,       # all message nodes decoded?
    };

  bless $self, $class;

  # set up basic structures
  for my $i (0..$mblocks + $ablocks - 1) {
    # mark blocks as unsolved, and having no XOR expansion
    $self->mark_as_unsolved($i);
    $self->{xor_list} ->[$i] = [];
    push @{$self->{n_edges}}, {};
    push @{$self->{v_edges}}, [] if $i >= $mblocks;
  }

  # set up edge structure (convert from auxlist's list of lists)
  for my $i (0..$mblocks -1) {
    for my $j (@{$auxlist->[$i]}) {
      $self->{n_edges}->[$i]->{$j} = undef;
    }
  }
  for my $i ($mblocks .. $mblocks + $ablocks - 1) {
    push @{$self->{v_edges}->[$i-$mblocks]}, @{$auxlist->[$i]}
  }


  # set up edge counts for aux blocks
  for my $i (0 .. $ablocks - 1) {
    push @{$self->{edge_count}}, scalar(@{$auxlist->[$mblocks + $i]});
  }

  $self;
}

sub is_message {
  my ($self, $i) = @_;
  return ($i < $self->{mblocks});
}

sub is_auxiliary {
  my ($self, $i) = @_;
  return (($i >= $self->{mblocks}) && ($i < $self->{coblocks}));
}

sub is_composite {
  my ($self, $i) = @_;
  return ($i < $self->{coblocks});
}

sub is_check {
  my ($self, $i) = @_;
  return ($i >= $self->{coblocks});
}




# the decoding algorithm is divided into two steps. The first adds a
# new check block to the graph, while the second resolves the graph to
# discover newly solvable auxiliary or message blocks.

# Decoder object creates a check block and we store it in the graph
# here

sub add_check_block {
  my $self = shift;
  my $nodelist = shift;

  unless (ref($nodelist) eq "ARRAY") {
    croak ref($self) . "->add_check_block: nodelist should be a listref!\n";
  }

  # The original code that I was using here would create a new entry
  # in the graph structure regardless of whether the check block
  # actually added any new information or not. Later, I modified this
  # to only add checkblocks that add new info to the graph.
  # Unfortunately, that led to a (fairly trivial) bug in my codec code
  # where it failed to check the return value of
  # Decoder->accept_check_block and got confused about its check block
  # array.
  #
  # Given the choice of making more work for the calling program (and
  # making them more error-prone) and using slightly more memory, I've
  # decided that the latter option is best. So this routine will now
  # revert to the original method and always add a check block,
  # regardless of whether it adds new information or not.

  my $node = $self->{nodes}++;

  # set up new array elements
  #push @{$self->{xor_hash}}, { $node => undef };
  push @{$self->{xor_list}}, [$node];
  $self->mark_as_solved($node);
  push @{$self->{v_edges}}, [];

  my $solved = 0;		# just used for debug output
  my @solved = ();		# ditto
  my $unsolved_count = 0;

  # set up graph edges and/or xor list
  foreach my $i (@$nodelist) {
    if ($self->{solved}->[$i]) {
      ++$solved;
      push @solved, $i;
      # solved, so add node $i to our xor list
      push @{$self->{xor_list}->[$node]}, $i;
      
    } else {
      # unsolved, so add edge to $i
      $self->add_edge($node,$i);
      ++$unsolved_count;
    }
  }
  push @{$self->{edge_count}}, $unsolved_count;

  # TODO: also expand any aux blocks and create separate edges
  # pointing directly to message blocks

  if (DEBUG) {
    print "New check block $node: " . (join " ", @$nodelist) . "\n";
    print "of which, there are $solved solved node(s): " . 
      (join " ", @solved) . "\n";
  }

  # mark node as pending resolution
  push @{$self->{unresolved}}, $node;

  # return index of newly created node
  return $node;

}

# Graph resolution. Resolution of the graph has a "downward" part
# (resolve()) where nodes with one unsolved edge solve a message or
# aux block, and an upward part (cascade()) that works up from a
# newly-solved node.


# an unsolved aux block can be solved if it has no unsolved neighbours
sub aux_rule {
  my ($self, $from, $solved) = @_;

  if (DEBUG) {
    print "Solving aux block $from based on aux rule\n";
    print "XORing expansion of these solved message blocks: " . 
      (join " ", @$solved) . "\n";
  }

  $self->mark_as_solved($from);

  push @{$self->{xor_list}->[$from]}, @$solved;
  for my $to (@$solved) {
    # don't call delete_edge: unsolved counts would be wrong
    delete $self->{n_edges}->[$to]->{$from};
  }
  $self->{v_edges}->[$from - $self->{mblocks}] = [];
}


# Work up from a newly-solved message or auxiliary block

sub cascade {
  my ($self,$node) = @_;

  my $mblocks = $self->{mblocks};
  my $ablocks = $self->{ablocks};
  my $pending = $self->{unresolved};
#  my @higher_nodes = grep { $_ > $node } $self->edge_list($node);
  my @higher_nodes = keys %{$self->{n_edges}->[$node]};

  if (DEBUG) {
    if (@higher_nodes) {
      print "Solved node $node cascades to nodes " . (join " ", @higher_nodes)
	. "\n\n";
    } else {
      print "Solved node $node has no cascade\n\n";
    }
  }

  # update the count of unsolved edges.
  for my $to (@higher_nodes) {
    ($self->{edge_count}->[$to - $mblocks])--;
  }
  push @$pending, @higher_nodes;

}

# Work down from a check or auxiliary block
sub resolve {

  # now doesn't take any arguments (uses unresolved queue instead)
  my ($self, @junk) = @_;

  if (ASSERT and scalar(@junk)) {
    die "resolve doesn't take arguments\n";
  }

  my $pending = $self->{unresolved};

  # Indicate to caller that our queue is empty and they need to add
  # another check block (see example code at top of Decoder man page)
  unless (@$pending) {
    return ($self->{done});
  }

  my $start_node = $pending->[0];

  if (ASSERT and $start_node < $self->{mblocks}) {
    croak ref($self) . "->resolve: start node '$start_node' is a message block!\n";
  }

  my @newly_solved = ();
  my $mblocks = $self->{mblocks};
  my $ablocks = $self->{ablocks};

  # exit if all message blocks are already solved
  unless ($self->{unsolved_count}) {
    $self->{done}=1;
    return (1);
  }

  while (@$pending) {

    my ($from, $to) = (shift @$pending);

    unless ($self->is_auxiliary($from) or $self->{solved}->[$from]) {
      print "skipping unproductive node $from\n" if DEBUG;
      next;
    }

    my @solved_nodes = ();
    my @unsolved_nodes;
    my $count_unsolved = 0;	# size of above array

    if (DEBUG) {
      print "\nStarting resolve at $from; XOR list is " . 
	(join ", ", @{$self->{xor_list}->[$from]}) . "\n";
    }

    next unless $self->{edge_count}->[$from - $mblocks] < 2 
      or $self->is_auxiliary($from);

#    my @lower_nodes = grep { $_ < $from } $self->edge_list($from);
    my @lower_nodes = @{$self->{v_edges}->[$from-$mblocks]};

    foreach $to (@lower_nodes) {
      if ($self->{solved}->[$to]) {
	push @solved_nodes, $to;
      } else {
	# don't need this optimisation any more since we should only
	# ever have unsolved count < 2 now
	#
	# last if ++$count_unsolved > 1;
	++$count_unsolved;
	push @unsolved_nodes, $to;
      }
    }

    # make sure that both ways of counting unsolved agree
    if (0 and ASSERT) {
      die "unsolved count mismatch\n" if
	$count_unsolved != $self->{edge_count}->[$from - $mblocks];
    }

    print "Unsolved lower degree: $count_unsolved\n" if DEBUG;

    if ($count_unsolved == 0) {

      if ($self->is_check($from)) {

	next;			# we could free this node's memory
                                # here if we wanted
      } else {

	if ($self->{solved}->[$from]) {
	  # was previously solved (by propagation rule), so we don't need to
	  # solve again. Delete the graph edges (since they're all solved too)

	  foreach (@solved_nodes) { 
	    delete $self->{n_edges}->[$_]->{$from};
	  }
	  $self->{v_edges}->[$from - $self->{mblocks}] = []

	} else {
	  # otherwise solve it here by expanding message blocks' xor lists
	  $self->aux_rule($from, \@solved_nodes);

	  print "Aux rule solved auxiliary block $from completely\n" if DEBUG;

	  push @newly_solved, $from;

	  $self->cascade($from);
	}
      }

    } elsif ($count_unsolved == 1) {

      next unless $self->{solved}->[$from];

      # Propagation rule matched
      $to = shift @unsolved_nodes;

      print "Node $from solves node $to\n" if DEBUG;

      $self->mark_as_solved($to);
      push @newly_solved, $to;

      # create XOR list for the newly-solved node, comprising this
      # node's XOR list plus all nodes in the @solved array

      if (DEBUG) {
	print "Node $from has XOR list: " . 
	  (join ", ", @{$self->{xor_list}->[$from]}) . "\n";
      }
						   
      $self->delete_up_edge($from,$to);
      push @{$self->{xor_list}->[$to]}, @{$self->{xor_list}->[$from]};
      push @{$self->{xor_list}->[$to]}, @solved_nodes;
      foreach my $i (@solved_nodes) {
	delete $self->{n_edges}->[$i]->{$from};
      }
      $self->{v_edges}->[$from - $self->{mblocks}] = [];

      # Update global structure and decide if we're done

      if ($to < $mblocks) {
	print "Solved message block $to completely\n" if DEBUG;
	unless (--($self->{unsolved_count})) {
	  $self->{done} = 1;
	  # comment out next two lines to continue decoding just in
	  # case there's a bug later
	  @$pending = ();
	  last;			# finish searching
	}

      } else {
	print "Solved auxiliary block $to completely\n" if DEBUG;
	push @$pending, $to;
      }

      # Cascade to potentially find more solvable blocks
      $self->cascade($to);

    }



  }

  return ($self->{done}, @newly_solved);

}


1;

__END__
