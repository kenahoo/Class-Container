#!/usr/bin/perl -w

use strict;

use Test;
BEGIN { plan tests => 15 };
use Class::Container;

use Params::Validate qw(:types);
my $SCALAR = SCALAR;   # So we don't have to keep importing it below

# Create some boilerplate classes
{
  no strict 'refs';
  foreach my $class (qw(Parent Boy Toy Daughter)) {
    push @{$class.'::ISA'}, 'Class::Container';
  }
}

# Define the relationships
{
  package Parent;
  push @Parent::ISA, 'Foo';  # Make sure it works with non-container superclasses
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
			     toy => {isa => 'Toy'});
  __PACKAGE__->contained_objects( toy => 'Slingshot',
				  other_toys => {class => 'Toy', delayed => 1},
				);
}

{
  package Son;
  push @Son::ISA, 'Boy';
  __PACKAGE__->valid_params( mood => { type => $SCALAR } );
}

{
  package Slingshot;
  push @Slingshot::ISA, 'Toy';
  __PACKAGE__->valid_params( weapon => { default => 'rock', type => $SCALAR } );
}

{
  package Daughter;
  __PACKAGE__->valid_params( hair => { default => 'short' } );
}

{
  package StepDaughter;
  push @StepDaughter::ISA, 'Daughter';
  __PACKAGE__->valid_params( toy => {isa => 'Toy'} );
  __PACKAGE__->contained_objects( toy => { class => 'Toy'},
				  other_toys => {class => 'Toy', delayed => 1},
				);
}
{
  push @StepSon::ISA, 'Son';
  push @Ball::ISA, 'Toy';
  push @Streamer::ISA, 'Toy';
}

# Try making an object
ok eval {new Daughter(hair => 'long')};
warn $@ if $@;

# Should fail, missing required parameter
ok !eval {new Parent()};

my %args = (parent_val => 7,
	    mood => 'bubbly');

# Try creating top-level object
ok eval {new Parent(%args)};
warn $@ if $@;

# Make sure sub-objects are created with proper values
ok eval {Parent->new(%args)->{son}->{mood} eq 'bubbly'};
warn $@ if $@;


# Create a delayed object
ok eval {my $p = new Parent(%args);
	 $p->create_delayed_object('daughter')};
warn $@ if $@;

# Create a delayed object with parameters
ok eval {my $p = new Parent(%args);
	 my $d = $p->create_delayed_object('daughter', hair => 'short');
	 $d->{hair} eq 'short';
       };
warn $@ if $@;

# Make sure error messages contain the name of the class
eval {new Daughter(foo => 'invalid')};
ok $@, '/Daughter/', $@;

# Make sure we can override class names
{
  ok my $p = eval {new Parent(mood => 'foo', parent_val => 1,
			      daughter_class => 'StepDaughter',
			      toy_class => 'Ball',
			      other_toys_class => 'Streamer',
			      son_class => 'StepSon')};
  warn $@ if $@;

  ok my $d = eval {$p->create_delayed_object('daughter')};
  warn $@ if $@;

  ok ref($d), 'StepDaughter';
  ok ref($p->{son}), 'StepSon';

  # Note - if one of these fails and the other succeeds, then we're
  # not properly passing 'toy_class' to both son & daughter classes.
  ok ref($d->{toy}), 'Ball';
  ok ref($p->{son}{toy}), 'Ball';

  ok $d->delayed_object_class('other_toys'), 'Streamer';
  ok $p->{son}->delayed_object_class('other_toys'), 'Streamer';
}


