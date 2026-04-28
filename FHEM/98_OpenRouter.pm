##############################################################################
# 98_OpenRouter.pm
#
# FHEM Modul für OpenRouter AI API (Multi-Provider LLM Gateway)
#
# Versionshistorie:
# 1.0.0 - 2026-04-27  Initiale Version
# 1.1.0 - 2026-04-27  Unified Device Context, Reading-Filter Widget
# 1.2.0 - 2026-04-28  Fix: readingExtraToggle fehlte im Set-Handler
#                     Fix: OpenRouter_ParseReadingFilter war nicht definiert
#                     Fix: CSS im Modul (kein externes Theme nötig)
#                     Fix: box-shadow verdeckte Reading-Namen
#                     Fix: Schriftfarben für dunkles Theme

package main;

use strict;
use warnings;
use HttpUtils;
use JSON;
use MIME::Base64;

##############################################################################
# CSS
##############################################################################
my $OpenRouter_CSS = <<'END_CSS';
/* OpenRouter Reading-Filter Widget */
#openrouter_rf_widget {
    margin: 10px 0;
    padding: 10px;
    border: 1px solid #555555;
    border-radius: 4px;
    background: #2a2a2a;
    color: #cccccc;
    font-size: 12px;
    box-sizing: border-box;
    max-width: 100%;
    overflow: hidden;
}
#openrouter_rf_widget b {
    color: #eeeeee;
    font-size: 13px;
}
#openrouter_rf_widget small {
    color: #aaaaaa;
}
#openrouter_rf_widget details {
    margin-bottom: 6px;
    max-width: 100%;
    overflow: hidden;
}
#openrouter_rf_widget summary {
    cursor: pointer;
    font-weight: bold;
    color: #dddddd;
    padding: 3px 0;
    user-select: none;
}
#openrouter_rf_widget summary:hover {
    color: #ffffff;
}
/* Label-Container: flex mit Umbruch, nie breiter als Elternelement */
#openrouter_rf_widget .or-label-group {
    display: flex;
    flex-wrap: wrap;
    gap: 4px;
    max-width: 100%;
    margin-bottom: 6px;
    box-sizing: border-box;
}
/* Jedes Label: feste Breite, kein Überlauf */
#openrouter_rf_widget label {
    display: inline-flex !important;
    align-items: center;
    width: 180px;
    max-width: 180px;
    box-sizing: border-box;
    padding: 3px 6px;
    border-radius: 3px;
    color: #cccccc !important;
    font-size: 11px;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    cursor: default;
}
/* Whitelist (grün-dunkel) */
#openrouter_rf_widget label.or-wl {
    background: #1a3a1a !important;
    border: 1px solid #2a5a2a;
    color: #88cc88 !important;
}
/* Extra aktiv (blau-dunkel) */
#openrouter_rf_widget label.or-extra {
    background: #1a2a3a !important;
    border: 1px solid #2a4a6a;
    color: #88aacc !important;
    cursor: pointer;
}
/* Inaktiv (grau) */
#openrouter_rf_widget label.or-inactive {
    background: #333333 !important;
    border: 1px solid #444444;
    color: #aaaaaa !important;
    cursor: pointer;
}
/* Blacklist (rot-dunkel) */
#openrouter_rf_widget label.or-bl {
    background: #3a1a1a !important;
    border: 1px solid #5a2a2a;
    color: #cc8888 !important;
}
#openrouter_rf_widget input[type="checkbox"] {
    accent-color: #4a9eff;
    margin-right: 4px;
    flex-shrink: 0;
    cursor: pointer;
}
/* Abschnitts-Titel */
#openrouter_rf_widget .or-section-title {
    color: #aaddff;
    font-weight: bold;
    margin: 6px 0 3px 0;
    font-size: 11px;
    text-transform: uppercase;
    letter-spacing: 0.5px;
    width: 100%;
}
/* Dashboard: verhindert dass box-shadow den Inhalt überdeckt */
#dashboard .dashboard_widgetheader {
    box-shadow: 2px 2px 4px rgba(0,0,0,0.5) !important;
    overflow: visible !important;
}
END_CSS

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
    'readingWhitelist:textField-long ' .
    'readingFilterExtra:textField-long ' .
    'senderPattern ' .          # Regex mit 2 Capture-Groups: ($sender, $text)
    'allowedSenders ' .         # Komma-getrennte Liste autorisierter Absender
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
    $hash->{VERSION} = '1.2.0';

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

    if ($attr =~ /^(?:deviceList|deviceRoom|controlList|controlRoom|readingBlacklist|readingFilter|readingFilterExtra)$/) {
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

    # -----------------------------------------------------------------
    # FIX 1: readingFilterToggle (globaler Filter) - war vorhanden
    # FIX 2: readingExtraToggle  (Extra-Aktivierungen) - fehlte komplett
    # Das JS im Widget rief readingExtraToggle auf, der Handler fehlte!
    # -----------------------------------------------------------------
    } elsif ($cmd eq 'readingFilterToggle') {
        return "Usage: set $name readingFilterToggle <device> <reading> enable|disable"
            unless @args == 3;
        my ($dev, $reading, $action) = @args;
        OpenRouter_ToggleReadingFilter($hash, $dev, $reading, $action eq 'disable' ? 1 : 0);
        return undef;

    } elsif ($cmd eq 'readingExtraToggle') {
        # Dieser Handler wurde vom JS aufgerufen aber fehlte im Set-Handler!
        return "Usage: set $name readingExtraToggle <device> <reading> enable|disable"
            unless @args == 3;
        my ($dev, $reading, $action) = @args;
        OpenRouter_ToggleReadingFilterExtra($hash, $dev, $reading, $action eq 'enable' ? 1 : 0);
        return undef;

    } else {
        return "Unknown argument $cmd, choose one of " .
               "ask:textField askWithImage:textField askAboutDevices:textField " .
               "chat:textField control:textField resetChat:noArg collectReadings:noArg";
    }
}


