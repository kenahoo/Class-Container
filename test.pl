#!/usr/bin/perl -w

use strict;

use Test;
BEGIN {plan tests => 7};
use Class::Container;

use Params::Validate qw(:types);
my $SCALAR = SCALAR;   # So we don't have to keep importing it below

# Create some boilerplate classes
{
  no strict 'refs';
  foreach my $class (qw(Parent Boy Son Slingshot Daughter)) {
    push @{$class.'::ISA'}, 'Class::Container';
  }
}

# Define the relationships
{
  package Parent;
  # Has one son and several daughters
  __PACKAGE__->valid_params( parent_val => { type => $SCALAR },
			     son => {isa => 'Son'},
			   );
  __PACKAGE__->contained_objects( son => 'Son',
				  daughter => {delayed => 1,
					       class => 'Daughter'});
}

{
  package Boy;
  __PACKAGE__->valid_params( eyes => { default => 'brown', type => $SCALAR },
			     toy => {isa => 'Slingshot'});
  __PACKAGE__->contained_objects( toy => 'Slingshot' );
}

{
  package Son;
  push @Son::ISA, 'Boy';
  __PACKAGE__->valid_params( mood => { type => $SCALAR } );
  __PACKAGE__->make_accessors(':all');
}

{
  package Slingshot;
  __PACKAGE__->valid_params( weapon => { default => 'rock', type => $SCALAR } );
}

{
  package Daughter;
  __PACKAGE__->valid_params( hair => { default => 'short' } );
}

# Try making an object
ok eval {new Daughter(hair => 'long')};

# Should fail, missing required parameter
ok !eval {new Parent()};

my %args = (parent_val => 7,
	    mood => 'bubbly');

# Try creating top-level object
ok eval {new Parent(%args)};

# Make sure sub-objects are created with proper values
ok eval {Parent->new(%args)->{son}->{mood} eq 'bubbly'};

# Try using accessor
ok eval {Parent->new(%args)->{son}->mood eq 'bubbly'};



# Create a delayed object
ok eval {my $p = new Parent(%args);
	 $p->create_delayed_object('daughter')};

# Create a delayed object with parameters
ok eval {my $p = new Parent(%args);
	 my $d = $p->create_delayed_object('daughter', hair => 'short');
	 $d->{hair} eq 'short';
       };
