# FHEM-OpenRouter

FHEM-Modul zur Anbindung der OpenRouter AI API – einem Multi-Provider-Gateway für verschiedene LLMs (Claude, GPT-4, Gemini, Llama, etc.). Ermöglicht Textanfragen, Bildanalyse, Smart-Home-Gerätesteuerung per Sprachbefehl (Function Calling), Automatisierung via AT/NOTIFY-Devices und mehr – direkt aus FHEM heraus. **Optimiert für kosteneffiziente Modelle.**

## Inhaltsverzeichnis

- [Features](#features)
- [Warum OpenRouter?](#warum-openrouter)
- [Voraussetzungen](#voraussetzungen)
- [Installation](#installation)
- [Einrichtung](#einrichtung)
- [Modell-Auswahl](#modell-auswahl)
- [Verwendung](#verwendung)
- [Attribute](#attribute)
- [Readings](#readings)
- [Praxisbeispiele](#praxisbeispiele)
- [Kostenoptimierung](#kostenoptimierung)
- [Fehlerbehebung](#fehlerbehebung)
- [Versionshistorie](#versionshistorie)
- [Lizenz](#lizenz)

---

## Features

- 💬 **Textfragen** – beliebige Fragen an verschiedene LLMs stellen
- 🖼️ **Bildanalyse** – Kamerabilder oder Snapshots direkt analysieren lassen (bei Vision-Modellen)
- 🏠 **Gerätesteuerung** – Smart-Home-Geräte per natürlicher Sprache steuern (Function Calling erforderlich)
- 🎯 **Mehrfach-Steuerung** – mehrere Geräte gleichzeitig steuern ("Fahre alle Rolläden hoch")
- ⏰ **Automatisierung** – AT-Devices für zeitgesteuerte Aktionen und NOTIFY-Devices für eventbasierte Reaktionen
- 📋 **Geräte-Status** – Zusammenfassung aller oder ausgewählter Geräte inkl. Raumfilter
- 🔄 **Multi-Turn Chat** – Kontext über mehrere Anfragen hinweg erhalten
- 📝 **Mehrere Ausgabeformate** – Antwort als Roh-Markdown, reiner Text und HTML verfügbar
- 🛡️ **Sicherheit** – nur explizit freigegebene Geräte dürfen gesteuert werden
- 🌍 **Multi-Provider** – Zugriff auf Claude, GPT-4, Gemini, Llama und viele mehr über eine API
- 💰 **Kostenoptimiert** – ultra-kompaktes Format für minimalen Token-Verbrauch

---

## Warum OpenRouter?

**OpenRouter** ist ein API-Gateway, das Zugriff auf über 200 verschiedene LLMs bietet:

✅ **Eine API für alle Modelle** – Claude, GPT-4, Gemini, Llama, etc.  
✅ **Transparente Preise** – Kostenvergleich in Echtzeit  
✅ **Kostenlose Modelle** – mehrere leistungsstarke Modelle komplett gratis  
✅ **Pay-as-you-go** – nur bezahlen, was du nutzt (keine Abos)  
✅ **Fallback-Mechanismus** – automatischer Wechsel wenn ein Modell down ist  

**Vergleich zu direkten APIs:**

| Feature | OpenRouter | Direkt (Google/OpenAI/Anthropic) |
|---|---|---|
| Modellwahl | 200+ Modelle | Nur eigene Modelle |
| API-Keys | 1 Key für alle | Mehrere Keys nötig |
| Kostenlose Modelle | Viele verfügbar | Begrenzt/Zeitlich limitiert |
| Prompt Caching | Provider-abhängig | Teilweise verfügbar |
| Fallback | Automatisch | Nicht verfügbar |

---

## Voraussetzungen

- **FHEM** ab Version 5.x (Perl-basiert)
- **OpenRouter API Key** – kostenlos erhältlich unter [openrouter.ai/keys](https://openrouter.ai/keys)
- Perl-Modul `JSON` (i. d. R. bereits vorhanden; ggf. `cpan JSON`)

---

## Installation

### Datei kopieren

Kopiere `98_OpenRouter.pm` nach `/opt/fhem/FHEM/`

### In FHEM aktivieren

```
reload 98_OpenRouter
```

---

## Einrichtung

### 1. Gerät definieren

```
define OpenRouterAI OpenRouter
```

### 2. API Key setzen

Kostenlos registrieren unter [openrouter.ai/keys](https://openrouter.ai/keys):

```
attr OpenRouterAI apiKey sk-or-v1-DEIN-API-KEY
```

### 3. Modell wählen (optional)

```
attr OpenRouterAI model google/gemini-2.0-flash-exp
```

Standard ist bereits `google/gemini-2.0-flash-exp` (kostenlos + Function Calling).

### 4. System-Prompt setzen (optional)

```
attr OpenRouterAI systemPrompt Du bist ein KI-Assistent für meine FHEM Haussteuerung. Antworte kurz und präzise.
```

---

## Modell-Auswahl

### Empfohlene Modelle für Haussteuerung (mit Function Calling)

| Modell | Input | Output | Function Calling | Besonderheit |
|---|---|---|---|---|
| **`google/gemini-2.0-flash-exp`** | **FREE** | **FREE** | ✅ | ⭐ **Beste Wahl!** Schnell, kostenlos, zuverlässig |
| `anthropic/claude-3.5-haiku` | $0.80/1M | $4.00/1M | ✅ | Sehr präzise, gute Sprachverständnis |
| `openai/gpt-4o-mini` | $0.15/1M | $0.60/1M | ✅ | Günstig, schnell, gut für einfache Tasks |
| `anthropic/claude-3.5-sonnet` | $3.00/1M | $15.00/1M | ✅ | Beste Qualität, teurer |

### Kostenlose Modelle OHNE Function Calling (nur Textfragen)

| Modell | Function Calling | Einsatz |
|---|---|---|
| `meta-llama/llama-3.3-70b-instruct` | ❌ | Allgemeine Fragen, keine Steuerung |
| `google/gemma-3-27b-it:free` | ❌ | Einfache Textfragen |
| `openai/gpt-oss-20b:free` | ❓ Unklar | Testen empfohlen |

### Modelle mit Vision (Bildanalyse)

| Modell | Input | Output | Vision | Function Calling |
|---|---|---|---|---|
| `google/gemini-2.0-flash-exp` | FREE | FREE | ✅ | ✅ |
| `anthropic/claude-3.5-sonnet` | $3.00/1M | $15.00/1M | ✅ | ✅ |
| `openai/gpt-4o-mini` | $0.15/1M | $0.60/1M | ✅ | ✅ |

**Tipp:** Aktuelle Preise und Modelle findest du unter [openrouter.ai/models](https://openrouter.ai/models)

---

## Verwendung

### Textfrage stellen

```
set OpenRouterAI ask Was ist das Wetter morgen in Berlin?
set OpenRouterAI ask Erkläre mir den Unterschied zwischen Wärmepumpe und Brennwertkessel.
```

### Bild analysieren (nur Vision-Modelle)

```
set OpenRouterAI askWithImage /opt/fhem/www/snapshot.jpg Was ist auf diesem Bild zu sehen?
set OpenRouterAI askWithImage /opt/fhem/www/door.jpg Ist jemand an der Tür?
```

Unterstützte Bildformate: `jpg`/`jpeg`, `png`, `gif`, `webp`, `bmp`, `heic`, `heif`.

### Geräte-Status abfragen

Einzelne Geräte über `deviceList` angeben:

```
attr OpenRouterAI deviceList Lampe1,Heizung,Rolladen1
set OpenRouterAI askAboutDevices Welche Geräte sind gerade eingeschaltet?
```

Alle Geräte eines oder mehrerer Räume automatisch einbeziehen:

```
attr OpenRouterAI deviceRoom Wohnzimmer,Küche
set OpenRouterAI askAboutDevices Gib mir eine Zusammenfassung aller Geräte.
```

### Geräte per Sprachbefehl steuern (Function Calling erforderlich!)

```
attr OpenRouterAI controlList Lampe1,Heizung,Rolladen1
set OpenRouterAI control Mach die Wohnzimmerlampe an
set OpenRouterAI control Stelle die Heizung auf 21 Grad
set OpenRouterAI control Fahre alle Rolläden runter
```

**Mehrere Geräte gleichzeitig:**

```
set OpenRouterAI control Fahre alle Rolläden auf 100%
set OpenRouterAI control Schalte alle Lampen im Wohnzimmer aus
```

**⚠️ Wichtig:** Function Calling funktioniert nur mit kompatiblen Modellen (siehe [Modell-Auswahl](#modell-auswahl)).

### Automatisierung per Sprachbefehl

**AT-Devices (zeitgesteuert):**

```
set OpenRouterAI chat Schalte das Licht um 18:00 ein
set OpenRouterAI chat In 30 Minuten soll die Heizung ausgehen
set OpenRouterAI chat Jeden Tag um 22:00 alle Lampen ausschalten
```

**NOTIFY-Devices (eventbasiert):**

```
set OpenRouterAI chat Wenn die Haustür aufgeht, schalte das Licht ein
set OpenRouterAI chat Benachrichtige mich wenn die Temperatur über 25 Grad steigt
```

### Universeller Chat-Befehl (für Telegram-Integration)

```
set OpenRouterAI chat Ist die Wohnzimmerlampe an?
set OpenRouterAI chat Mach bitte das Licht im Flur aus
set OpenRouterAI chat Fahre alle Rolläden hoch
set OpenRouterAI chat Was ist der Unterschied zwischen Wärmepumpe und Brennwertkessel?
set OpenRouterAI chat Schalte morgen um 7 Uhr das Licht ein
```

### Chat-Verlauf verwalten

```
set OpenRouterAI resetChat
get OpenRouterAI chatHistory
```

---

## Attribute

| Attribut | Beschreibung | Standard |
|---|---|---|
| `apiKey` | OpenRouter API Key **(Pflicht)** | – |
| `model` | LLM Modell | `google/gemini-2.0-flash-exp` |
| `maxHistory` | Maximale Anzahl gespeicherter Chat-Nachrichten | `20` |
| `maxReadingsPerDevice` | Maximale Anzahl Readings pro Gerät im Status. Bei Überschreitung wird im Log protokolliert. | `20` |
| `systemPrompt` | Optionaler System-Prompt (Rolle/Verhalten) | – |
| `timeout` | HTTP-Timeout in Sekunden | `30` |
| `disable` | Modul deaktivieren (`0`/`1`) | `0` |
| `disableHistory` | Chat-Verlauf deaktivieren (`0`/`1`) | `0` |
| `deviceList` | Komma-getrennte Geräteliste für `askAboutDevices`; `*` = alle Geräte | – |
| `deviceRoom` | Komma-getrennte Raumliste; Geräte werden automatisch einbezogen | – |
| `controlList` | Komma-getrennte Liste der Geräte, die gesteuert werden dürfen **(Pflicht für `control`/`chat` mit Steuerung)** | – |
| `controlRoom` | Komma-getrennte Raumliste; Geräte werden automatisch als steuerbar eingestuft | – |
| `automationRoom` | Raum für automatisch angelegte AT/NOTIFY-Geräte | Erster Raum des OpenRouter-Devices |
| `readingBlacklist` | Leerzeichen-getrennte Liste von Reading-Namen, die **nicht** übermittelt werden. Wildcards (`*`) werden unterstützt. | `attrTemplate associate R-* RegL_* associatedWith peerListRDate protLastRcv lastTimeSync lastcmd Heap LoadAvg Uptime Wifi_*` |

---

## Readings

| Reading | Beschreibung |
|---|---|
| `response` | Letzte Textantwort vom LLM (Roh-Markdown) |
| `responsePlain` | Letzte Textantwort, Markdown bereinigt (ideal für Sprachausgabe, Telegram) |
| `responseHTML` | Letzte Textantwort, Markdown in HTML konvertiert (ideal für Tablet-UI) |
| `state` | Aktueller Status (`initialized`, `requesting...`, `ok`, `error`, `disabled`) |
| `lastError` | Letzter Fehler |
| `chatHistory` | Anzahl der Nachrichten im Chat-Verlauf |
| `lastCommand` | Letzter ausgeführter `set`-Befehl (z. B. `Lampe1 on`) |
| `lastCommandResult` | Ergebnis des letzten `set`-Befehls (`ok` oder Fehlermeldung) |
| `lastAutomation` | Letztes angelegtes AT/NOTIFY-Gerät |
| `promptTokenCount` | Anzahl der gesendeten Tokens (Input) |
| `candidatesTokenCount` | Anzahl der generierten Tokens (Output) |
| `totalTokenCount` | Gesamtsumme der verbrauchten Tokens (Input + Output) |

---

## Praxisbeispiele

### Sprachausgabe mit Text2Speech

```perl
define OpenRouterNotify notify OpenRouterAI:responsePlain {
    my $text = ReadingsVal("OpenRouterAI", "responsePlain", "");
    fhem("set Lautsprecher speak $text") if $text;
}
```

### Antwort per Telegram verschicken

```perl
define TelegramBot TELEGRAM <bot-token>

define OpenRouterTelegramIn notify TelegramBot:msgText.* {
    my $msg = ReadingsVal("TelegramBot", "msgText", "");
    fhem("set OpenRouterAI chat $msg") if $msg;
}

define OpenRouterTelegramOut notify OpenRouterAI:responsePlain {
    my $text = ReadingsVal("OpenRouterAI", "responsePlain", "");
    fhem("set TelegramBot message $text") if $text;
}
```

### Türkamera-Analyse bei Bewegung

```perl
define KameraAnalyse notify BewegungsMelder:on {
    fhem("set OpenRouterAI askWithImage /opt/fhem/www/cam.jpg Ist jemand an der Tür?")
}
```

### Tägliche Hausübersicht

```perl
define HausReport at *08:00:00 {
    fhem("set OpenRouterAI askAboutDevices Gib mir eine kurze Zusammenfassung des Hauses.")
}
```

### Modell wechseln je nach Task

```perl
# Für komplexe Steuerungsaufgaben: Claude (besseres Verständnis)
attr OpenRouterAI model anthropic/claude-3.5-haiku

# Für einfache Fragen: kostenloses Gemini
attr OpenRouterAI model google/gemini-2.0-flash-exp

# Für Bildanalyse: Vision-Modell
attr OpenRouterAI model google/gemini-2.0-flash-exp
```

---

## Kostenoptimierung

### 1. Kostenlose Modelle nutzen

Für Haussteuerung ist **`google/gemini-2.0-flash-exp`** optimal:
- Komplett kostenlos
- Function Calling enthalten
- Vision (Bildanalyse) enthalten
- Schnell und zuverlässig

```
attr OpenRouterAI model google/gemini-2.0-flash-exp
```

### 2. Token-Verbrauch minimieren

**Readings-Limit reduzieren:**
```
attr OpenRouterAI maxReadingsPerDevice 10
```

**Blacklist erweitern:**
```
attr OpenRouterAI readingBlacklist attrTemplate associate R-* Wifi_* state-*
```

**History kürzer halten:**
```
attr OpenRouterAI maxHistory 10
```

### 3. Token-Verbrauch überwachen

OpenRouter Dashboard zeigt alle Anfragen: [openrouter.ai/activity](https://openrouter.ai/activity)

In FHEM:
```
{ReadingsVal("OpenRouterAI","totalTokenCount","")}
```

### 4. Modell-Fallback konfigurieren (OpenRouter Feature)

OpenRouter wechselt automatisch zu günstigen Alternativen, wenn ein Modell down ist.

### 5. Kosten-Beispiel (100 Requests/Monat, 150 Geräte)

| Modell | Input Tokens | Output Tokens | Kosten/Monat |
|---|---|---|---|
| `google/gemini-2.0-flash-exp` | 300k | 5k | **$0.00** ✅ |
| `anthropic/claude-3.5-haiku` | 300k | 5k | **$0.26** |
| `openai/gpt-4o-mini` | 300k | 5k | **$0.05** |

**Mit ultra-kompaktem Format sparst du ~70% Tokens** im Vergleich zu Standard-Übertragung!

---

## Fehlerbehebung

| Symptom | Mögliche Ursache | Lösung |
|---|---|---|
| `state: error`, `lastError` enthält HTTP-Fehler 400 | Ungültiger Chat-Verlauf | `set OpenRouterAI resetChat` ausführen |
| `state: error`, `lastError` enthält HTTP-Fehler 401 | API Key ungültig | `apiKey`-Attribut prüfen, neuen Key unter openrouter.ai/keys erstellen |
| `state: error`, `lastError` enthält HTTP-Fehler 429 | Rate Limit erreicht | Warten oder auf kostenpflichtiges Modell wechseln |
| Keine Gerätesteuerung | Modell unterstützt kein Function Calling | Auf `google/gemini-2.0-flash-exp` oder `anthropic/claude-3.5-haiku` wechseln |
| `state: disabled` | Modul deaktiviert | `attr OpenRouterAI disable 0` |
| Timeout-Fehler | Modell antwortet zu langsam | `attr OpenRouterAI timeout 60` erhöhen |
| Hoher Token-Verbrauch | Zu viele Readings pro Gerät | `maxReadingsPerDevice` reduzieren |
| AT/NOTIFY landen im falschen Raum | `automationRoom` nicht gesetzt | `attr OpenRouterAI automationRoom Automation` |
| Vision funktioniert nicht | Modell unterstützt keine Bilder | Auf Vision-Modell wechseln (siehe [Modell-Auswahl](#modell-auswahl)) |

### OpenRouter-spezifische Fehler

**"Model not found":**
- Modellname falsch geschrieben
- Modell existiert nicht mehr (prüfe [openrouter.ai/models](https://openrouter.ai/models))

**"Insufficient credits":**
- Guthaben aufgebraucht
- Credits unter [openrouter.ai/credits](https://openrouter.ai/credits) aufladen

**Detaillierte Logs:**
```
attr global verbose 3
```

Alle Anfragen im OpenRouter-Dashboard: [openrouter.ai/activity](https://openrouter.ai/activity)

---

## Versionshistorie

| Version | Datum | Änderung |
|---|---|---|
| 1.0.0 | 2026-04-27 | Initiale Version basierend auf FHEM-Gemini 4.0.3; OpenRouter API Integration (OpenAI-kompatibel); ultra-kompaktes Format für niedrigen Token-Verbrauch; Function Calling für unterstützte Modelle; AT/NOTIFY Support; Standard-Modell: `google/gemini-2.0-flash-exp` (kostenlos) |

---

## Hinweise zu Kosten und Haftung

Die Nutzung der Gemini-API erfolgt auf eigene Verantwortung. Sämtliche durch die API-Nutzung entstehenden Kosten hängen von deinem individuellen Setup, den verwendeten Modellen, dem übermittelten Kontext sowie deinem Nutzungsverhalten ab und können im Einzelfall deutlich von den im README genannten Groborientierungen abweichen.

Weder das Open-Source-Community-Projekt FHEM noch dessen Mitwirkende oder der Autor dieses Moduls übernehmen eine Gewähr oder Haftung für entstehende API-Kosten, unerwartet hohen Tokenverbrauch, Fehlkonfigurationen, ungünstige Prompts, zu großen oder unnötigen Kontext, Fehler im Modul, Veränderungen an der externen API oder sonstige Umstände, die zu höherem Verbrauch oder zusätzlichen Kosten führen.

Es liegt in der Verantwortung des Nutzers, die Konfiguration sorgfältig zu wählen, den Tokenverbrauch über die vorhandenen Readings zu beobachten und den eingesetzten Kontext auf das notwendige Maß zu begrenzen.

---

## Lizenz

Dieses Modul ist ein Community-Beitrag und steht unter der [GNU General Public License v2](https://www.gnu.org/licenses/gpl-2.0.html), entsprechend der FHEM-Lizenz.

---

## Links

- **OpenRouter Website:** [openrouter.ai](https://openrouter.ai)
- **API Keys:** [openrouter.ai/keys](https://openrouter.ai/keys)
- **Modell-Übersicht:** [openrouter.ai/models](https://openrouter.ai/models)
- **Dashboard:** [openrouter.ai/activity](https://openrouter.ai/activity)
- **Dokumentation:** [openrouter.ai/docs](https://openrouter.ai/docs)
- **Preise:** [openrouter.ai/models](https://openrouter.ai/models) (Live-Preise bei jedem Modell)

---

## Support

Bei Fragen oder Problemen:
1. Prüfe die [Fehlerbehebung](#fehlerbehebung)
2. Schaue im OpenRouter-Dashboard nach Fehlern: [openrouter.ai/activity](https://openrouter.ai/activity)
3. Erstelle ein Issue im GitHub-Repository

**Tipp:** Das OpenRouter-Dashboard zeigt alle API-Anfragen mit Details (Tokens, Kosten, Fehler, Latenz).
