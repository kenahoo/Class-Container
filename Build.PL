use Module::Build;

my $b = Module::Build->subclass(code => join '', <DATA>)->new
  (
   module_name => 'Class::Container',
   requires => {
		Params::Validate => '0.23',
		Carp => 0,
	       },
   recommends => { Scalar::Util => 0 },
   license => 'perl',
  );

$b->create_build_script;

__DATA__

sub ACTION_distdir {
  my $self = shift;
  $self->do_system(qw(rm -f README));
  $self->do_system("pod2text -80 < $self->{properties}{dist_version_from} > README");
  $self->do_system('cp', '-f', 'README', $self->dist_dir);
  $self->SUPER::ACTION_distdir(@_);
}
