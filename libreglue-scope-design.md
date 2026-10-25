# Glucoglu — Self-Hosted Glucose Monitoring & Analytics Platform (Handoff v2.2)

*   **Version:** 2.2 (supersedes `project_handoff.md` v1; v2.1: storage → PostgreSQL, O1–O6/O8 resolved, caregiver sharing added; v2.2, 2026-10-25: code review fixes, Danne event rule with gap tolerance, unit rule with sensor-range limits, quick log in the PWA (D17), Juggluco treatments not ingested)
    
*   **Status:** Metric scope verified against primary sources and approved. All decisions and open items closed. Build steps 1–4 done (§13): skeleton and login, ingest, schema, Tier 1 engine + AGP + Today view. Code review fixes done: secure tokens, production secret check, login link confirm form, event rule, unit rule, import and ingest transactions, dashboard fixes. Review items still open: runit deploy, "Last 24 h" summary line, time-weighted metrics (one source per 15-min slot). Then build step 5 (quick log + PP engine).
    
*   **Stack:** Perl / Mojolicious, PostgreSQL, PWA (vendored JS, no npm build step)
    

* * *

## 1. Objective & Strategy

Maintain a lightweight, privacy-focused, zero-cloud health monitoring and web platform [1].
Core philosophy: minimize supply-chain attack vectors and dependency bloat. Use native, compiled source stacks (Perl/Mojolicious) over mainstream package ecosystems (npm/pip). Maintain direct, auditable control over telemetry and health data [1].
**Build rules**

*   Perl only. Mojolicious. Source installs via cpanm. Minimal CPAN beyond core. Goal: a small, auditable supply chain — not fewer features.
    
*   No npm. No pip. PWA uses vendored JS. No build step.
    
*   PostgreSQL for storage (supersedes ClickHouse; see "Storage design", Section 3).
    
*   Public VPS hosting with TLS.
    

* * *

## 2. Locked Decisions

| # | Decision |
| --- | --- |
| D1 | Multi-tenant from the start |
| D2 | Ingest = Juggluco's Nightscout uploader (V1 `api-secret` header or V3 Bearer) POSTs Nightscout-style JSON (`type`, `date` in ms, `sgv`) to our own endpoint `/api/v1/entries` (§4). We do not run a full Nightscout server. Libre 1 history and scans come by TSV import (§4, item 2). The raw payload stays in JSONB, so schema control stays with us |
| D3 | Sensor scope: Libre 1 (NFC) + Libre 2 / 2+ / 3 (Bluetooth streaming) |
| D4 | Registration by invite code. Email address only. No real names |
| D5 | Billing hooks/stubs in v1. Payment implementation deferred |
| D6 | Public VPS hosting with TLS |
| D7 | v1 metric scope: per Section 7. All 31 metric rows verified against primary sources |
| D8 | Storage: PostgreSQL (supersedes ClickHouse, 2026-10-24). Dedup = UNIQUE (user ID, timestamp, source type); raw payload kept in JSONB |
| D9 | Login: email link + code (Claude.ai pattern). One token, 10-min expiry, single use, no passwords. First login = invite code + email → account created and verified (closes O5) |
| D10 | Read-only caregiver sharing in v1: table `shares` (owner, viewer); every read query checks ownership or grant |
| D11 | Units: store mg/dL only; user selects display/report unit; ingest range rule (2.2–27.8 → mmol/L; 40–500 → mg/dL; anything else → reject; see §3) |
| D12 | Export: CSV + browser PDF (PWA print stylesheet) in v1; right-to-delete at the storage layer; scheduled/emailed reports in v2 via headless Chromium (not Selenium) |
| D13 | Time: store UTC; per-user time zone from the browser; reports convert |
| D14 | Product: Glucoglu — "the glue for your glucose data from Juggluco" (login page). One canonical domain for app + mail; optional defensive redirect of the .com to the canonical. Juggluco name: nominative use only — factual data source, no logos, no "official" |
| D15 | License: AGPLv3. Applies also to the hosted service. GPLv3 code can enter the project (GPLv3 §14); check Juggluco's license file only if we ever copy its code |
| D16 | Deploy: app Perl in perlbrew (`perl-5.x@glucoglu` lib, no distro-Perl pollution). A front-end proxy (e.g. Apache) owns TLS on 443 and proxies to hypnotoad on 127.0.0.1:3000; `proxy => 1` trusts X-Forwarded-* |
| D17 | Meal, exercise and sleep marks are logged in the Glucoglu PWA (quick log, §6), one tap each. Juggluco treatments (`/api/v1/treatments`) and mirror amounts (`-N` export) are not ingested in v1: Juggluco's entry UI is hard to use, and one in-app path gives one data format. Turn off sending amounts/treatments in Juggluco, so its uploader does not retry against an endpoint we do not serve |

