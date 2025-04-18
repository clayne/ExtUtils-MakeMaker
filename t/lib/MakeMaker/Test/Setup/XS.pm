package MakeMaker::Test::Setup::XS;

@ISA = qw(Exporter);
require Exporter;
@EXPORT = qw(run_tests list_dynamic list_static);

use strict;
use warnings;
use File::Path;
use MakeMaker::Test::Utils;
use Config;
use Carp qw(croak);
use Test::More;
use File::Spec;

use File::Temp qw[tempdir];
use Cwd;
use ExtUtils::MM;
# this is to avoid MM->new overwriting _eumm in top dir
my $tempdir = tempdir(DIR => getcwd, CLEANUP => 1);
chdir $tempdir;
my $typemap = 'type map';
my $MM = MM->new({NAME=>'name', NORECURS=>1});
$typemap =~ s/ //g unless $MM->can_dep_space;
chdir File::Spec->updir;

my $PM_TEST = <<'END';
use strict;
use warnings;
package XS::Test;
require Exporter;
require DynaLoader;
our $VERSION = 1.01;
our @ISA    = qw(Exporter DynaLoader);
our @EXPORT = qw(is_even);
bootstrap XS::Test $VERSION;
1;
END

my $XS_TEST = <<'END';
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
MODULE = XS::Test       PACKAGE = XS::Test
PROTOTYPES: DISABLE
int
is_even(input)
  int input
   CODE:
       RETVAL = (input % 2 == 0);
   OUTPUT:
       RETVAL
END

my $T_TEST = <<'END';
use strict;
use warnings;
use Test::More tests => 3;
use_ok "XS::Test";
ok !is_even(1);
ok is_even(2);
END

my $MAKEFILEPL = <<'END';
use strict;
use warnings;
use ExtUtils::MakeMaker;
WriteMakefile(
  NAME          => 'XS::%s',
  VERSION_FROM  => '%s',
  TYPEMAPS      => [ %s ],
  PERL          => "$^X -w",
  %s
);
END

my $BS_TEST = '$DynaLoader::bscode = q(warn "BIG NOISE";)';

my $T_BOOTSTRAP = <<'EOF';
use strict;
use warnings;
use Test::More tests => 1;
my $w = '';
$SIG{__WARN__} = sub { $w .= join '', @_; };
require XS::Test;
like $w, qr/NOISE/;
EOF

my $PM_OTHER = <<'END';
use strict;
use warnings;
package XS::Other;
require Exporter;
require DynaLoader;
our $VERSION = 1.20;
our @ISA    = qw(Exporter DynaLoader);
our @EXPORT = qw(is_odd);
bootstrap XS::Other $VERSION;
1;
END

my $XS_OTHER = <<'END';
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

int is_odd(int input) { return (INVAR % 2 == 1); }

MODULE = XS::Other       PACKAGE = XS::Other
PROTOTYPES: DISABLE
int
is_odd(input)
  int input
END

my $T_OTHER = <<'END';
use strict;
use warnings;
use Test::More tests => 3;
use_ok "XS::Other";
ok is_odd(1);
ok !is_odd(2);
END

my $PLUS1_C = <<'EOF';
#ifdef __cplusplus
extern "C" {
int plus1(int i)
#else
int plus1(i)
int i;
#endif
{ return i + 1; }
#ifdef __cplusplus
}
#endif
EOF

my %Files = (
  'lib/XS/Test.pm' => $PM_TEST,
  $typemap => '',
  'Test.xs' => $XS_TEST,
  't/is_even.t' => $T_TEST,
  'Makefile.PL' => sprintf($MAKEFILEPL, 'Test', 'lib/XS/Test.pm', qq{'$typemap'}, ''),
);

my %label2files = (basic => \%Files, basic2 => \%Files); # basic2 so no clash

$label2files{bscode} = +{
  %{ $label2files{'basic'} }, # make copy
  'Test_BS' => $BS_TEST,
  't/bs.t' => $T_BOOTSTRAP,
};
delete $label2files{bscode}->{'t/is_even.t'};

