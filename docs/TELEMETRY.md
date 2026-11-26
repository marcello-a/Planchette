# Telemetry

Planchette can send one report under a random ID on a day it is used: which features are used, how big
the workspace is, which errors happened and where the app crashed. It asks first. It sends nothing, and counts
nothing, before the answer is yes.

This page is the contract. If a field is added to a report, it is added here in the same change.

## The question

- Asked once, in a sheet, after the welcome of a first launch (`TelemetryPromptSheet`).
- The sheet asks with reasons, never with pressure: why the data matters, what is sent and what
  never is, the report as it would look now (built by the same code that sends it), and a link to
  this page. **Share usage data** is in the accent colour; **Don't share** is just as large, right
  beside it and one click (or Escape) away. Neither is the default (Return picks nothing): consent
  must be freely given and informed (GDPR; the EDPB guidelines on deceptive design). Keep it so — no
  yes on Return, no smaller or hidden no, no "maybe later" in place of a no, no guilt.
- **Share usage data** or **Don't share**. Closing the sheet another way answers nothing: the
  question comes back once after the next update, and never before.
- The answer can be changed at any time in **Settings → Privacy**. That page also shows the last
  report word for word, what waits for the next one, and the random ID with a button that makes
  a new one.
- Counting starts with the yes: before it, `TelemetryRecord.absorb` and `add(crashes:)` keep
  nothing, and the crash scan starts at the moment of the yes. A report never carries what
  happened before the user agreed.
- **No** forgets everything collected so far.
- The id is random and pseudonymous, not anonymous: it links one install's reports to each
  other. That is why the sheet says "random ID", never "anonymous".

Nothing is asked and nothing is sent by an isolated instance (`PLANCHETTE_STATE_DIR`), an
unbundled dev run, or a build whose `Telemetry.projectKey` is empty.

## Where it goes