* * *

## 3. Sensor & Data Model

### Libre 1 (FreeStyle Flash)

*   NFC scan only. No Bluetooth [1].
    
*   Buffer: 8 hours rolling storage [1].
    
*   Commit: one historical point every 15 min. 32 points per 8-hour window [1].
    
*   Each tap also yields one instantaneous spot value [1].
    
*   Expected density: 96 points/day.
    

### Libre 2 / 2+ / 3

*   Bluetooth streaming, 1-min interval. Up to 1,440 points/day.
    
*   Juggluco receives the stream, then pushes to the same endpoint.
    

### Reading record

Every reading carries: user ID, timestamp, glucose value, source type (history block | stream | spot), source interval (15 | 1 min).

### Storage design (PostgreSQL)

*   One instance stores everything: users, invite codes, login tokens, readings, meals, insulin, IOB, exercise, sleep, notes, lab A1c, shares. One backup, one restore.
    
*   Dedup: UNIQUE (user ID, timestamp, source type) + ON CONFLICT DO NOTHING. Immediate and deterministic. No background merges, so a query right after insert can never count one reading twice.
    
*   Dedup check for Libre 1 history (2026-10-25): history timestamps do not change between exports. A repeat import after a new export gave 0 new rows and 28,052 duplicates. The exact-timestamp key stays. Fallback, only if duplicate sensor minutes ever appear: key history on sensor + sensor minute (TSV `Sensorid` + `Min`).
    
*   Raw payload: one JSONB column keeps each original Juggluco payload. Audit trail and evidence for O7.
    
*   Quick log marks (D17): `meals` gets `kind` (breakfast | lunch | dinner | snack, optional); `exercise` gets `intensity` (light | moderate | vigorous, optional); new table `sleep` (user ID, start, end). Times in UTC like all other data. Needs one migration (build step 5).
    
*   Unit rule at ingest, per glucose value (`Glucoglu::Units`, one function for the uploader and the TSV import): 2.2–27.8 → mmol/L, multiply by 18.018 → mg/dL. 40–500 → mg/dL as-is. Anything else (0, negative, non-numeric, `Inf`, or between the two ranges) → reject and log. The sensor range (40–500 mg/dL = 2.2–27.8 mmol/L) makes the two unit ranges disjoint. Checked 2026-10-25: Juggluco shows LO/HI only on screen and stores numbers; no stored value was outside 40–500.
    
*   All timestamps in UTC. Per-user time zone (the PWA sends it at registration); reports convert.
    
*   Lab A1c entry accepts % (DCCT) and mmol/mol (IFCC). Stored as %.
    
*   User delete (right-to-delete): DELETE by user ID across all tables.

### Scan discipline (Libre 1)

*   Consensus rule: minimum 3 scans/day; maximum 8 h between scans (Battelino 2023).
    
*   Project guidance: scan every 6–7 h. This leaves margin before the 8-hour buffer overflows [1].
    

* * *

## 4. Ingestion Pipeline

1.  Libre 2/2+/3 (Bluetooth stream): Juggluco's Nightscout uploader POSTs to `/api/v1/entries` (V1: `api-secret` header; V3: `/api/v2/authorization/request` handshake + Bearer). Verified against Juggluco source and live data (O7): Nightscout-style JSON, `sgv` + `date` epoch ms.
    
