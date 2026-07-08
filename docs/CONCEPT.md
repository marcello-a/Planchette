# Planchette — Konzept & Implementierungsplan

## Kontext

**Problem:** Viele iTerm-Fenster über verschiedene Projektordner, in den meisten läuft ein Claude-Code-Agent. Es gibt keinen Ort, der zeigt: Wer stellt gerade eine Frage? Wer ist fertig? Welches Terminal ist frei? Sessions warten unbemerkt („Leerlauf"), Kontextwechsel sind teuer, und nach einem Reboot ist die ganze Anordnung weg.

**Lösung:** Planchette — eine native Terminal-IDE (macOS + Linux, kein Electron) auf Basis der Ghostty-Engine (libghostty, MIT), die Terminal-Anordnungen als persistente Workspaces verwaltet und den Aufmerksamkeits-Status jeder Session sichtbar macht.

**Entschieden:**
- Name: **Planchette**
- Plattformen: **macOS + Linux ab Tag 1** → gemeinsamer Core, zwei native UI-Frontends (wie Ghostty selbst)
- Persistenz: **Restore-basiert** (kein Daemon in V1)
- Repo: `~/development/planchette`

## Der Name

Die **Planchette** ist der Zeiger auf dem Ouija-Brett: Bei einer Séance mit mehreren Geistern bewegt sie sich zu dem Geist, der gerade etwas zu sagen hat. Genau das macht die App — viele Ghostty-Sessions („Geister"), und der Zeiger führt dich immer zu der, die sich meldet. README-Pitch:

> **Planchette** — *points you to the session that speaks.*
> A native terminal IDE for running many AI coding agents at once, built on the Ghostty engine. Planchette keeps your terminal layouts persistent across restarts and reboots, and always shows you which session needs your attention — who's asking, who's done, who's free.

Namensprüfung erledigt: GitHub praktisch frei (größtes Repo 7★, andere Domäne), Homebrew frei, npm nur totes Mini-Paket (irrelevant für native App, notfalls `@planchette/cli`).

## Kernkonzepte

| Begriff | Bedeutung |
|---|---|
| **Session** | Ein Terminal (eine libghostty-Surface + PTY), gehört zu einem Projekt |
| **Projekt** | Ein Ordner; hat Priorität **high** (Favorit/Hauptprojekt) oder **normal** (Side Project) |
| **Gruppe** | Tab-Gruppe mit Farbe + Titel; enthält Sessions, kann als Tabs oder Cluster (Splits) dargestellt werden |
| **Attention-State** | Zustand pro Session: `working` / `asking` / `done` / `free` |
| **Workspace** | Der Gesamtzustand (alle Gruppen, Layouts, Styles) — wird kontinuierlich persistiert |

### Zustandsmodell (Herzstück)

```
            Claude startet Turn                Claude fragt / braucht Permission
  free ──────────────────────▶ working ──────────────────────▶ asking
   ▲                              │  ▲                            │
   │      Shell idle am Prompt    │  │   User antwortet           │
   │      (OSC 133, kein FG-      │  └────────────────────────────┘
   │       Prozess, kein claude)  │
   │                              ▼  Stop-Hook (Turn beendet)
   └────────────────────────── done
```

**Signalquellen (kein Output-Parsing, keine LLM-Calls):**
1. **Claude Code Hooks** (`Notification` = fragt/wartet auf Permission, `Stop` = Turn fertig, `SessionStart` = Session-ID erfassen). Payload enthält `session_id`, `transcript_path`, `cwd`. Ein von Planchette installierter Hook schickt das Event an einen Unix-Socket.
2. **Session-Zuordnung:** Planchette setzt in jedem Terminal `PLANCHETTE_SESSION=<uuid>` als Env-Var — Hooks erben die Umgebung, das Event landet eindeutig beim richtigen Terminal.
3. **Shell Integration (OSC 133):** Prompt-Marks von Ghostty. „Am Prompt + kein Foreground-Prozess" = **free**. Deckt auch Nicht-Claude-Fälle ab (Build fertig, nach `push + pr`).
4. **Transcript-Reader:** liest `~/.claude/projects/**/<session>.jsonl` (tail) für „woran arbeitet der Agent" (Agent-Board, Hover-Preview) — alles liegt lokal, kein API-Call.

## Feature-Set

### V1
- **Multi-Terminal** auf libghostty (GPU-Rendering, native Performance)
- **Ansichten:** Tabs, Tab-Gruppen, Cluster-View (mehrere Terminals einer Gruppe als Splits in einem View)
- **Styling:** Farbe + Titel pro Session und Gruppe; **Auto-Titel** (Ticket-Nummer aus Git-Branch, z.B. `NIE-4213`, sonst Ordnername; manuell überschreibbar)
- **Pfadanzeige:** letzte 2 Ordner im Tab, voller Pfad + Details beim Hover
- **Attention-System:** Zustandsmodell oben, **Notification-Inbox** (klickbare Queue: `asking` vor `done`, Favoriten zuerst, älteste Wartezeit oben; Klick springt zur Session), **Idle-Timer** („fragt seit 12 min"), **Menüleisten-Badge** („2 Fragen, 1 fertig")
- **Favoriten:** Projekt als high/normal markieren → beeinflusst Sortierung, Notifications, Switcher
- **Quick Switcher:** `⌘K` Fuzzy-Suche (Titel/Ordner/Branch), `⌘⇧K` = „nächste Session, die wartet" — Reihenfolge: favorisiert+asking → favorisiert+done → normal+asking → normal+done → Recency
- **Frei-Meldung:** Terminal meldet sich als `free` (nach push+PR, nach jedem beendeten Prozess am Prompt)
- **Persistenz (Restore-basiert):** Layout, Gruppen, Farben, Titel, cwd, Scrollback, Claude-Session-ID werden kontinuierlich in SQLite gespeichert. Beim Start (App-Restart **und** Reboot): Terminals im richtigen Ordner, Scrollback wiederhergestellt, Claude via `claude --resume <id>` fortgesetzt, optionaler **Startup-Command** pro Session (z.B. `npm run dev`) läuft wieder an.

### V2
- **Agent-Board („Mission Control"):** Übersicht aller Sessions — Projekt, Branch/Ticket, Zustand, Ein-Zeiler „woran arbeitet der Agent gerade" (aus Transcript-JSONL)
- **Hover-Preview:** letzte ~5 Output-Zeilen bzw. Claudes konkrete Frage beim Hover über Tab/Inbox-Eintrag
- **Projekt-Templates:** „Projekt öffnen" spawnt vordefiniertes Layout (Claude + Dev-Server + Git-Terminal, Farbe, Titel)
- **Frei-Pool:** freies Terminal bietet an „nächsten Task hier starten?" (Ein-Klick `git checkout master && git pull`)
- **Fokus-Modus:** Side-Project-Notifications stumm/gesammelt, nur Favoriten unterbrechen
- **Git-Kontext im Tab:** Branch, dirty-Indikator, PR-/CI-Status (via `gh`)
- **Sound-Hooks:** Events optional an bestehende Hooks durchreichen (z.B. peon-ping) statt eigener Sounds
- **Cross-Session-Suche** im Scrollback aller Sessions

## Architektur

Monorepo, Struktur gespiegelt an Ghostty selbst (Zig-Core + Swift-macOS-App + GTK-Linux-App):

```
planchette/
├── vendor/ghostty/          # Submodule, auf Commit gepinnt → baut libghostty/GhosttyKit
├── core/                    # Zig: libplanchette (C-ABI für beide UIs)
│   ├── session/             #   Session-/Projekt-/Gruppen-Modell, Attention-State-Machine
│   ├── pty/                 #   PTY-Spawn/-Verwaltung, Env-Injection (PLANCHETTE_SESSION)
│   ├── store/               #   SQLite-Persistenz (State + Scrollback-Dumps)
│   ├── ipc/                 #   Unix-Socket-Server für Hook-Events (JSON)
│   ├── claude/              #   Hook-Event-Verarbeitung, Transcript-Reader (JSONL-tail)
│   └── title/               #   Auto-Titel-Heuristik (Branch-Ticket-Regex, Pfadkürzung)
├── hook/                    # planchette-hook: winziges statisches Binary (stdin-JSON → Socket)
│                            # + Installer, der ~/.claude/settings.json um die Hooks ergänzt
├── macos/                   # Swift/SwiftUI-App, embeddet GhosttyKit + libplanchette
├── linux/                   # Zig + GTK4-App (wie Ghosttys GTK-Frontend)
└── docs/CONCEPT.md          # dieses Konzept, versioniert im Repo
```

**Warum Zig für den Core:** identischer Toolchain wie Ghostty (muss zum Bauen von libghostty ohnehin da sein), verlustfreie Interop mit den libghostty-Headern, triviale C-ABI für Swift und GTK, Cross-Compilation eingebaut. SQLite, Unix-Sockets und JSON deckt die Zig-Std/C-Interop ab.

**Event-Fluss:**
`Claude Hook (Notification/Stop/SessionStart)` → `planchette-hook` (liest stdin-JSON + `$PLANCHETTE_SESSION`) → Unix-Socket → `core/ipc` → State-Machine → UI-Update (Inbox, Badge, Tab-Indikator).

**Realistischer Risiko-Status libghostty (Recherche 07/2026):** stabil getaggt ist bisher nur libghostty-vt (VT-Parser); die volle Embedding-API (Rendering, Surface-Widgets) ist funktional bewährt, aber API-instabil. Bewährter Weg: libghostty aus dem Ghostty-Source bauen und wie Ghosttys eigene Apps einbetten (machen mehrere Dritt-Projekte so). Konsequenz: **Submodule pinnen**, API-Drift bei Updates einplanen, Spikes zuerst.

## Datenmodell (SQLite)

```sql
projects(id, path, name, priority /* high|normal */, color)
groups(id, title, color, view_mode /* tabs|cluster */, sort_order)
sessions(id, project_id, group_id, custom_title, color, cwd,
         claude_session_id, startup_cmd, layout_slot,
         state /* working|asking|done|free */, state_since,
         scrollback_path, created_at, last_active_at)
events(id, session_id, kind, payload_json, created_at)   -- Audit/Debug + Inbox-Historie
```

Scrollback-Dumps als Dateien neben der DB (`~/.local/share/planchette/scrollback/<session>.bin`), periodisch + bei Detach geschrieben.

## Umsetzungsreihenfolge

### Phase 0 — Spikes (zuerst, je mit hartem Exit-Kriterium)
- **Spike A (macOS):** GhosttyKit aus `vendor/ghostty` bauen, in minimaler SwiftUI-App **2 Surfaces nebeneinander** rendern — Input, Resize, Scrollback funktionieren. *Exit: 2 interaktive Terminals in einer eigenen App.*
- **Spike B (Linux):** dasselbe mit Zig+GTK4 gegen libghostty. *Exit: 1 interaktives Terminal-Widget.* Falls blockiert (API-Lücke): Linux wartet auf libghostty-Tagging, macOS zieht vor — Entscheidung nach dem Spike, nicht vorher.
- **Spike C (Integration):** Hook-Roundtrip — `settings.json`-Hook → `planchette-hook` → Socket → Toast in der App, mit korrekter Session-Zuordnung via Env-Var. *Exit: Claude fragt in Terminal 2 → App zeigt „Terminal 2 fragt".*

### Phase 1 — Terminal-Grundgerüst
Multi-Session, Tabs + Gruppen + Cluster-View, Styling (Farbe/Titel), Auto-Titel, Pfadanzeige (2 Ordner + Hover), PTY-Spawn mit Env-Injection.

### Phase 2 — Attention-System
State-Machine im Core, Hook-Installer, OSC-133-Auswertung, Notification-Inbox, Idle-Timer, Menüleisten-Badge, Tab-Zustandsindikatoren.

### Phase 3 — Navigation & Priorität
Favoriten (high/normal), Quick Switcher ⌘K/⌘⇧K mit Prioritäts-Reihenfolge, Frei-Meldung.

### Phase 4 — Persistenz
SQLite-Store, kontinuierliches State-Snapshotting, Scrollback-Dump/-Restore, `claude --resume`-Wiederherstellung, Startup-Commands. *Abnahmetest: App killen bzw. Rechner rebooten → alles wieder da.*

### Phase 5 — V2-Features
Agent-Board, Hover-Preview, Templates, Frei-Pool, Fokus-Modus, Git-Kontext, Sound-Hooks, Cross-Session-Suche.

## Verifikation (End-to-End)

1. **Spike-Kriterien** wie oben — hart, vor Weiterbau.
2. **Attention-Flow:** 3 Projekte öffnen (1 Favorit), in zweien Claude arbeiten lassen → Favorit stellt Frage → Inbox zeigt ihn zuoberst, ⌘⇧K springt hin, Badge stimmt.
3. **Frei-Flow:** in einer Session `commit push pr`-Workflow durchlaufen → Terminal meldet `free` nach Rückkehr zum Prompt.
4. **Persistenz:** App hart beenden → Neustart: Layout, Farben, Titel, Scrollback, laufende Claude-Konversation (via resume) identisch. Danach derselbe Test über einen Reboot.
5. **Zuordnung:** 2 Claude-Sessions im selben Ordner → Events landen dank Env-Var trotzdem beim richtigen Terminal.

## Risiken

- **libghostty-API-Drift** (größtes Risiko): Submodule pinnen, Updates bewusst und selten; Spike A/B validieren die Machbarkeit vor jedem Feature-Bau.
- **Linux ab Tag 1** ist der am wenigsten ausgetretene Pfad — deshalb entscheidet Spike B früh und ehrlich, ob Linux in V1 mitschifft oder kurz nachzieht.
- **Scrollback-Restore ist visuell:** wiederhergestellter Verlauf ist Anzeige, kein lebender Prozess (Prozesse überleben Reboots prinzipbedingt nicht) — Startup-Commands schließen die Lücke für Dev-Server.
- **Hook-Installation:** `~/.claude/settings.json` wird gemerged, nicht überschrieben; bestehende Hooks (z.B. peon-ping) bleiben unangetastet.

## Erster konkreter Schritt nach Freigabe

`~/development/planchette` anlegen, `git init`, Ghostty-Submodule pinnen, dieses Konzept als `docs/CONCEPT.md` einchecken, dann Spike A starten.