$label2files{static} = +{
  %{ $label2files{'basic'} }, # make copy
  'Makefile.PL' => sprintf(
    $MAKEFILEPL, 'Test', 'lib/XS/Test.pm', qq{'$typemap'},
    q{LINKTYPE => 'static'},
  ),
  "blib/arch/auto/share/dist/x-y/libwhatevs$MM->{LIB_EXT}" => 'hi there', # mimic what File::ShareDir can do
  "blib/arch/auto/Alien/ROOT/root/lib/root/root$MM->{LIB_EXT}" => 'hi there', # mimic Alien::ROOT that installs a .a without extralibs.ld
  # next two mimic dist that installs a .a WITH extralibs.ld but that is still not XS
  "blib/arch/auto/Dist/File$MM->{LIB_EXT}" => 'hi there',
  "blib/arch/auto/Dist/extralibs.ld" => '',
};

$label2files{subdirs} = +{
  %{ $label2files{'basic'} }, # make copy
  'Makefile.PL' => sprintf(
    $MAKEFILEPL, 'Test', 'Test.pm', qq{'$typemap'},
    q{DEFINE => '-DINVAR=input', INC => "-Inewline\n", LIBS => "-Lnewline\n",},
  ),
  'Other/Makefile.PL' => sprintf($MAKEFILEPL, 'Other', 'Other.pm', qq{}, ''),
  'Other/Other.pm' => $PM_OTHER,
  'Other/Other.xs' => $XS_OTHER,
  't/is_odd.t' => $T_OTHER,
};
virtual_rename('subdirs', 'lib/XS/Test.pm', 'Test.pm');

# to mimic ExtUtils::Depends-facilitated B::Hooks::OP::Check
$label2files{eud_produce} = +{
  %{ $label2files{basic} }, # make copy
  'Makefile.PL' => sprintf(
    $MAKEFILEPL, 'Other', 'Other.pm', qq{},
    q{
      DEFINE => '-DINVAR=input',
      FUNCLIST => [qw(is_odd)],
      DL_FUNCS => { 'XS::Other' => [] },
    },
  ),
  'Other.pm' => do {
    my $t = $PM_OTHER; $t =~ s:bootstrap:sub dl_load_flags { 0x01 }\n$&:g; $t
  },
  'Other.xs' => $XS_OTHER,
  't/is_even.t' => $T_OTHER,
};
delete @{ $label2files{eud_produce} }{qw(lib/XS/Test.pm Test.xs)};

# to mimic ExtUtils::Depends-facilitated consuming B::Hooks::OP::Check
$label2files{eud_consume} = +{
  %{ $label2files{basic} }, # make copy
  'Makefile.PL' => <<'EOF' .
use File::Spec::Functions;
my $root; BEGIN {$root = catdir(updir, qw(XS-Testeud_produce blib arch));}
EOF
    sprintf(
      $MAKEFILEPL, 'Test', 'Test.pm', qq{},
      q{
        DEFINE => '-DINVAR=input',
        LDFROM => join(' ', '$(OBJECT)', map _quote_if_space($_), find_extra_libs({'XS::Other'=>undef}, [$root])),
      },
    ) . <<'EOF',
use Config;
use File::Spec::Functions;
sub _quote_if_space { $_[0] =~ / / ? qq{"$_[0]"} : $_[0] }
my %exts; BEGIN { %exts = (
  MSWin32 => [ ".lib", ".$Config{dlext}", $Config{_a} ],
  cygwin => [ '.dll' ],
  android => [ ".$Config{dlext}" ],
); }
sub find_extra_libs {
  my ($deps, $search) = @_;
  return () if !keys %$deps;
  return () unless my $exts = $exts{$^O};
  my @found_libs = ();
  DEP: foreach my $name (keys %$deps) {
    my @parts = split /::/, $name;
    my $stem = defined &DynaLoader::mod2fname
      ? DynaLoader::mod2fname(\@parts) : $parts[-1];
    my @bases = map $stem.$_, @$exts;
    for my $dir (grep -d, @$search) { # only extant dirs
      my ($found) = grep -f, map catfile($dir, 'auto', @parts, $_), @bases;
      next if !defined $found;
      push @found_libs, $found;
      next DEP;
    }
  }
  @found_libs;
}
EOF
  'Test.pm' => do {
    my $t = $PM_TEST; $t =~ s:is_even:is_odd:g;
    $t =~ s/bootstrap/
      use File::Spec::Functions;
      my \$root; BEGIN {\$root = catdir(updir, qw(XS-Testeud_produce blib));}
      use lib map catdir(\$root, \$_), qw(lib arch);
      require XS::Other;\n$&
    /g;
    $t
  },
  'Test.xs' => do {
    my $t = $XS_OTHER; $t =~ s:Other:Test:g; $t =~ s:\{.*?\}:;:; $t
  },
  't/is_even.t' => <<'END',
use strict;
use warnings;
use Test::More tests => 2;
use XS::Test;
ok XS::Test::is_odd(1);
ok !XS::Test::is_odd(2);
END
};
delete @{ $label2files{eud_consume} }{qw(lib/XS/Test.pm)};

