# Notifications 2.0 — Konzept

**Ziel:** Ein Blick genügt, um drei Fragen zu beantworten:

1. **Wer arbeitet — und woran?**
2. **Wer braucht meine Eingabe — und welche?**
3. **Wer ist frei?**

Heute beantwortet die App zuverlässig *„in welchem Zustand ist jede Session"*
(Farben, Panel, Badges). Was fehlt, ist das **„woran"** und das **sofortige
Sehen ohne Suchen** — auch wenn das Fenster gerade nicht vorn ist.

## Ist-Zustand (v0.2.6+)

| Baustein | Status |
|---|---|
| Zustandsmodell ready/running/waiting/error, hook-getrieben | ✅ |
| Notifications-Panel spiegelt Projekte & Tabs, Klick springt | ✅ |
| Badges (Sidebar + Panel) aus einer Farbquelle (`AttentionState.tint`) | ✅ |
| Wartezeit („seit 12 min"), „Nur aktive"-Filter | ✅ |
| Desktop-Notifications (nur Favoriten), peon-ping-Sounds, Klick fokussiert | ✅ |
| ⌘⇧K „nächste wartende Session", Quick Switcher, Tags | ✅ |
| **Woran arbeitet eine running-Session?** | ❌ nur mit KI-Assist (verzögert) |
| **Was genau fragt eine waiting-Session?** | ⚠️ `lastMessage`, 2 Zeilen gekürzt |
| **Sichtbarkeit ohne App-Fenster (Menüleiste/Dock)** | ❌ (war im V1-Konzept geplant) |
| **frei vs. fertig** (Terminal leer vs. Ergebnis liegt bereit) | ❌ beides „ready" |

## Leitidee

> **Jede Zeile im Panel ist ein Satz:** `<wer> <macht was> <seit wann>` —
> und die dringendste Information ist nie weiter als einen Blick entfernt:
> Menüleiste → Panel-Triage → Zeile → Hover fürs Detail → Klick zum Handeln.

Alles bleibt **deterministisch und lokal** (Hooks + OSC, kein Output-Parsing,
kein zusätzlicher LLM-Call). KI-Assist verfeinert optional, ist aber nie
Voraussetzung.

## Bausteine

### 1. „Woran?" — Task-Zeile aus dem Prompt (der größte Hebel)

Der `UserPromptSubmit`-Hook liefert **den Prompt-Text selbst** — wir werfen
ihn heute weg. Stattdessen: als `currentTask` an der Session speichern
(erste Zeile, ~100 Zeichen, persistiert).

- **running:** `⚙ „fix restore for multiple tabs" — seit 3 min`
- **waiting:** Frage *plus* Task: man weiß sofort, *worum es bei der Frage geht*
- **done:** „fertig: ‚fix restore …'" — was liegt zur Abnahme bereit?

Kein LLM, keine Latenz, exakt das, was ich dem Agenten aufgetragen habe.
KI-Assist (Stufe 2) darf die Zeile später durch seine Zusammenfassung
ersetzen — `currentTask` ist der sofortige, immer verfügbare Fallback.

### 2. Triage-Kopf im Notifications-Panel

Der Projekt-Spiegel (seit v0.2.6) beantwortet „wo ist was" — aber „was
braucht mich JETZT" soll man nicht zusammensuchen. Oben ins Panel kommt ein
kompakter **Triage-Block**, nur sichtbar wenn nicht leer:

```
┌─ Notifications ────────────── □ Nur aktive ─┐
│ ▌BRAUCHT DICH (2)                           │
│ ▌🔴 NIE-4802 · Tests failed: 3 of 57 · 1h10 │
│ ▌🔵 NIE-4711 · Permission: npm run build? 12m│
│─────────────────────────────────────────────│
│ ● product-text-generator ★              [1] │
│   🔵 NIE-4711  „update prompts for …"       │
│      Permission to run `npm run build`?     │
│   🟣 refactor  „migrate to batch api"   3m  │
│   🟢 free                                   │
│ ● datadog-error-hunter                  [1] │
│   …                                         │
└─────────────────────────────────────────────┘
```

Sortierung im Triage-Block: error vor waiting, Favoriten zuerst, längste
Wartezeit oben (= bestehende `attentionQueue`). Klick springt, wie überall.
Der Spiegel darunter bleibt unverändert in Tab-Reihenfolge.

### 3. Menüleisten-Status (sehen, ohne die App zu sehen)

`NSStatusItem`, immer da (war als „Menüleisten-Badge" schon im V1-Konzept):

- **Icon + Zählern**, eingefärbt aus `AttentionState.tint`:
  ruhig `🞅` · aktiv `🟣3` · will was `🔵2` · Fehler `🔴1`
- **Dropdown = Mini-Triage:** die „Braucht dich"-Liste; Klick aktiviert die
  App und springt zur Session (nutzt `focusSession`, existiert bereits).
- Dock-Badge zeigt dieselbe Zahl (`NSApp.dockTile.badgeLabel`).

### 4. Hover = ganze Frage

`lastMessage` ist auf 2 Zeilen gekürzt. Beim Hover über eine Panel-Zeile:
Popover mit **voller Frage/Fehlermeldung** + `currentTask` + Pfad — die
Entscheidung „kurz antworten oder erst Kontext ansehen?" fällt ohne Klick.

### 5. „frei" vs. „fertig" (ready wird präziser)

„Grün" heißt heute zweierlei. Die Antwort auf Frage 3 („wer ist frei?")
braucht die Unterscheidung:

| Zustand | Bedeutung | Signal | Darstellung |
|---|---|---|---|
| **done** | Turn beendet, Ergebnis wartet auf Abnahme | `Stop`-Hook | 🟢 gefüllt, „fertig: <task>" |
| **free** | Prompt leer, nichts zu reviewen | `SessionEnd`, `SessionStart` einer frischen Unterhaltung (`startup`/`clear`/`resume`) / OSC 133 ohne aktiven Claude | ⚪ hohl/grau, „frei" |

`/clear` sendet `SessionEnd(clear)` **und** `SessionStart(clear)` — beide führen
auf „frei", damit ein verlorenes Event den Zustand nicht hängen lässt. Nur
`SessionStart(compact)` und `SessionStart(fork)` ändern nichts: sie passieren
mitten im Turn, `running`/`waiting` muss sie überleben.

`done → free` beim nächsten `UserPromptSubmit` oder manuell („als frei
markieren", existiert). Kein neuer Persistenz-Bruch: `AttentionState` bekommt
einen Fall dazu, Decoder-Fallback wie beim v0.1-Migrationspfad.

### 6. Sanfte Eskalation statt Dauerfeuer

Warten soll auffallen, ohne zu nerven:

- waiting/error **> 10 min** (konfigurierbar): Panel-Badge pulsiert einmal,
  Menüleisten-Zähler wird fett; Favoriten bekommen genau **eine**
  Erinnerungs-Notification („wartet seit 15 min").
- Nicht-Favoriten eskalieren nie laut — sie sammeln sich sichtbar im
  Triage-Block und Menüleisten-Zähler.

## Nicht-Ziele

- **Kein Output-Parsing** des Terminals (bleibt Grundsatz).
- **Keine zusätzlichen LLM-Calls** für die Kernfunktion; KI-Assist bleibt
  optionale Verfeinerung.
- **Nie automatisch antworten** (kein Auto-Approve von Permissions).

## Phasen

| Phase | Inhalt | Aufwand |
|---|---|---|
| **1 — Sofort sehen** | `currentTask` aus `UserPromptSubmit` + Anzeige in Panel/Tab-Tooltip; Triage-Block im Panel; Hover-Popover | ~1 Tag |
| **2 — Ohne Fenster sehen** | Menüleisten-Status + Dropdown-Triage; Dock-Badge | ~1 Tag |
| **3 — Präziser & ruhiger** | done/free-Split; Eskalation; Panel-Feinschliff (z. B. „frei"-Sektion einklappbar) | ~1–2 Tage |

Jede Phase ist einzeln shipbar; Phase 1 löst den größten Schmerz
(„woran arbeitet der gerade?") ohne UI-Umbau.

## Offene Fragen

1. Triage-Block: fest oben (Vorschlag) oder umschaltbar „Struktur ↔ Triage"?
2. done/free: reichen zwei Grüntöne/gefüllt-hohl — oder eigene Farbe für done?
3. Eskalationsschwelle: global 10 min oder pro Projekt (Favorit = kürzer)?
4. Menüleiste: nur Zähler oder auch Mini-Titel der dringendsten Session
   („NIE-4802 ⏳15m")?
