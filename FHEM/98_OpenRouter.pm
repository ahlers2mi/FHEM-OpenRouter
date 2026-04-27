##############################################################################
# 98_OpenRouter.pm
#
# FHEM Modul für OpenRouter AI API (Multi-Provider LLM Gateway)
#
# Funktionen:
#   - Text-Anfragen an verschiedene LLMs (Claude, GPT-4, Gemini, etc.) senden
#   - Bilder (Base64 oder Dateipfad) senden
#   - Chat-Verlauf (Multi-Turn) beibehalten
#   - Chat zurücksetzen
#   - FHEM-Geräte per Function Calling steuern (bei unterstützten Modellen)
#   - AT-Devices (zeitgesteuert) anlegen
#   - NOTIFY-Devices (eventbasiert) anlegen mit Auto-Cleanup
#   - Reading-Filter per Checkbox-Widget in FHEMWEB
#
# Attribute:
#   apiKey               - OpenRouter API Key (Pflicht)
#   model                - LLM Modell (Standard: google/gemini-2.0-flash-exp)
#   maxHistory           - Maximale Anzahl Chat-Nachrichten (Standard: 20)
#   systemPrompt         - Optionaler System-Prompt
#   timeout              - HTTP Timeout in Sekunden (Standard: 30)
#   deviceList           - Komma-getrennte Liste der Geräte für Statusabfragen
#   deviceRoom           - Komma-getrennte Raumliste für Statusabfragen
#   controlList          - Komma-getrennte Liste der steuerbaren Geräte
#   controlRoom          - Komma-getrennte Raumliste steuerbarer Geräte
#   automationRoom       - Raum für automatisch angelegte AT/NOTIFY-Geräte
#   disableHistory       - Chat-Verlauf deaktivieren (0/1)
#   readingBlacklist     - Globale Blacklist für Readings (Wildcards erlaubt)
#   readingFilter        - Gerätespezifische deaktivierte Readings (via Widget)
#   maxReadingsPerDevice - Maximale Anzahl Readings pro Gerät (Standard: 20)
#
# Set-Befehle:
#   ask <Frage>                    - Textfrage stellen
#   askWithImage <Pfad> <Frage>    - Bild + Frage senden (nur bei Vision-Modellen)
#   askAboutDevices [<Frage>]      - Geräte-Statusabfrage (LLM fragt selbst nach)
#   chat <Nachricht>               - Universeller Befehl (Fragen, Status, Steuerung)
#   control <Anweisung>            - LLM steuert Geräte via Function Calling
#   resetChat                      - Chat-Verlauf löschen
#   collectReadings                - Bekannte Readings neu einlesen (für Widget)
#   readingFilterToggle            - Intern: Reading ein/ausschalten (via Widget)
#
# Readings:
#   response           - Letzte Antwort vom LLM (Roh-Markdown)
#   responsePlain      - Letzte Antwort, Markdown bereinigt
#   responseHTML       - Letzte Antwort, Markdown in HTML konvertiert
#   state              - Aktueller Status
#   lastError          - Letzter Fehler
#   chatHistory        - Anzahl der Nachrichten im Verlauf
#   lastCommand        - Letzter ausgeführter set-Befehl
#   lastCommandResult  - Ergebnis des letzten set-Befehls
#   lastAutomation     - Letztes angelegtes AT/NOTIFY-Gerät
#   promptTokenCount   - Anzahl Input-Tokens
#   candidatesTokenCount - Anzahl Output-Tokens
#   totalTokenCount    - Gesamte Token-Anzahl
#
##############################################################################

# Versionshistorie:
# 1.0.0 - 2026-04-27  Initiale Version
# 1.1.0 - 2026-04-27  Unified Device Context (keine Dopplung mehr)
#                     Readings per Tool nachladen (Prompt Caching optimiert)
#                     Reading-Filter Widget in FHEMWEB
#                     Ein einziger Send-Pfad für alle Befehle

package main;

use strict;
use warnings;
use HttpUtils;
use JSON;
use MIME::Base64;

##############################################################################
# Initialize
##############################################################################
sub OpenRouter_Initialize {
    my ($hash) = @_;

    $hash->{DefFn}       = 'OpenRouter_Define';
    $hash->{UndefFn}     = 'OpenRouter_Undefine';
    $hash->{SetFn}       = 'OpenRouter_Set';
    $hash->{GetFn}       = 'OpenRouter_Get';
    $hash->{AttrFn}      = 'OpenRouter_Attr';
    $hash->{FW_detailFn} = 'OpenRouter_FW_detail';

    $hash->{AttrList} =
        'apiKey ' .
        'model ' .
        'maxHistory:5,10,20,50,100 ' .
        'maxReadingsPerDevice ' .
        'timeout ' .
        'disable:0,1 ' .
        'disableHistory:0,1 ' .
        'deviceList:textField-long ' .
        'controlList:textField-long ' .
        'controlRoom:textField-long ' .
        'deviceRoom:textField-long ' .
        'automationRoom ' .
        'systemPrompt:textField-long ' .
        'readingBlacklist:textField-long ' .
        'readingFilter:textField-long ' .
        $readingFnAttributes;

    return undef;
}

##############################################################################
# Define
##############################################################################
sub OpenRouter_Define {
    my ($hash, $def) = @_;
    my @args = split('[ \t]+', $def);

    return "Usage: define <name> OpenRouter" if @args < 2;

    my $name = $args[0];
    $hash->{NAME}    = $name;
    $hash->{CHAT}    = [];
    $hash->{VERSION} = '1.1.0';

    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, 'state',                'initialized');
    readingsBulkUpdate($hash, 'response',             '-');
    readingsBulkUpdate($hash, 'responsePlain',        '-');
    readingsBulkUpdate($hash, 'responseHTML',         '-');
    readingsBulkUpdate($hash, 'chatHistory',          0);
    readingsBulkUpdate($hash, 'lastError',            '-');
    readingsBulkUpdate($hash, 'lastCommand',          '-');
    readingsBulkUpdate($hash, 'lastCommandResult',    '-');
    readingsBulkUpdate($hash, 'lastAutomation',       '-');
    readingsBulkUpdate($hash, 'promptTokenCount',     0);
    readingsBulkUpdate($hash, 'candidatesTokenCount', 0);
    readingsBulkUpdate($hash, 'totalTokenCount',      0);
    readingsEndUpdate($hash, 1);

    Log3 $name, 3, "OpenRouter ($name): Defined v$hash->{VERSION}";
    return undef;
}

##############################################################################
# Undefine
##############################################################################
sub OpenRouter_Undefine {
    my ($hash, $name) = @_;
    return undef;
}

