package Class::Container;

$VERSION = '0.07';
$VERSION = eval $VERSION if $VERSION =~ /_/;

my $HAVE_WEAKEN = 0;
BEGIN {
  eval {
    require Scalar::Util;
    Scalar::Util->import('weaken');
    $HAVE_WEAKEN = 1;
  };
  
  *weaken = sub {} unless defined &weaken;
}

use strict;

# The create_contained_objects() method lets one object
# (e.g. Compiler) transparently create another (e.g. Lexer) by passing
# creator parameters through to the created object.
#
# Any auto-created objects should be declared in a class's
# %CONTAINED_OBJECTS hash.  The keys of this hash are objects which
# can be created and the values are the default classes to use.

# For instance, the key 'lexer' indicates that a 'lexer' parameter
# should be silently passed through, and a 'lexer_class' parameter
# will trigger the creation of an object whose class is specified by
# the value.  If no value is present there, the value of 'lexer' in
# the %CONTAINED_OBJECTS hash is used.  If no value is present there,
# no contained object is created.
#
# We return the list of parameters for the creator.  If contained
# objects were auto-created, their creation parameters aren't included
# in the return value.  This lets the creator be totally ignorant of
# the creation parameters of any objects it creates.

use Params::Validate qw(:all);
Params::Validate::validation_options( on_fail => sub { die @_ } );

my %VALID_PARAMS = ();
my %CONTAINED_OBJECTS = ();
my %VALID_CACHE = ();
my %CONTAINED_CACHE = ();

sub new
{
    my $proto = shift;
    my $class = ref($proto) || $proto;
    return bless scalar validate_with(
				      params => $class->create_contained_objects(@_),
				      spec   => $class->validation_spec,
				      called => "$class->new()",
				     ), $class;
}

sub all_specs
{
    require B::Deparse;
    my %out;

    foreach my $class (sort keys %VALID_PARAMS)
    {
	my $params = $VALID_PARAMS{$class};

	foreach my $name (sort keys %$params)
	{
	    my $spec = $params->{$name};
	    my ($type, $default);
	    if ($spec->{isa}) {
		my $obj_class;

		$type = 'object';

		if (exists $CONTAINED_OBJECTS{$class}{$name}) {
		    $default = "$CONTAINED_OBJECTS{$class}{$name}{class}->new";
		}
	    } else {
		($type, $default) = ($spec->{parse}, $spec->{default});
	    }

	    if (ref($default) eq 'CODE') {
		$default = 'sub ' . B::Deparse->new()->coderef2text($default);
		$default =~ s/\s+/ /g;
	    } elsif (ref($default) eq 'ARRAY') {
		$default = '[' . join(', ', map "'$_'", @$default) . ']';
	    } elsif (ref($default) eq 'Regexp') {
		$type = 'regex';
		$default =~ s,^\(\?(\w*)-\w*:(.*)\),/$2/$1,;
		$default = "qr$default";
	    }
	    unless ($type) {
	      # Guess from the validation spec
	      $type = ($spec->{type} & ARRAYREF ? 'list' :
		       $spec->{type} & SCALAR   ? 'string' :
		       $spec->{type} & CODEREF  ? 'code' :
		       $spec->{type} & HASHREF  ? 'hash' :
		       undef);  # Oh well
	    }

	    my $descr = $spec->{descr} || '(No description available)';
	    $out{$class}{valid_params}{$name} = { type => $type,
						  pv_type => $spec->{type},
						  default => $default,
						  descr => $descr,
						  required => defined $default || $spec->{optional} ? 0 : 1,
						  public => exists $spec->{public} ? $spec->{public} : 1,
						};
	}

	$out{$class}{contained_objects} = {};
	next unless exists $CONTAINED_OBJECTS{$class};
	my $contains = $CONTAINED_OBJECTS{$class};

	foreach my $name (sort keys %$contains)
	{
	    $out{$class}{contained_objects}{$name} 
	      = {map {$_, $contains->{$name}{$_}} qw(class delayed descr)};
	}
    }

    return %out;
}

