#!/usr/bin/perl -w

# Note - I create a bunch of classes in these tests and then change
# their valid_params() and contained_objects() lists several times.
# This isn't really supported behavior of this module, but it's
# necessary to do it in the tests.

use strict;

use Test;
BEGIN { plan tests => 50 };
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

  # Special 'container' parameter shouldn't be shared among objects
  ok ($p->{container} ne $p->{son}{container});

  # Check some of the formatting of show_containers()
  my $string = $p->show_containers;
  ok $string, '/\n  son -> StepSon/', $string;
}


{
  # Check that subclass contained_objects override superclass

  local @Superclass::ISA = qw(Class::Container);
  local @Subclass::ISA = qw(Superclass);
  'Superclass'->valid_params( foo => {isa => 'Foo'} );
  'Subclass'->valid_params(   foo => {isa => 'Bar'} );
  'Superclass'->contained_objects( foo => 'Foo' );
  'Subclass'->contained_objects(   foo => 'Bar' );
  local @Bar::ISA = qw(Foo);
  sub Foo::new { bless {}, 'Foo' }
  sub Bar::new { bless {}, 'Bar' }

  my $child = 'Subclass'->new;
  ok ref($child->{foo}), 'Bar', 'Subclass contained_object should override superclass';

  my $spec = 'Subclass'->validation_spec;
  ok $spec->{foo}{isa}, 'Bar';
}

{
  local @Top::ISA = qw(Class::Container);
  'Top'->valid_params(      document => {isa => 'Document'} );
  'Top'->contained_objects( document => 'Document',
			    collection => {class => 'Collection', delayed => 1} );
  
  local @Collection::ISA = qw(Class::Container);
  'Collection'->contained_objects( document => {class => 'Document', delayed => 1} );
  
  local @Document::ISA = qw(Class::Container);
  local @Document2::ISA = qw(Document);
  
  my $k = new Top;
  print $k->show_containers;
  ok $k->contained_class('document'), 'Document';
  my $collection = $k->create_delayed_object('collection');
  ok ref($collection), 'Collection';
  ok $collection->contained_class('document'), 'Document';

  my $string = $k->show_containers;
  ok $string, '/ collection -> Collection \(delayed\)/';
  ok $string, '/  document -> Document \(delayed\)/';

  my $k2 = new Top(document_class => 'Document2');
  print $k2->show_containers;
  ok $k2->contained_class('document'), 'Document2';
  my $collection2 = $k2->create_delayed_object('collection');
  ok ref($collection2), 'Collection';
  ok $collection2->contained_class('document'), 'Document2';

  my $string2 = $k2->show_containers;
  ok $string2, '/ collection -> Collection \(delayed\)/';
  ok $string2, '/  document -> Document2 \(delayed\)/';
}

{
  local @Top::ISA = qw(Class::Container);
  'Top'->valid_params( document => {isa => 'Document1'} );
  'Top'->contained_objects( document => 'Document1' );
  
  my $contained = 'Top'->get_contained_object_spec;
  ok  $contained->{document};
  ok !$contained->{collection}; # Shouldn't have anything left over from the last block
  
  local @Document1::ISA = qw(Class::Container);
  'Document1'->valid_params( doc1 => {type => SCALAR} );
  
  local @Document2::ISA = qw(Class::Container);
  'Document2'->valid_params( doc2 => {type => SCALAR} );
  
  my $allowed = 'Top'->allowed_params();
  ok  $allowed->{doc1};
  ok !$allowed->{doc2};
  
  $allowed = 'Top'->allowed_params( document_class => 'Document2' );
  ok  $allowed->{doc2};
  ok !$allowed->{doc1};
}

{
  local @Top::ISA = qw(Class::Container);
  'Top'->_expire_caches;
  'Top'->valid_params( document => {isa => 'Document1'} );
  'Top'->contained_objects( document => 'Document1' );
  
  local @Document1::ISA = qw(Class::Container);
  'Document1'->valid_params();
  local @Document2::ISA = qw(Document1);
  'Document2'->valid_params();
  
  my $t = new Top( document => bless {}, 'Document2' );
  ok $t;
  ok ref($t->{document}), 'Document2';
}

{
  local @Top::ISA = qw(Class::Container);
  'Top'->valid_params( document => {isa => 'Document'} );
  'Top'->contained_objects( document => 'Document' );
  
  local @Document::ISA = qw(Class::Container);
  'Document'->valid_params( sub => {isa => 'Class::Container'} );
  'Document'->contained_objects( sub => 'Sub1' );
  
  local @Sub1::ISA = qw(Class::Container);
  'Sub1'->valid_params( bar => {type => SCALAR} );
  'Sub1'->contained_objects();

  local @Sub2::ISA = qw(Class::Container);
  'Sub2'->valid_params( foo => {type => SCALAR} );
  'Sub2'->contained_objects();
  
  my $allowed = 'Top'->allowed_params();
  ok  $allowed->{document};
  ok  $allowed->{bar};
  ok !$allowed->{foo};
  
  $allowed = 'Top'->allowed_params(sub_class => 'Sub2');
  ok  $allowed->{document};
  ok !$allowed->{bar};
  ok  $allowed->{foo};
}

{
  local @Top::ISA = qw(Class::Container);
  Top->valid_params(foo => {type => SCALAR});
  Top->contained_objects();
  
  ok 'Top'->valid_params;
  ok 'Top'->valid_params->{foo}{type}, SCALAR;
}

{
  local @Top::ISA = qw(Class::Container);
  Top->valid_params(foo => {type => SCALAR}, child => {isa => 'Child'});
  Top->contained_objects(child => 'Child');
  
  local @Child::ISA = qw(Class::Container);
  Child->valid_params(bar => {type => SCALAR});
  Child->contained_objects();
  
  my $dump = Child->new(bar => 'BAR')->dump_parameters;
  ok keys(%$dump), 1;
  ok $dump->{bar}, 'BAR';
  
  $dump = Top->new(foo => 'FOO', bar => 'BAR')->dump_parameters;
  ok keys(%$dump), 2;
  ok $dump->{foo}, 'FOO';
  ok $dump->{bar}, 'BAR';
}
