package Class::Container;

$VERSION = '0.03';
$VERSION = eval $VERSION if $VERSION =~ /_/;

my $HAVE_WEAKEN = 0;
BEGIN {
  eval {
    require Scalar::Util;
    Scalar::Util->import('weaken');
    $HAVE_WEAKEN = 1;
  };
  warn "Scalar::Util not detected - container() method not available\n" if !$HAVE_WEAKEN and $^W;
  
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

sub new
{
    my $proto = shift;
    my $class = ref($proto) || $proto;
    my @args = $class->create_contained_objects(@_);
    return bless {
		  validate_with(
				params => \@args,
				spec => $class->validation_spec,
				called => "$class->new()",
			       )
		 }, $class;
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
		    $obj_class = $CONTAINED_OBJECTS{$class}{$name};
		    $obj_class = $obj_class->{class} if ref $obj_class;

		    $default = "$obj_class\->new";
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
		$default =~ s/^\(\?(\w*)-\w*:(.*)\)/\/$2\/$1/;
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
	    $out{$class}{contained_objects}{$name} = ref($contains->{$name}) 
		? {map {$_, $contains->{$name}{$_}} qw(class delayed descr)}
		: {class => $contains->{$name}, delayed => 0};
	}
    }

    return %out;
}

sub valid_params
{
    my $class = shift;
    $VALID_PARAMS{$class} = {@_};
}

sub contained_objects
{
    my $class = shift;
    $CONTAINED_OBJECTS{$class} = {@_};
}

sub container {
  my $self = shift;
  return undef unless $HAVE_WEAKEN;
  return $self->{container}{container};
}

sub call_method {
  my ($self, $name, $method, @args) = @_;
  
  my $class = $self->contained_class($name)
    or die "Unknown contained item '$name'";

  $self->_load_module($class);
  return $class->$method( %{ $self->{container}{delayed}{$name}{args} }, @args );
}

# Accepts a list of key-value pairs as parameters, representing all
# parameters taken by this object and its descendants.  Returns a list
# of key-value pairs representing *only* this object's parameters.
sub create_contained_objects
{
    # Typically $self doesn't exist yet, $_[0] is a string classname
    my ($class, %args) = @_;

    # This one is special, don't pass to descendants
    my $container_stuff = delete($args{container}) || {};

    my %c = $class->get_contained_object_spec;
    my %contained_args;

    while (my ($name, $spec) = each %c) {
	my $default_class = ref($spec) ? $spec->{class}   : $spec;
	my $delayed       = ref($spec) ? $spec->{delayed} : 0;
	if (exists $args{$name}) {
	    # User provided an object
	    die "Cannot provide a '$name' object, its creation is delayed" if $delayed;

	    # We still need to delete any arguments that _would_ have
	    # been given to this object's constructor (if the object
	    # had not been given).  This allows a container class to
	    # provide defaults for a contained object while still
	    # accepting an already-constructed object as one of its
	    # params.
	    #
	    my $c_args = $class->_get_contained_args(ref $args{$name}, \%args);
	    @contained_args{ keys %$c_args } = ();
	    next;
	}

	# Figure out exactly which class to make an object of
	my $contained_class = delete $args{"${name}_class"} || $default_class;
	next unless $contained_class;

	my $c_args = $class->_get_contained_args($contained_class, \%args);
	@contained_args{ keys %$c_args } = ();  # Populate with keys

	if ($delayed) {
	  $container_stuff->{delayed}{$name}{args} = $c_args;
	  $container_stuff->{delayed}{$name}{class} = $contained_class;
	} else {
	  $args{$name} = $contained_class->new(%$c_args);
	  $container_stuff->{contained}{$name}{class} = $contained_class;
	}
    }

    # Delete things that we're not going to use - things that are in
    # our contained object specs but not in ours.
    my $my_spec = $class->validation_spec;
    delete @args{ grep {!exists $my_spec->{$_}} keys %contained_args };

    $args{container} = $container_stuff;
    return %args;
}

sub create_delayed_object
{
  my ($self, $name) = (shift, shift);
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
	unless exists $self->{container}{delayed}{$name};

    return $self->{container}{delayed}{$name}{class};
}

sub contained_class
{
    my ($self, $name) = @_;
    die "Unknown contained item '$name'"
	unless my $spec = $self->{container}{contained}{$name} || $self->{container}{delayed}{$name};
    return $spec->{class};
}

sub delayed_object_params
{
    my ($self, $name, %args) = @_;
    die "Unknown delayed object '$name'"
	unless exists $self->{container}{delayed}{$name};

    if (%args)
    {
	@{ $self->{container}{delayed}{$name}{args} }{ keys(%args) } = values(%args);
    }

    return %{ $self->{container}{delayed}{$name}{args} };
}