2.  Libre 1 (NFC only): Juggluco's uploader pushes stream values ONLY — scans and history are never uploaded (upstream gap). Path: Juggluco mirror → Juggluco cmdline server (receiver) → `-H`/`-S` TSV exports → `glucoglu-admin import history|spot`, run by a runit loop every 60 s (`script/libre1-sync`, added with the runit deploy). The import reads only rows newer than the last import minus 9 h, in one transaction. Re-imports are safe (dedup).
    
3.  PostgreSQL ingests historical blocks and spot scans. The UNIQUE constraint on (user ID, timestamp, source type) ignores overlapping timestamps from sequential scans within the same 8-hour window [1].
    
4.  Juggluco can also send meal marks (Amount field [1]), insulin doses, IOB, exercise marks and notes, via treatments (uploader, `/api/v1/treatments`) and amounts (mirror; `-N` export). Not ingested in v1 (D17): marks come from the quick log in the PWA. Turn off sending amounts in Juggluco.
    
5.  ~~Verify before build: capture one real Juggluco payload.~~ Done (O7 resolved): payload format and TSV formats confirmed against live data, 2026-10-24.
    

* * *

## 5. Postprandial (PP) Engine

Base engine per handoff [1]:

*   Input: meal timestamp from the PWA quick log (D17). The logged time is the meal start; the user can set it back ("30 min ago") when logging after the meal.
    
*   Window: 1–3 h after the meal mark [1].
    
*   Compute baseline glucose, locate the peak on the smoothed 15-min history curve, output Δ Glucose [1].
    

v1 extensions (approved):

*   Time to peak: `t(peak) − t(meal)`.
    
*   Duration above 180 mg/dL within the window.
    
*   iAUC: trapezoid area above baseline (Brouns 2005).
    

Clinical targets (verified):

*   ADA: peak postprandial <180 mg/dL, measured 1–2 h after meal start (ADA Standards of Care, Section 6, Table 6.3). The ADA peak window (1–2 h) sits inside our engine window (1–3 h) [1].
    
*   IDF: 2-h postmeal <140 mg/dL (7.8 mmol/L), as long as hypoglycemia is avoided (IDF Guideline for Management of Postmeal Glucose, 2007).
    

**Confirmed:** PP baseline = 30-min pre-meal mean (O4 resolved, 2026-10-24).

* * *

## 6. Reports & Dashboard

*   Default window: 14 days (consensus standard). Options 7 / 30 / 90. Confirmed (O2).
    
*   AGP chart: percentiles 5/25/50/75/95 by time of day (Mazze 1987; Bergenstal 2013).
    
*   AGP data note (observed 2026-10-24): a slot with a single sample collapses to the median line (zero-width percentile bands); bands appear where >=2 days overlap a slot. Sharp p5 troughs are isolated dips, smooth p95 peaks are sustained highs — percentile semantics, not defects. Thin windows are flagged by the data-sufficiency metric, not by hiding the chart.
    
*   **Today view ("100 m race")** — top of the dashboard, above AGP ("marathon"):
    
    *   Current value with trend arrow and reading age ("238 mg/dL ↗ 12 min ago"). Age matters on Libre 1: data is only as fresh as the last scan.
        
    *   Since-local-midnight line chart of ALL readings (history + spot + stream). Spot values belong in the daily trace — their scan bias invalidates summary metrics, not the record of what actually happened.
        
    *   Y guides 70 / 180 / 250 mg/dL; the 70–180 band shaded; fixed 40–400 scale for consistency with AGP.
        
*   **Trend and deltas (v1 decision, revised after field review)**: the "brace for it" signal is the delta numbers, not the arrow. Display Δ1 / Δ5 / Δ15 (change over the last 1 / 5 / 15 minutes, each from readings bracketing the window, each "--" when no data brackets it). Arrow uses Dexcom thresholds on mg/dL/min slope (>=3 Double, 2-3 Single, 1-2 FortyFive, <1 Flat, mirrored down) computed from the best available basis (Delta5 if data brackets it, else Delta15 -- an approximation at NFC cadence). Doubles are genuinely rarer on Libre 1: spikes between 15-min points are invisible to the sensor, and thresholds are NOT lowered to compensate -- the deltas carry the speed information. Juggluco's own direction (uploader `direction` field; mirror TSV `Rate`/`ChangeLabel`) is preserved in readings.raw for audit (TSV import includes it); display is always computed, so it cannot disagree across sources. Nightscout returns `delta` in the display unit but classifies arrows in mg/dL/min -- we do the same.
    
