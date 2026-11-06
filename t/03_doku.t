#!/usr/bin/perl
#
# Commandref: jedes Attribut und jeder set/get-Befehl hat einen Anker IM <li>,
# sonst zeigt FHEMWEB unter dem Dropdown keine Hilfe (fhemweb.js FW_displayHelp).

use strict;
use warnings;
use File::Basename qw(dirname);
use Cwd qw(abs_path);
my $stub = dirname(abs_path(__FILE__)) . "/fhem_stub.pl";
require $stub;

my $file = dirname(abs_path(__FILE__)) . "/../FHEM/98_OpenRouter.pm";
open(my $fh, "<", $file) or die $!;
my $src = do { local $/; <$fh> };
close($fh);
my ($doc) = $src =~ /=begin html(.*)=end html/s;
ok(defined $doc && $src =~ /=item summary_DE /, "Commandref mit summary_DE");

my $h = { NAME => "x" };
OpenRouter_Initialize($h);
for my $a (map { (split(/:/, $_))[0] } split(/\s+/, $h->{AttrList})) {
    next if ($a eq "" || $a =~ /^event-on/);
    ok($doc =~ /<li><a id="OpenRouter-attr-\Q$a\E"><\/a>/, "attr $a: Anker im <li>");
}
for my $type (qw(set get)) {
    my $ret = $type eq "set" ? OpenRouter_Set(setup(), "ki", "?") : OpenRouter_Get(setup(), "ki", "?");
    my ($l) = $ret =~ /choose one of (.*)$/;
    for my $c (map { (split(/:/, $_))[0] } split(/\s+/, $l)) {
        ok($doc =~ /<li><a id="OpenRouter-$type-\Q$c\E"><\/a>/, "$type $c: Anker im <li>");
    }
}
done();
