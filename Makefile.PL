use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile(
    'NAME'	=> 'Apache::ConfigFile',
    'VERSION_FROM' => 'ConfigFile.pm', # finds $VERSION
    'MAN3PODS' => { 'ConfigFile.pm' => '$(INST_MAN3DIR)/Apache::ConfigFile.$(MAN3EXT)' }
);