##############################################################################
# Präfix parsen: Absender und Nachricht trennen
# Unterstützt: "User=Nachricht", "User sagt: Nachricht", "User: Nachricht"
##############################################################################
sub OpenRouter_ParseSender {
    my ($hash, $message) = @_;
    my $name = $hash->{NAME};

    # Konfigurierbares Pattern via Attribut
    my $pattern = AttrVal($name, 'senderPattern', '');

    if ($pattern) {
        my ($sender, $text) = ('', $message);
        eval {
            if ($message =~ /$pattern/) {
                $sender = $1 // '';
                $text   = $2 // $message;
            }
        };
        if ($@) {
            Log3 $name, 2, "OpenRouter ($name): senderPattern Regex-Fehler: $@";
        }
        return ($sender, $text);
    }

    # Standard-Patterns:

    # "Username=Nachricht" (Telegram klassisch)
    if ($message =~ /^([^=\s]+)=(.+)$/s) {
        return ($1, $2);
    }

    # "Username sagt: Nachricht"
    if ($message =~ /^(\S+)\s+sagt:\s*(.+)$/s) {
        return ($1, $2);
    }

    # "Username: Nachricht" (nur wenn Username kein Leerzeichen hat)
    if ($message =~ /^(\S+):\s+(.+)$/s) {
        return ($1, $2);
    }

    # Kein Präfix erkannt
    return ('', $message);
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
                            $text .= $part->{text}  if exists $part->{text};
                            $text .= '[Bild]'       if exists $part->{image_url};
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
    } elsif ($cmd eq 'debugContext') {
        my $ctx = OpenRouter_BuildUnifiedDeviceContext($hash);
        return $ctx || '(leer)';
    }

    return "Unknown argument $cmd, choose one of chatHistory:noArg debugContext:noArg";
}

##############################################################################
# Standard-Whitelist
##############################################################################
sub OpenRouter_GetDefaultWhitelist {
    return qw(
        state
        temperature humidity
        brightness dim level
        power energy voltage current
        motion contact presence
        battery batteryLevel
        setpoint desiredTemp measuredTemp valvePosition
        wind rain
        lock
        color colorTemperature
        volume mute
        mode
    );
}

##############################################################################
# CSS in die Seite injizieren (einmalig per ID-Check)
##############################################################################
sub OpenRouter_InjectCSS {
    # CSS-String für JS escapen
    (my $cssEscaped = $OpenRouter_CSS) =~ s/\\/\\\\/g;
    $cssEscaped =~ s/'/\\'/g;
    $cssEscaped =~ s/\n/\\n/g;

    return <<"END_INJECT";
<script>
(function(){
    if (document.getElementById('openrouter-module-css')) return;
    var s = document.createElement('style');
    s.id = 'openrouter-module-css';
    s.textContent = '$cssEscaped';
    document.head.appendChild(s);
})();
</script>
END_INJECT
}

##############################################################################
# Hilfsfunktion: HTML-Sonderzeichen escapen (kein FW_htmlEsc nötig)
##############################################################################
sub OpenRouter_HtmlEsc {
    my ($text) = @_;
    return '' unless defined $text;
    $text =~ s/&/&amp;/g;
    $text =~ s/</&lt;/g;
    $text =~ s/>/&gt;/g;
    $text =~ s/"/&quot;/g;
    $text =~ s/'/&#39;/g;
    return $text;
}

