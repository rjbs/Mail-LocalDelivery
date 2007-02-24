use strict;
use ExtUtils::MakeMaker;

WriteMakefile(
  'NAME'		=> 'Mail::LocalDelivery',
  'VERSION_FROM'	=> 'lib/Mail/LocalDelivery.pm',
  (eval { ExtUtils::MakeMaker->VERSION(6.21) } ? (LICENSE => 'perl') : ()),
  'PREREQ_PM'		=> {},
  ($] >= 5.005 ?
    (ABSTRACT_FROM => 'lib/Mail/LocalDelivery.pm',
     AUTHOR     => 'Jose Alves de Castro <cog@cpan.org>') : ()),
);