sub show_containers {
  my $self = shift;
  my $name = shift;
  my %args = (indent => '', @_);

  $name = defined($name) ? "$name -> " : "";

  my $out = "$args{indent}$name$self";
  $out .= " (delayed)" if $args{delayed};
  $out .= "\n";
  return $out unless $self->isa(__PACKAGE__);

  my $specs = ref($self) ? $self->{container}{contained} : $self->get_contained_object_spec;

  while (my ($name, $spec) = each %$specs) {
    my $class = $args{args}{"${name}_class"} || $spec->{class};
    $self->_load_module($class);

    if ($class->isa(__PACKAGE__)) {
      $out .= $class->show_containers($name,
				      indent => "$args{indent}  ",
				      args => $spec->{args},
				      delayed => $spec->{delayed});
    } else {
      $out .= "$args{indent}  $name -> $class\n";
    }
  }

  return $out;
}

sub _expire_caches {
  %VALID_CACHE = %CONTAINED_CACHE = ();
}

sub valid_params {
  my $class = shift;
  if (@_) {
    $class->_expire_caches;
    $VALID_PARAMS{$class} = @_ == 1 && !defined($_[0]) ? {} : {@_};
  }
  return $VALID_PARAMS{$class};
}

sub contained_objects
{
    my $class = shift;
    $class->_expire_caches;
    $CONTAINED_OBJECTS{$class} = {};
    while (@_) {
      my ($name, $spec) = (shift, shift);
      $CONTAINED_OBJECTS{$class}{$name} = ref($spec) ? $spec : { class => $spec };
    }
}

sub container {
  my $self = shift;
  die "The ", ref($self), "->container() method requires installation of Scalar::Utils" unless $HAVE_WEAKEN;
  return $self->{container}{container};
}

sub call_method {
  my ($self, $name, $method, @args) = @_;
  
  my $class = $self->contained_class($name)
    or die "Unknown contained item '$name'";

  $self->_load_module($class);
  return $class->$method( %{ $self->{container}{contained}{$name}{args} }, @args );
}

# Accepts a list of key-value pairs as parameters, representing all
# parameters taken by this object and its descendants.  Returns a list
# of key-value pairs representing *only* this object's parameters.
sub create_contained_objects
{
    # Typically $self doesn't exist yet, $_[0] is a string classname
    my $class = shift;

    my $c = $class->get_contained_object_spec;
    return {@_, container => {}} unless %$c;
    
    my %args = @_;

    # This one is special, don't pass to descendants
    my $container_stuff = delete($args{container}) || {};

    keys %$c; # Reset the iterator - why can't I do this in get_contained_object_spec??
    my %contained_args;
    my %to_create;

    while (my ($name, $spec) = each %$c) {
      # Figure out exactly which class to make an object of
      my ($contained_class, $c_args) = $class->_get_contained_args($name, \%args);
      @contained_args{ keys %$c_args } = ();  # Populate with keys
      $to_create{$name}{class} = $contained_class;
      $to_create{$name}{args} = $c_args;
    }
    
    while (my ($name, $spec) = each %$c) {
      # This delete() needs to be outside the previous loop, because
      # multiple contained objects might need to see it
      delete $args{"${name}_class"};

      if ($spec->{delayed}) {
	$container_stuff->{contained}{$name} = $to_create{$name};
	$container_stuff->{contained}{$name}{delayed} = 1;
      } else {
	$args{$name} ||= $to_create{$name}{class}->new(%{$to_create{$name}{args}});
	$container_stuff->{contained}{$name}{class} = ref $args{$name};
      }
    }

    # Delete things that we're not going to use - things that are in
    # our contained object specs but not in ours.
    my $my_spec = $class->validation_spec;
    delete @args{ grep {!exists $my_spec->{$_}} keys %contained_args };

    $args{container} = $container_stuff;
    return \%args;
}

