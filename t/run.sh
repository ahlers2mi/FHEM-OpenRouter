#!/bin/sh
#
# Alle Tests: sh t/run.sh  (braucht nur perl; JSON/HttpUtils kommen als
# Attrappe aus t/stub, falls nicht installiert). 0 = alles grün.

dir=$(dirname "$0")
rc=0
if perl -I"$dir/stub" -c "$dir/../FHEM/98_OpenRouter.pm" 2>&1 | grep -q "syntax OK"; then
    echo "ok    98_OpenRouter.pm syntax OK"
else
    echo "FAIL  98_OpenRouter.pm syntax"; perl -I"$dir/stub" -c "$dir/../FHEM/98_OpenRouter.pm"; rc=$((rc + 1))
fi
for t in "$dir"/*.t; do
    echo; echo "--- $t"
    perl "$t" || rc=$((rc + 1))
done
echo
[ "$rc" -eq 0 ] && echo "ALLES GRUEN" || echo "$rc Datei(en) mit Fehlern"
exit "$rc"
