#!/usr/bin/perl
#
# v1.3.0: UTF-8, API-Key, Define, Callback-Schutz, Befehlsfilter, doppelte Subs.

use strict;
use warnings;
use File::Basename qw(dirname);
use Cwd qw(abs_path);
use Encode ();
my $stub = dirname(abs_path(__FILE__)) . "/fhem_stub.pl";
require $stub;
our (%defs, %attr, %KV, %SETS, @HTTP, @CMDS);

print "=== Umlaute ===\n";
my $h = setup();
my $frage = "Wie warm ist es im B\xc3\xbcro?";          # FHEM liefert UTF-8-Bytes
OpenRouter_SendRequest($h, $frage, undef, 0);
my $raw = $HTTP[-1]{data};
ok($raw =~ /B\xc3\xbcro/ && $raw !~ /B\xc3\x83\xc2\xbcro/, "Büro geht einfach UTF-8-kodiert raus (nicht BÃ¼ro)");

print "\n=== API-Key ===\n";
ok($HTTP[-1]{header} =~ /Bearer sk-test/, "Key aus dem Keyvalue-Store");
delete $KV{"OpenRouter_ki_apiKey"};
$attr{ki}{apiKey} = "sk-attr";
OpenRouter_SendRequest($h, "x", undef, 0);
ok($HTTP[-1]{header} =~ /Bearer sk-attr/, "Fallback auf attr apiKey");
my $msg = OpenRouter_Set($h, "ki", "apiKey", "sk-neu");
ok($KV{"OpenRouter_ki_apiKey"} eq "sk-neu" && $msg =~ /deleteattr ki apiKey/, "set apiKey speichert und rät zu deleteattr");
OpenRouter_Rename("ki2", "ki");
ok(!exists $KV{"OpenRouter_ki_apiKey"} && $KV{"OpenRouter_ki2_apiKey"} eq "sk-neu", "rename nimmt den Key mit");
OpenRouter_Delete($h, "ki2");
ok(!exists $KV{"OpenRouter_ki2_apiKey"}, "delete entfernt den Key");

print "\n=== Define setzt nichts zurück ===\n";
$h = setup();
$h->{READINGS}{totalTokenCount}{VAL} = 1234;
$h->{READINGS}{state}{VAL} = "ok";
OpenRouter_Define($h, "ki OpenRouter");
ok($h->{READINGS}{totalTokenCount}{VAL} == 1234 && $h->{READINGS}{state}{VAL} eq "ok", "defmod/Neustart: Readings bleiben");
ok($h->{FVERSION} =~ /^98_OpenRouter\.pm:v\d+\.\d+\.\d+$/, "FVERSION gesetzt");

print "\n=== Callback stirbt nicht ===\n";
$h = setup();
my $ok = eval { OpenRouter_HandleResponse({ hash => $h }, "", '{"choices":"kaputt"}'); 1 };
ok($ok && ReadingsVal("ki", "lastError", "") =~ /Interner Fehler/, "unerwartete Antwort -> lastError statt die()");

print "\n=== Befehle im Kontext ===\n";
$SETS{Lampe} = "on:noArg off:noArg factoryReset:noArg pair:noArg tplSet_1:noArg";
my $cmds = OpenRouter_GetShortCmds("Lampe", []);
ok($cmds =~ /on/ && $cmds !~ /factoryReset|pair|tplSet_/, "factoryReset/pair/tplSet_ gehen nicht an das Modell");

print "\n=== readingFilterToggle ===\n";
$h = setup();
@CMDS = ();
OpenRouter_Set($h, "ki", "readingFilterToggle", "Tuer", "battery", "disable");
ok((grep { /^attr ki readingFilter Tuer:battery$/ } @CMDS) ? 1 : 0, "Funktion vorhanden, setzt readingFilter");

print "\n=== Code-Struktur ===\n";
my $file = dirname(abs_path(__FILE__)) . "/../FHEM/98_OpenRouter.pm";
open(my $fh, "<", $file) or die $!;
my $src = do { local $/; <$fh> };
close($fh);
(my $code = $src) =~ s/^=\w+.*?^=cut\s*$//msg;      # POD (Doku, Auskommentiertes) raus
my %n;
$n{$1}++ while ($code =~ /^sub (\w+)/mg);
my @dup = grep { $n{$_} > 1 } sort keys %n;
ok(!@dup, "keine doppelt definierten Subs" . (@dup ? ": @dup" : ""));
ok($code !~ /^\s*use JSON\s*;/m, "use JSON ohne Import nach main");
my $host = "git" . "hub.com";
ok($src !~ /\Q$host\E/, "keine $host-Adresse im Modul (Anon-Spiegel)");
my ($v1) = $src =~ /# Version:\s+v(\S+)/;
my ($v2) = $src =~ /\{VERSION\}\s*=\s*'([^']+)'/;
ok($v1 && $v2 && $v1 eq $v2, "Version Kopf ($v1) = VERSION ($v2)");
done();