# to mimic behaviour of Unicode-LineBreak version 2015.07.16
$label2files{subdirscomplex} = +{
  %{ $label2files{'subdirs'} }, # make copy
  'Other/Makefile.PL' => sprintf(
    $MAKEFILEPL,
    'Other', 'Other.pm', qq{},
    <<'EOF',
C => [qw(lib$(DIRFILESEP)file.c)],
OBJECT => 'lib$(DIRFILESEP)file$(OBJ_EXT)',
EOF
  ) . <<'EOF',
sub MY::c_o {
  package MY;
  my $self = shift;
  my $inherited = $self->SUPER::c_o(@_);
  $inherited =~ s{(:\n\t)(.*(?:\n\t.*)*)}
      { $1 . $self->cd('lib', split /(?<!\\)\n\t/, $2) }eg;
  $inherited =~ s{(\s)(\$\*\.c\s)}
      { "$1..\$(DIRFILESEP)$2" }eg;
  $inherited;
}

sub MY::top_targets {
  <<'SNIP';
all :: lib$(DIRFILESEP)file$(OBJ_EXT)
	$(NOECHO) $(NOOP)

config ::
	$(NOECHO) $(NOOP)

pure_all ::
	$(NOECHO) $(NOOP)
SNIP
}
EOF
  'Other/lib/file.c' => $PLUS1_C,
};
delete $label2files{subdirscomplex}{'Other/Other.xs'};
delete $label2files{subdirscomplex}{'t/is_odd.t'};

$label2files{subdirsstatic} = +{
  %{ $label2files{'subdirs'} }, # make copy
  'Makefile.PL' => sprintf(
    $MAKEFILEPL, 'Test', 'Test.pm', qq{'$typemap'},
    q{DEFINE => '-DINVAR=input', LINKTYPE => 'static',},
  ),
};

# to mimic behaviour of CGI-Deurl-XS version 0.08
my $OTHERMAKEFILE = File::Spec->catfile('Other', makefile_name());
$label2files{subdirsskip} = +{
  %{ $label2files{subdirscomplex} }, # make copy
  'Makefile.PL' => sprintf(
    $MAKEFILEPL,
    'Test', 'Test.pm', qq{},
    q[
MYEXTLIB => '] . File::Spec->catfile('Other', 'libparser$(LIB_EXT)') . q[',
     ]
  )
  . q[
sub MY::postamble {
    my ($self) = @_;
    return '$(MYEXTLIB) : ] . $OTHERMAKEFILE . q['."\n\t".$self->cd('Other', '$(MAKE) $(PASSTHRU)')."\n";
}
     ],
  'Other/Makefile.PL' => sprintf(
    $MAKEFILEPL,
    'Other', 'Other.pm', qq{},
    <<'EOF',
SKIP   => [qw(all static dynamic)],
clean  => {'FILES' => 'libparser$(LIB_EXT)'},
EOF
  ) . <<'EOF',
sub MY::top_targets {
  my ($self) = @_;
  my $static_lib_pure_cmd = $self->static_lib_pure_cmd('$(O_FILES)');
  <<'SNIP' . $static_lib_pure_cmd;
all :: static

pure_all :: static

static :: libparser$(LIB_EXT)

libparser$(LIB_EXT): $(O_FILES)
SNIP
}
EOF
  't/plus1.t' => <<'END',
use strict;
use warnings;
use Test::More tests => 2;
use_ok "XS::Test";
is XS::Test::plus1(3), 4;
END
  'Test.xs' => <<EOF,
#ifdef __cplusplus
extern "C" {
#endif
int plus1(int);
#ifdef __cplusplus
}
#endif
$XS_TEST
int
plus1(input)
       int     input
   CODE:
       RETVAL = plus1(input);
   OUTPUT:
       RETVAL
EOF
};
virtual_rename('subdirsskip', 'Other/lib/file.c', 'Other/file.c');