sub OpenRouter_FW_detail {
    my ($FW_wname, $devName, $room, $pageHash) = @_;

    return '' unless exists $main::defs{$devName};
    my $hash = $main::defs{$devName};
    return '' unless $hash->{TYPE} eq 'OpenRouter';

    OpenRouter_CollectAllReadings($hash);

    my %extraActive = OpenRouter_ParseReadingFilterExtra($hash);
    my @whitelist   = OpenRouter_GetEffectiveWhitelist($hash);
    my %wlSet       = map { $_ => 1 } @whitelist;
    my @blacklist   = OpenRouter_GetBlacklist($hash);
    my $knownRef    = $hash->{helper}{knownReadings} // {};

    return '' unless %$knownRef;

    my $name = $devName;
    my $html = OpenRouter_InjectCSS();

    $html .= '<div id="openrouter_rf_widget">';
    $html .= '<b>Reading-Filter</b> ';
    $html .= '<small>';
    $html .= '&nbsp;🟢&nbsp;Whitelist&nbsp;';
    $html .= '&nbsp;🔵&nbsp;Aktiviert&nbsp;';
    $html .= '&nbsp;⬜&nbsp;Deaktiviert&nbsp;';
    $html .= '&nbsp;🚫&nbsp;Blacklist';
    $html .= '</small><br><br>';

    for my $dev (sort keys %$knownRef) {
        my @allReadings = sort keys %{$knownRef->{$dev}};
        next unless @allReadings;

        my (@inWhitelist, @inExtra, @inactive, @blacklisted);
        for my $r (@allReadings) {
            if (OpenRouter_IsBlacklisted($r, @blacklist)) {
                push @blacklisted, $r;
            } elsif ($wlSet{$r}) {
                push @inWhitelist, $r;
            } elsif (exists $extraActive{$dev}{$r} || exists $extraActive{'*'}{$r}) {
                push @inExtra, $r;
            } else {
                push @inactive, $r;
            }
        }

        my $activeCount = scalar(@inWhitelist) + scalar(@inExtra);

        $html .= '<details style="margin-bottom:5px;max-width:100%;">';
        $html .= sprintf(
            '<summary>%s <span style="font-weight:normal;color:#999">(%d aktiv von %d)</span></summary>',
            OpenRouter_HtmlEsc($dev), $activeCount, scalar(@allReadings)
        );
        $html .= '<div style="margin:5px 0 5px 15px;max-width:100%;overflow:hidden;">';

        # --- Whitelist ---
        if (@inWhitelist) {
            $html .= '<div class="or-section-title">Whitelist (immer aktiv):</div>';
            $html .= '<div class="or-label-group">';
            for my $r (@inWhitelist) {
                $html .= sprintf(
                    '<label class="or-wl" title="%s">&#10003;&nbsp;%s</label>',
                    OpenRouter_HtmlEsc($r), OpenRouter_HtmlEsc($r)
                );
            }
            $html .= '</div>';
        }

        # --- Extra aktiv ---
        if (@inExtra) {
            $html .= '<div class="or-section-title">Zusätzlich aktiv:</div>';
            $html .= '<div class="or-label-group">';
            for my $r (@inExtra) {
                (my $cbId = "rfe_${dev}_${r}") =~ s/[^a-zA-Z0-9_]/_/g;
                $html .= sprintf(
                    '<label class="or-extra" title="%s">'
                  . '<input type="checkbox" id="%s" checked '
                  . 'onchange="openrouter_extra_change(\'%s\',\'%s\',\'%s\',this.checked)">'
                  . '%s</label>',
                    OpenRouter_HtmlEsc($r), $cbId,
                    OpenRouter_HtmlEsc($name), OpenRouter_HtmlEsc($dev), OpenRouter_HtmlEsc($r),
                    OpenRouter_HtmlEsc($r)
                );
            }
            $html .= '</div>';
        }

        # --- Inaktiv ---
        if (@inactive) {
            $html .= '<div class="or-section-title">Nicht aktiv:</div>';
            $html .= '<div class="or-label-group">';
            for my $r (@inactive) {
                (my $cbId = "rfe_${dev}_${r}") =~ s/[^a-zA-Z0-9_]/_/g;
                $html .= sprintf(
                    '<label class="or-inactive" title="%s">'
                  . '<input type="checkbox" id="%s" '
                  . 'onchange="openrouter_extra_change(\'%s\',\'%s\',\'%s\',this.checked)">'
                  . '%s</label>',
                    OpenRouter_HtmlEsc($r), $cbId,
                    OpenRouter_HtmlEsc($name), OpenRouter_HtmlEsc($dev), OpenRouter_HtmlEsc($r),
                    OpenRouter_HtmlEsc($r)
                );
            }
            $html .= '</div>';
        }

        # --- Blacklist ---
        if (@blacklisted) {
            $html .= '<div class="or-section-title">Blacklist (gefiltert):</div>';
            $html .= '<div class="or-label-group">';
            for my $r (@blacklisted) {
                $html .= sprintf(
                    '<label class="or-bl" title="%s">&#128683;&nbsp;%s</label>',
                    OpenRouter_HtmlEsc($r), OpenRouter_HtmlEsc($r)
                );
            }
            $html .= '</div>';
        }

        $html .= '</div></details>';
    }

    $html .= '</div>';  # #openrouter_rf_widget

    $html .= <<'JSEND';
<script>
function openrouter_extra_change(orName, devName, reading, isChecked) {
    var action = isChecked ? 'enable' : 'disable';
    var cmd = 'set ' + orName + ' readingExtraToggle ' + devName + ' ' + reading + ' ' + action;
    FW_cmd(FW_root + '?XHR=1&cmd=' + encodeURIComponent(cmd), function(resp) {
        var cbId = 'rfe_' + devName + '_' + reading;
        cbId = cbId.replace(/[^a-zA-Z0-9_]/g, '_');
        var el = document.getElementById(cbId);
        if (el) {
            var label = el.parentElement;
            label.className = isChecked ? 'or-extra' : 'or-inactive';
            label.style.outline = '2px solid #4a9eff';
            setTimeout(function(){ label.style.outline = ''; }, 600);
        }
    });
}
</script>
JSEND

    return $html;
}

##############################################################################
# FIX 3: OpenRouter_ParseReadingFilter war im Original nicht definiert!
# Parst das readingFilter-Attribut: "dev1:r1,r2 dev2:r3" → { dev => { r => 1 } }
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
                $disabled{$dev}{$r} = 1 if $r ne '';
            }
        }
    }
    return %disabled;
}