*   **Quick log (D17)** — one tap for each mark, like the Libre app; no other app needed:
    
    *   Buttons: Meal, Exercise, Sleep. A tap logs "now". One more tap sets the time back: 15 / 30 / 60 min, or a typed time.
        
    *   Meal: kind is optional. The default comes from the local time (breakfast, lunch, dinner, else snack); one tap changes it. Carbs (g) and a note are optional.
        
    *   Exercise: duration in minutes and intensity (light / moderate / vigorous). Both optional, so a single tap still logs the mark.
        
    *   Sleep: start and end. Two taps ("Going to sleep", "Woke up"), or both times typed. A start with no end shows as open until the next "Woke up".
        
    *   Marks show on the Today chart at their time (meal, exercise, sleep band). The owner can edit and delete marks. Viewers see them read-only (D10).
        
*   PWA dashboard, vendored JS, offline-capable.
    

* * *

## 7. Metric Specification (v1, all verified)

**Weighting (target, code review item L1):** percentage metrics, mean and SD weight each reading by the time it covers. One source per 15-min slot: stream readings if the slot has any, else the history value (spot scans stay out). A history value covers the 15 min around its timestamp (checked 2026-10-25 on 1,463 values: 3.4 mg/dL mean difference to the centered stream mean, 6.1 for the 15 min before or after). Until L1, each reading counts once, so 1-min stream days outweigh 15-min history days.

Unit pairs (mg/dL = mmol/L): 70 = 3.9, 54 = 3.0, 63 = 3.5, 140 = 7.8, 180 = 10.0, 250 = 13.9.

### Tier 1 — Standard metrics (all in v1)

| # | Metric | Formula | Target | Source | Interval needed |
| --- | --- | --- | --- | --- | --- |
| 1 | TIR 70–180 | `N(70≤G≤180)/N×100` | >70% | Battelino 2019, _Diabetes Care_ 42(8):1593–1603 | Any; 15-min OK |
| 2 | TAR >180 / >250 | % of readings | <25% / <5% | Same | Any |
| 3 | TBR <70 / <54 | % of readings | <4% / <1% | Same; 54 threshold: IHSG, _Diabetes Care_ 40(1):155–157, 2017 | 1-min best; 15-min misses dips <15 min |
| 4 | Mean glucose | arithmetic mean | — | Battelino 2019 | Any |
| 5 | Glucose SD | population SD | — | Battelino 2019 | Any |
| 6 | CV% | `SD/mean×100` | ≤36% | Battelino 2019; threshold: Monnier 2017, _Diabetes Care_ 40(7):832–838 | Any |
| 7 | GMI | `% = 3.31 + 0.02392×mean [mg/dL]`; IFCC: `mmol/mol = 12.71 + 4.70587×mean [mmol/L]` | — | Bergenstal 2018, _Diabetes Care_ 41(11):2275–2280 | Any; use ≥14 days. Note: formula derived from Dexcom data; sensor-bias caveat per source |
| 8 | eA1c (ADAG) | `A1c% = (mean+46.7)/28.7 [mg/dL]` | — | Nathan 2008, _Diabetes Care_ 31(8):1473–1478 | Any |
| 9 | AGP | percentiles 5/25/50/75/95 by time of day, 14 days | — | Mazze 1987; Bergenstal 2013, _Diabetes Technol Ther_ 15(3):198–211 | Any |
| 10 | Data sufficiency | ≥70% of 14 days; alternative: 10 days at 80–100%. Measured as filled 15-min slots / (days × 96); a slot is filled if it holds at least one reading. Reading counts are not used. Target: code review item L1; until then the code counts readings against 96/day | — | Battelino 2019; Battelino 2023, _Lancet Diabetes Endocrinol_ 11:42–57 | Any |
| 11 | Hypo/hyper events | Event starts: ≥15 min below threshold. Ends: ≥15 min at/past the exit level (L1 exit ≥70; L2 exit ≥54; hyper exit ≤250). Extended hypo <70: >120 min. Extended hyper >250: ≥90 cumulative min within 120 min. A gap of more than 20 min between readings (one missing 15-min point plus jitter) breaks the run. An event that a gap or the end of the data closes counts if the time beyond the threshold is ≥15 min; with no recovery seen, that time runs from the first to the last reading beyond the threshold | — | Danne 2017, _Diabetes Care_ 40(12):1631–1640; Battelino 2023 Table 4 | 1-min best |