sub _get_contained_args
{
    my ($class, $contained_class, $args) = @_;

    die "Invalid class name '$contained_class'"
	unless $contained_class =~ /^[\w:]+$/;

    $class->_load_module($contained_class);

    return {} unless $contained_class->isa(__PACKAGE__);

    # Everything this class will accept, including parameters it will
    # pass on to its own contained objects
    my $allowed = $contained_class->allowed_params($args);

    my %contained_args;
    foreach (keys %$allowed) {
	$contained_args{$_} = $args->{$_} if exists $args->{$_};
    }
    return \%contained_args;
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

# Iterate through this object's @ISA and find all entries in
# 'contained_objects' list.  Return as a hash.
sub get_contained_object_spec
{
    my $class = ref($_[0]) || shift;

    my %c = %{ $CONTAINED_OBJECTS{$class} || {} };

    no strict 'refs';
    foreach my $superclass (@{ "${class}::ISA" }) {
	next unless $superclass->isa(__PACKAGE__);
	my %superparams = $superclass->get_contained_object_spec;
	foreach my $key (keys %superparams) {
	  # Let subclass take precedence
	  $c{$key} = $superparams{$key} unless exists $c{$key};
	}
    }

    return %c;
}

sub allowed_params
{
    my $class = shift;
    my $args = ref($_[0]) ? shift : {@_};

    my %p = %{ $class->validation_spec };

    my %c = $class->get_contained_object_spec;

    foreach my $name (keys %c)
    {
	# Can accept a 'foo' parameter - should already be in the validation_spec.
	# Also, its creation parameters should already have been extracted from $args,
	# so don't extract any parameters.
	next if exists $args->{$name};

	# Can accept a 'foo_class' parameter instead of a 'foo' parameter
	# If neither parameter is present, give up - perhaps it's optional
	my $class_name_param = "${name}_class";

	if ( exists $args->{$class_name_param} )
	{
	    delete $p{$name};
	    $p{$class_name_param} = { type => SCALAR, parse => 'string' };  # A loose spec
	}

	# We have to get the allowed params for the contained object
	# class.  That class could be overridden, in which case we use
	# the new class provided.  Otherwise, we use our default.
	my $spec = exists $args->{$class_name_param} ? $args->{$class_name_param} : $c{$name};
	my $contained_class = ref($spec) ? $spec->{class}   : $spec;

	# we have to make sure it is loaded before we try calling
	# ->allowed_params
	$class->_load_module($contained_class);
	next unless $contained_class->can('allowed_params');

	my $subparams = $contained_class->allowed_params($args);

	#
	# What we're doing here is checking for parameters in
	# contained objects that expect an object of which the current
	# class (for which we are retrieving allowed params) is a
	# subclass (or the same class).
	#
	# For example, the HTML::Mason::Request class accepts an
	# 'interp' param that must be of the HTML::Mason::Interp
	# class.
	#
	# But the HTML::Mason::Interp class contains a request object.
	# While it makes sense to say that the interp class can accept
	# a parameter like 'autoflush' on behalf of the request, it
	# makes very little sense to say that the interp can accept an
	# interp as a param.
	#
	# This _does_ cause a potential problem if we ever want to
	# have a class that 'contains' other objects of the same
	# class.
	#
	foreach (keys %$subparams)
	{
	    if ( ref $subparams->{$_} &&
		 exists $subparams->{$_}{isa} &&
		 $class->isa( $subparams->{$_}{isa} ) )
	    {
		next;
	    }
	    $p{$_} = $subparams->{$_};
	}
    }

    return \%p;
}

sub validation_spec
{
    my $class = ref($_[0]) || shift;

    my %p = %{ $VALID_PARAMS{$class} || {} };

    no strict 'refs';
    foreach my $superclass (@{ "${class}::ISA" }) {
	next unless $superclass->isa(__PACKAGE__);
	my $superparams = $superclass->validation_spec;
	@p{keys %$superparams} = values %$superparams;
    }

    $p{container} = { type => HASHREF };

    return \%p;
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
   
   # Build $self, possibly passing elements of @_ to 'ingredient' object
   my $self = $package->SUPER::new(@_);

   ... do any more initialization here ...
   return $self;
 }

=head1 DESCRIPTION

This class facilitates building frameworks of several classes that
inter-operate.  It was first designed and built for C<HTML::Mason>, in
which the Compiler, Lexer, Interpreter, Resolver, Component, Buffer, and several
other objects must create each other transparently, passing the
appropriate parameters to the right class.

The main features of C<Class::Container> are:

=over 4

=item * Declaration of parameters used by each member in a class
framework

=item * Transparent passing of constructor parameters to the class
that needs them

=item * Ability to create one (automatic) or many (manual) contained
objects automatically and transparently

=back

The most important methods provided are C<valid_params()> and
C<contained_objects()>, both of which are class methods.

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

=head2 __PACKAGE__->valid_params()

The C<valid_params()> method is similar to the C<contained_objects()>
method in that it is a class method that declares properties of the
current class.  It is called in order to register a set of parameters
which are valid for a class's C<new()> constructor method.  It is
called with a hash that contains parameter names as its keys and
validation specifications as values.  This validation specification
is largely the same as that used by the C<Params::Validate> module,
because we use C<Params::Validate> internally.

As an example, HTML::Mason::Compiler contains the following:

  __PACKAGE__->valid_params
      (
       allow_globals        => { parse => 'list',   type => ARRAYREF, default => [] },
       default_escape_flags => { parse => 'string', type => SCALAR,   default => '' },
       lexer                => { isa => 'HTML::Mason::Lexer' },
       preprocess           => { parse => 'code',   type => CODEREF,  optional => 1 },
       postprocess_perl     => { parse => 'code',   type => CODEREF,  optional => 1 },
       postprocess_text     => { parse => 'code',   type => CODEREF,  optional => 1 },
      );

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

=head2 $self->allowed_params()

Returns a hash reference of every parameter this class will accept,
I<including> parameters it will pass on to its own contained objects.

=head2 $self->container()

Returns the object that created you.  This is remembered by storing a
reference to that object, so we use the C<Scalar::Utils> C<weakref()>
function to avoid persistent circular references that would cause
memory leaks.  

If you don't have C<Scalar::Utils> installed, we don't make these
references in the first place, and calling C<container()> will always
return undef.

In most cases you shouldn't care what object created you, so use this
method sparingly.

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