sub create_delayed_object
{
  my ($self, $name) = (shift, shift);
  die "Unknown delayed item '$name'" unless $self->{container}{contained}{$name}{delayed};

  if ($HAVE_WEAKEN) {
    push @_, container => {container => $self};
    weaken $_[-1]->{container};
  }
  return $self->call_method($name, 'new', @_);
}

sub delayed_object_class
{
    my $self = shift;
    my $name = shift;
    die "Unknown delayed item '$name'"
	unless $self->{container}{contained}{$name}{delayed};

    return $self->{container}{contained}{$name}{class};
}

sub contained_class
{
    my ($self, $name) = @_;
    die "Unknown contained item '$name'"
	unless my $spec = $self->{container}{contained}{$name};
    return $spec->{class};
}

sub delayed_object_params
{
    my ($self, $name, %args) = @_;
    die "Unknown delayed object '$name'"
	unless $self->{container}{contained}{$name}{delayed};

    if (keys %args)
    {
	@{ $self->{container}{contained}{$name}{args} }{ keys %args } = values %args;
    }

    return %{ $self->{container}{contained}{$name}{args} };
}

# Everything the specified contained object will accept, including
# parameters it will pass on to its own contained objects.
sub _get_contained_args
{
    my ($class, $name, $args) = @_;
    
    my $spec = $class->get_contained_object_spec->{$name}
      or die "Unknown contained object '$name'";

    my $contained_class = $args->{"${name}_class"} || $spec->{class};
    die "Invalid class name '$contained_class'"
	unless $contained_class =~ /^[\w:]+$/;

    $class->_load_module($contained_class);
    return ($contained_class, {}) unless $contained_class->isa(__PACKAGE__);

    my $allowed = $contained_class->allowed_params($args);

    my %contained_args;
    foreach (keys %$allowed) {
	$contained_args{$_} = $args->{$_} if exists $args->{$_};
    }
    return ($contained_class, \%contained_args);
}

sub _load_module {
    my ($self, $module) = @_;
    
    unless ( eval { $module->can('new') } )
    {
	no strict 'refs';
	eval "use $module";
	die $@ if $@;
    }
}

sub allowed_params
{
    my $class = shift;
    my $args = ref($_[0]) ? shift : {@_};
    
    # Strategy: the allowed_params of this class consists of the
    # validation_spec of this class, merged with the allowed_params of
    # all contained classes.  The specific contained classes may be
    # affected by arguments passed in, like 'interp' or
    # 'interp_class'.  A parameter like 'interp' doesn't add anything
    # to our allowed_params (because it's already created) but
    # 'interp_class' does.

    my $c = $class->get_contained_object_spec;
    my %p = %{ $class->validation_spec };

    foreach my $name (keys %$c)
    {
	# Can accept a 'foo' parameter - should already be in the validation_spec.
	# Also, its creation parameters should already have been extracted from $args,
	# so don't extract any parameters.
	next if exists $args->{$name};
	
	# Figure out what class to use for this contained item
	my $contained_class;
	if ( exists $args->{"${name}_class"} ) {
	  $contained_class = $args->{"${name}_class"};
	  $p{"${name}_class"} = { type => SCALAR, parse => 'string' };  # Add to spec
	} else {
	  $contained_class = $c->{$name}{class};
	}
	
	# We have to make sure it is loaded before we try calling allowed_params()
	$class->_load_module($contained_class);
	next unless $contained_class->can('allowed_params');
	
	my $subparams = $contained_class->allowed_params($args);
	
	foreach (keys %$subparams) {
	  $p{$_} ||= $subparams->{$_};
	}
    }

    return \%p;
}