### Tier 2 — Population profiles (all in v1; threshold presets only, no extra code)

| # | Profile | Targets | Source |
| --- | --- | --- | --- |
| 12 | TITR 70–140 | suggested >70% | Battelino 2023 (secondary consensus metric); Beck 2024, _Diabetes Technol Ther_ 26(3):151–155 |
| 13 | Pregnancy | TIR 63–140 >70%; TBR <63 <4%; <54 <1%; TAR >140 <25% | Battelino 2019 Table 4; range from CONCEPTT: Feig 2017, _Lancet_ 390:2347–2359 |
| 14 | Older / high-risk | TIR >50%; TBR <1% (<70); TAR >250 <10%; ADA SOC adds TAR >180 <50% for older adults with complex health | Battelino 2019 Table 3; ADA Standards of Care, Table 6.2 |

### Tier 3 — Differentiated metrics (v1)

| # | Metric | Formula / definition | Source | Interval |
| --- | --- | --- | --- | --- |
| 15 | PP delta | `peak − baseline`, 1–3 h window [1] | Engine [1]; meal Gmax/Tmax criteria: Service 1987, _Diabetes Care_ 10:225–237; targets: ADA SOC Table 6.3; IDF 2007 | 15-min OK (±15 min resolution); meal mark [1] |
| 16 | Time to peak | `t(peak) − t(meal)` | Derived; Service 1987 | As row 15 |
| 17 | PP duration >180 | minutes >180 in window | Derived | As row 15 |
| 18 | PP iAUC | trapezoid integral of `max(G − baseline, 0)` | Brouns 2005, _Nutr Res Rev_ 18:145–171; meal-synchronized profiles: Rodbard 2018, _Diabetes Technol Ther_ 20(S2) | As row 15 |
| 19 | GMI − lab A1c gap | track gap over time; user enters lab A1c. Real-world discordance: ≥0.5 pp in 50%, ≥1.0 pp in 22% (trials: 28% and 3%) | Bergenstal 2018 Table 3; Perlman 2021, _Diabetes Technol Ther_ 23(4):253–258 | Any; lab entry required |
| 20 | LBGI / HBGI | `f(x) = 1.509×((ln x)^1.084 − 5.381)` [x in mg/dL]; `r(x) = 22.77×f(x)²`; LBGI = mean of r over readings ≤112.5; HBGI over >112.5. Zones: LBGI <2.5 low, 2.5–5 moderate, >5 high | Kovatchev 2019, _J Diabetes Sci Technol_ 13(4):627–635; validation: Kovatchev 1998, _Diabetes Care_ 21:1870–1875; constant: Gaynanova 2018, _Diabetes Technol Ther_ 20(4):317 | Any |
| 25 | Scan gap alarm | warn as `now − last scan` nears the 8-hour buffer [1]. Consensus: min 3 scans/day, ≤8 h apart. Warn threshold default 6.5 h (tunable). Based on the last spot scan. Delivery: email through the existing SMTP relay (D9); Web Push is out because it needs crypto modules, against the build rules. The import also records when it last ran: if that time is stale, the alarm reports a stopped sync, not a missed scan | Buffer [1]; rule: Battelino 2023; scan frequency ↔ outcomes: Dunn 2018, _Diabetes Res Clin Pract_ 137:37–46 | NFC only |
| 26 | Data completeness | filled 15-min slots / (days × 96), the same measure as row 10. A slot is filled if it holds at least one reading, so NFC (96/day) and stream (1,440/day) users use one scale. Target: code review item L1; until then the code counts readings | Project-specific; consensus requires reporting % data obtained (Battelino 2023) | Both |
| 29 | Dawn phenomenon | `Δ = G(pre-breakfast) − G(nadir)`, per day on complete nights. Present if Δ > 20 mg/dL. Median T2D magnitude ~16 mg/dL; adds ~0.4 pp to HbA1c | Monnier 2013, _Diabetes Care_ 36(12):4057–4062; commentary: Porcellati 2013, 36(12):3860–3862 | Any; nights with gaps → invalid |
| 31 | GRI | `3.0×%VLow + 2.4×%Low + 1.6×%VHigh + 0.8×%High`. Scale 0 (best) to 100 (worst). GRI grid display | Klonoff 2022, _J Diabetes Sci Technol_, doi:10.1177/19322968221085273; emerging metric per Battelino 2023 and APAC consensus (Kong 2023, _Diabetes Res Clin Pract_) | Any |

