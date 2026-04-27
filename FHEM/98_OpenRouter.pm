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
#
# Attribute:
#   apiKey        - OpenRouter API Key (Pflicht)
#   model         - LLM Modell (Standard: google/gemini-2.0-flash-exp)
#   maxHistory    - Maximale Anzahl Chat-Nachrichten (Standard: 20)
#   systemPrompt  - Optionaler System-Prompt
#   timeout       - HTTP Timeout in Sekunden (Standard: 30)
#   deviceList    - Komma-getrennte Liste der Geräte für askAboutDevices
#   deviceRoom    - Komma-getrennte Raumliste; Geräte mit passendem room-Attribut
#                   werden automatisch für askAboutDevices verwendet
#   controlList   - Komma-getrennte Liste der Geräte, die das LLM steuern darf
#   controlRoom   - Komma-getrennte Raumliste; Geraete mit passendem room-Attribut
#                   werden automatisch als steuerbar eingestuft (ergaenzt controlList)
#   automationRoom - Raum für automatisch angelegte AT/NOTIFY-Geräte (Standard: erster Raum von OpenRouter selbst)
#   disableHistory - Chat-Verlauf deaktivieren (0/1); jede Anfrage wird als eigenstaendiges Gespraech behandelt
#   readingBlacklist - Leerzeichen-getrennte Liste von Reading-/Befehlsnamen, die nicht an das LLM
#                      uebermittelt werden; Wildcards (*) werden unterstuetzt.
#                      Standard: attrTemplate associate R-* RegL_* associatedWith peerListRDate
#                                protLastRcv lastTimeSync lastcmd Heap LoadAvg Uptime Wifi_*
#   maxReadingsPerDevice - Maximale Anzahl Readings pro Gerät im dynamischen Status (Standard: 20)
#
# Set-Befehle:
#   ask <Frage>                    - Textfrage stellen
#   askWithImage <Pfad> <Frage>    - Bild + Frage senden (nur bei Vision-Modellen)
#   askAboutDevices [<Frage>]      - Geräte-Statusabfrage
#   chat <Nachricht>               - Universeller Befehl: allgemeine Fragen, Geraete-Status
#                                    und Steuerung in einem (ideal fuer Telegram-Integration)
#   control <Anweisung>            - LLM steuert Geräte via Function Calling
#   resetChat                      - Chat-Verlauf löschen
#
# Lesewerte (Readings):
#   response           - Letzte Antwort vom LLM (Roh-Markdown)
#   responsePlain      - Letzte Antwort, Markdown bereinigt (reiner Text)
#   responseHTML       - Letzte Antwort, Markdown in HTML konvertiert
#   state              - Aktueller Status
#   lastError          - Letzter Fehler
#   chatHistory        - Anzahl der Nachrichten im Verlauf
#   lastCommand        - Letzter ausgeführter set-Befehl
#   lastCommandResult  - Ergebnis des letzten set-Befehls
#   lastAutomation     - Letztes angelegtes AT/NOTIFY-Gerät
#
##############################################################################

# Versionshistorie:
# 1.0.0 - 2026-04-27  Initiale Version basierend auf FHEM-Gemini 4.1.1
#                     - OpenRouter API Integration (OpenAI-kompatibel)
#                     - Ultra-kompaktes Format für niedrigen Token-Verbrauch
#                     - Function Calling für unterstützte Modelle
#                     - AT/NOTIFY Support
#                     - Standard-Modell: google/gemini-2.0-flash-exp (kostenlos)

package main;

use strict;
use warnings;
use HttpUtils;
use JSON;
use MIME::Base64;


sub OpenRouter_Initialize {
    my ($hash) = @_; 

    $hash->{DefFn}      = 'OpenRouter_Define';
    $hash->{UndefFn}    = 'OpenRouter_Undefine';
    $hash->{SetFn}      = 'OpenRouter_Set';
    $hash->{GetFn}      = 'OpenRouter_Get';
    $hash->{AttrFn}     = 'OpenRouter_Attr';
    $hash->{AttrList}   =
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
        $readingFnAttributes;

    return undef;
}

sub OpenRouter_Define {    
    my $hash = shift;
    my $def  = shift;
    my $h    = shift;
    
    my @args = split('[ \t]+', $def);

    return "Usage: define <name> OpenRouter" if (@args < 2);

    my $name = $args[0];
    $hash->{NAME}        = $name;
    $hash->{CHAT}        = [];   # Chat-Verlauf als Array-Referenz
    $hash->{VERSION}     = '1.0.0';

    readingsSingleUpdate($hash, 'state',                'initialized', 1);
    readingsSingleUpdate($hash, 'response',             '-',           0);
    readingsSingleUpdate($hash, 'chatHistory',          0,             0);
    readingsSingleUpdate($hash, 'lastError',            '-',           0);
    readingsSingleUpdate($hash, 'lastCommand',          '-',           0);
    readingsSingleUpdate($hash, 'lastCommandResult',    '-',           0);
    readingsSingleUpdate($hash, 'lastAutomation',       '-',           0);
    readingsSingleUpdate($hash, 'responseHTML',         '-',           0);
    readingsSingleUpdate($hash, 'responsePlain',        '-',           0);
    readingsSingleUpdate($hash, 'candidatesTokenCount', '-',           0);
    readingsSingleUpdate($hash, 'promptTokenCount',     '-',           0);
    readingsSingleUpdate($hash, 'totalTokenCount',      '-',           0);

    

    addToAttrList($hash->{NAME} . "Comment:textField-long","OpenRouter");  
    
    Log3 $name, 3, "OpenRouter ($name): Defined";
    return undef;
}