sub _iterate_ISA {
  my ($class, $look_in, $cache_in, $add_container) = @_;

  return $cache_in->{$class} if $cache_in->{$class};

  my %out;
  
  no strict 'refs';
  foreach my $superclass (@{ "${class}::ISA" }) {
    next unless $superclass->isa(__PACKAGE__);
    my $superparams = $superclass->_iterate_ISA($look_in, $cache_in, $add_container);
    @out{keys %$superparams} = values %$superparams;
  }
  if (my $x = $look_in->{$class}) {
    @out{keys %$x} = values %$x;
  }
  
  $out{container} = { type => HASHREF } if $add_container;  # Urgh

  return $cache_in->{$class} = \%out;
}

sub get_contained_object_spec {
  return (ref($_[0]) || shift)->_iterate_ISA(\%CONTAINED_OBJECTS, \%CONTAINED_CACHE);
}

sub validation_spec {
  return (ref($_[0]) || shift)->_iterate_ISA(\%VALID_PARAMS, \%VALID_CACHE, 1);
}

1;

__END__

=head1 NAME

Class::Container - Glues object frameworks together transparently

=head1 SYNOPSIS

 package Candy;
 
 use Class::Container;
 use base qw(Class::Container);
 
 __PACKAGE__->valid_params
   (
    color  => {default => 'green'},
    flavor => {default => 'hog'},
   );
 
 __PACKAGE__->contained_objects
   (
    frog       =>  'Food::TreeFrog',
    vegetables => { class => 'Food::Ingredient',
                    delayed => 1 },
   );
 
 sub new {
   my $package = shift;
   
   # Build $self, possibly passing elements of @_ to
   # 'frog' or 'vegetables' objects
   my $self = $package->SUPER::new(@_);

   ... do any more initialization here ...
   return $self;
 }

=head1 DESCRIPTION

This class facilitates building frameworks of several classes that
inter-operate.  It was first designed and built for C<HTML::Mason>, in
which the Compiler, Lexer, Interpreter, Resolver, Component, Buffer,
and several other objects must create each other transparently,
passing the appropriate parameters to the right class, possibly
substituting their own subclass for any of these objects.

The main features of C<Class::Container> are:

=over 4

=item *

Declaration of parameters used by each member in a class
framework

=item *

Transparent passing of constructor parameters to the class
that needs them

=item *

Ability to create one (automatic) or many (manual) contained
objects automatically and transparently

=back

=head2 Scenario

Suppose you've got a class called C<Parent>, which creates object of
the class C<Child>, which in turn creates objects of the class
C<GrandChild>.  Each class accepts a set of named parameters in its
C<new()> method.  Without using C<Class::Container>, C<Parent> will
have to know all the parameters that C<Child> takes, and C<Child> will
have to know all the parameters that C<GrandChild> takes.  And some of
the parameters accepted by C<Parent> will really control aspects of
C<Child> or C<GrandChild>.  Likewise, some of the parameters accepted
by C<Child> will really control aspects of C<GrandChild>.  So, what
happens when you decide you want to use a C<GrandDaughter> class
instead of the generic C<GrandChild>?  C<Parent> and C<Child> must be
modified accordingly, so that any additional parameters taken by
C<GrandDaughter> can be accommodated.  This is a pain - the kind of
pain that object-oriented programming was supposed to shield us from.

Now, how can C<Class::Container> help?  Using C<Class::Container>,
each class (C<Parent>, C<Child>, and C<GrandChild>) will declare what
arguments they take, and declare their relationships to the other
classes (C<Parent> creates/contains a C<Child>, and C<Child>
creates/contains a C<GrandChild>).  Then, when you create a C<Parent>
object, you can pass C<< Parent->new() >> all the parameters for all
three classes, and they will trickle down to the right places.
Furthermore, C<Parent> and C<Child> won't have to know anything about
the parameters of its contained objects.  And finally, if you replace
C<GrandChild> with C<GrandDaughter>, no changes to C<Parent> or
C<Child> will likely be necessary.