### Sensor interval engineering notes

*   All Tier 1 % metrics: any interval works.
    
*   15-min data undercounts events shorter than one interval (rows 3, 11, 15–18).
    
*   Rows needing continuous data: ≥48 h without gaps; Libre 1 meets this only under scan discipline (Section 3).
    

* * *

## 8. Deferred to v2

| # | Metric | Source | Note |
| --- | --- | --- | --- |
| 21 | MAGE | Service 1970, _Diabetes_ 19(9):644–655 | Automated calculators disagree (Sechterberger 2014); pick one algorithm, document it |
| 22 | CONGA-n | McDonnell 2005, _Diabetes Technol Ther_ 7(2):253–263 | ≥48 h continuous required |
| 23 | MODD | Molnar 1972, _Diabetologia_ 8(5):342–348 | ≥48 h continuous required |
| 24 | GVP | Peyser 2018, _Diabetes Technol Ther_ 20(1):6–16 | `(L/L₀ − 1)×100`. 1-min best; 15-min approximate; >30 min unsuitable |
| 27 | Overnight report | Nocturnal window 00:00–05:59 per Battelino 2023 | — |
| 28 | Exercise response | Riddell 2017, _Lancet Diabetes Endocrinol_ 5(5):377–390 | Hypo risk ≥24 h post-exercise; needs exercise marks (quick log, D17) |
| 30 | Week-over-week deltas | Project-specific | Trivial once Tier 1 exists |

**Naming note:** handoff v1 used the label "GVI". The verified curve-length metric is GVP (Peyser 2018). Implement GVP under the v1 label if the name matters, or rename to GVP.

* * *

## 9. Multi-User, Privacy, Billing

*   Multi-tenant. Data isolation per user at the storage layer.
    
*   Invite-code registration. Email address only. No real names.
    
*   Login: email link + code, no passwords (D9). Mail goes through an external SMTP relay (new domain; SPF + DKIM records required). We do our part: TLS, 10-minute expiry, single use, rate limit per address. A stolen mailbox is the user's domain, not ours.
    
*   Caregiver sharing, read-only (D10): table `shares` (owner, viewer). The owner grants a viewer by email; the viewer must be a registered user. Every read query takes a target user and checks: session user = target, or a grant exists. Viewers see all data read-only (readings, meals, insulin, notes, reports); they cannot write, delete, or change settings. The PWA shows a user switcher to viewers.
    
*   Billing hooks/stubs in v1: account tier field, feature-flag stubs. No payment processing.
    
*   Public VPS with TLS.

*   Every page shows "Not for treatment decisions" (layout footer).

*   Operator maintenance via `script/glucoglu-admin` CLI (invites, user list, right-to-delete, prune of expired tokens and old mail log). No web admin in v1; the operator is the admin.
    

* * *

## 10. Competitive Gap vs LibreView (verified from Abbott documentation)

LibreView offers: AGP report (mean, GMI, CV, TIR, percentiles), Glucose Pattern Insights, Daily Patterns, Mealtime Patterns (pre/post averages only), Weekly Summary, Snapshot, Daily Log, Monthly Summary.
LibreView does **not** offer: TITR, LBGI/HBGI, GRI, per-meal Δ / time-to-peak / iAUC, GMI−lab A1c tracking, scan-gap data-loss alarms, completeness vs theoretical maximum, MAGE/CONGA/MODD.
These gaps are the product differentiation.

* * *

## 11. Verification Corrections (supersede v1 assumptions)