sub OpenRouter_Undefine {
    my ($hash, $name) = @_;
    return undef;
}

sub OpenRouter_Attr {
    my ($cmd, $name, $attr, $value) = @_; 
    if ($attr eq 'timeout') {
        return "timeout must be a positive number" unless ($value =~ /^\d+$/ && $value > 0);
    }
    if ($attr eq 'maxReadingsPerDevice') {
        return "maxReadingsPerDevice must be a positive number" unless ($value =~ /^\d+$/ && $value > 0);
    }
    return undef;
}

sub OpenRouter_Set {
    my ($hash, $name, $cmd, @args) = @_; 

    return "\"set $name\" needs at least one argument" unless defined($cmd);

    if ($cmd eq 'ask') {
        return "Usage: set $name ask <Frage>" unless @args;
        my $question = join(' ', @args);
        OpenRouter_SendRequest($hash, $question, undef, 0);
        return undef;

    } elsif ($cmd eq 'askWithImage') {
        return "Usage: set $name askWithImage <Bildpfad> <Frage>" unless @args >= 2;
        my $imagePath = $args[0];
        my $question  = join(' ', @args[1..$#args]);
        return "Bilddatei nicht gefunden: $imagePath" unless -f $imagePath;
        OpenRouter_SendRequest($hash, $question, $imagePath, 0);
        return undef;

    } elsif ($cmd eq 'askAboutDevices') {
        my $question = @args ? join(' ', @args) : 'Gib mir eine Zusammenfassung aller Geräte und ihres aktuellen Status.';
        OpenRouter_SendRequest($hash, $question, undef, 1);
        return undef;

    } elsif ($cmd eq 'chat') {
        return "Usage: set $name chat <Nachricht>" unless @args;
        my $message = join(' ', @args);
        my @controlDevices = OpenRouter_GetControlDevices($hash);
        if (@controlDevices) {
            OpenRouter_SendControl($hash, $message, 1);
        } else {
            OpenRouter_SendRequest($hash, $message, undef, 1);
        }
        return undef;

    } elsif ($cmd eq 'control') {
        return "Usage: set $name control <Anweisung>" unless @args;
        my @controlDevices = OpenRouter_GetControlDevices($hash);
        return "Fehler: Weder controlList noch controlRoom ist gesetzt" unless @controlDevices;
        my $instruction = join(' ', @args);
        OpenRouter_SendControl($hash, $instruction, 0);
        return undef;

    } elsif ($cmd eq 'resetChat') {
        $hash->{CHAT} = [];
        readingsSingleUpdate($hash, 'chatHistory', 0, 1);
        readingsSingleUpdate($hash, 'state', 'chat reset', 1);
        Log3 $name, 3, "OpenRouter ($name): Chat-Verlauf zurückgesetzt";
        return undef;

    } else {
        return "Unknown argument $cmd, choose one of ask:textField askWithImage:textField askAboutDevices:textField chat:textField control:textField resetChat:noArg";
    }
}

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
                            $text .= $part->{text} if exists $part->{text};
                            $text .= '[Bild]' if exists $part->{image_url};
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
# Hauptfunktion: Anfrage an OpenRouter API senden
##############################################################################
sub OpenRouter_SendRequest {
    my ($hash, $question, $imagePath, $includeDeviceStatus) = @_; 
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

    # DYNAMISCHER Teil: aktueller Gerätestatus (in user message)
    my $dynamicStatus = '';
    if ($includeDeviceStatus) {
        $dynamicStatus = OpenRouter_BuildDynamicDeviceStatus($hash);
    }

    # User-Message zusammenbauen (OpenAI-Format)
    my @contentParts;

    # Erst dynamischer Status (falls gewünscht)
    if ($dynamicStatus) {
        push @contentParts, {
            type => 'text',
            text => $dynamicStatus
        };
    }

    # Dann Bild (falls vorhanden)
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
            type => 'image_url',
            image_url => {
                url => "data:${mimeType};base64,${base64Image}"
            }
        };
        Log3 $name, 4, "OpenRouter ($name): Bild geladen: $imagePath ($mimeType)";
    }

    # Dann die eigentliche Frage
    push @contentParts, {
        type => 'text',
        text => $question
    };

    push @{$hash->{CHAT}}, {
        role    => 'user',
        content => \@contentParts
    };

    while (scalar(@{$hash->{CHAT}}) > $maxHistory) {
        shift @{$hash->{CHAT}};
    }

    # History-Cleanup: ensure valid chat structure
    while (@{$hash->{CHAT}}) {
        my $first = $hash->{CHAT}[0];
        last if $first->{role} eq 'user';
        shift @{$hash->{CHAT}};
    }

    my $disableHistory = AttrVal($name, 'disableHistory', 0);
    my $messagesToSend = $disableHistory ? [ $hash->{CHAT}[-1] ] : $hash->{CHAT};

    my %requestBody = (
        model    => $model,
        messages => $messagesToSend
    );

    # STATISCHER Teil für system message (optional)
    my $systemPrompt        = AttrVal($name, 'systemPrompt', '');
    my $staticDeviceContext = '';
    
    if ($includeDeviceStatus) {
        $staticDeviceContext = OpenRouter_BuildStaticDeviceContext($hash);
    }

    my $fullSystem = '';
    $fullSystem .= $systemPrompt if $systemPrompt;
    $fullSystem .= "\n\n" if $systemPrompt && $staticDeviceContext;
    $fullSystem .= $staticDeviceContext if $staticDeviceContext;

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

    Log3 $name, 4, "OpenRouter ($name): Anfrage " . $jsonBody;

    my $url = "https://openrouter.ai/api/v1/chat/completions";

    readingsSingleUpdate($hash, 'state', 'requesting...', 1);

    HttpUtils_NonblockingGet({
        url      => $url,
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
# Callback: Antwort von OpenRouter verarbeiten
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

    if (exists $result->{usage}) {
        my $promptTokens     = $result->{usage}{prompt_tokens} // 0;
        my $completionTokens = $result->{usage}{completion_tokens} // 0;
        my $totalTokens      = $result->{usage}{total_tokens} // 0;
        readingsSingleUpdate($hash, 'promptTokenCount', $promptTokens, 1);
        readingsSingleUpdate($hash, 'candidatesTokenCount', $completionTokens, 1);
        readingsSingleUpdate($hash, 'totalTokenCount', $totalTokens, 1);
    }

    my $responseUnicode = '';
    eval {
        $responseUnicode = $result->{choices}[0]{message}{content};
    };

    if (!$responseUnicode) {
        my $finishReason = eval { $result->{choices}[0]{finish_reason} } // 'UNKNOWN';
        readingsSingleUpdate($hash, 'lastError', "Leere Antwort, finishReason: $finishReason", 1);
        readingsSingleUpdate($hash, 'state', 'error', 1);
        Log3 $name, 2, "OpenRouter ($name): Leere Antwort erhalten, finishReason: $finishReason";
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
    readingsBulkUpdate($hash, 'chatHistory', scalar(@{$hash->{CHAT}}));
    readingsBulkUpdate($hash, 'state',       'ok');
    readingsBulkUpdate($hash, 'lastError',   '-');
    readingsEndUpdate($hash, 1);

    Log3 $name, 4, "OpenRouter ($name): Antwort erhalten (" . length($responseUnicode) . " Zeichen)";
    return undef;
}

##############################################################################
# Hilfsfunktion: Markdown in reinen Text konvertieren
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
# Hilfsfunktion: Markdown in HTML konvertieren
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
    $text =~ s/((?:^[\-\*]\s+.+\n?)+)/my $block = $1; $block =~ s{^[\-\*]\s+(.+)$}{<li>$1<\/li>}gm; "<ul>$block<\/ul>"/gme;
    $text =~ s/^(?:---|\*\*\*)\s*$/<hr>/gm;
    $text =~ s/\n(?!<(?:ul|\/ul|li|\/li|h[3-6]|\/h[3-6]|pre|\/pre|hr))/<br>\n/g;

    return $text;
}

##############################################################################
# Hilfsfunktion: MIME-Typ anhand Dateiendung bestimmen
##############################################################################
sub OpenRouter_GetMimeType {
    my ($filePath) = @_; 

    my $ext = '';
    if ($filePath =~ /\.([^.]+)$/) {
        $ext = lc($1);
    }

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
# Hilfsfunktion: Blacklist-Muster fuer Readings/Befehle liefern
##############################################################################
sub OpenRouter_GetBlacklist {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    my $attr = AttrVal($name, 'readingBlacklist', '');
    if ($attr ne '') {
        return split(/\s+/, $attr);
    }
    return qw(
        attrTemplate associate R-* RegL_* associatedWith
        peerListRDate protLastRcv lastTimeSync lastcmd
        Heap LoadAvg Uptime Wifi_*
    );
}

##############################################################################
# Hilfsfunktion: Pruefen ob ein Name auf ein Blacklist-Muster passt
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
# Hilfsfunktion: Raum für Automation-Geräte ermitteln
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
# Hilfsfunktion: Liste der Geräte aus deviceList/deviceRoom ermitteln
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
    $devList = join(',', sort keys %main::defs) if $devList eq '*';
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
# ULTRA-KOMPAKT: Statischen Gerätekontext für niedrigen Token-Verbrauch
##############################################################################
sub OpenRouter_BuildStaticDeviceContext {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    my @devices = OpenRouter_GetDeviceList($hash);
    return '' unless @devices;

    my @blacklist = OpenRouter_GetBlacklist($hash);
    
    my $context = "Smart-Home Geräte (Struktur):\n";
    $context .= "name(alias)|type|R:readings|comment";
    
    for my $devName (@devices) {
        next unless exists $main::defs{$devName};
        my $dev   = $main::defs{$devName};
        my $alias = AttrVal($devName, 'alias', '');
        my $type  = $dev->{TYPE} // '?';
        
        $context .= $devName;
        $context .= "($alias)" if $alias && $alias ne $devName;
        $context .= "|$type";
        
        if (exists $dev->{READINGS}) {
            my @readings = grep { 
                $_ ne 'state' && !OpenRouter_IsBlacklisted($_, @blacklist) 
            } sort keys %{$dev->{READINGS}};
            
            $context .= "|R:" . join(',', @readings) if @readings;
        }
        
        my $aiComment = AttrVal($devName, $name . 'Comment', '');
        my $comment   = AttrVal($devName, 'comment', '');
        
        if ($aiComment) {
            $context .= "|$aiComment";
        } elsif ($comment) {
            $context .= "|$comment";
        }
        
        $context .= "\n";
    }
    
    $context .= "\nNutze get_device_state(device) für Details.\n";
    
    return $context;
}

##############################################################################
# ULTRA-KOMPAKT: Dynamischen Gerätestatus für User-Message
##############################################################################
sub OpenRouter_BuildDynamicDeviceStatus {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    my @devices = OpenRouter_GetDeviceList($hash);
    return '' unless @devices;

    my @blacklist    = OpenRouter_GetBlacklist($hash);
    my $maxReadings  = AttrVal($name, 'maxReadingsPerDevice', 20);
    
    my $status = "Status:\n";
    
    for my $devName (@devices) {
        next unless exists $main::defs{$devName};
        my $dev   = $main::defs{$devName};
        my $alias = AttrVal($devName, 'alias', $devName);
        my $state = ReadingsVal($devName, 'state', '?');
        
        $status .= "$devName:$state";
        $status .= "name|state|reading1=x,reading2=y..";
        
        if (exists $dev->{READINGS}) {
            my @values;
            my $totalReadings = 0;
            my $truncated = 0;
            
            for my $reading (sort keys %{$dev->{READINGS}}) {
                next if $reading eq 'state';
                next if OpenRouter_IsBlacklisted($reading, @blacklist);
                
                $totalReadings++;
                
                if (scalar(@values) < $maxReadings) {
                    my $val = $dev->{READINGS}{$reading}{VAL} // '';
                    push @values, "$reading=$val";
                } else {
                    $truncated = 1;
                }
            }
            
            if (@values) {
                $status .= "|" . join(',', @values);
                $status .= "...+" . ($totalReadings - $maxReadings) if $truncated;
                
                if ($truncated) {
                    Log3 $name, 4, "OpenRouter ($name): $devName Readings gekürzt ($totalReadings -> $maxReadings)";
                }
            }
        }
        $status .= "\n";
    }

    return $status;
}

##############################################################################
# Hilfsfunktion: Liste aller steuerbaren Geräte ermitteln
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
# ULTRA-KOMPAKT: Statischen Control-Kontext
##############################################################################
sub OpenRouter_BuildStaticControlContext {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    my @devices = OpenRouter_GetControlDevices($hash);
    return '' unless @devices;

    my @blacklist = OpenRouter_GetBlacklist($hash);
    
    my $context = "Steuerbare Geräte:\n";
    $context .= "name(alias)|cmds|comment";
    
    for my $devName (@devices) {
        next unless exists $main::defs{$devName};
        my $alias = AttrVal($devName, 'alias', $devName);

        my $setListRaw = main::getAllSets($devName) // '';
        my @cmds;
        for my $entry (split(/\s+/, $setListRaw)) {
            my ($cmdName) = split(/:/, $entry, 2);
            next unless $cmdName;
            next if OpenRouter_IsBlacklisted($cmdName, @blacklist);
            push @cmds, $entry;
        }

        my $cmdsStr = @cmds ? join(',', @cmds) : '?';
        
        $context .= $devName;
        $context .= "($alias)" if $alias ne $devName;
        $context .= "|$cmdsStr";
        
        my $aiComment = AttrVal($devName, $name . 'Comment', '');
        $context .= "|$aiComment" if $aiComment;
        
        $context .= "\n";
    }

    return $context;
}

##############################################################################
# Hilfsfunktion: Tool-Definitionen für Function Calling zurückgeben
##############################################################################
sub OpenRouter_GetControlTools {
    return [
        {
            type => 'function',
            function => {
                name        => 'set_device',
                description => 'Führt einen FHEM set-Befehl auf einem Gerät aus. Kann PARALLEL mehrfach aufgerufen werden für mehrere Geräte.',
                parameters  => {
                    type       => 'object',
                    properties => {
                        device  => { type => 'string', description => 'FHEM Gerätename (intern)' },
                        command => { type => 'string', description => 'Der set-Befehl, z.B. on, off, 21' }
                    },
                    required => ['device', 'command']
                }
            }
        },
        {
            type => 'function',
            function => {
                name        => 'get_device_state',
                description => 'Liest den aktuellen Status und alle Readings eines FHEM-Geräts',
                parameters  => {
                    type       => 'object',
                    properties => {
                        device => { type => 'string', description => 'FHEM Gerätename (intern)' }
                    },
                    required => ['device']
                }
            }
        },
        {
            type => 'function',
            function => {
                name        => 'create_at_device',
                description => 'Legt ein zeitgesteuertes AT-Device in FHEM an für einmalige oder wiederkehrende Aktionen.',
                parameters  => {
                    type       => 'object',
                    properties => {
                        device_name => { 
                            type => 'string', 
                            description => 'Name des neuen AT-Geräts' 
                        },
                        time_spec   => { 
                            type => 'string', 
                            description => 'Zeitspezifikation: HH:MM:SS, +HH:MM:SS, *HH:MM:SS' 
                        },
                        command     => { 
                            type => 'string', 
                            description => 'Der set-Befehl, exakter FHEM-Gerätename verwenden'
                        },
                        recurring   => { 
                            type => 'boolean', 
                            description => 'true für wiederkehrend, false für einmalig. Standard: false' 
                        }
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
                        device_name => { 
                            type => 'string', 
                            description => 'Name des neuen NOTIFY-Geräts' 
                        },
                        event_spec  => { 
                            type => 'string', 
                            description => 'Event-Spezifikation: "Gerätename:Event-Pattern"' 
                        },
                        command     => { 
                            type => 'string', 
                            description => 'Der set-Befehl, exakter FHEM-Gerätename verwenden'  
                        },
                        one_shot    => { 
                            type => 'boolean', 
                            description => 'true für einmalig (löscht sich), false für permanent. Standard: true' 
                        }
                    },
                    required => ['device_name', 'event_spec', 'command']
                }
            }
        }
    ];
}

##############################################################################
# Hilfsfunktion: Control-Session-Chat zurücksetzen (Fehlerbehandlung)
##############################################################################
sub OpenRouter_RollbackControlSession {
    my ($hash) = @_;
    my $startIdx = $hash->{CONTROL_START_IDX} // 0;
    splice(@{$hash->{CHAT}}, $startIdx);
    delete $hash->{CONTROL_START_IDX};
    delete $hash->{CHAT_INCLUDE_DEVICE_STATUS};
}

##############################################################################
# OPTIMIERT: Control-Funktion mit Function Calling
##############################################################################
sub OpenRouter_SendControl {
    my ($hash, $instruction, $includeDeviceStatus) = @_;
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

    $hash->{CONTROL_START_IDX}          = scalar(@{$hash->{CHAT}});
    $hash->{CHAT_INCLUDE_DEVICE_STATUS} = $includeDeviceStatus;

    # DYNAMISCHER Teil: aktueller Gerätestatus (falls gewünscht)
    my @contentParts;
    
    if ($includeDeviceStatus) {
        my $dynamicStatus = OpenRouter_BuildDynamicDeviceStatus($hash);
        if ($dynamicStatus) {
            push @contentParts, {
                type => 'text',
                text => $dynamicStatus
            };
        }
    }

    # Die eigentliche Anweisung
    push @contentParts, {
        type => 'text',
        text => $instruction
    };

    push @{$hash->{CHAT}}, {
        role    => 'user',
        content => \@contentParts
    };

    while (scalar(@{$hash->{CHAT}}) > $maxHistory) {
        shift @{$hash->{CHAT}};
        $hash->{CONTROL_START_IDX}-- if $hash->{CONTROL_START_IDX} > 0;
    }

    # History cleanup
    while (@{$hash->{CHAT}}) {
        my $first = $hash->{CHAT}[0];
        last if $first->{role} eq 'user';
        shift @{$hash->{CHAT}};
        $hash->{CONTROL_START_IDX}-- if $hash->{CONTROL_START_IDX} > 0;
    }

    my $disableHistory = AttrVal($name, 'disableHistory', 0);
    my $messagesToSend = $disableHistory ? [ $hash->{CHAT}[-1] ] : $hash->{CHAT};

    my %requestBody = (
        model    => $model,
        messages => $messagesToSend,
        tools    => OpenRouter_GetControlTools()
    );

    # STATISCHER Teil für system message
    my $systemPrompt         = AttrVal($name, 'systemPrompt', '');
    my $staticControlContext = OpenRouter_BuildStaticControlContext($hash);
    my $staticDeviceContext  = '';
    
    if ($includeDeviceStatus) {
        $staticDeviceContext = OpenRouter_BuildStaticDeviceContext($hash);
    }

    my $fullSystem = '';
    $fullSystem .= $systemPrompt if $systemPrompt;
    $fullSystem .= "\n\n" if $systemPrompt && $staticDeviceContext;
    $fullSystem .= $staticDeviceContext if $staticDeviceContext;
    $fullSystem .= "\n\n" if $fullSystem && $staticControlContext;
    $fullSystem .= $staticControlContext if $staticControlContext;

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

    Log3 $name, 4, "OpenRouter ($name): Control-Anfrage";

    my $url = "https://openrouter.ai/api/v1/chat/completions";

    readingsSingleUpdate($hash, 'state', 'requesting...', 1);

    HttpUtils_NonblockingGet({
        url      => $url,
        timeout  => $timeout,
        method   => 'POST',
        header   => "Content-Type: application/json\r\n" .
                    "Authorization: Bearer ${apiKey}\r\n" .
                    "HTTP-Referer: https://fhem.de\r\n" .
                    "X-Title: FHEM-OpenRouter",
        data     => $jsonBody,
        hash     => $hash,
        callback => \&OpenRouter_HandleControlResponse,
    });

    return undef;
}

##############################################################################
# Callback: Antwort auf Control-Anfrage / Function-Result verarbeiten
##############################################################################
sub OpenRouter_HandleControlResponse {
    my ($param, $err, $data) = @_; 
    my $hash = $param->{hash};
    my $name = $hash->{NAME};

    if ($err) {
        readingsSingleUpdate($hash, 'lastError', "HTTP Fehler: $err", 1);
        readingsSingleUpdate($hash, 'state', 'error', 1);
        Log3 $name, 1, "OpenRouter ($name): HTTP Fehler: $err";
        OpenRouter_RollbackControlSession($hash);
        return;
    }

    utf8::downgrade($data, 1);

    Log3 $name, 5, "OpenRouter ($name): Control-Antwort raw: $data";

    my $result = eval { decode_json($data) };
    if ($@) {
        readingsSingleUpdate($hash, 'lastError', "JSON Parse Fehler: $@", 1);
        readingsSingleUpdate($hash, 'state', 'error', 1);
        Log3 $name, 1, "OpenRouter ($name): JSON Parse Fehler: $@";
        OpenRouter_RollbackControlSession($hash);
        return;
    }

    if (exists $result->{error}) {
        my $errMsg  = $result->{error}{message} // 'Unbekannter API Fehler';
        my $errCode = $result->{error}{code}    // 'N/A';
        readingsSingleUpdate($hash, 'lastError', "API Fehler $errCode: $errMsg", 1);
        readingsSingleUpdate($hash, 'state', 'error', 1);
        Log3 $name, 1, "OpenRouter ($name): API Fehler $errCode: $errMsg";
        OpenRouter_RollbackControlSession($hash);
        return;
    }

    if (exists $result->{usage}) {
        my $promptTokens     = $result->{usage}{prompt_tokens} // 0;
        my $completionTokens = $result->{usage}{completion_tokens} // 0;
        my $totalTokens      = $result->{usage}{total_tokens} // 0;
        readingsSingleUpdate($hash, 'promptTokenCount', $promptTokens, 1);
        readingsSingleUpdate($hash, 'candidatesTokenCount', $completionTokens, 1);
        readingsSingleUpdate($hash, 'totalTokenCount', $totalTokens, 1);
    }

    my $choice  = $result->{choices}[0];
    my $message = $choice->{message};

    # Function Calls prüfen
    if (exists $message->{tool_calls} && ref($message->{tool_calls}) eq 'ARRAY') {
        my @tool_calls = @{$message->{tool_calls}};
        
        if (@tool_calls) {
            # Assistant-Message mit tool_calls speichern
            push @{$hash->{CHAT}}, $message;
            
            my @fcResults = ();
            for my $tc (@tool_calls) {
                my $fcName = $tc->{function}{name} // '';
                my $args   = eval { decode_json($tc->{function}{arguments} // '{}') } // {};
                my $result = OpenRouter_ExecuteFunctionCall($hash, $fcName, $args);
                push @fcResults, { 
                    tool_call_id => $tc->{id},
                    name         => $fcName, 
                    result       => $result 
                };
            }
            
            if (scalar(@fcResults) > 1) {
                my @names = map { $_->{name} } @fcResults;
                Log3 $name, 3, "OpenRouter ($name): Mehrere Befehle parallel: " . join(', ', @names);
            }
            
            OpenRouter_SendFunctionResults($hash, \@fcResults);
            return;
        }
    }

    # Kein Function Call - finale Textantwort
    my $responseUnicode = $message->{content} // '';

    if (!$responseUnicode) {
        my $finishReason = $choice->{finish_reason} // 'UNKNOWN';
        readingsSingleUpdate($hash, 'lastError', "Leere Antwort, finishReason: $finishReason", 1);
        readingsSingleUpdate($hash, 'state', 'error', 1);
        Log3 $name, 2, "OpenRouter ($name): Leere Control-Antwort, finishReason: $finishReason";
        OpenRouter_RollbackControlSession($hash);
        return;
    }

    push @{$hash->{CHAT}}, $message;

    delete $hash->{CONTROL_START_IDX};
    delete $hash->{CHAT_INCLUDE_DEVICE_STATUS};

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
    readingsBulkUpdate($hash, 'chatHistory', scalar(@{$hash->{CHAT}}));
    readingsBulkUpdate($hash, 'state',       'ok');
    readingsBulkUpdate($hash, 'lastError',   '-');
    readingsEndUpdate($hash, 1);

    Log3 $name, 4, "OpenRouter ($name): Control-Antwort erhalten";
    return undef;
}

##############################################################################
# Hilfsfunktion: Einzelnen Function Call ausführen
##############################################################################
sub OpenRouter_ExecuteFunctionCall {
    my ($hash, $fcName, $args) = @_;
    my $name = $hash->{NAME};

    if ($fcName eq 'set_device') {
        my $device  = $args->{device}  // '';
        my $command = $args->{command} // '';

        if ($command =~ /[;|`\$\(\)<>\n]/) {
            my $errMsg = "Fehler: Ungültiger Befehl '$command' (unerlaubte Zeichen)";
            Log3 $name, 2, "OpenRouter ($name): $errMsg";
            return $errMsg;
        }

        my %allowed = map { $_ => 1 } OpenRouter_GetControlDevices($hash);

        if ($allowed{$device} && exists $main::defs{$device}) {
            my $setResult = CommandSet(undef, "$device $command");
            $setResult //= 'ok';
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
            return "OK: $device $command ausgefuehrt";
        } else {
            my $errMsg = "Fehler: Geraet '$device' nicht in controlList oder nicht vorhanden";
            Log3 $name, 2, "OpenRouter ($name): $errMsg";
            return $errMsg;
        }

    } elsif ($fcName eq 'get_device_state') {
        my $device = $args->{device} // '';

        if (exists $main::defs{$device}) {
            my $dev = $main::defs{$device};
            my @blacklist = OpenRouter_GetBlacklist($hash);
            my $stateResult  = "Geraet: $device\n";
            $stateResult .= "Typ: " . ($dev->{TYPE} // 'unbekannt') . "\n";
            $stateResult .= "Status: " . ReadingsVal($device, 'state', 'unbekannt') . "\n";
            if (exists $dev->{READINGS}) {
                $stateResult .= "Readings:\n";
                for my $reading (sort keys %{$dev->{READINGS}}) {
                    next if $reading eq 'state';
                    next if OpenRouter_IsBlacklisted($reading, @blacklist);
                    my $val = $dev->{READINGS}{$reading}{VAL} // '';
                    $stateResult .= "  $reading: $val\n";
                }
            }
            return $stateResult;
        } else {
            return "Fehler: Geraet '$device' nicht gefunden";
        }

    } elsif ($fcName eq 'create_at_device') {
        my $deviceName = $args->{device_name} // '';
        my $timeSpec   = $args->{time_spec}   // '';
        my $command    = $args->{command}     // '';
        my $recurring  = $args->{recurring}   // 0;

        if ($deviceName !~ /^[a-zA-Z0-9_\-]+$/) {
            my $errMsg = "Fehler: Ungültiger Gerätename '$deviceName'";
            Log3 $name, 2, "OpenRouter ($name): $errMsg";
            return $errMsg;
        }
        
        my $uniqueID = sprintf("%x%x%x", time(), rand(0xffff), rand(0xffff));
        $deviceName = "at_" . $name . "_" . $uniqueID . "_" . $deviceName;
        
        if (exists $main::defs{$deviceName}) {
            my $errMsg = "Fehler: Gerät '$deviceName' existiert bereits";
            Log3 $name, 2, "OpenRouter ($name): $errMsg";
            return $errMsg;
        }

        if ($command =~ /[;|`\(\)<>]/) {
            my $errMsg = "Fehler: Ungültiger Befehl '$command' (unerlaubte Zeichen)";
            Log3 $name, 2, "OpenRouter ($name): $errMsg";
            return $errMsg;
        }

        my $room = OpenRouter_GetAutomationRoom($hash);

        my $defineCmd = "$deviceName at $timeSpec $command";
        my $defineResult = CommandDefine(undef, $defineCmd);
        
        if ($defineResult) {
            my $errMsg = "Fehler beim Anlegen von AT-Device: $defineResult";
            Log3 $name, 2, "OpenRouter ($name): $errMsg";
            return $errMsg;
        }

        if ($room) {
            CommandAttr(undef, "$deviceName room $room");
        }

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

        return "OK: AT-Device '$deviceName' erfolgreich angelegt";

    } elsif ($fcName eq 'create_notify_device') {
        my $deviceName = $args->{device_name} // '';
        my $eventSpec  = $args->{event_spec}  // '';
        my $command    = $args->{command}     // '';
        my $oneShot    = $args->{one_shot}    // 1;

        if ($deviceName !~ /^[a-zA-Z0-9_\-]+$/) {
            my $errMsg = "Fehler: Ungültiger Gerätename '$deviceName'";
            Log3 $name, 2, "OpenRouter ($name): $errMsg";
            return $errMsg;
        }

        my $uniqueID = sprintf("%x%x%x", time(), rand(0xffff), rand(0xffff));
        $deviceName = "n_" . $name . "_" . $uniqueID . "_" . $deviceName;

        if (exists $main::defs{$deviceName}) {
            my $errMsg = "Fehler: Gerät '$deviceName' existiert bereits";
            Log3 $name, 2, "OpenRouter ($name): $errMsg";
            return $errMsg;
        }

        if ($command =~ /[;|`\(\)<>]/) {
            my $errMsg = "Fehler: Ungültiger Befehl '$command' (unerlaubte Zeichen)";
            Log3 $name, 2, "OpenRouter ($name): $errMsg";
            return $errMsg;
        }

        my $room = OpenRouter_GetAutomationRoom($hash);

        my $finalCommand = $command;
        if ($oneShot) {
            $finalCommand = "{ fhem('$command');; fhem('delete $deviceName') }";
        }

        my $defineCmd = "$deviceName notify $eventSpec $finalCommand";
        my $defineResult = CommandDefine(undef, $defineCmd);
        
        if ($defineResult) {
            my $errMsg = "Fehler beim Anlegen von NOTIFY-Device: $defineResult";
            Log3 $name, 2, "OpenRouter ($name): $errMsg";
            return $errMsg;
        }

        if ($room) {
            CommandAttr(undef, "$deviceName room $room");
        }

        if ($oneShot) {
            Log3 $name, 3, "OpenRouter ($name): NOTIFY-Device $deviceName angelegt (einmalig)";
        } else {
            Log3 $name, 3, "OpenRouter ($name): NOTIFY-Device $deviceName angelegt (permanent)";
        }

        my $autoForReading = "NOTIFY: $deviceName";
        utf8::encode($autoForReading) if utf8::is_utf8($autoForReading);
        readingsSingleUpdate($hash, 'lastAutomation', $autoForReading, 1);

        return "OK: NOTIFY-Device '$deviceName' erfolgreich angelegt";

    } else {
        return "Fehler: Unbekannte Funktion '$fcName'";
    }
}

##############################################################################
# Hilfsfunktion: Mehrere functionResponse-Ergebnisse zurücksenden
##############################################################################
sub OpenRouter_SendFunctionResults {
    my ($hash, $results) = @_;
    my $name = $hash->{NAME};

    # OpenAI-Format: tool-Messages
    my @toolMessages;
    for my $res (@$results) {
        push @toolMessages, {
            role         => 'tool',
            tool_call_id => $res->{tool_call_id},
            name         => $res->{name},
            content      => $res->{result}
        };
    }

    push @{$hash->{CHAT}}, @toolMessages;

    my $apiKey = AttrVal($name, 'apiKey', '');
    my $model  = AttrVal($name, 'model',  'google/gemini-2.0-flash-exp');
    my $timeout = AttrVal($name, 'timeout', 30);

    my $disableHistory = AttrVal($name, 'disableHistory', 0);
    my $messagesToSend;
    if ($disableHistory) {
        my $startIdx = $hash->{CONTROL_START_IDX} // 0;
        $messagesToSend = [ @{$hash->{CHAT}}[$startIdx..$#{$hash->{CHAT}}] ];
    } else {
        $messagesToSend = $hash->{CHAT};
    }

    my %requestBody = (
        model    => $model,
        messages => $messagesToSend,
        tools    => OpenRouter_GetControlTools()
    );

    # System message
    my $systemPrompt         = AttrVal($name, 'systemPrompt', '');
    my $staticControlContext = OpenRouter_BuildStaticControlContext($hash);
    my $staticDeviceContext  = '';
    
    my $includeDeviceStatus = $hash->{CHAT_INCLUDE_DEVICE_STATUS} // 0;
    if ($includeDeviceStatus) {
        $staticDeviceContext = OpenRouter_BuildStaticDeviceContext($hash);
    }

    my $fullSystem = '';
    $fullSystem .= $systemPrompt if $systemPrompt;
    $fullSystem .= "\n\n" if $systemPrompt && $staticDeviceContext;
    $fullSystem .= $staticDeviceContext if $staticDeviceContext;
    $fullSystem .= "\n\n" if $fullSystem && $staticControlContext;
    $fullSystem .= $staticControlContext if $staticControlContext;

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
        OpenRouter_RollbackControlSession($hash);
        return;
    }

    my $names = join(', ', map { $_->{name} } @$results);
    Log3 $name, 4, "OpenRouter ($name): FunctionResults für '$names' gesendet";

    my $url = "https://openrouter.ai/api/v1/chat/completions";

    HttpUtils_NonblockingGet({
        url      => $url,
        timeout  => $timeout,
        method   => 'POST',
        header   => "Content-Type: application/json\r\n" .
                    "Authorization: Bearer ${apiKey}\r\n" .
                    "HTTP-Referer: https://fhem.de\r\n" .
                    "X-Title: FHEM-OpenRouter",
        data     => $jsonBody,
        hash     => $hash,
        callback => \&OpenRouter_HandleControlResponse,
    });

    return undef;
}

1;

=pod
=item device
=item summary OpenRouter AI integration for FHEM with Automation
=item summary_DE OpenRouter AI Anbindung fuer FHEM mit Automatisierung
=begin html

<a name="OpenRouter"></a>
<h3>OpenRouter</h3>
<ul>
  FHEM Modul zur Anbindung der OpenRouter AI API (Multi-Provider LLM Gateway).<br>
  OpenRouter bietet Zugriff auf verschiedene LLMs (Claude, GPT-4, Gemini, etc.) über eine einheitliche API.<br><br>

  <b>Define</b><br>
  <ul><code>define &lt;name&gt; OpenRouter</code></ul><br>

  <b>Attribute</b><br>
  <ul>
    <li><b>apiKey</b> - OpenRouter API Key (Pflicht) - erhältlich unter https://openrouter.ai/keys</li>
    <li><b>model</b> - LLM Modell (Standard: google/gemini-2.0-flash-exp)<br>
      Empfohlene kosteneffiziente Modelle:<br>
      - google/gemini-2.0-flash-exp (kostenlos + Function Calling)<br>
      - anthropic/claude-3.5-haiku ($0.80/$4.00 per 1M tokens + Function Calling)<br>
      - openai/gpt-4o-mini ($0.15/$0.60 per 1M tokens + Function Calling)<br>
      - meta-llama/llama-3.3-70b-instruct (kostenlos, OHNE Function Calling)</li>
    <li><b>maxHistory</b> - Max. Chat-Nachrichten (Standard: 20)</li>
    <li><b>maxReadingsPerDevice</b> - Max. Anzahl Readings pro Gerät (Standard: 20)</li>
    <li><b>systemPrompt</b> - Optionaler System-Prompt</li>
    <li><b>timeout</b> - HTTP Timeout in Sekunden (Standard: 30)</li>
    <li><b>disable</b> - Modul deaktivieren</li>
    <li><b>disableHistory</b> - Chat-Verlauf deaktivieren (0/1)</li>
    <li><b>deviceList</b> - Komma-getrennte Geraete liste</li>
    <li><b>deviceRoom</b> - Komma-getrennte Raumliste</li>
    <li><b>controlList</b> - Komma-getrennte Liste steuerbarer Geraete</li>
    <li><b>controlRoom</b> - Komma-getrennte Raumliste steuerbarer Geraete</li>
    <li><b>automationRoom</b> - Raum für AT/NOTIFY-Geräte</li>
    <li><b>readingBlacklist</b> - Leerzeichen-getrennte Blacklist</li>
  </ul><br>

  <b>Set</b><br>
  <ul>
    <li><b>ask</b> &lt;Frage&gt; - Textfrage stellen</li>
    <li><b>askWithImage</b> &lt;Bildpfad&gt; &lt;Frage&gt; - Bild + Frage (nur Vision-Modelle)</li>
    <li><b>askAboutDevices</b> [&lt;Frage&gt;] - Geraete-Status abfragen</li>
    <li><b>chat</b> &lt;Nachricht&gt; - Universeller Befehl (Fragen, Status, Steuerung, Automatisierung)</li>
    <li><b>control</b> &lt;Anweisung&gt; - Geräte steuern (Function Calling erforderlich)</li>
    <li><b>resetChat</b> - Chat zurücksetzen</li>
  </ul><br>

  <b>Readings</b><br>
  <ul>
    <li><b>response</b> - Letzte Antwort (Roh-Markdown)</li>
    <li><b>responsePlain</b> - Letzte Antwort (Text)</li>
    <li><b>responseHTML</b> - Letzte Antwort (HTML)</li>
    <li><b>state</b> - Aktueller Status</li>
    <li><b>lastError</b> - Letzter Fehler</li>
    <li><b>chatHistory</b> - Anzahl Nachrichten</li>
    <li><b>lastCommand</b> - Letzter Befehl</li>
    <li><b>lastCommandResult</b> - Ergebnis</li>
    <li><b>lastAutomation</b> - Letztes AT/NOTIFY</li>
    <li><b>promptTokenCount</b> - Input Tokens</li>
    <li><b>candidatesTokenCount</b> - Output Tokens</li>
    <li><b>totalTokenCount</b> - Total Tokens</li>
  </ul><br>

  <b>Beispiele</b><br>
  <ul>
    <li><code>set OpenRouterAI chat Mach das Licht an</code></li>
    <li><code>set OpenRouterAI chat Fahre alle Rolläden hoch</code></li>
    <li><code>set OpenRouterAI chat Schalte morgen um 7 Uhr das Licht ein</code></li>
  </ul>
</ul>

=end html
=cut