##############################################################################
# Sicherheits-Check für set-Befehle
##############################################################################
sub OpenRouter_IsSafeCommand {
    my ($command) = @_;

    # Gefährliche Shell/FHEM-Injection Zeichen blockieren
    my $dangerous = qr/[;|`\$\{\}\(\)\[\]<>\\]/;

    if ($command =~ $dangerous) {
        return (0, "Befehl enthält unerlaubte Zeichen: $command");
    }

    # Maximale Länge prüfen
    if (length($command) > 200) {
        return (0, "Befehl zu lang: " . length($command) . " Zeichen");
    }

    return (1, '');
}

##############################################################################
# readingFilter aktualisieren (global deaktiviert)
##############################################################################
sub OpenRouter_ToggleReadingFilter {
    my ($hash, $devName, $reading, $disable) = @_;
    my $name = $hash->{NAME};

    my %disabled = OpenRouter_ParseReadingFilter($hash);

    if ($disable) {
        $disabled{$devName}{$reading} = 1;
    } else {
        delete $disabled{$devName}{$reading};
        delete $disabled{$devName} unless %{$disabled{$devName} // {}};
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
# Hilfsfunktion: Alle bekannten Readings einsammeln
##############################################################################
sub OpenRouter_CollectAllReadings {
    my ($hash) = @_;

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
# Effektive Whitelist (Standard oder Attribut)
##############################################################################
sub OpenRouter_GetEffectiveWhitelist {
    my ($hash) = @_;
    my $attr = AttrVal($hash->{NAME}, 'readingWhitelist', '');
    return split(/[\s,]+/, $attr) if $attr ne '';
    return OpenRouter_GetDefaultWhitelist();
}

##############################################################################
# readingFilterExtra parsen: "dev1:r1,r2 dev2:r3" → { dev => { r => 1 } }
##############################################################################
sub OpenRouter_ParseReadingFilterExtra {
    my ($hash) = @_;
    my $attr = AttrVal($hash->{NAME}, 'readingFilterExtra', '');

    my %extra;
    return %extra unless $attr;

    for my $token (split(/\s+/, $attr)) {
        if ($token =~ /^([^:]+):(.+)$/) {
            my ($dev, $readings) = ($1, $2);
            for my $r (split(/,/, $readings)) {
                $extra{$dev}{$r} = 1 if $r ne '';
            }
        }
    }
    return %extra;
}

##############################################################################
# readingFilterExtra aktualisieren
##############################################################################
sub OpenRouter_ToggleReadingFilterExtra {
    my ($hash, $devName, $reading, $enable) = @_;
    my $name = $hash->{NAME};

    my %extra = OpenRouter_ParseReadingFilterExtra($hash);

    if ($enable) {
        $extra{$devName}{$reading} = 1;
    } else {
        delete $extra{$devName}{$reading};
        delete $extra{$devName} unless %{$extra{$devName} // {}};
    }

    my @parts;
    for my $dev (sort keys %extra) {
        my @readings = sort keys %{$extra{$dev}};
        push @parts, "$dev:" . join(',', @readings) if @readings;
    }

    my $newAttr = join(' ', @parts);
    if ($newAttr) {
        CommandAttr(undef, "$name readingFilterExtra $newAttr");
    } else {
        CommandDeleteAttr(undef, "$name readingFilterExtra");
    }
    return;
}

##############################################################################
# Hilfsfunktion: Prüft ob Reading deaktiviert (nur intern, noch nicht genutzt)
##############################################################################
sub OpenRouter_IsReadingDisabled {
    my ($disabledRef, $devName, $reading) = @_;
    return 1 if exists $disabledRef->{'*'}{$reading};
    return 1 if exists $disabledRef->{$devName}{$reading};
    return 0;
}

##############################################################################
# Globale Blacklist
##############################################################################
sub OpenRouter_GetBlacklist {
    my ($hash) = @_;
    my $attr = AttrVal($hash->{NAME}, 'readingBlacklist', '');
    return split(/\s+/, $attr) if $attr ne '';
    return qw(
        attrTemplate associate R-* RegL_* associatedWith
        peerListRDate protLastRcv lastTimeSync lastcmd
        Heap LoadAvg Uptime Wifi_*
    );
}

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
# Zentraler Filter: Wird ein Reading ans LLM gesendet?
##############################################################################
sub OpenRouter_IsFiltered {
    my ($hash, $devName, $reading, $whitelistRef, $extraRef, $blacklistRef) = @_;

    return 1 if OpenRouter_IsBlacklisted($reading, @$blacklistRef);
    return 0 if $whitelistRef->{$reading};
    return 0 if exists $extraRef->{'*'}{$reading};
    return 0 if exists $extraRef->{$devName}{$reading};
    return 1;
}

##############################################################################
# Geräteliste aus deviceList/deviceRoom
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
                    push @devices, $devName unless $seen{$devName}++;
                    last;
                }
            }
        }
    }

    my $devList = AttrVal($name, 'deviceList', '');
    if ($devList) {
        for my $devName (split(/\s*,\s*/, $devList)) {
            push @devices, $devName unless $seen{$devName}++;
        }
    }

    return @devices;
}

##############################################################################
# Steuerbare Geräte aus controlList/controlRoom
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
                    push @devices, $devName unless $seen{$devName}++;
                    last;
                }
            }
        }
    }

    my $controlList = AttrVal($name, 'controlList', '');
    if ($controlList) {
        for my $devName (split(/\s*,\s*/, $controlList)) {
            push @devices, $devName unless $seen{$devName}++;
        }
    }

    return @devices;
}

##############################################################################
# Automation-Raum
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
# Unified Device Context (statisch, cachebar)
##############################################################################
sub OpenRouter_BuildUnifiedDeviceContext {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    my %deviceRoles;
    for my $dev (OpenRouter_GetDeviceList($hash)) {
        $deviceRoles{$dev}{list} = 1;
    }
    for my $dev (OpenRouter_GetControlDevices($hash)) {
        $deviceRoles{$dev}{control} = 1;
    }

    return '' unless %deviceRoles;

    my @whitelist   = OpenRouter_GetEffectiveWhitelist($hash);
    my %wlSet       = map { $_ => 1 } @whitelist;
    my %extraActive = OpenRouter_ParseReadingFilterExtra($hash);
    my @blacklist   = OpenRouter_GetBlacklist($hash);
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

        $context .= $devName;
        $context .= "($alias)" if $alias && $alias ne $devName;
        $context .= "|$type|$isCtrl";

        if (exists $dev->{READINGS}) {
            my @readings = grep {
                $_ ne 'state' &&
                !OpenRouter_IsFiltered($hash, $devName, $_, \%wlSet, \%extraActive, \@blacklist)
            } sort keys %{$dev->{READINGS}};

            my $truncated = scalar(@readings) > $maxReadings;
            @readings = @readings[0..$maxReadings-1] if $truncated;

            $context .= '|R:' . join(',', @readings);
            $context .= '...' if $truncated;
        } else {
            $context .= '|';
        }

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

        my $aiComment = AttrVal($devName, $name . 'Comment', '');
        $context .= "|$aiComment" if $aiComment;
        $context .= "\n";
    }

    $context .= "\nNutze get_device_state() für aktuelle Werte.\n";
    return $context;
}

##############################################################################
# Tools: nur lesen
##############################################################################
sub OpenRouter_GetReadTools {
    return [
        {
            type => 'function',
            function => {
                name        => 'get_device_state',
                description => 'Liest den aktuellen Status und alle Readings eines FHEM-Geräts.',
                parameters  => {
                    type       => 'object',
                    properties => {
                        device => { type => 'string', description => 'FHEM Gerätename (intern)' }
                    },
                    required => ['device']
                }
            }
        }
    ];
}

##############################################################################
# Tools: lesen + steuern
##############################################################################
sub OpenRouter_GetControlTools {
    return [
        @{OpenRouter_GetReadTools()},
        {
            type => 'function',
            function => {
                name        => 'set_device',
                description => 'Führt einen FHEM set-Befehl aus. Kann parallel mehrfach aufgerufen werden.',
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
                description => 'Legt ein zeitgesteuertes AT-Device an.',
                parameters  => {
                    type       => 'object',
                    properties => {
                        device_name => { type => 'string', description => 'Name des neuen AT-Geräts' },
                        time_spec   => { type => 'string', description => 'HH:MM:SS, +HH:MM:SS, *HH:MM:SS' },
                        command     => { type => 'string', description => 'FHEM set-Befehl' },
                        recurring   => { type => 'boolean', description => 'true=wiederkehrend' }
                    },
                    required => ['device_name', 'time_spec', 'command']
                }
            }
        },
        {
            type => 'function',
            function => {
                name        => 'create_notify_device',
                description => 'Legt ein eventbasiertes NOTIFY-Device an.',
                parameters  => {
                    type       => 'object',
                    properties => {
                        device_name => { type => 'string', description => 'Name des NOTIFY-Geräts' },
                        event_spec  => { type => 'string', description => 'Gerätename:Event-Pattern' },
                        command     => { type => 'string', description => 'FHEM set-Befehl' },
                        one_shot    => { type => 'boolean', description => 'true=einmalig' }
                    },
                    required => ['device_name', 'event_spec', 'command']
                }
            }
        }
    ];
}


##############################################################################
# Präfix parsen: Absender und Nachricht trennen
# Unterstützt: "User=Nachricht", "User sagt: Nachricht", "User: Nachricht"
##############################################################################
sub OpenRouter_ParseSender {
    my ($hash, $message) = @_;
    my $name = $hash->{NAME};

    # Konfigurierbares Pattern via Attribut
    my $pattern = AttrVal($name, 'senderPattern', '');

    if ($pattern) {
        my ($sender, $text) = ('', $message);
        eval {
            if ($message =~ /$pattern/) {
                $sender = $1 // '';
                $text   = $2 // $message;
            }
        };
        if ($@) {
            Log3 $name, 2, "OpenRouter ($name): senderPattern Regex-Fehler: $@";
        }
        return ($sender, $text);
    }

    # Standard-Patterns:

    # "Username=Nachricht" (Telegram klassisch)
    if ($message =~ /^([^=\s]+)=(.+)$/s) {
        return ($1, $2);
    }

    # "Username sagt: Nachricht"
    if ($message =~ /^(\S+)\s+sagt:\s*(.+)$/s) {
        return ($1, $2);
    }

    # "Username: Nachricht" (nur wenn Username kein Leerzeichen hat)
    if ($message =~ /^(\S+):\s+(.+)$/s) {
        return ($1, $2);
    }

    # Kein Präfix erkannt
    return ('', $message);
}


##############################################################################
# Hauptfunktion: Anfrage senden
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

    my $model      = AttrVal($name, 'model',      'google/gemini-2.0-flash-exp');
    my $timeout    = AttrVal($name, 'timeout',    30);
    my $maxHistory = AttrVal($name, 'maxHistory', 20);

    # ------------------------------------------------------------------
    # Absender aus Nachricht extrahieren
    # ------------------------------------------------------------------
    my ($sender, $cleanMessage) = OpenRouter_ParseSender($hash, $question);

    if ($sender) {
        readingsSingleUpdate($hash, 'lastSender', $sender, 1);
        Log3 $name, 4, "OpenRouter ($name): Absender erkannt: $sender";
    }

    # ------------------------------------------------------------------
    # Content-Parts aufbauen (Text + optional Bild)
    # ------------------------------------------------------------------
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
    }

    # Saubere Nachricht (ohne Präfix) in den Chat
    push @contentParts, { type => 'text', text => $cleanMessage };

    # ------------------------------------------------------------------
    # Persistenten Chat-Verlauf aktualisieren
    # NIEMALS system-messages in $hash->{CHAT} schreiben!
    # ------------------------------------------------------------------
    push @{$hash->{CHAT}}, { role => 'user', content => \@contentParts };

    # History auf maxHistory begrenzen
    while (scalar(@{$hash->{CHAT}}) > $maxHistory) {
        shift @{$hash->{CHAT}};
    }
    # Sicherstellen dass erste Nachricht immer vom User ist
    while (@{$hash->{CHAT}}) {
        last if $hash->{CHAT}[0]{role} eq 'user';
        shift @{$hash->{CHAT}};
    }

    # ------------------------------------------------------------------
    # Echte Kopie für den API-Request (nicht $hash->{CHAT} modifizieren!)
    # ------------------------------------------------------------------
    my $disableHistory = AttrVal($name, 'disableHistory', 0);
    my @sendMessages = $disableHistory
        ? ( $hash->{CHAT}[-1] )
        : @{$hash->{CHAT}};

    # ------------------------------------------------------------------
    # System-Message aufbauen und NUR in die Kopie einfügen
    # ------------------------------------------------------------------
    my $systemPrompt  = AttrVal($name, 'systemPrompt', '');
    my $deviceContext = $includeDeviceContext
        ? OpenRouter_BuildUnifiedDeviceContext($hash)
        : '';

    # Absender-Kontext
    my $senderContext = '';
    if ($sender) {
        my $allowedSenders = AttrVal($name, 'allowedSenders', '');
        if ($allowedSenders) {
            my @allowed = split(/\s*,\s*/, $allowedSenders);
            if (grep { $_ eq $sender } @allowed) {
                $senderContext = "Der aktuelle Benutzer ist: $sender (autorisiert, darf Geräte steuern).";
            } else {
                $senderContext = "Der aktuelle Benutzer ist: $sender (NICHT autorisiert - nur Auskünfte erteilen, KEINE Geräte steuern!).";
                Log3 $name, 2, "OpenRouter ($name): Nicht autorisierter Absender: $sender";
            }
        } else {
            $senderContext = "Der aktuelle Benutzer ist: $sender.";
        }
    }

    my $fullSystem = join("\n\n", grep { $_ } ($systemPrompt, $senderContext, $deviceContext));

    if ($fullSystem) {
        unshift @sendMessages, { role => 'system', content => $fullSystem };
    }

    # ------------------------------------------------------------------
    # Tools bestimmen
    # ------------------------------------------------------------------
    my @controlDevices = OpenRouter_GetControlDevices($hash);
    my $tools = @controlDevices
        ? OpenRouter_GetControlTools()
        : OpenRouter_GetReadTools();

    # ------------------------------------------------------------------
    # Request abschicken
    # ------------------------------------------------------------------
    my %requestBody = (
        model    => $model,
        messages => \@sendMessages,
        tools    => $tools
    );

    my $jsonBody = eval { encode_json(\%requestBody) };
    if ($@) {
        readingsSingleUpdate($hash, 'lastError', "JSON Encode Fehler: $@", 1);
        readingsSingleUpdate($hash, 'state', 'error', 1);
        pop @{$hash->{CHAT}};
        return;
    }

    Log3 $name, 4, "OpenRouter ($name): Anfrage wird gesendet (Sender: " . ($sender || 'unbekannt') . ")";
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
# Callback: Antwort verarbeiten
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
        pop @{$hash->{CHAT}};
        return;
    }

    if (exists $result->{error}) {
        my $errMsg  = $result->{error}{message} // 'Unbekannter API Fehler';
        my $errCode = $result->{error}{code}    // 'N/A';
        readingsSingleUpdate($hash, 'lastError', "API Fehler $errCode: $errMsg", 1);
        readingsSingleUpdate($hash, 'state', 'error', 1);
        pop @{$hash->{CHAT}};
        return;
    }

    if (exists $result->{usage}) {
        readingsBeginUpdate($hash);
        readingsBulkUpdate($hash, 'promptTokenCount',     $result->{usage}{prompt_tokens}     // 0);
        readingsBulkUpdate($hash, 'candidatesTokenCount', $result->{usage}{completion_tokens} // 0);
        readingsBulkUpdate($hash, 'totalTokenCount',      $result->{usage}{total_tokens}      // 0);
        readingsEndUpdate($hash, 1);
    }

    my $choice  = $result->{choices}[0];
    my $message = $choice->{message};

    if (exists $message->{tool_calls} && ref($message->{tool_calls}) eq 'ARRAY' && @{$message->{tool_calls}}) {
        push @{$hash->{CHAT}}, $message;

        my @fcResults;
        for my $tc (@{$message->{tool_calls}}) {
            my $fcName = $tc->{function}{name}                              // '';
            my $args   = eval { decode_json($tc->{function}{arguments} // '{}') } // {};
            my $res    = OpenRouter_ExecuteFunctionCall($hash, $fcName, $args);
            push @fcResults, {
                tool_call_id => $tc->{id},
                name         => $fcName,
                result       => $res
            };
        }

        Log3 $name, 3, "OpenRouter ($name): " . scalar(@fcResults) . " Tool-Aufruf(e)"
            if scalar(@fcResults) > 1;

        OpenRouter_SendToolResults($hash, \@fcResults);
        return;
    }

    my $responseUnicode = $message->{content} // '';

    if (!$responseUnicode) {
        my $finishReason = $choice->{finish_reason} // 'UNKNOWN';
        readingsSingleUpdate($hash, 'lastError', "Leere Antwort, finishReason: $finishReason", 1);
        readingsSingleUpdate($hash, 'state', 'error', 1);
        pop @{$hash->{CHAT}};
        return;
    }

    push @{$hash->{CHAT}}, { role => 'assistant', content => $responseUnicode };

    my $responseForReading = $responseUnicode;
    utf8::encode($responseForReading) if utf8::is_utf8($responseForReading);

    my $responsePlain = OpenRouter_MarkdownToPlain($responseUnicode);
    utf8::encode($responsePlain) if utf8::is_utf8($responsePlain);

    my $responseHTML = OpenRouter_MarkdownToHTML($responseUnicode);
    utf8::encode($responseHTML) if utf8::is_utf8($responseHTML);

    # Telegram MarkdownV2 Reading
    my $telegramText = OpenRouter_EscapeMarkdownV2($responseUnicode);
    utf8::encode($telegramText ) if utf8::is_utf8($telegramText );

    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, 'response',         $responseForReading);
    readingsBulkUpdate($hash, 'responsePlain',    $responsePlain);
    readingsBulkUpdate($hash, 'responseHTML',     $responseHTML);
    readingsBulkUpdate($hash, 'responseTelegram', $telegramText);
    readingsBulkUpdate($hash, 'chatHistory',      scalar(@{$hash->{CHAT}}));
    readingsBulkUpdate($hash, 'state',            'ok');
    readingsBulkUpdate($hash, 'lastError',        '-');
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

    # Tool-Messages in persistenten Chat einfügen (korrekt)
    for my $res (@$results) {
        push @{$hash->{CHAT}}, {
            role         => 'tool',
            tool_call_id => $res->{tool_call_id},
            name         => $res->{name},
            content      => $res->{result}
        };
    }

    my $apiKey  = AttrVal($name, 'apiKey',  '');
    my $model   = AttrVal($name, 'model',   'google/gemini-2.0-flash-exp');
    my $timeout = AttrVal($name, 'timeout', 30);

    my @controlDevices = OpenRouter_GetControlDevices($hash);
    my $tools = @controlDevices
        ? OpenRouter_GetControlTools()
        : OpenRouter_GetReadTools();

    # FIX: Echte Kopie für den Request
    my $disableHistory = AttrVal($name, 'disableHistory', 0);
    my @sendMessages = $disableHistory
        ? grep { $_->{role} ne 'system' } @{$hash->{CHAT}}
        : @{$hash->{CHAT}};

    # System-Message NUR in die Send-Kopie
    my $systemPrompt  = AttrVal($name, 'systemPrompt', '');
    my $deviceContext = OpenRouter_BuildUnifiedDeviceContext($hash);
    my $fullSystem    = join("\n\n", grep { $_ } ($systemPrompt, $deviceContext));

    if ($fullSystem) {
        unshift @sendMessages, { role => 'system', content => $fullSystem };
    }

    my %requestBody = (
        model    => $model,
        messages => \@sendMessages,   # Kopie, nicht $hash->{CHAT}
        tools    => $tools
    );

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

    if ($fcName eq 'get_device_state') {
        my $device = $args->{device} // '';
        return "Fehler: Gerät '$device' nicht gefunden"
            unless exists $main::defs{$device};

        my $dev         = $main::defs{$device};
        my @whitelist   = OpenRouter_GetEffectiveWhitelist($hash);
        my %wlSet       = map { $_ => 1 } @whitelist;
        my %extraActive = OpenRouter_ParseReadingFilterExtra($hash);
        my @blacklist   = OpenRouter_GetBlacklist($hash);

        my $result  = "Gerät: $device\n";
        $result    .= "Typ: "   . ($dev->{TYPE} // 'unbekannt') . "\n";
        $result    .= "State: " . ReadingsVal($device, 'state', 'unbekannt') . "\n";

        if (exists $dev->{READINGS}) {
            $result .= "Readings:\n";
            for my $reading (sort keys %{$dev->{READINGS}}) {
                next if $reading eq 'state';
                next if OpenRouter_IsFiltered($hash, $device, $reading, \%wlSet, \%extraActive, \@blacklist);
                $result .= "  $reading: " . ($dev->{READINGS}{$reading}{VAL} // '') . "\n";
            }
        }

        Log3 $name, 4, "OpenRouter ($name): get_device_state($device)";
        return $result;

    } elsif ($fcName eq 'set_device') {
        my $device  = $args->{device}  // '';
        my $command = $args->{command} // '';

        my ($safe, $reason) = OpenRouter_IsSafeCommand($command);
        if (!$safe) {
            Log3 $name, 2, "OpenRouter ($name): Unsicherer Befehl blockiert: $reason";
            return "Fehler: $reason";
        }

        my %allowed = map { $_ => 1 } OpenRouter_GetControlDevices($hash);
        unless ($allowed{$device} && exists $main::defs{$device}) {
            my $msg = "Fehler: Gerät '$device' nicht in controlList";
            Log3 $name, 2, "OpenRouter ($name): $msg";
            return $msg;
        }

        my $setResult = CommandSet(undef, "$device $command") // 'ok';
        $setResult = 'ok' if $setResult eq '';

        my $cmdR = "$device $command";
        utf8::encode($cmdR) if utf8::is_utf8($cmdR);
        my $resR = $setResult;
        utf8::encode($resR) if utf8::is_utf8($resR);

        readingsBeginUpdate($hash);
        readingsBulkUpdate($hash, 'lastCommand',       $cmdR);
        readingsBulkUpdate($hash, 'lastCommandResult', $resR);
        readingsEndUpdate($hash, 1);

        Log3 $name, 3, "OpenRouter ($name): set $device $command -> $setResult";
        return "OK: set $device $command -> $setResult";

    } elsif ($fcName eq 'create_at_device') {
        my $deviceName = $args->{device_name} // '';
        my $timeSpec   = $args->{time_spec}   // '';
        my $command    = $args->{command}     // '';
        my $recurring  = $args->{recurring}   // 0;

        return "Fehler: Ungültiger Gerätename '$deviceName'"
            unless $deviceName =~ /^[a-zA-Z0-9_\-]+$/;

        my ($safe, $reason) = OpenRouter_IsSafeCommand($command);
        if (!$safe) {
            Log3 $name, 2, "OpenRouter ($name): Unsicherer Befehl blockiert: $reason";
            return "Fehler: $reason";
        }

        my $uid = sprintf("%x%x%x", time(), rand(0xffff), rand(0xffff));
        $deviceName = "at_${name}_${uid}_${deviceName}";

        my $res = CommandDefine(undef, "$deviceName at $timeSpec $command");
        return "Fehler beim Anlegen: $res" if $res;

        my $room = OpenRouter_GetAutomationRoom($hash);
        CommandAttr(undef, "$deviceName room $room") if $room;

        unless ($recurring) {
            CommandModify(undef, "$deviceName $timeSpec $command;; delete $deviceName");
            Log3 $name, 3, "OpenRouter ($name): AT-Device $deviceName angelegt (einmalig)";
        } else {
            Log3 $name, 3, "OpenRouter ($name): AT-Device $deviceName angelegt (wiederkehrend)";
        }

        my $auto = "AT: $deviceName";
        utf8::encode($auto) if utf8::is_utf8($auto);
        readingsSingleUpdate($hash, 'lastAutomation', $auto, 1);
        return "OK: AT-Device '$deviceName' angelegt";

    } elsif ($fcName eq 'create_notify_device') {
        my $deviceName = $args->{device_name} // '';
        my $eventSpec  = $args->{event_spec}  // '';
        my $command    = $args->{command}     // '';
        my $oneShot    = $args->{one_shot}    // 1;

        return "Fehler: Ungültiger Gerätename '$deviceName'"
            unless $deviceName =~ /^[a-zA-Z0-9_\-]+$/;
        my ($safe, $reason) = OpenRouter_IsSafeCommand($command);
        if (!$safe) {
            Log3 $name, 2, "OpenRouter ($name): Unsicherer Befehl blockiert: $reason";
            return "Fehler: $reason";
        }

        my $uid = sprintf("%x%x%x", time(), rand(0xffff), rand(0xffff));
        $deviceName = "n_${name}_${uid}_${deviceName}";

        my $finalCommand = $oneShot
            ? "{ fhem('$command');; fhem('delete $deviceName') }"
            : $command;

        my $res = CommandDefine(undef, "$deviceName notify $eventSpec $finalCommand");
        return "Fehler beim Anlegen: $res" if $res;

        my $room = OpenRouter_GetAutomationRoom($hash);
        CommandAttr(undef, "$deviceName room $room") if $room;

        Log3 $name, 3, "OpenRouter ($name): NOTIFY-Device $deviceName angelegt (" .
                        ($oneShot ? 'einmalig' : 'permanent') . ")";

        my $auto = "NOTIFY: $deviceName";
        utf8::encode($auto) if utf8::is_utf8($auto);
        readingsSingleUpdate($hash, 'lastAutomation', $auto, 1);
        return "OK: NOTIFY-Device '$deviceName' angelegt";

    } else {
        return "Fehler: Unbekannte Funktion '$fcName'";
    }
}

##############################################################################
# MIME-Typ
##############################################################################
sub OpenRouter_GetMimeType {
    my ($filePath) = @_;
    my $ext = '';
    $ext = lc($1) if $filePath =~ /\.([^.]+)$/;
    my %m = (jpg=>'image/jpeg', jpeg=>'image/jpeg', png=>'image/png',
             gif=>'image/gif',  webp=>'image/webp', bmp=>'image/bmp',
             heic=>'image/heic', heif=>'image/heif');
    return $m{$ext} // 'image/jpeg';
}

##############################################################################
# Markdown → Plain
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
# Markdown → HTML
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
    $text =~ s/((?:^[\-\*]\s+.+\n?)+)/my $b=$1; $b=~s{^[\-\*]\s+(.+)$}{<li>$1<\/li>}gm; "<ul>$b<\/ul>"/gme;
    $text =~ s/^(?:---|\*\*\*)\s*$/<hr>/gm;
    $text =~ s/\n(?!<(?:ul|\/ul|li|\/li|h[3-6]|\/h[3-6]|pre|\/pre|hr))/<br>\n/g;
    return $text;
}

##############################################################################
# Text für Telegram MarkdownV2 escapen
##############################################################################
sub OpenRouter_EscapeMarkdownV2 {
    my ($text) = @_;

    # Telegram MarkdownV2: diese Zeichen müssen escaped werden:
    # _ * [ ] ( ) ~ ` > # + - = | { } . ! \
    # AUSNAHME: Formatting-Markdown (*fett*, _kursiv_, `code`) soll erhalten bleiben

    # Strategie: Erst Markdown-Blöcke schützen, dann Rest escapen

    my $result = '';
    my $remaining = $text;

    while ($remaining) {
        # **fett** oder *fett*
        if ($remaining =~ /\A(\*\*(.+?)\*\*)/s) {
            $result   .= "*" . OpenRouter_EscapeMarkdownV2Plain($2) . "*";
            $remaining = substr($remaining, length($1));

        } elsif ($remaining =~ /\A(\*(.+?)\*)/s) {
            $result   .= "*" . OpenRouter_EscapeMarkdownV2Plain($2) . "*";
            $remaining = substr($remaining, length($1));

        # _kursiv_
        } elsif ($remaining =~ /\A(\_(.+?)\_)/s) {
            $result   .= "_" . OpenRouter_EscapeMarkdownV2Plain($2) . "_";
            $remaining = substr($remaining, length($1));

        # `code`
        } elsif ($remaining =~ /\A(`(.+?)`)/s) {
            $result   .= "`" . $2 . "`";   # In Code nichts escapen
            $remaining = substr($remaining, length($1));

        # ```codeblock```
        } elsif ($remaining =~ /\A(```(.+?)```)/s) {
            $result   .= "```" . $2 . "```";
            $remaining = substr($remaining, length($1));

        # normales Zeichen
        } else {
            my $char = substr($remaining, 0, 1);
            $result   .= OpenRouter_EscapeMarkdownV2Plain($char);
            $remaining = substr($remaining, 1);
        }
    }

    return $result;
}

##############################################################################
# Einzelne Zeichen für MarkdownV2 escapen (ohne Formatting-Zeichen)
##############################################################################
sub OpenRouter_EscapeMarkdownV2Plain {
    my ($text) = @_;
    # Sonderzeichen die Telegram MarkdownV2 escaped haben will
    $text =~ s/([_\[\]()~`>#+\-=|{}.!\\])/\\$1/g;
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
  Unterstützt Claude, GPT-4, Gemini und viele weitere Modelle.<br><br>

  <b>Define</b><br>
  <ul><code>define &lt;name&gt; OpenRouter</code></ul><br>

  <b>Set</b><br>
  <ul>
    <li><b>ask</b> &lt;Frage&gt;</li>
    <li><b>askWithImage</b> &lt;Pfad&gt; &lt;Frage&gt;</li>
    <li><b>askAboutDevices</b> [&lt;Frage&gt;]</li>
    <li><b>chat</b> &lt;Nachricht&gt;</li>
    <li><b>control</b> &lt;Anweisung&gt;</li>
    <li><b>resetChat</b></li>
    <li><b>collectReadings</b></li>
  </ul><br>

  <b>Reading-Filter Widget</b><br>
  <ul>
    Detailseite zeigt Checkboxen für alle bekannten Readings.<br>
    Aktivierte Extras werden in <code>readingFilterExtra</code> gespeichert.<br>
    Das Widget ist theme-unabhängig (CSS im Modul eingebettet).
  </ul>
</ul>

=end html
=cut