# to mimic behaviour of Math-CDF version 0.1
$label2files{subdirsskip2} = +{
  %{ $label2files{subdirsskip} }, # make copy
  'Other/Makefile.PL' => sprintf(
    $MAKEFILEPL,
    'Other', 'Other.pm', qq{},
    <<'EOF',
SKIP   => [qw(all static static_lib dynamic dynamic_lib test_dynamic test)],
clean  => {'FILES' => 'libparser$(LIB_EXT)'},
EOF
  ) . <<'EOF',
sub MY::top_targets {
  my ($self) = @_;
  <<'SNIP' . $self->static_lib_pure_cmd('$(O_FILES)');
test ::
all :: static
static :: libparser$(LIB_EXT)
libparser$(LIB_EXT): $(O_FILES)
SNIP
}
EOF
};

$label2files{subdirsskip3} = +{
  %{ $label2files{subdirsskip} }, # make copy
  'Other/Makefile.PL' => sprintf(
    $MAKEFILEPL,
    'Other', 'Other.pm', qq{},
    <<'EOF',
SKIP   => [qw(all static static_lib dynamic dynamic_lib test_dynamic test)],
clean  => {'FILES' => 'libparser$(LIB_EXT)'},
EOF
  ) . <<'EOF',
sub MY::top_targets {
  my ($self) = @_;
  <<'SNIP' . $self->static_lib_pure_cmd('$(O_FILES)');
test ::
test_static:
test_dynamic:
all :: static
static :: libparser$(LIB_EXT)
libparser$(LIB_EXT): $(O_FILES)
SNIP
}
EOF
};