1.  GMI mmol/L form outputs **mmol/mol (IFCC)**, not %: `12.71 + 4.70587 × mean [mmol/L]` (Bergenstal 2018).
    
2.  GMI−HbA1c discordance, real-world clinic data: 50% ≥0.5 pp, 22% ≥1.0 pp (Perlman 2021); trial data: 28% and 3% (Bergenstal 2018).
    
3.  MODD is Molnar 1972, not Service 1970.
    
4.  Handoff "GVI" → the verified curve-length metric is GVP (Peyser 2018).
    
5.  LBGI risk-function constant: **22.77** (Kovatchev 2019; Gaynanova 2018), not 22.577.
    

* * *

## 12. Open Items

| # | Item | Resolution |
| --- | --- | --- |
| O1 | Units | Resolved (D11): store mg/dL only; user selects display/report unit; ingest range rule |
| O2 | Report window | Resolved: default 14 days; options 7 / 30 / 90 |
| O3 | Login method | Resolved (D9): email link + code; no passwords |
| O4 | PP baseline window | Resolved: 30-min pre-meal mean |
| O5 | Email verification | Resolved by design (D9): the first working code proves the mailbox |
| O6 | Data export / deletion | Resolved (D12): CSV + browser PDF (PWA print stylesheet) in v1; right-to-delete at the storage layer; scheduled/emailed reports in v2 via headless Chromium (not Selenium) |
| O7 | Juggluco JSON field names | Resolved (2026-10-24): Nightscout-style (`type`,`date` ms,`sgv`), confirmed against live uploads; TSV export formats confirmed for the mirror path |
| O8 | IDF 140 mg/dL target | Resolved as display guidance: T2D-oriented; individualize; do not apply blindly |

* * *

## 13. Build Order

1.  Mojolicious skeleton, TLS, external SMTP, invite-code registration, link + code login (D9).
    
2.  `/api/v1/entries` ingest [1] + payload capture (O7).
    
3.  PostgreSQL schema: users, invite codes, login tokens, readings (+ UNIQUE dedup, JSONB payload), meals, insulin, IOB, exercise, notes, lab A1c, `shares`. Right-to-delete. Schema freeze after the step 2 payload check (O7).
    
4.  Tier 1 engine + AGP chart. Every read query goes through the ownership-or-grant check (D10).
    
5.  Quick log (D17, §6): migration for meal kind, exercise intensity, `sleep`; log, edit, delete; marks on the Today chart. Then the PP engine + extensions [1].
    
6.  Tier 3: LBGI/HBGI, GRI, scan gap alarm, completeness, dawn phenomenon.
    
7.  GMI−lab A1c tracking (lab entry form).
    
8.  PWA polish, units (O1), report windows (O2), CSV export, print-stylesheet PDF (O6), caregiver user switcher (D10).
    

* * *

## 14. References

1.  Battelino T, et al. Clinical targets for CGM data interpretation: recommendations from the International Consensus on Time in Range. _Diabetes Care_ 2019;42(8):1593–1603.
    
2.  Danne T, et al. International consensus on use of continuous glucose monitoring. _Diabetes Care_ 2017;40(12):1631–1640.
    
3.  Battelino T, et al. CGM and metrics for clinical trials: an international consensus statement. _Lancet Diabetes Endocrinol_ 2023;11:42–57.
    
4.  Bergenstal RM, et al. Glucose Management Indicator (GMI): a new term for estimating A1C from CGM. _Diabetes Care_ 2018;41(11):2275–2280.
    
5.  Nathan DM, et al. Translating the A1C assay into estimated average glucose values (ADAG). _Diabetes Care_ 2008;31(8):1473–1478.
    
6.  International Hypoglycaemia Study Group. Glucose concentrations <3.0 mmol/L (54 mg/dL) should be reported in clinical trials. _Diabetes Care_ 2017;40(1):155–157.
    
7.  Monnier L, et al. Toward defining the threshold between low and high glucose variability. _Diabetes Care_ 2017;40(7):832–838.
    
8.  Mazze RS, et al. Ambulatory glucose profile. _Diabetes Care_ 1987;10(1):111–117.
    
