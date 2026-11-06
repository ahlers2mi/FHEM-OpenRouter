# Test-Attrappe: JSON.pm (in FHEM vorhanden) über das Perl-Kernmodul JSON::PP.
# Achtung: JSON::PP::encode_json hat den Prototyp ($) - mit @_ käme die Anzahl (1) an.
package JSON;
use strict;
use warnings;
use JSON::PP ();
sub encode_json { return JSON::PP::encode_json($_[0]); }
sub decode_json { return JSON::PP::decode_json($_[0]); }
sub new         { shift; return JSON::PP->new(@_); }
1;