=head1 METHODS

=head2 new()

Any class that inherits from C<Class::Container> should also inherit
its C<new()> method.  You can do this simply by omitting it in your
class, or by calling C<SUPER::new(@_)> as indicated in the SYNOPSIS.
The C<new()> method ensures that the proper parameters and objects are
passed to the proper constructor methods.

At the moment, the only possible constructor method is C<new()>.  If
you need to create other constructor methods, they should also call
C<SUPER::new()>, or possibly even your class's C<new()> method.

=head2 __PACKAGE__->contained_objects()

This class method is used to register what other objects, if any, a given
class creates.  It is called with a hash whose keys are the parameter
names that the contained class's constructor accepts, and whose values
are the default class to create an object of.

For example, consider the C<HTML::Mason::Compiler> class, which uses
the following code:

  __PACKAGE__->contained_objects( lexer => 'HTML::Mason::Lexer' );

This defines the relationship between the C<HTML::Mason::Compiler>
class and the class it creates to go in its C<lexer> slot.  The
C<HTML::Mason::Compiler> class "has a" C<lexer>.  The C<<
HTML::Mason::Compiler->new() >> method will accept a C<lexer>
parameter and, if no such parameter is given, an object of the
C<HTML::Mason::Lexer> class should be constructed.

We implement a bit of magic here, so that if C<<
HTML::Mason::Compiler->new() >> is called with a C<lexer_class>
parameter, it will load the indicated class (presumably a subclass of
C<HTML::Mason::Lexer>), instantiate a new object of that class, and
use it for the Compiler's C<lexer> object.  We're also smart enough to
notice if parameters given to C<< HTML::Mason::Compiler->new() >>
actually should go to the C<lexer> contained object, and it will make
sure that they get passed along.

Furthermore, an object may be declared as "delayed", which means that
an object I<won't> be created when its containing class is constructed.
Instead, these objects will be created "on demand", potentially more
than once.  The constructors will still enjoy the automatic passing of
parameters to the correct class.  See the C<create_delayed_object()>
for more.

To declare an object as "delayed", call this method like this:

  __PACKAGE__->contained_objects( train => { class => 'Big::Train',
                                             delayed => 1 } );

=head2 __PACKAGE__->valid_params(...)

Specifies the parameters accepted by this class's C<new()> method as a
set of key/value pairs.  Any parameters accepted by a
superclass/subclass will also be accepted, as well as any parameters
accepted by contained objects.  This method is a get/set accessor
method, so it returns a reference to a hash of these key/value pairs.
As a special case, if you wish to set the valid params to an empty set
and you previously set it to a non-empty set, you may call 
C<< __PACKAGE__->valid_params(undef) >>.

C<valid_params()> is called with a hash that contains parameter names
as its keys and validation specifications as values.  This validation
specification is largely the same as that used by the
C<Params::Validate> module, because we use C<Params::Validate>
internally.

As an example, consider the following situation:

  use Class::Container;
  use Params::Validate qw(:types);
  __PACKAGE__->valid_params
      (
       allow_globals        => { type => ARRAYREF, parse => 'list',   default => [] },
       default_escape_flags => { type => SCALAR,   parse => 'string', default => '' },
       lexer                => { isa => 'HTML::Mason::Lexer' },
       preprocess           => { type => CODEREF,  parse => 'code',   optional => 1 },
       postprocess_perl     => { type => CODEREF,  parse => 'code',   optional => 1 },
       postprocess_text     => { type => CODEREF,  parse => 'code',   optional => 1 },
      );
  
  __PACKAGE__->contained_objects( lexer => 'HTML::Mason::Lexer' );

The C<type>, C<default>, and C<optional> parameters are part of the
validation specification used by C<Params::Validate>.  The various
constants used, C<ARRAYREF>, C<SCALAR>, etc. are all exported by
C<Params::Validate>.  This means that any of these six parameter
names, plus the C<lexer_class> parameter (because of the
C<contained_objects()> specification given earlier), are valid
arguments to the Compiler's C<new()> method.