[PostHog](https://posthog.com), EU cloud (`https://eu.i.posthog.com/batch/`), with a plain HTTPS
request — no SDK, so ground rule 1 holds. Every event carries:

| Property | Value |
|---|---|
| `distinct_id` | A random UUID made on this Mac (`telemetry.json`), derived from nothing |
| `$process_person_profile` | `false` — PostHog keeps no person profile |
| `$geoip_disable` | `true` — PostHog looks up no location from the IP address |
| `app_version`, `os_version` | The Planchette and macOS version |

## When a report goes out

PostHog bills per event, not per request, and its free tier is 1 million analytics events and
100,000 exceptions a month. So an install sends **one analytics event on a day it is used, and
none on a day it is not**. The rules are `Telemetry.reportDue`, checked a minute after launch and
then every hour; the limits are the constants beside it.

| Rule | Limit |
|---|---|
| Consent | Only after a yes |
| Gap | Not on the calendar day of the last report, and not within **20 hours** of it — across restarts, the time is in `telemetry.json` |
| Use | **1 minute** in front (`active_minutes`), or a crash. Less, and the counts wait for a day with use |
| Heartbeat | An install that is not used reports once in **7 days** |
| Size | 1 `daily_snapshot` + at most **3** `$exception` events; hard cap **5** events a request |
| Failure | No retry loop: the next try at the earliest **50 minutes** later; after **3** failures in a row, one try a day |
| Retry | Same timestamps and event ids (`uuid`, made from the install id and the period since the last report), so PostHog keeps one copy of a report that did arrive |

Foreground time runs while Planchette is the frontmost app and the screens are awake. Agent time (`agent_minutes`) does not make a day worth a report: an agent left running over a weekend would otherwise report every day.

The budget: about 30 events per install a month, so the free tier holds about **30,000 installs
that use Planchette every day**. Crashes are grouped (below), so a crash at every launch costs one
exception, not fifty.

In PostHog, turn on **Discard client IP data** (project settings). `$geoip_disable` only stops the
location lookup; without this setting PostHog still stores the request's IP address beside the
random ID.

In PostHog, keep the project on the free plan (no card): an event over the quota is dropped, never
billed. With a card, set the billing limit of Product analytics and of Error tracking to $0, and
an alert at 80 %.

Later, from about 10,000 installs: a `telemetry-config.json` release asset beside
`screen-rules.json`, read with the update check (no extra request), with `enabled`,
`minHoursBetweenReports`, `sampleRate` (by a hash of the install id, so the same installs stay in)
and `crashesPerReport` — to slow or stop the reports without a new build. Not built yet.

## What a report holds

### `daily_snapshot` — one per report

| Property | Meaning |
|---|---|
| `windows`, `folders`, `projects`, `parked_projects`, `worktree_projects` | Counts |
| `tabs`, `split_tabs`, `terminals`, `durable_terminals` | Counts |
| `claude_terminals`, `codex_terminals`, `tagged_terminals` | Counts |
| `tags_in_list`, `presets`, `todos`, `open_reviews` | Counts |
| `setting_ai`, `setting_durable`, `tmux_available`, `setting_reviews`, `setting_todos`, `setting_jira`, `setting_auto_update` | Switches |
| `setting_claude_sleep`, `setting_language`, `setting_appearance` | The raw value of the app's own enum |
| `hook_claude`, `hook_codex` | Whether this launch wrote the hooks into the agent's config: `ok`, `failed`, `absent` (Codex not installed), `not_tried` |
| `notifications` | macOS's answer for Planchette's banners: `authorized`, `denied`, `not_determined`, `provisional`, `ephemeral`, `unknown`. Without `authorized`, no question reaches a user who looks elsewhere |
| `hook_events` | Hook events that arrived. Agent terminals but no hook events = the integration is broken |
| `state_by_hook`, `state_by_screen` | State changes the hooks made, and those the screen detection made (`AttentionState.fromScreen`) — where work on the detection pays |
| `wait_answered_lt30s`, `_lt5m`, `_lt30m`, `_gt30m` | Questions (`waiting`) raised while the user looked elsewhere, by how long until they opened the terminal through Planchette (`select(session:)`). A bucket, never the seconds. The app's core promise, measured |
| `peak_terminals`, `peak_agents_running`, `peak_waiting` | The most terminals, agents at work, and open questions (not silenced) at one time since the last report, sampled once a minute |
| `install_age_days` | Days since this install's record was made — the first launch of a version with telemetry. Tells a new install from an old one |
| `f_<feature>` | Uses of each `TelemetryFeature` since the last report — **every** feature, 0 included, so an unused feature shows as a column of zeros |
| `e_<key>` | Times each `Log.error` key happened since the last report, only the keys that did: `hook-server.bind_failed` → `e_hook_server_bind_failed`. A key is the `StaticString` a `Log.error` call is written with, so only a literal from the source can be a key. The free-text message stays in the unified log on this Mac |
| `errors`, `crashes`, `unclean_exits` | Totals since the last report (`crashes`: the crashes this report carries, with their counts); `unclean_exits` = launches that found the previous run had not quit (crash, force quit, kill) |
| `active_minutes` | Minutes Planchette was in front since the last report |
| `active_days` | Calendar days with time in front since the last report. A report can cover two days of use (the 20-hour gap); count retention by this, not by reports |
| `agent_minutes` | Minutes in which at least one agent's turn was running (a Claude or Codex terminal working on a prompt, in front or not; a terminal kept `running` only by background work does not count). Sampled once a minute; a sleep counts as at most two minutes |
| `hours_since_last_report` | Gap to the previous report |

A report covers the time since the last one: after days without use, its counts span those days.

### `$exception` — one per distinct crash

Read from `~/Library/Logs/DiagnosticReports/Planchette-*.ips`: the exception type, the signal, and
up to 30 frames of the crashed thread as binary name and function name — Apple's libraries and
Planchette by name, any other library as `?` (its name would say what else is installed). No
path, no user name, no other thread. PostHog's error tracking groups these into issues.

Crashes with the same version, exception, signal and top 5 frames of Planchette's own code are one
event with `count`; `timestamp` is the first of them. At most 3 a report; the rest wait.

### Never

Paths, project or folder names, titles, prompts, notepad text, branches, tickets, tag names,
anything a terminal shows, the Jira site, the GitHub account.

## Local log

Every `Log.info` and `Log.error` line goes to the unified log, with or without consent:

```sh
log stream --predicate 'subsystem == "build.planchette.app"'
log show --last 1d --predicate 'subsystem == "build.planchette.app"'
```

## Reading it in PostHog

SQL insights (PostHog → SQL) for the questions the data was collected for:

```sql
-- Active installs per day (a heartbeat has active_minutes = 0)
SELECT toDate(timestamp) AS day, count(DISTINCT distinct_id) AS installs
FROM events WHERE event = 'daily_snapshot' AND toInt(properties.active_minutes) > 0
GROUP BY day ORDER BY day

-- Which features are used, and by how many installs (last 30 days)
SELECT arrayJoin(JSONExtractKeys(properties)) AS key,
       sum(JSONExtractInt(properties, key)) AS uses,
       countIf(DISTINCT distinct_id, JSONExtractInt(properties, key) > 0) AS installs
FROM events
WHERE event = 'daily_snapshot' AND timestamp > now() - INTERVAL 30 DAY AND key LIKE 'f\_%'
GROUP BY key ORDER BY installs DESC

-- Does the app send you to the right terminal fast? (last 30 days)
SELECT sum(toInt(properties.wait_answered_lt30s)) AS under_30s,
       sum(toInt(properties.wait_answered_lt5m))  AS under_5m,
       sum(toInt(properties.wait_answered_lt30m)) AS under_30m,
       sum(toInt(properties.wait_answered_gt30m)) AS over_30m
FROM events WHERE event = 'daily_snapshot' AND timestamp > now() - INTERVAL 30 DAY

-- Broken integration: agent terminals, but no hook ever arrived
SELECT count(DISTINCT distinct_id) AS installs
FROM events
WHERE event = 'daily_snapshot' AND timestamp > now() - INTERVAL 30 DAY
  AND toInt(properties.claude_terminals) > 0 AND toInt(properties.hook_events) = 0

-- Activation: new installs (first week) that reached a project, a terminal, an agent
SELECT countIf(toInt(properties.projects) > 0) AS with_project,
       countIf(toInt(properties.terminals) > 0) AS with_terminal,
       countIf(toInt(properties.claude_terminals) + toInt(properties.codex_terminals) > 0
               OR toInt(properties.agent_minutes) > 0) AS with_agent,
       count() AS installs
FROM (SELECT argMax(properties, timestamp) AS properties FROM events
      WHERE event = 'daily_snapshot' AND toInt(properties.install_age_days) <= 7
      GROUP BY distinct_id)

-- How big a workspace is (latest report per install)
SELECT quantile(0.5)(toInt(properties.projects)) AS projects_median,
       quantile(0.5)(toInt(properties.terminals)) AS terminals_median,
       quantile(0.9)(toInt(properties.terminals)) AS terminals_p90,
       quantile(0.5)(toInt(properties.folders)) AS folders_median
FROM (SELECT argMax(properties, timestamp) AS properties FROM events
      WHERE event = 'daily_snapshot' AND timestamp > now() - INTERVAL 7 DAY GROUP BY distinct_id)

-- Errors by key (last 30 days)
SELECT arrayJoin(JSONExtractKeys(properties)) AS key,
       sum(JSONExtractInt(properties, key)) AS times,
       countIf(DISTINCT distinct_id, JSONExtractInt(properties, key) > 0) AS installs
FROM events
WHERE event = 'daily_snapshot' AND timestamp > now() - INTERVAL 30 DAY AND key LIKE 'e\_%'
GROUP BY key ORDER BY installs DESC, times DESC
```

Crashes: PostHog → Error tracking.

## Adding to it

- **A new feature** gets a `TelemetryFeature` case and one `Telemetry.count(.x)` where the user
  does it — never in restore code, never in a function that also runs on its own (for example on
  every selection), and **after the guards**: count what the feature did, not a click that did
  nothing (an empty project, nothing to reopen, a second click on a running send). A call that
  acts on several items at once counts once. The case's raw value is a PostHog column: never rename one.
- **A new error** is `Log.error("area.what", "message")`. Never `NSLog`: it is neither counted nor
  kept apart from the message. It costs no event: it is a column of the snapshot.
- **A new event** is a cost: every event of every install counts against the free tier. Prefer
  a column of `daily_snapshot`; an event of its own needs a reason and stays under the cap of 5.
- **A new metric** — how the app does its job, not what the user does — is a `TelemetryMetric`
  case and one `Telemetry.count(.x)`; a high is a `TelemetryPeak` case observed in
  `TelemetryService.sampleAgents`. Both are columns, 0 included. A time is a bucket, never seconds.
- **A new snapshot field** goes into `TelemetrySnapshot` and `AppState.telemetrySnapshot()`, and
  into the table above.
