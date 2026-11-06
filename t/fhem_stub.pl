#!/usr/bin/perl
#
# Minimaler FHEM-Ersatz, damit 98_OpenRouter.pm ohne FHEM-Installation
# getestet werden kann (Muster: FHEM-Knowhow / FHEM-HeatManager).
# HTTP geht nicht raus: HttpUtils_NonblockingGet merkt sich nur die Anfrage.

use strict;
use warnings;
use File::Basename qw(dirname);
use Cwd qw(abs_path);
BEGIN { unshift @INC, dirname(abs_path(__FILE__)) . "/stub"; }   # HttpUtils.pm, JSON.pm

# wie fhem.pl: Globals per "use vars" (gelten paketweit, auch für das geladene Modul)
use vars qw(%defs %attr $init_done $readingFnAttributes);
our (@CMDS, @HTTP, %KV, %SETS);
$init_done           = 1;
$readingFnAttributes = "event-on-change-reading";

sub Log3 { }
sub AttrVal {
    my ($n, $a, $d) = @_;
    return (exists $attr{$n} && defined $attr{$n}{$a} && $attr{$n}{$a} ne "") ? $attr{$n}{$a} : $d;
}
sub ReadingsVal {
    my ($n, $r, $d) = @_;
    return $d if (!exists $defs{$n} || !exists $defs{$n}{READINGS}{$r});
    return $defs{$n}{READINGS}{$r}{VAL};
}
sub readingsBeginUpdate  { }
sub readingsEndUpdate    { }
sub readingsBulkUpdate   { my ($h,$r,$v)=@_; $h->{READINGS}{$r}{VAL}=$v; }
sub readingsSingleUpdate { my ($h,$r,$v)=@_; $h->{READINGS}{$r}{VAL}=$v; }
sub getKeyValue          { my ($k)=@_; return (undef, $KV{$k}); }
sub setKeyValue          { my ($k,$v)=@_; if (defined $v) { $KV{$k}=$v } else { delete $KV{$k} } return undef; }
sub CommandSet           { push @CMDS, "set $_[1]";       return undef; }
sub CommandDefine        { push @CMDS, "define $_[1]";    return undef; }
sub CommandAttr          { push @CMDS, "attr $_[1]";      return undef; }
sub CommandModify        { push @CMDS, "modify $_[1]";    return undef; }
sub CommandDeleteAttr    { push @CMDS, "deleteattr $_[1]"; return undef; }
sub HttpUtils_NonblockingGet { push @HTTP, $_[0]; return undef; }
sub getAllSets           { return $SETS{$_[0]} // ""; }

my $modul = dirname(abs_path(__FILE__)) . "/../FHEM/98_OpenRouter.pm";
do $modul or die "Konnte $modul nicht laden: " . ($@ || $!) . "\n";

our ($FAILS, $OKS) = (0, 0);
sub ok {
    my ($c, $t) = @_;
    printf("%-5s %s\n", $c ? "ok" : "FAIL", $t);
    $c ? $OKS++ : $FAILS++;
    return $c;
}
sub done { printf("\n%d ok, %d FAILED\n", $OKS, $FAILS); exit($FAILS ? 1 : 0); }
sub cmds { my ($re) = @_; return scalar grep { /$re/ } @CMDS; }

# Anlage: ein KI-Gerät, Lampe + Tür steuerbar/lesbar, Alarm nur vorhanden
sub setup {
    my (%o) = @_;
    %defs = (); %attr = (); @CMDS = (); @HTTP = (); %KV = ();
    for my $d (qw(Lampe Tuer Alarm Heizung)) {
        $defs{$d} = { NAME => $d, TYPE => "dummy", READINGS => { state => { VAL => "off" } } };
    }
    $attr{Lampe}{room}   = "KI";
    $attr{Tuer}{room}    = "Lesen";
    $attr{Heizung}{room} = "KI";
    my $h = { NAME => "ki", TYPE => "OpenRouter", READINGS => {} };
    $defs{ki} = $h;
    my $err = OpenRouter_Define($h, "ki OpenRouter");
    die $err if ($err);
    %{$attr{ki}} = (controlRoom => "KI", deviceRoom => "Lesen", %o);
    $KV{"OpenRouter_ki_apiKey"} = "sk-test";
    return $h;
}

# Letzte HTTP-Anfrage als Perl-Struktur
sub last_request { return JSON::PP::decode_json($HTTP[-1]{data}); }

1;