##############################################################################
# Attr
##############################################################################
sub OpenRouter_Attr {
    my ($cmd, $name, $attr, $value) = @_;

    if ($attr eq 'timeout') {
        return "timeout must be a positive number"
            unless $value =~ /^\d+$/ && $value > 0;
    }
    if ($attr eq 'maxReadingsPerDevice') {
        return "maxReadingsPerDevice must be a positive number"
            unless $value =~ /^\d+$/ && $value > 0;
    }

    # Bei Änderung der Gerätelisten: Cache invalidieren
    if ($attr =~ /^(?:deviceList|deviceRoom|controlList|controlRoom|readingBlacklist|readingFilter)$/) {
        my $hash = $main::defs{$name};
        delete $hash->{helper}{knownReadings} if $hash;
    }

    return undef;
}

##############################################################################
# Set
##############################################################################
sub OpenRouter_Set {
    my ($hash, $name, $cmd, @args) = @_;

    return "\"set $name\" needs at least one argument" unless defined $cmd;

    if ($cmd eq 'ask') {
        return "Usage: set $name ask <Frage>" unless @args;
        OpenRouter_SendRequest($hash, join(' ', @args), undef, 0);
        return undef;

    } elsif ($cmd eq 'askWithImage') {
        return "Usage: set $name askWithImage <Bildpfad> <Frage>" unless @args >= 2;
        my $imagePath = $args[0];
        my $question  = join(' ', @args[1..$#args]);
        return "Bilddatei nicht gefunden: $imagePath" unless -f $imagePath;
        OpenRouter_SendRequest($hash, $question, $imagePath, 0);
        return undef;

    } elsif ($cmd eq 'askAboutDevices') {
        my $question = @args
            ? join(' ', @args)
            : 'Gib mir eine Zusammenfassung aller Geräte und ihres aktuellen Status.';
        OpenRouter_SendRequest($hash, $question, undef, 1);
        return undef;

    } elsif ($cmd eq 'chat') {
        return "Usage: set $name chat <Nachricht>" unless @args;
        OpenRouter_SendRequest($hash, join(' ', @args), undef, 1);
        return undef;

    } elsif ($cmd eq 'control') {
        return "Usage: set $name control <Anweisung>" unless @args;
        my @ctrl = OpenRouter_GetControlDevices($hash);
        return "Fehler: Weder controlList noch controlRoom ist gesetzt" unless @ctrl;
        OpenRouter_SendRequest($hash, join(' ', @args), undef, 1);
        return undef;

    } elsif ($cmd eq 'resetChat') {
        $hash->{CHAT} = [];
        readingsSingleUpdate($hash, 'chatHistory', 0, 1);
        readingsSingleUpdate($hash, 'state', 'chat reset', 1);
        Log3 $name, 3, "OpenRouter ($name): Chat-Verlauf zurückgesetzt";
        return undef;

    } elsif ($cmd eq 'collectReadings') {
        OpenRouter_CollectAllReadings($hash);
        my $count = 0;
        for my $dev (keys %{$hash->{helper}{knownReadings} // {}}) {
            $count += scalar keys %{$hash->{helper}{knownReadings}{$dev}};
        }
        readingsSingleUpdate($hash, 'state', "collected $count readings", 1);
        return undef;

    } elsif ($cmd eq 'readingFilterToggle') {
        return "Usage: set $name readingFilterToggle <device> <reading> enable|disable"
            unless @args == 3;
        my ($dev, $reading, $action) = @args;
        OpenRouter_ToggleReadingFilter($hash, $dev, $reading, $action eq 'disable' ? 1 : 0);
        return undef;

    } else {
        return "Unknown argument $cmd, choose one of " .
               "ask:textField askWithImage:textField askAboutDevices:textField " .
               "chat:textField control:textField resetChat:noArg collectReadings:noArg";
    }
}

##############################################################################
# Get
##############################################################################
sub OpenRouter_Get {
    my ($hash, $name, $cmd, @args) = @_;

    if ($cmd eq 'chatHistory') {
        my $history = $hash->{CHAT};
        my $output  = "Chat-Verlauf (" . scalar(@$history) . " Einträge):\n";
        $output    .= "-" x 60 . "\n";
        for my $i (0..$#$history) {
            my $msg  = $history->[$i];
            my $role = $msg->{role} eq 'user' ? 'Du' : 'AI';
            my $text = '';
            if (exists $msg->{content}) {
                if (ref($msg->{content}) eq 'ARRAY') {
                    for my $part (@{$msg->{content}}) {
                        if (ref($part) eq 'HASH') {
                            $text .= $part->{text}      if exists $part->{text};
                            $text .= '[Bild]'           if exists $part->{image_url};
                        } else {
                            $text .= $part;
                        }
                    }
                } else {
                    $text = $msg->{content};
                }
            }
            $output .= sprintf("[%02d] %s: %s\n", $i+1, $role, $text);
        }
        return $output;
    }

    return "Unknown argument $cmd, choose one of chatHistory:noArg";
}

##############################################################################
# FHEMWEB Detail-Widget für Reading-Filter
##############################################################################
sub OpenRouter_FW_detail {
    my ($FW_wname, $devName, $room, $pageHash) = @_;

    return '' unless exists $main::defs{$devName};
    my $hash = $main::defs{$devName};
    return '' unless $hash->{TYPE} eq 'OpenRouter';

    # Readings einsammeln falls noch nicht geschehen
    OpenRouter_CollectAllReadings($hash);

    my %disabled = OpenRouter_ParseReadingFilter($hash);
    my $knownRef = $hash->{helper}{knownReadings} // {};

    return '' unless %$knownRef;

    my $name = $devName;
    my $html = '';

    $html .= '<div id="openrouter_rf_widget" style="margin:10px 0;padding:10px;' .
             'border:1px solid #ccc;border-radius:4px;background:#f9f9f9;">';
    $html .= '<b>Reading-Filter</b>';
    $html .= '&nbsp;<small style="color:#666">(deaktiviert = wird nicht ans LLM gesendet)</small>';
    $html .= '&nbsp;<button onclick="openrouter_rf_toggle_all()" ' .
             'style="font-size:0.8em;margin-left:10px">Alle umschalten</button>';
    $html .= '<br><br>';

    for my $dev (sort keys %$knownRef) {
        my @readings = sort keys %{$knownRef->{$dev}};
        next unless @readings;

        my $disabledCount = 0;
        for my $r (@readings) {
            $disabledCount++ if OpenRouter_IsReadingDisabled(\%disabled, $dev, $r);
        }

        $html .= '<details style="margin-bottom:5px;">';
        $html .= sprintf('<summary style="cursor:pointer;font-weight:bold">%s ' .
                         '<span style="font-weight:normal;color:#666">(%d Readings, %d deaktiviert)</span>' .
                         '</summary>',
                         $dev, scalar(@readings), $disabledCount);
        $html .= '<div style="margin:5px 0 5px 15px;display:flex;flex-wrap:wrap;">';

        for my $r (@readings) {
            my $isDisabled = OpenRouter_IsReadingDisabled(\%disabled, $dev, $r);
            my $checked    = $isDisabled ? '' : 'checked';
            my $cbId       = "rf_${dev}_${r}";
            $cbId =~ s/[^a-zA-Z0-9_]/_/g;

            $html .= sprintf(
                '<label style="display:inline-block;min-width:180px;margin:2px 8px 2px 0;' .
                'padding:2px 5px;background:%s;border-radius:3px;">' .
                '<input type="checkbox" id="%s" %s ' .
                'onchange="openrouter_rf_change(\'%s\',\'%s\',\'%s\',this.checked)"> %s</label>',
                $isDisabled ? '#ffe0e0' : '#e0ffe0',
                $cbId, $checked, $name, $dev, $r, $r
            );
        }

        $html .= '</div></details>';
    }

    $html .= '</div>';

    $html .= <<'JSEND';
<script>
function openrouter_rf_change(orName, devName, reading, isChecked) {
    var action = isChecked ? 'enable' : 'disable';
    var cmd = 'set ' + orName + ' readingFilterToggle ' + devName + ' ' + reading + ' ' + action;
    FW_cmd(FW_root + '?XHR=1&cmd=' + encodeURIComponent(cmd), function(resp) {
        var cbId = 'rf_' + devName + '_' + reading;
        cbId = cbId.replace(/[^a-zA-Z0-9_]/g, '_');
        var el = document.getElementById(cbId);
        if (el) {
            el.parentElement.style.background = isChecked ? '#e0ffe0' : '#ffe0e0';
            el.parentElement.style.outline = '2px solid #4a4';
            setTimeout(function(){ el.parentElement.style.outline = ''; }, 800);
        }
    });
}
function openrouter_rf_toggle_all() {
    var cbs = document.querySelectorAll('#openrouter_rf_widget input[type=checkbox]');
    var checkedCount = 0;
    cbs.forEach(function(cb){ if (cb.checked) checkedCount++; });
    var newState = checkedCount < cbs.length;
    cbs.forEach(function(cb){
        if (cb.checked !== newState) {
            cb.checked = newState;
            cb.dispatchEvent(new Event('change'));
        }
    });
}
</script>
JSEND

    return $html;
}

##############################################################################
# Hilfsfunktion: Alle bekannten Readings aller Geräte einsammeln
##############################################################################
sub OpenRouter_CollectAllReadings {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    my %seen;
    my @allDevices = (OpenRouter_GetDeviceList($hash), OpenRouter_GetControlDevices($hash));

    for my $devName (@allDevices) {
        next if $seen{$devName}++;
        next unless exists $main::defs{$devName};
        my $dev = $main::defs{$devName};
        next unless exists $dev->{READINGS};
        for my $reading (sort keys %{$dev->{READINGS}}) {
            $hash->{helper}{knownReadings}{$devName}{$reading} = 1;
        }
    }
    return;
}

##############################################################################
# Hilfsfunktion: readingFilter-Attribut parsen
# Rückgabe: { DeviceName => { reading => 1 } }
##############################################################################
sub OpenRouter_ParseReadingFilter {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    my $attr = AttrVal($name, 'readingFilter', '');

    my %disabled;
    return %disabled unless $attr;

    for my $token (split(/\s+/, $attr)) {
        if ($token =~ /^([^:]+):(.+)$/) {
            my ($dev, $readings) = ($1, $2);
            for my $r (split(/,/, $readings)) {
                $disabled{$dev}{$r} = 1 if $r;
            }
        }
    }
    return %disabled;
}

##############################################################################
# Hilfsfunktion: Prüft ob ein Reading für ein Gerät deaktiviert ist
##############################################################################
sub OpenRouter_IsReadingDisabled {
    my ($disabledRef, $devName, $reading) = @_;
    return 1 if exists $disabledRef->{'*'}{$reading};
    return 1 if exists $disabledRef->{$devName}{$reading};
    return 0;
}

##############################################################################
# Hilfsfunktion: readingFilter-Attribut aktualisieren
##############################################################################
sub OpenRouter_ToggleReadingFilter {
    my ($hash, $devName, $reading, $disable) = @_;
    my $name = $hash->{NAME};

    my %disabled = OpenRouter_ParseReadingFilter($hash);

    if ($disable) {
        $disabled{$devName}{$reading} = 1;
    } else {
        delete $disabled{$devName}{$reading};
        delete $disabled{$devName} unless keys %{$disabled{$devName} // {}};
    }

    my @parts;
    for my $dev (sort keys %disabled) {
        my @readings = sort keys %{$disabled{$dev}};
        push @parts, "$dev:" . join(',', @readings) if @readings;
    }

    my $newAttr = join(' ', @parts);
    if ($newAttr) {
        CommandAttr(undef, "$name readingFilter $newAttr");
    } else {
        CommandDeleteAttr(undef, "$name readingFilter");
    }
    return;
}

##############################################################################
# Hilfsfunktion: Globale Blacklist holen
##############################################################################
sub OpenRouter_GetBlacklist {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    my $attr = AttrVal($name, 'readingBlacklist', '');

    return split(/\s+/, $attr) if $attr ne '';

    return qw(
        attrTemplate associate R-* RegL_* associatedWith
        peerListRDate protLastRcv lastTimeSync lastcmd
        Heap LoadAvg Uptime Wifi_*
    );
}

##############################################################################
# Hilfsfunktion: Prüft ob ein Reading global geblacklistet ist
##############################################################################
sub OpenRouter_IsBlacklisted {
    my ($entry, @patterns) = @_;
    for my $pat (@patterns) {
        return 1 if OpenRouter_GlobMatch($pat, $entry);
    }
    return 0;
}

sub OpenRouter_GlobMatch {
    my ($pat, $str) = @_;
    return ($str eq $pat) unless index($pat, '*') >= 0;
    return 1 if $pat eq '*';

    my @parts  = split(/\*/, $pat, -1);
    my $prefix = shift @parts;
    my $suffix = pop   @parts;

    return 0 if length($prefix) && substr($str, 0, length($prefix)) ne $prefix;
    return 0 if length($suffix) && substr($str, -length($suffix))   ne $suffix;

    my $pos = length($prefix);
    for my $mid (@parts) {
        next unless length($mid);
        my $found = index($str, $mid, $pos);
        return 0 if $found < 0;
        $pos = $found + length($mid);
    }
    return 1;
}

##############################################################################
# Hilfsfunktion: Kombinierter Filter (Blacklist + readingFilter)
##############################################################################
sub OpenRouter_IsFiltered {
    my ($hash, $devName, $reading, $disabledRef) = @_;

    # 1. Globale Blacklist
    my @blacklist = OpenRouter_GetBlacklist($hash);
    return 1 if OpenRouter_IsBlacklisted($reading, @blacklist);

    # 2. Gerätespezifischer Filter
    if ($disabledRef) {
        return 1 if OpenRouter_IsReadingDisabled($disabledRef, $devName, $reading);
    }

    return 0;
}

##############################################################################
# Hilfsfunktion: Liste der Geräte aus deviceList/deviceRoom
##############################################################################
sub OpenRouter_GetDeviceList {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    my %seen;
    my @devices;

    my $deviceRoom = AttrVal($name, 'deviceRoom', '');
    if ($deviceRoom) {
        my @rooms = split(/\s*,\s*/, $deviceRoom);
        for my $devName (sort keys %main::defs) {
            my $devRoomAttr = AttrVal($devName, 'room', '');
            for my $room (@rooms) {
                if (grep { $_ eq $room } split(/\s*,\s*/, $devRoomAttr)) {
                    unless ($seen{$devName}) {
                        push @devices, $devName;
                        $seen{$devName} = 1;
                    }
                    last;
                }
            }
        }
    }

    my $devList = AttrVal($name, 'deviceList', '');
    if ($devList) {
        for my $devName (split(/\s*,\s*/, $devList)) {
            unless ($seen{$devName}) {
                push @devices, $devName;
                $seen{$devName} = 1;
            }
        }
    }

    return @devices;
}

##############################################################################
# Hilfsfunktion: Liste der steuerbaren Geräte
##############################################################################
sub OpenRouter_GetControlDevices {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    my %seen;
    my @devices;

    my $controlRoom = AttrVal($name, 'controlRoom', '');
    if ($controlRoom) {
        my @rooms = split(/\s*,\s*/, $controlRoom);
        for my $devName (sort keys %main::defs) {
            my $devRoomAttr = AttrVal($devName, 'room', '');
            for my $room (@rooms) {
                if (grep { $_ eq $room } split(/\s*,\s*/, $devRoomAttr)) {
                    unless ($seen{$devName}) {
                        push @devices, $devName;
                        $seen{$devName} = 1;
                    }
                    last;
                }
            }
        }
    }

    my $controlList = AttrVal($name, 'controlList', '');
    if ($controlList) {
        for my $devName (split(/\s*,\s*/, $controlList)) {
            unless ($seen{$devName}) {
                push @devices, $devName;
                $seen{$devName} = 1;
            }
        }
    }

    return @devices;
}

##############################################################################
# Hilfsfunktion: Raum für Automation-Geräte
##############################################################################
sub OpenRouter_GetAutomationRoom {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    my $automationRoom = AttrVal($name, 'automationRoom', '');
    return $automationRoom if $automationRoom;

    my $myRooms = AttrVal($name, 'room', '');
    if ($myRooms) {
        my @rooms = split(/\s*,\s*/, $myRooms);
        return $rooms[0] if @rooms;
    }

    return '';
}

##############################################################################
# UNIFIED STATIC CONTEXT: Ein Block für alle Geräte (cachebar)
# Spalten: name(alias)|type|ctrl|R:readings|cmds|comment
##############################################################################
sub OpenRouter_BuildUnifiedDeviceContext {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    # Rollen sammeln
    my %deviceRoles;
    for my $dev (OpenRouter_GetDeviceList($hash)) {
        $deviceRoles{$dev}{list} = 1;
    }
    for my $dev (OpenRouter_GetControlDevices($hash)) {
        $deviceRoles{$dev}{control} = 1;
    }

    return '' unless %deviceRoles;

    my @blacklist   = OpenRouter_GetBlacklist($hash);
    my %disabled    = OpenRouter_ParseReadingFilter($hash);
    my $maxReadings = AttrVal($name, 'maxReadingsPerDevice', 20);

    my $context  = "FHEM Geräte:\n";
    $context    .= "name(alias)|type|ctrl|R:readings|cmds|comment\n";
    $context    .= "ctrl=steuerbar ro=nur-lesen\n\n";

    for my $devName (sort keys %deviceRoles) {
        next unless exists $main::defs{$devName};
        my $dev    = $main::defs{$devName};
        my $alias  = AttrVal($devName, 'alias', '');
        my $type   = $dev->{TYPE} // '?';
        my $isCtrl = $deviceRoles{$devName}{control} ? 'ctrl' : 'ro';

        # name(alias)
        $context .= $devName;
        $context .= "($alias)" if $alias && $alias ne $devName;
        $context .= "|$type|$isCtrl";

        # Readings (nur Namen, keine Werte - cachebar!)
        if (exists $dev->{READINGS}) {
            my @readings = grep {
                $_ ne 'state' &&
                !OpenRouter_IsFiltered($hash, $devName, $_, \%disabled)
            } sort keys %{$dev->{READINGS}};

            my $truncated = scalar(@readings) > $maxReadings;
            @readings = @readings[0..$maxReadings-1] if $truncated;

            $context .= '|R:' . join(',', @readings);
            $context .= '...' if $truncated;
        } else {
            $context .= '|';
        }

        # Set-Befehle nur bei steuerbaren Geräten
        if ($deviceRoles{$devName}{control}) {
            my $setListRaw = main::getAllSets($devName) // '';
            my @cmds;
            for my $entry (split(/\s+/, $setListRaw)) {
                my ($cmdName) = split(/:/, $entry, 2);
                next unless $cmdName;
                next if OpenRouter_IsBlacklisted($cmdName, @blacklist);
                push @cmds, $entry;
            }
            $context .= '|' . join(',', @cmds);
        } else {
            $context .= '|';
        }

        # Kommentar
        my $aiComment = AttrVal($devName, $name . 'Comment', '');
        $context .= "|$aiComment" if $aiComment;

        $context .= "\n";
    }

    $context .= "\nNutze get_device_state() für aktuelle Werte.\n";

    return $context;
}

##############################################################################
# Tools: Nur Lesen (für ask/askAboutDevices ohne controlList)
##############################################################################
sub OpenRouter_GetReadTools {
    return [
        {
            type => 'function',
            function => {
                name        => 'get_device_state',
                description => 'Liest den aktuellen Status und alle Readings eines FHEM-Geräts. ' .
                               'Kann mehrfach parallel aufgerufen werden.',
                parameters  => {
                    type       => 'object',
                    properties => {
                        device => {
                            type        => 'string',
                            description => 'FHEM Gerätename (intern)'
                        }
                    },
                    required => ['device']
                }
            }
        }
    ];
}

##############################################################################
# Tools: Lesen + Steuern (für control/chat mit controlList)
##############################################################################
sub OpenRouter_GetControlTools {
    return [
        @{OpenRouter_GetReadTools()},
        {
            type => 'function',
            function => {
                name        => 'set_device',
                description => 'Führt einen FHEM set-Befehl auf einem Gerät aus. ' .
                               'Kann PARALLEL mehrfach aufgerufen werden.',
                parameters  => {
                    type       => 'object',
                    properties => {
                        device  => { type => 'string', description => 'FHEM Gerätename (intern)' },
                        command => { type => 'string', description => 'set-Befehl, z.B. on, off, 21' }
                    },
                    required => ['device', 'command']
                }
            }
        },
        {
            type => 'function',
            function => {
                name        => 'create_at_device',
                description => 'Legt ein zeitgesteuertes AT-Device in FHEM an.',
                parameters  => {
                    type       => 'object',
                    properties => {
                        device_name => { type => 'string', description => 'Name des neuen AT-Geräts' },
                        time_spec   => { type => 'string', description => 'HH:MM:SS, +HH:MM:SS, *HH:MM:SS' },
                        command     => { type => 'string', description => 'FHEM set-Befehl' },
                        recurring   => { type => 'boolean', description => 'true=wiederkehrend, false=einmalig' }
                    },
                    required => ['device_name', 'time_spec', 'command']
                }
            }
        },
        {
            type => 'function',
            function => {
                name        => 'create_notify_device',
                description => 'Legt ein eventbasiertes NOTIFY-Device in FHEM an.',
                parameters  => {
                    type       => 'object',
                    properties => {
                        device_name => { type => 'string', description => 'Name des neuen NOTIFY-Geräts' },
                        event_spec  => { type => 'string', description => 'Gerätename:Event-Pattern' },
                        command     => { type => 'string', description => 'FHEM set-Befehl' },
                        one_shot    => { type => 'boolean', description => 'true=einmalig (löscht sich), false=permanent' }
                    },
                    required => ['device_name', 'event_spec', 'command']
                }
            }
        }
    ];
}

##############################################################################
# Hauptfunktion: Anfrage senden (einziger Pfad für alle Befehle)
##############################################################################
sub OpenRouter_SendRequest {
    my ($hash, $question, $imagePath, $includeDeviceContext) = @_;
    my $name = $hash->{NAME};

    if (AttrVal($name, 'disable', 0)) {
        readingsSingleUpdate($hash, 'state', 'disabled', 1);
        return;
    }

    my $apiKey = AttrVal($name, 'apiKey', '');
    if (!$apiKey) {
        readingsSingleUpdate($hash, 'lastError', 'Kein API Key gesetzt (attr apiKey)', 1);
        readingsSingleUpdate($hash, 'state', 'error', 1);
        Log3 $name, 1, "OpenRouter ($name): Kein API Key konfiguriert!";
        return;
    }

    my $model      = AttrVal($name, 'model', 'google/gemini-2.0-flash-exp');
    my $timeout    = AttrVal($name, 'timeout', 30);
    my $maxHistory = AttrVal($name, 'maxHistory', 20);

    # User-Message: nur Bild (falls vorhanden) + Frage
    # KEINE dynamischen Werte hier - die holt das LLM per Tool
    my @contentParts;

    if ($imagePath) {
        my $mimeType = OpenRouter_GetMimeType($imagePath);
        open(my $fh, '<', $imagePath) or do {
            readingsSingleUpdate($hash, 'lastError', "Kann Bild nicht lesen: $imagePath", 1);
            readingsSingleUpdate($hash, 'state', 'error', 1);
            return;
        };
        binmode($fh);
        local $/;
        my $imageData   = <$fh>;
        close($fh);
        my $base64Image = encode_base64($imageData, '');

        push @contentParts, {
            type      => 'image_url',
            image_url => { url => "data:${mimeType};base64,${base64Image}" }
        };
        Log3 $name, 4, "OpenRouter ($name): Bild geladen: $imagePath ($mimeType)";
    }

    push @contentParts, { type => 'text', text => $question };

    push @{$hash->{CHAT}}, {
        role    => 'user',
        content => \@contentParts
    };

    # History trimmen
    while (scalar(@{$hash->{CHAT}}) > $maxHistory) {
        shift @{$hash->{CHAT}};
    }

    # History muss mit user-message beginnen
    while (@{$hash->{CHAT}}) {
        last if $hash->{CHAT}[0]{role} eq 'user';
        shift @{$hash->{CHAT}};
    }

    my $disableHistory = AttrVal($name, 'disableHistory', 0);
    my $messagesToSend = $disableHistory ? [ $hash->{CHAT}[-1] ] : $hash->{CHAT};

    # Tools: control wenn controlList gesetzt, sonst nur read
    my @controlDevices = OpenRouter_GetControlDevices($hash);
    my $tools = @controlDevices
        ? OpenRouter_GetControlTools()
        : OpenRouter_GetReadTools();

    my %requestBody = (
        model    => $model,
        messages => $messagesToSend,
        tools    => $tools
    );

    # System Message: statischer Kontext (cachebar, ändert sich selten)
    my $systemPrompt  = AttrVal($name, 'systemPrompt', '');
    my $deviceContext = $includeDeviceContext
        ? OpenRouter_BuildUnifiedDeviceContext($hash)
        : '';

    my $fullSystem = join("\n\n", grep { $_ } ($systemPrompt, $deviceContext));

    if ($fullSystem) {
        unshift @{$requestBody{messages}}, {
            role    => 'system',
            content => $fullSystem
        };
    }

    my $jsonBody = eval { encode_json(\%requestBody) };
    if ($@) {
        readingsSingleUpdate($hash, 'lastError', "JSON Encode Fehler: $@", 1);
        readingsSingleUpdate($hash, 'state', 'error', 1);
        pop @{$hash->{CHAT}};
        return;
    }

    Log3 $name, 4, "OpenRouter ($name): Anfrage wird gesendet";
    Log3 $name, 5, "OpenRouter ($name): Request Body: $jsonBody";

    readingsSingleUpdate($hash, 'state', 'requesting...', 1);

    HttpUtils_NonblockingGet({
        url      => 'https://openrouter.ai/api/v1/chat/completions',
        timeout  => $timeout,
        method   => 'POST',
        header   => "Content-Type: application/json\r\n" .
                    "Authorization: Bearer ${apiKey}\r\n" .
                    "HTTP-Referer: https://fhem.de\r\n" .
                    "X-Title: FHEM-OpenRouter",
        data     => $jsonBody,
        hash     => $hash,
        callback => \&OpenRouter_HandleResponse,
    });

    return undef;
}

##############################################################################
# Callback: Antwort verarbeiten (einziger Callback für alle Anfragen)
##############################################################################
sub OpenRouter_HandleResponse {
    my ($param, $err, $data) = @_;
    my $hash = $param->{hash};
    my $name = $hash->{NAME};

    if ($err) {
        readingsSingleUpdate($hash, 'lastError', "HTTP Fehler: $err", 1);
        readingsSingleUpdate($hash, 'state', 'error', 1);
        Log3 $name, 1, "OpenRouter ($name): HTTP Fehler: $err";
        pop @{$hash->{CHAT}};
        return;
    }

    utf8::downgrade($data, 1);
    Log3 $name, 5, "OpenRouter ($name): Antwort raw: $data";

    my $result = eval { decode_json($data) };
    if ($@) {
        readingsSingleUpdate($hash, 'lastError', "JSON Parse Fehler: $@", 1);
        readingsSingleUpdate($hash, 'state', 'error', 1);
        Log3 $name, 1, "OpenRouter ($name): JSON Parse Fehler: $@";
        pop @{$hash->{CHAT}};
        return;
    }

    if (exists $result->{error}) {
        my $errMsg  = $result->{error}{message} // 'Unbekannter API Fehler';
        my $errCode = $result->{error}{code}    // 'N/A';
        readingsSingleUpdate($hash, 'lastError', "API Fehler $errCode: $errMsg", 1);
        readingsSingleUpdate($hash, 'state', 'error', 1);
        Log3 $name, 1, "OpenRouter ($name): API Fehler $errCode: $errMsg";
        pop @{$hash->{CHAT}};
        return;
    }

    # Token-Verbrauch
    if (exists $result->{usage}) {
        readingsBeginUpdate($hash);
        readingsBulkUpdate($hash, 'promptTokenCount',     $result->{usage}{prompt_tokens}     // 0);
        readingsBulkUpdate($hash, 'candidatesTokenCount', $result->{usage}{completion_tokens} // 0);
        readingsBulkUpdate($hash, 'totalTokenCount',      $result->{usage}{total_tokens}      // 0);
        readingsEndUpdate($hash, 1);
    }

    my $choice  = $result->{choices}[0];
    my $message = $choice->{message};

    # Tool Calls prüfen
    if (exists $message->{tool_calls} && ref($message->{tool_calls}) eq 'ARRAY' && @{$message->{tool_calls}}) {
        # Assistant-Message mit tool_calls in Chat speichern
        push @{$hash->{CHAT}}, $message;

        my @fcResults;
        for my $tc (@{$message->{tool_calls}}) {
            my $fcName = $tc->{function}{name}                              // '';
            my $args   = eval { decode_json($tc->{function}{arguments} // '{}') } // {};
            my $result = OpenRouter_ExecuteFunctionCall($hash, $fcName, $args);
            push @fcResults, {
                tool_call_id => $tc->{id},
                name         => $fcName,
                result       => $result
            };
        }

        if (scalar(@fcResults) > 1) {
            Log3 $name, 3, "OpenRouter ($name): " . scalar(@fcResults) . " parallele Tool-Aufrufe";
        }

        OpenRouter_SendToolResults($hash, \@fcResults);
        return;
    }

    # Finale Textantwort
    my $responseUnicode = $message->{content} // '';

    if (!$responseUnicode) {
        my $finishReason = $choice->{finish_reason} // 'UNKNOWN';
        readingsSingleUpdate($hash, 'lastError', "Leere Antwort, finishReason: $finishReason", 1);
        readingsSingleUpdate($hash, 'state', 'error', 1);
        Log3 $name, 2, "OpenRouter ($name): Leere Antwort, finishReason: $finishReason";
        pop @{$hash->{CHAT}};
        return;
    }

    push @{$hash->{CHAT}}, {
        role    => 'assistant',
        content => $responseUnicode
    };

    my $responseForReading = $responseUnicode;
    utf8::encode($responseForReading) if utf8::is_utf8($responseForReading);

    my $responsePlain = OpenRouter_MarkdownToPlain($responseUnicode);
    utf8::encode($responsePlain) if utf8::is_utf8($responsePlain);

    my $responseHTML = OpenRouter_MarkdownToHTML($responseUnicode);
    utf8::encode($responseHTML) if utf8::is_utf8($responseHTML);

    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, 'response',      $responseForReading);
    readingsBulkUpdate($hash, 'responsePlain', $responsePlain);
    readingsBulkUpdate($hash, 'responseHTML',  $responseHTML);
    readingsBulkUpdate($hash, 'chatHistory',   scalar(@{$hash->{CHAT}}));
    readingsBulkUpdate($hash, 'state',         'ok');
    readingsBulkUpdate($hash, 'lastError',     '-');
    readingsEndUpdate($hash, 1);

    Log3 $name, 4, "OpenRouter ($name): Antwort erhalten (" . length($responseUnicode) . " Zeichen)";
    return undef;
}

##############################################################################
# Tool-Ergebnisse zurücksenden
##############################################################################
sub OpenRouter_SendToolResults {
    my ($hash, $results) = @_;
    my $name = $hash->{NAME};

    # Tool-Messages in Chat einfügen
    for my $res (@$results) {
        push @{$hash->{CHAT}}, {
            role         => 'tool',
            tool_call_id => $res->{tool_call_id},
            name         => $res->{name},
            content      => $res->{result}
        };
    }

    my $apiKey  = AttrVal($name, 'apiKey',   '');
    my $model   = AttrVal($name, 'model',    'google/gemini-2.0-flash-exp');
    my $timeout = AttrVal($name, 'timeout',  30);

    # Gleiche Tools wie beim letzten Request
    my @controlDevices = OpenRouter_GetControlDevices($hash);
    my $tools = @controlDevices
        ? OpenRouter_GetControlTools()
        : OpenRouter_GetReadTools();

    my $disableHistory = AttrVal($name, 'disableHistory', 0);
    my $messagesToSend = $disableHistory
        ? [ grep { $_->{role} ne 'system' } @{$hash->{CHAT}} ]
        : $hash->{CHAT};

    my %requestBody = (
        model    => $model,
        messages => $messagesToSend,
        tools    => $tools
    );

    # System Message wieder hinzufügen
    my $systemPrompt  = AttrVal($name, 'systemPrompt', '');
    my $deviceContext = OpenRouter_BuildUnifiedDeviceContext($hash);
    my $fullSystem    = join("\n\n", grep { $_ } ($systemPrompt, $deviceContext));

    if ($fullSystem) {
        unshift @{$requestBody{messages}}, {
            role    => 'system',
            content => $fullSystem
        };
    }

    my $jsonBody = eval { encode_json(\%requestBody) };
    if ($@) {
        readingsSingleUpdate($hash, 'lastError', "JSON Encode Fehler: $@", 1);
        readingsSingleUpdate($hash, 'state', 'error', 1);
        return;
    }

    my $names = join(', ', map { $_->{name} } @$results);
    Log3 $name, 4, "OpenRouter ($name): Tool-Ergebnisse für '$names' gesendet";

    HttpUtils_NonblockingGet({
        url      => 'https://openrouter.ai/api/v1/chat/completions',
        timeout  => $timeout,
        method   => 'POST',
        header   => "Content-Type: application/json\r\n" .
                    "Authorization: Bearer ${apiKey}\r\n" .
                    "HTTP-Referer: https://fhem.de\r\n" .
                    "X-Title: FHEM-OpenRouter",
        data     => $jsonBody,
        hash     => $hash,
        callback => \&OpenRouter_HandleResponse,
    });

    return undef;
}

##############################################################################
# Function Calls ausführen
##############################################################################
sub OpenRouter_ExecuteFunctionCall {
    my ($hash, $fcName, $args) = @_;
    my $name = $hash->{NAME};

    # get_device_state
    if ($fcName eq 'get_device_state') {
        my $device = $args->{device} // '';

        unless (exists $main::defs{$device}) {
            return "Fehler: Gerät '$device' nicht gefunden";
        }

        my $dev    = $main::defs{$device};
        my %disabled = OpenRouter_ParseReadingFilter($hash);
        my $result = "Gerät: $device\n";
        $result   .= "Typ: " . ($dev->{TYPE} // 'unbekannt') . "\n";
        $result   .= "State: " . ReadingsVal($device, 'state', 'unbekannt') . "\n";

        if (exists $dev->{READINGS}) {
            $result .= "Readings:\n";
            for my $reading (sort keys %{$dev->{READINGS}}) {
                next if $reading eq 'state';
                next if OpenRouter_IsFiltered($hash, $device, $reading, \%disabled);
                my $val = $dev->{READINGS}{$reading}{VAL} // '';
                $result .= "  $reading: $val\n";
            }
        }

        Log3 $name, 4, "OpenRouter ($name): get_device_state($device)";
        return $result;

    # set_device
    } elsif ($fcName eq 'set_device') {
        my $device  = $args->{device}  // '';
        my $command = $args->{command} // '';

        if ($command =~ /[;|`\$\(\)<>\n]/) {
            my $msg = "Fehler: Ungültiger Befehl '$command' (unerlaubte Zeichen)";
            Log3 $name, 2, "OpenRouter ($name): $msg";
            return $msg;
        }

        my %allowed = map { $_ => 1 } OpenRouter_GetControlDevices($hash);

        unless ($allowed{$device} && exists $main::defs{$device}) {
            my $msg = "Fehler: Gerät '$device' nicht in controlList oder nicht vorhanden";
            Log3 $name, 2, "OpenRouter ($name): $msg";
            return $msg;
        }

        my $setResult = CommandSet(undef, "$device $command") // 'ok';
        $setResult = 'ok' if $setResult eq '';

        my $cmdForReading = "$device $command";
        utf8::encode($cmdForReading) if utf8::is_utf8($cmdForReading);
        my $resForReading = $setResult;
        utf8::encode($resForReading) if utf8::is_utf8($resForReading);

        readingsBeginUpdate($hash);
        readingsBulkUpdate($hash, 'lastCommand',       $cmdForReading);
        readingsBulkUpdate($hash, 'lastCommandResult', $resForReading);
        readingsEndUpdate($hash, 1);

        Log3 $name, 3, "OpenRouter ($name): set $device $command -> $setResult";
        return "OK: set $device $command -> $setResult";

    # create_at_device
    } elsif ($fcName eq 'create_at_device') {
        my $deviceName = $args->{device_name} // '';
        my $timeSpec   = $args->{time_spec}   // '';
        my $command    = $args->{command}      // '';
        my $recurring  = $args->{recurring}    // 0;

        if ($deviceName !~ /^[a-zA-Z0-9_\-]+$/) {
            my $msg = "Fehler: Ungültiger Gerätename '$deviceName'";
            Log3 $name, 2, "OpenRouter ($name): $msg";
            return $msg;
        }

        my $uniqueID = sprintf("%x%x%x", time(), rand(0xffff), rand(0xffff));
        $deviceName  = "at_" . $name . "_" . $uniqueID . "_" . $deviceName;

        if ($command =~ /[;|`\(\)<>]/) {
            my $msg = "Fehler: Ungültiger Befehl '$command' (unerlaubte Zeichen)";
            Log3 $name, 2, "OpenRouter ($name): $msg";
            return $msg;
        }

        my $defineResult = CommandDefine(undef, "$deviceName at $timeSpec $command");
        if ($defineResult) {
            my $msg = "Fehler beim Anlegen von AT-Device: $defineResult";
            Log3 $name, 2, "OpenRouter ($name): $msg";
            return $msg;
        }

        my $room = OpenRouter_GetAutomationRoom($hash);
        CommandAttr(undef, "$deviceName room $room") if $room;

        unless ($recurring) {
            my $extendedCmd = "$command;; delete $deviceName";
            CommandModify(undef, "$deviceName $timeSpec $extendedCmd");
            Log3 $name, 3, "OpenRouter ($name): AT-Device $deviceName angelegt (einmalig)";
        } else {
            Log3 $name, 3, "OpenRouter ($name): AT-Device $deviceName angelegt (wiederkehrend)";
        }

        my $autoForReading = "AT: $deviceName";
        utf8::encode($autoForReading) if utf8::is_utf8($autoForReading);
        readingsSingleUpdate($hash, 'lastAutomation', $autoForReading, 1);

        return "OK: AT-Device '$deviceName' angelegt";

    # create_notify_device
    } elsif ($fcName eq 'create_notify_device') {
        my $deviceName = $args->{device_name} // '';
        my $eventSpec  = $args->{event_spec}  // '';
        my $command    = $args->{command}      // '';
        my $oneShot    = $args->{one_shot}     // 1;

        if ($deviceName !~ /^[a-zA-Z0-9_\-]+$/) {
            my $msg = "Fehler: Ungültiger Gerätename '$deviceName'";
            Log3 $name, 2, "OpenRouter ($name): $msg";
            return $msg;
        }

        my $uniqueID = sprintf("%x%x%x", time(), rand(0xffff), rand(0xffff));
        $deviceName  = "n_" . $name . "_" . $uniqueID . "_" . $deviceName;

        if ($command =~ /[;|`\(\)<>]/) {
            my $msg = "Fehler: Ungültiger Befehl '$command' (unerlaubte Zeichen)";
            Log3 $name, 2, "OpenRouter ($name): $msg";
            return $msg;
        }

        my $finalCommand = $oneShot
            ? "{ fhem('$command');; fhem('delete $deviceName') }"
            : $command;

        my $defineResult = CommandDefine(undef, "$deviceName notify $eventSpec $finalCommand");
        if ($defineResult) {
            my $msg = "Fehler beim Anlegen von NOTIFY-Device: $defineResult";
            Log3 $name, 2, "OpenRouter ($name): $msg";
            return $msg;
        }

        my $room = OpenRouter_GetAutomationRoom($hash);
        CommandAttr(undef, "$deviceName room $room") if $room;

        Log3 $name, 3, "OpenRouter ($name): NOTIFY-Device $deviceName angelegt (" .
                        ($oneShot ? 'einmalig' : 'permanent') . ")";

        my $autoForReading = "NOTIFY: $deviceName";
        utf8::encode($autoForReading) if utf8::is_utf8($autoForReading);
        readingsSingleUpdate($hash, 'lastAutomation', $autoForReading, 1);

        return "OK: NOTIFY-Device '$deviceName' angelegt";

    } else {
        return "Fehler: Unbekannte Funktion '$fcName'";
    }
}

##############################################################################
# Hilfsfunktion: MIME-Typ ermitteln
##############################################################################
sub OpenRouter_GetMimeType {
    my ($filePath) = @_;

    my $ext = '';
    $ext = lc($1) if $filePath =~ /\.([^.]+)$/;

    my %mimeTypes = (
        'jpg'  => 'image/jpeg',
        'jpeg' => 'image/jpeg',
        'png'  => 'image/png',
        'gif'  => 'image/gif',
        'webp' => 'image/webp',
        'bmp'  => 'image/bmp',
        'heic' => 'image/heic',
        'heif' => 'image/heif',
    );

    return $mimeTypes{$ext} // 'image/jpeg';
}

##############################################################################
# Hilfsfunktion: Markdown → Plain Text
##############################################################################
sub OpenRouter_MarkdownToPlain {
    my ($text) = @_;
    return '' unless defined $text;

    $text =~ s/```[^\n]*\n(.*?)```/$1/gms;
    $text =~ s/\*\*(.+?)\*\*/$1/gs;
    $text =~ s/__(.+?)__/$1/gs;
    $text =~ s/\*(.+?)\*/$1/gs;
    $text =~ s/_(.+?)_/$1/gs;
    $text =~ s/`(.+?)`/$1/gs;
    $text =~ s/^#{1,6}\s+(.+)$/$1/gm;
    $text =~ s/^[\-\*]\s+(.+)$/$1/gm;
    $text =~ s/<a[^>]*>(.+?)<\/a>/$1/gsi;
    $text =~ s/^(?:---|\*\*\*)\s*$//gm;

    return $text;
}

##############################################################################
# Hilfsfunktion: Markdown → HTML
##############################################################################
sub OpenRouter_MarkdownToHTML {
    my ($text) = @_;
    return '' unless defined $text;

    $text =~ s/```[^\n]*\n(.*?)```/<pre><code>$1<\/code><\/pre>/gms;
    $text =~ s/\*\*(.+?)\*\*/<b>$1<\/b>/gs;
    $text =~ s/__(.+?)__/<b>$1<\/b>/gs;
    $text =~ s/\*(.+?)\*/<i>$1<\/i>/gs;
    $text =~ s/_(.+?)_/<i>$1<\/i>/gs;
    $text =~ s/`(.+?)`/<code>$1<\/code>/gs;
    $text =~ s/^#{6}\s+(.+)$/<h6>$1<\/h6>/gm;
    $text =~ s/^#{5}\s+(.+)$/<h6>$1<\/h6>/gm;
    $text =~ s/^#{4}\s+(.+)$/<h6>$1<\/h6>/gm;
    $text =~ s/^#{3}\s+(.+)$/<h5>$1<\/h5>/gm;
    $text =~ s/^#{2}\s+(.+)$/<h4>$1<\/h4>/gm;
    $text =~ s/^#\s+(.+)$/<h3>$1<\/h3>/gm;
    $text =~ s/((?:^[\-\*]\s+.+\n?)+)/my $block=$1; $block=~s{^[\-\*]\s+(.+)$}{<li>$1<\/li>}gm; "<ul>$block<\/ul>"/gme;
    $text =~ s/^(?:---|\*\*\*)\s*$/<hr>/gm;
    $text =~ s/\n(?!<(?:ul|\/ul|li|\/li|h[3-6]|\/h[3-6]|pre|\/pre|hr))/<br>\n/g;

    return $text;
}

1;

=pod
=item device
=item summary OpenRouter AI integration for FHEM with Function Calling and Reading Filter
=item summary_DE OpenRouter AI Anbindung fuer FHEM mit Function Calling und Reading-Filter
=begin html

<a name="OpenRouter"></a>
<h3>OpenRouter</h3>
<ul>
  FHEM Modul zur Anbindung der OpenRouter AI API.<br>
  Unterstützt Claude, GPT-4, Gemini und viele weitere Modelle über eine einheitliche API.<br><br>

  <b>Architektur (Prompt Caching optimiert)</b><br>
  <ul>
    <li>System Message: Statischer Gerätekontext (cachebar, ändert sich selten)</li>
    <li>User Message: Nur die eigentliche Frage (minimal, nie cachebar)</li>
    <li>Aktuelle Readings: LLM fragt per get_device_state() selbst nach (nur was nötig)</li>
  </ul><br>

  <b>Define</b><br>
  <ul><code>define &lt;name&gt; OpenRouter</code></ul><br>

  <b>Set</b><br>
  <ul>
    <li><b>ask</b> &lt;Frage&gt;</li>
    <li><b>askWithImage</b> &lt;Pfad&gt; &lt;Frage&gt;</li>
    <li><b>askAboutDevices</b> [&lt;Frage&gt;]</li>
    <li><b>chat</b> &lt;Nachricht&gt; - Universell: Fragen, Status, Steuerung</li>
    <li><b>control</b> &lt;Anweisung&gt;</li>
    <li><b>resetChat</b></li>
    <li><b>collectReadings</b> - Readings für Widget neu einlesen</li>
  </ul><br>

  <b>Reading-Filter Widget</b><br>
  <ul>
    Die Detailseite des Geräts zeigt ein Checkbox-Widget mit allen bekannten Readings.<br>
    Deaktivierte Readings werden nicht ans LLM übermittelt.<br>
    Der Zustand wird im Attribut readingFilter gespeichert.
  </ul>
</ul>

=end html
=cut