my $XS_MULTI = $XS_OTHER;
# check compiling from top dir still can include local
$XS_MULTI =~ s:(#include "XSUB.h"):$1\n#include "header.h":;
$label2files{multi} = +{
  %{ $label2files{'basic'} }, # make copy
  'Makefile.PL' => sprintf(
    $MAKEFILEPL, 'Test', 'lib/XS/Test.pm', qq{'lib/XS/$typemap'},
    q{XSMULTI => 1,},
  ),
  'lib/XS/Other.pm' => $PM_OTHER,
  'lib/XS/Other.xs' => $XS_MULTI,
  't/is_odd.t' => $T_OTHER,
  'lib/XS/header.h' => "#define INVAR input\n",
};
virtual_rename('multi', $typemap, "lib/XS/$typemap");
virtual_rename('multi', 'Test.xs', 'lib/XS/Test.xs');

$label2files{bscodemulti} = +{
  %{ $label2files{'multi'} }, # make copy
  'lib/XS/Test_BS' => $BS_TEST,
  't/bs.t' => $T_BOOTSTRAP,
};
delete $label2files{bscodemulti}->{'t/is_even.t'};
delete $label2files{bscodemulti}->{'t/is_odd.t'};

$label2files{staticmulti} = +{
  %{ $label2files{'multi'} }, # make copy
  'Makefile.PL' => sprintf(
    $MAKEFILEPL, 'Test', 'lib/XS/Test.pm', qq{},
    q{LINKTYPE => 'static', XSMULTI => 1,},
  ),
};

$label2files{xsbuild} = +{
  %{ $label2files{'multi'} }, # make copy
  'Makefile.PL' => sprintf(
    $MAKEFILEPL, 'Test', 'lib/XS/Test.pm', qq{},
    q{
      XSMULTI => 1,
      XSBUILD => {
        xs => {
          'lib/XS/Other' => {
            DEFINE => '-DINVAR=input',
            OBJECT => 'lib/XS/Other$(OBJ_EXT) lib/XS/plus1$(OBJ_EXT)'
          }
        },
      },
    },
  ),

  'lib/XS/Other.xs' => <<EOF,
#ifdef __cplusplus
extern "C" {
#endif
int plus1(int);
#ifdef __cplusplus
}
#endif
$XS_OTHER
int
plus1(input)
       int     input
   CODE:
       RETVAL = plus1(INVAR);
   OUTPUT:
       RETVAL
EOF

  'lib/XS/plus1.c' => $PLUS1_C,

  't/is_odd.t' => <<'END',
use strict;
use warnings;
use Test::More tests => 4;
use_ok "XS::Other";
ok is_odd(1);
ok !is_odd(2);
is XS::Other::plus1(3), 4;
END

};

sub virtual_rename {
  my ($label, $oldfile, $newfile) = @_;
  $label2files{$label}->{$newfile} = delete $label2files{$label}->{$oldfile};
}

sub setup_xs {
  my ($label, $sublabel) = @_;
  croak "Must supply label" unless defined $label;
  my $files = $label2files{$label};
  croak "Must supply valid label" unless defined $files;
  croak "Must supply sublabel" unless defined $sublabel;
  my $prefix = "XS-Test$label$sublabel";
  hash2files($prefix, $files);
  return $prefix;
}

sub list_static {
  (
    ( !$Config{usedl} ? [ 'basic2', '', '' ] : ()), # still needs testing on static perl
    [ 'static', '', '' ],
    [ 'basic', ' static', '_static' ],
    [ 'multi', ' static', '_static' ],
    [ 'subdirs', ' LINKTYPE=static', ' LINKTYPE=static' ],
    [ 'subdirsstatic', '', '' ],
    [ 'staticmulti', '', '' ],
  );
}

sub list_dynamic {
  (
    [ 'basic', '', '' ],
    $^O ne 'MSWin32' ? (
        [ 'bscode', '', '' ],
        [ 'bscodemulti', '', '' ],
        $^O !~ m!^(VMS|aix)$! ? ([ 'subdirscomplex', '', '' ]) : (),
    ) : (), # DynaLoader different
    [ 'subdirs', '', '' ],
    [ 'eud_produce', '', '', 1 ],
    [ 'eud_consume', '', '' ],
    # https://github.com/Perl/perl5/issues/17601
    # https://rt.cpan.org/Ticket/Display.html?id=115321
    $^O ne 'MSWin32' ? (
        [ 'subdirsstatic', ' LINKTYPE=dynamic', ' LINKTYPE=dynamic' ],
        [ 'subdirsstatic', ' dynamic', '_dynamic' ],
    ) : (),
    [ 'multi', '', '' ],
    $^O ne 'MSWin32' ? (
        [ 'staticmulti', ' LINKTYPE=dynamic', ' LINKTYPE=dynamic' ],
        [ 'staticmulti', ' dynamic', '_dynamic' ],
    ) : (),
    [ 'xsbuild', '', '' ],
    [ 'subdirsskip', '', '' ],
    [ 'subdirsskip2', '', '' ],
#    [ 'subdirsskip3', '', '' ], # Defanged I'm unsure how to magic a fix for this.
  );
}

my $held_dir = undef;
sub run_tests {
  my ($perl, $label, $add_target, $add_testtarget, $hold_dir) = @_;
  my $sublabel = $add_target;
  $sublabel =~ s#[\s=]##g;
  ok( my $dir = setup_xs($label, $sublabel), "setup $label$sublabel" );

  ok( chdir($dir), "chdir'd to $dir" ) || diag("chdir failed: $!");

  my @mpl_out = run(qq{$perl Makefile.PL});
  SKIP: {
    unless (cmp_ok( $?, '==', 0, "Makefile.PL exited with zero ($label)" )) {
      diag(@mpl_out);
      skip 'perl Makefile.PL failed', 2;
    }

    my $make = make_run();
    my $target = '';
    my %macros = ();
    if (defined($add_target)) {
        if ($add_target =~ m/(\S+)=(\S+)/) {
            $macros{$1} = $2;
        }
        else {
            $target = $add_target;
        }
    }
    my $make_cmd = make_macro($make, $target, %macros);
    my $make_out = run($make_cmd);
    unless (is( $?, 0, "$make_cmd exited normally ($label)" )) {
        diag $make_out;
        skip 'Make failed - skipping test', 1;
    }

    $target = 'test';
    %macros = ();
    if (defined($add_testtarget) && length($add_testtarget)) {
        if ($add_testtarget =~ m/(\S+)=(\S+)/) {
            $macros{$1} = $2;
        }
        else {
            # an underscore prefix means combine, e.g. 'test' + '_dynamic'
            unless ($add_testtarget =~ m/^_/) {
                $target .= ($make =~ m/^MM(K|S)/i) ? ',' : ' ';
            }
            $target .= $add_testtarget;
        }
    }
    my $test_cmd = make_macro($make, $target, %macros);
    my $test_out = run($test_cmd);
    is( $?, 0, "$test_cmd exited normally ($label)" ) || diag "$make_out\n$test_out";
  }

  chdir File::Spec->updir or die;
  if ($ENV{EUMM_KEEP_TESTDIRS}) {
    ok 1, "don't teardown $dir";
    return;
  }
  if (defined $held_dir) {
    ok rmtree($held_dir), "belated teardown $held_dir";
    $held_dir = undef;
  }
  if ($hold_dir) {
    $held_dir = $dir;
  } else {
    ok rmtree($dir), "teardown $dir";
  }
}

1;