9.  Bergenstal RM, et al. Recommendations for standardizing glucose reporting: the AGP. _Diabetes Technol Ther_ 2013;15(3):198–211.
    
10.  Feig DS, et al. CGM in pregnant women with type 1 diabetes (CONCEPTT). _Lancet_ 2017;390(10110):2347–2359.
     
11.  Beck RW, et al. TIR 70–180 vs TITR 70–140. _Diabetes Technol Ther_ 2024;26(3):151–155.
     
12.  Perlman JE, et al. HbA1c and GMI discordance: a real-world analysis. _Diabetes Technol Ther_ 2021;23(4):253–258.
     
13.  Kovatchev B. Glycemic variability: risk factors, assessment, and control. _J Diabetes Sci Technol_ 2019;13(4):627–635.
     
14.  Kovatchev BP, et al. Assessment of risk for severe hypoglycemia: validation of the LBGI. _Diabetes Care_ 1998;21(11):1870–1875.
     
15.  Gaynanova I, et al. Corrections of equations on glycemic variability. _Diabetes Technol Ther_ 2018;20(4):317.
     
16.  Service FJ, et al. Glucose variability: where it is important and how to measure it. _Diabetes Care_ 1987;10(4):225–237.
     
17.  Brouns F, et al. Glycaemic index methodology. _Nutr Res Rev_ 2005;18:145–171.
     
18.  Rodbard D. Glycemic variability: a review of clinical applications and research developments. _Diabetes Technol Ther_ 2018;20(Suppl 2).
     
19.  American Diabetes Association. Standards of Care in Diabetes, Section 6 (Glycemic Goals), Tables 6.2 and 6.3. 2024; reaffirmed 2026.
     
20.  International Diabetes Federation. Guideline for Management of Postmeal Glucose. 2007. Review: Ceriello A, Colagiuri S. _Diabet Med_ 2008;25(10):1151–1156.
     
21.  Monnier L, et al. Magnitude of the dawn phenomenon and its impact on overall glucose exposure in type 2 diabetes. _Diabetes Care_ 2013;36(12):4057–4062.
     
22.  Porcellati F, et al. Thirty years of research on the dawn phenomenon. _Diabetes Care_ 2013;36(12):3860–3862.
     
23.  Klonoff DC, et al. A Glycemia Risk Index (GRI) of hypoglycemia and hyperglycemia for CGM validated by clinician ratings. _J Diabetes Sci Technol_ 2022. doi:10.1177/19322968221085273.
     
24.  Kong APS, et al. Asia-Pacific consensus recommendations for CGM. _Diabetes Res Clin Pract_ 2023.
     
25.  Dunn TC, et al. Real-world flash glucose monitoring patterns and associations between scanning frequency and glycaemic measures. _Diabetes Res Clin Pract_ 2018;137:37–46.
     
26.  Riddell MC, et al. Exercise management in type 1 diabetes: a consensus statement. _Lancet Diabetes Endocrinol_ 2017;5(5):377–390.
     
27.  Service FJ, et al. Mean amplitude of glycemic excursions (MAGE). _Diabetes_ 1970;19(9):644–655.
     
28.  Sechterberger MK, et al. Poor agreement of computerized calculators for MAGE. _Diabetes Technol Ther_ 2014;16(1):72–75.
     
29.  McDonnell CM, et al. A novel approach to continuous glucose analysis utilizing glycemic variation (CONGA). _Diabetes Technol Ther_ 2005;7(2):253–263.
     
30.  Molnar GD, Taylor WF, Ho MM. Day-to-day variation of continuously monitored glycaemia (MODD). _Diabetologia_ 1972;8(5):342–348.
     
31.  Peyser TA, et al. Glycemic Variability Percentage (GVP). _Diabetes Technol Ther_ 2018;20(1):6–16.
     

* * *

**Next action:** build steps 1–4 and the code review fixes are done (security, events, units, import, ingest, dashboard). Next, in this order: deploy with runit (sets `MOJO_MODE=production`, runs the Libre 1 sync loop), the "Last 24 h" summary line, then time-weighted metrics (review item L1; do it before trusting 30- and 90-day numbers). Then build step 5: quick log (D17), then the PP engine.