Note that there are also some C<parse> attributes declared.  These
have nothing to do with C<Class::Container> or C<Params::Validate> -
any extra entries like this are simply ignored, so you are free to put
extra information in the specifications as long as it doesn't overlap
with what C<Class::Container> or C<Params::Validate> are looking for.

=head2 $self->create_delayed_object()

If a contained object was declared with C<< delayed => 1 >>, use this
method to create an instance of the object.  Note that this is an
object method, not a class method:

   my $foo =       $self->create_delayed_object('foo', ...); # YES!
   my $foo = __PACKAGE__->create_delayed_object('foo', ...); # NO!

The first argument should be a key passed to the
C<contained_objects()> method.  Any additional arguments will be
passed to the C<new()> method of the object being created, overriding
any parameters previously passed to the container class constructor.
(Could I possibly be more alliterative?  Veni, vedi, vici.)

=head2 $self->delayed_object_params($name, [params])

Allows you to adjust the parameters that will be used to create any
delayed objects in the future.  The first argument specifies the
"name" of the object, and any additional arguments are key-value pairs
that will become parameters to the delayed object.

=head2 $self->delayed_object_class($name)

Returns the class that will be used when creating delayed objects of
the given name.  Use this sparingly - in most situations you shouldn't
care what the class is.

=head2 $self->validation_spec()

Returns a hash reference suitable for passing to the
C<Params::Validate> C<validate> function.  Does I<not> include any
arguments that can be passed to contained objects.

=head2 $class->allowed_params(\%args)

Returns a hash reference of every parameter this class will accept,
I<including> parameters it will pass on to its own contained objects.
The keys are the parameter names, and the values are their
corresponding specifications from their C<valid_params()> definitions.
If a parameter is used by both the current object and one of its
contained objects, the specification returned will be from the
container class, not the contained.

Because the parameters accepted by C<new()> can vary based on the
parameters I<passed> to C<new()>, you can pass any parameters to the
C<allowed_params()> method too, ensuring that the hash you get back is
accurate.

=head2 $self->container()

Returns the object that created you.  This is remembered by storing a
reference to that object, so we use the C<Scalar::Utils> C<weakref()>
function to avoid persistent circular references that would cause
memory leaks.  If you don't have C<Scalar::Utils> installed, we don't
make these references in the first place, and calling C<container()>
will result in a fatal error.

If you weren't created by another object via C<Class::Container>,
C<container()> returns C<undef>.

In most cases you shouldn't care what object created you, so use this
method sparingly.

=head2 $object->show_containers

=head2 $package->show_containers

This method returns a string meant to describe the containment
relationships among classes.  You should not depend on the specific
formatting of the string, because I may change things in a future
release to make it prettier.

For example, the HTML::Mason code returns the following when you do
C<< $interp->show_containers >>:

 HTML::Mason::Interp=HASH(0x238944)
   resolver -> HTML::Mason::Resolver::File
   compiler -> HTML::Mason::Compiler::ToObject
     lexer -> HTML::Mason::Lexer
   request -> HTML::Mason::Request (delayed)
     buffer -> HTML::Mason::Buffer (delayed)

Currently, containment is shown by indentation, so the Interp object
contains a resolver and a compiler, and a delayed request (or several
delayed requests).  The compiler contains a lexer, and each request
contains a delayed buffer (or several delayed buffers).

=head1 SEE ALSO

L<Params::Validate>, L<HTML::Mason>

=head1 AUTHOR

Ken Williams <ken@mathforum.org>, based extremely heavily on
collaborative work with Dave Rolsky <autarch@urth.org> and Jonathan
Swartz <swartz@pobox.com> on the HTML::Mason project.

=head1 COPYRIGHT

This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
