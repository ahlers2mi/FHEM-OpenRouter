#!/usr/bin/perl
#
# v1.3.0: Function Calling darf nur, was die Attribute freigeben.
# Gegenprobe: gegen v1.2.0 sind die Ablehnungs-Tests rot.

use strict;
use warnings;
use File::Basename qw(dirname);
use Cwd qw(abs_path);
my $stub = dirname(abs_path(__FILE__)) . "/fhem_stub.pl";
require $stub;
our (@CMDS);

my $h = setup();
my $r;

print "=== set_device ===\n";
$r = OpenRouter_ExecuteFunctionCall($h, "set_device", { device => "Lampe", command => "on" });
ok(cmds('^set Lampe on$') && $r =~ /^OK/, "Lampe (controlRoom) on -> ausgeführt");
@CMDS = ();
$r = OpenRouter_ExecuteFunctionCall($h, "set_device", { device => "Alarm", command => "off" });
ok(!@CMDS && $r =~ /nicht in controlList/, "Alarm (nicht freigegeben) -> abgelehnt");
$r = OpenRouter_ExecuteFunctionCall($h, "set_device", { device => "Lampe", command => "on'x" });
ok(!@CMDS && $r =~ /unerlaubte Zeichen/, "Hochkomma im Befehl -> abgelehnt");

print "\n=== create_at_device ===\n";
$r = OpenRouter_ExecuteFunctionCall($h, "create_at_device",
     { device_name => "x", time_spec => "+00:00:05 {qx/id/}", command => "set Lampe on" });
ok(!cmds('^define') && $r =~ /time_spec/, "Code in time_spec -> abgelehnt");
$r = OpenRouter_ExecuteFunctionCall($h, "create_at_device",
     { device_name => "x", time_spec => "+00:10:00", command => "delete n_teleBot" });
ok(!cmds('^define') && $r =~ /nicht steuerbar|set <Gerät>/, "beliebiger FHEM-Befehl (delete) -> abgelehnt");
$r = OpenRouter_ExecuteFunctionCall($h, "create_at_device",
     { device_name => "x", time_spec => "+00:10:00", command => "set Alarm off" });
ok(!cmds('^define') && $r =~ /nicht steuerbar/, "set auf nicht steuerbares Gerät -> abgelehnt");
$r = OpenRouter_ExecuteFunctionCall($h, "create_at_device",
     { device_name => "licht", time_spec => "+00:10:00", command => "set Lampe off" });
ok(cmds('^define at_ki_\w+_licht at \+00:10:00 set Lampe off$'), "einmaliges at: +00:10:00 set Lampe off");
ok(!cmds('^modify'), "kein nachträgliches modify mehr (FHEM löscht at ohne * selbst)");
@CMDS = ();
OpenRouter_ExecuteFunctionCall($h, "create_at_device",
     { device_name => "abends", time_spec => "22:00", command => "Lampe off", recurring => 1 });
ok(cmds('^define at_ki_\w+_abends at \*22:00 set Lampe off$'), "wiederkehrend: *22:00, Befehl ohne 'set' wird ergänzt");

print "\n=== create_notify_device ===\n";
@CMDS = ();
$r = OpenRouter_ExecuteFunctionCall($h, "create_notify_device",
     { device_name => "x", event_spec => "Tuer:open {qx/id/}", command => "set Lampe on" });
ok(!cmds('^define') && $r =~ /Leerzeichen/, "Leerzeichen/Code im event_spec -> abgelehnt");
$r = OpenRouter_ExecuteFunctionCall($h, "create_notify_device",
     { device_name => "x", event_spec => "Gibtsnicht:open", command => "set Lampe on" });
ok(!cmds('^define') && $r =~ /unbekannt/, "unbekanntes Gerät im event_spec -> abgelehnt");
$r = OpenRouter_ExecuteFunctionCall($h, "create_notify_device",
     { device_name => "x", event_spec => "Tuer:open", command => "set Lampe on'.qx/id/.'" });
ok(!cmds('^define') && $r =~ /unerlaubte Zeichen/, "Ausbruch über ' im Befehl -> abgelehnt");
$r = OpenRouter_ExecuteFunctionCall($h, "create_notify_device",
     { device_name => "tuerlicht", event_spec => "Tuer:open", command => "set Lampe on", one_shot => 1 });
ok(cmds('^define (n_ki_\w+_tuerlicht) notify Tuer:open set Lampe on; delete n_ki_\w+_tuerlicht$'),
   "einmaliger notify: Befehlskette ohne Perl");
ok(!cmds('\{'), "kein { ... } im notify");

print "\n=== Lesen nur freigegebener Geräte ===\n";
$r = OpenRouter_ExecuteFunctionCall($h, "get_device_state", { device => "Alarm" });
ok($r =~ /nicht freigegeben/, "Alarm lesen -> abgelehnt");
$r = OpenRouter_ExecuteFunctionCall($h, "get_device_state", { device => "Tuer" });
ok($r =~ /^Gerät: Tuer/, "Tuer (deviceRoom) lesen -> ok");
$r = OpenRouter_ExecuteFunctionCall($h, "get_device_commands", { device => "Alarm" });
ok($r =~ /nicht freigegeben/, "Befehle von Alarm -> abgelehnt");

print "\n=== Absender ohne Berechtigung ===\n";
$h = setup(allowedSenders => "Michael_Ahlers,Maike_Palm");
OpenRouter_SendRequest($h, "Fremder=mach das Licht an", undef, 1);
my $req = last_request();
my @tools = map { $_->{function}{name} } @{$req->{tools}};
ok("@tools" eq "get_device_state", "nicht autorisiert: nur Lese-Tool angeboten");
@CMDS = ();
$r = OpenRouter_ExecuteFunctionCall($h, "set_device", { device => "Lampe", command => "on" });
ok(!@CMDS && $r =~ /nicht autorisiert/, "Steuerbefehl trotzdem geschickt -> im Modul abgelehnt");
OpenRouter_SendRequest($h, "Michael_Ahlers=mach das Licht an", undef, 1);
@tools = map { $_->{function}{name} } @{last_request()->{tools}};
ok((grep { $_ eq "set_device" } @tools) ? 1 : 0, "autorisiert: Steuer-Tools angeboten");
OpenRouter_SendRequest($h, "Licht an", undef, 1);
@tools = map { $_->{function}{name} } @{last_request()->{tools}};
ok((grep { $_ eq "set_device" } @tools) ? 1 : 0, "ohne Absender (direkt aus FHEM): Steuer-Tools wie bisher");
done();
