# $GREED — Mechanics & Data Model (rebuild spec)

**Source of truth:** `index.html` — "Rose Island International Greed Tournament" (manual score-entry build).
**Purpose:** A complete, GUI-agnostic description of how player *names* and *scores* are created, held in memory, mutated, undone, and persisted — so the interface can be rebuilt from scratch without the original markup.

This is the **data/state spec**, not a styling guide. Where the original had a specific DOM structure, it is noted only to explain what state drives what visible element.

---

## 1. STORAGE LAYERS (3 places state lives)

| Layer | Mechanism | Lifetime | What it holds |
|-------|-----------|----------|---------------|
| **In-memory game state** | JS variables | until page refresh / NEW GAME | the live game: players, scores, turn, history, end-mode |
| **Browser localStorage** | `localStorage` keys | persists across refreshes on this device | saved player names, all-time leaderboard, (was phrase seed — removed) |
| **Cloud (Supabase)** | REST API, anon key | persists across devices | shared player names, leaderboard, per-player stats |

**Cloud config (hard-coded in script):**
- `SUPABASE_URL`, `SUPABASE_ANON_KEY` constants.
- `SB` = object if both keys present, else `null` (cloud disabled → local-only fallback).
- RLS expected **disabled** (anon key has read/write). Key is public by design.
- Live-poll: leaderboard re-fetched every 10s, saved players every 15s, when `SB` is set.

---

## 2. IN-MEMORY GAME STATE

### 2.1 Player record
```
players: Array<{
  name:  string,   // free text, may duplicate across players (not recommended)
  total: number,   // running banked score, starts 0
  last:  number | null  // that player's most recent turn score; null if none yet
}>
```
- Created on Start Game from the setup name inputs: `names.map((n,i)=>({name:n, total:0, last:null}))`.

### 2.2 Turn / flow state
```
current:            number   // index into players[] of the active player
history:            Array<{ player:string, score:number, bonus:'greed'|'six'|undefined }>
gameRunning:        boolean  // true once a game has started
endMode:            boolean  // true after first player hits 5000
endModeTriggerIdx:  number   // index of the player who triggered end mode (-1 if none)
endTurnsRemaining:  Array<{ remaining:number }>  // one per player; counts left in end mode
winnerDeclared:     boolean
```

### 2.3 Derived (computed, not stored)
- `findHighestScorer()` → index of player with max `total` (ties → first such index).
- `leaderTotal` = max of all `total`.
- "needs N" shown on a non-leader card in end mode = `leaderTotal - p.total` (only if > 0).
- Card visual class from `cardClasses(i)`:
  - `winnerDeclared`: `leader` if i==highest else `eliminated`.
  - not endMode: `active` if i==current else `''`.
  - endMode & i==highest: `leader` (+ `active` if also current).
  - endMode & remaining==0: `eliminated`.

---

## 3. NAMES — HOW THEY ARE CREATED & KEPT

### 3.1 Setup-time (in-game roster)
- Setup screen has add/remove player rows. **Min 2, max 6** rows (`add-player-btn` stops at 6; delete disabled at 2).
- Start Game validation: `< 2` → "Enter at least 2 player names"; `> 6` → "Max 6 players".
- On start, names are copied into `players[]` (the in-memory roster). After that, the setup inputs are gone.

### 3.2 Saved names (persistent, shared)
- localStorage key **`greed-saved-players-v1`** → `JSON array of strings` (player names).
- On Start Game, names are merged into saved list: `Array.from(new Set([...existing, ...currentNames]))` then written back (local) **and** pushed to cloud (`greed_players` table, name-only, duplicate-safe insert).
- Setup screen shows saved names as tappable chips; tapping adds that name to the current roster (skipped if already present).
- Cloud table **`greed_players`**: columns `{ name }`. Read via `?select=name`. Written via POST with `Prefer: resolution=ignore-duplicates`.

### 3.3 Admin-managed names
- Admin ⚙ (password `roseisland`, session `{unlocked:false}`) → Players tab.
- Add: upsert name into saved list (local + cloud).
- **Rename:** adds new name, then transfers that player's leaderboard wins and all stats to the new name, then deletes the old name (cascade across `greed_players`, `greed_leaderboard`, `greed_stats`).
- **Delete:** removes name from saved list AND cascades delete from `greed_leaderboard` and `greed_stats`.

---

## 4. SCORES — HOW THEY ARE ENTERED & KEPT

### 4.1 Entry methods (all call `addScore(score, bonus?)`)
1. Type in number input (`min="0"`, `step="50"`) + **+ Add** (or Enter).
2. Tap a Quick-Add button: 50,100,150,200,250,300,350,400,450,500,550,600,650,700,750,800,850,900,950,1000.
3. Tap a Bonus button (see 4.3).

### 4.2 `addScore(score, bonus)` — the core mutation
```
score = Math.max(0, parseInt(score) || 0)   // blanks/negatives/NaN → 0
i = current
players[i].last = score
players[i].total += score
if (score > 0)         saveStatCloud(name, { biggest: score })   // track single-turn max
if (bonus === 'greed') saveStatCloud(name, { greed: 1 })
if (bonus === 'six')   saveStatCloud(name, { six: 1 })
history.push({ player: name, score, bonus })
clear input
```
- **End-mode trigger:** if `!endMode && players[i].total >= 5000` → set `endMode=true`, `endModeTriggerIdx=i`, and `endTurnsRemaining = players.map((_,idx)=>({ remaining: idx===i ? 0 : 1 }))`. Banner → "WE ARE IN THE END TIMES".
- **End-mode completion:** if `endMode && !bonus` → decrement `endTurnsRemaining[i].remaining`; if all `remaining===0` → declare winner (§5).
- **Bonus entries do NOT advance** (the player keeps the turn); normal entries advance.
- After a normal entry (or after bonus handling): `advance()` then re-render.

### 4.3 Bonus buttons
| Button | `score` | `bonus` | Stat | Behaviour |
|--------|---------|---------|------|-----------|
| **$GREED** | 1000 | `'greed'` | `greed +1` (💲) | add 1000, keep turn |
| **6 OF A KIND** | 5000 | `'six'` | `six +1` (6️⃣) | add 5000, keep turn, instantly triggers end mode (crosses 5000) |

- These are manual declarations; the app does not verify dice.

### 4.4 `advance()` — turn rotation
```
n = players.length
next = (current + 1) % n
while tries < n:
  if !endMode OR endTurnsRemaining[next].remaining > 0: break
  next = (next + 1) % n
current = next
```
- In end mode, skips players who have exhausted their final turn (`remaining===0`).

### 4.4b Dice symbol colours & full-set rule (virtual dice mode)
- Dice faces: **$** dark green, **G** yellow, **R** red, **E** light green, **E** blue, **D** black.
- There are **two differently-coloured E dice**: one light green, one blue.
- **$GREED (Full set) requires both coloured E's.** The 1000-point full set is awarded only when a single roll contains one of every symbol *including both the light-green E and the blue E*. Two E's of the same colour do NOT complete the set.
- The two E colours are **separate entities**: a 3-of-a-kind (or 4-of-a-kind) must be 3× (or 4×) of a *single* colour — either 3× light-green E **or** 3× blue E. A mixture of colours does NOT score.

### 4.5 NO SCORE / pass (`nextBtn`)
- Not end mode: `advance()` only (no score added).
- End mode: `addScore(0)` → consumes that player's remaining end-mode turn (score 0, no bonus → decrement path → may end game).

---

## 5. WINNER DECLARATION

When all end-mode turns are exhausted (`endTurnsRemaining` all 0):
- `topScore = max(total)`; `winners = players with total === topScore`.
- For **every** player: `saveStatCloud(name, { games: 1 })` (games played +1).
- **Comeback stat (↩):** for each winner `w` where `w.index !== endModeTriggerIdx` AND `w.last > 0` → `saveStatCloud(w.name, { comeback: w.last })`. (Stores the winner's final-turn score; `saveStatCloud` keeps the MAX across games.)
- Each winner → `recordWin(name)` (leaderboard wins +1).
- Banner: if `winners.length > 1` → **"TIE"** (no win recorded); else **"WINNER: name"** + total.
- `winnerDeclared = true`.

**Tie behaviour:** a TIE increments everyone's `games` but records **no** win and **no** comeback.

---

## 6. UNDO (`undoBtn`) — always available

```
if history empty: return
last = history.pop()
pid = index of player whose name === last.player
if endMode && endTurnsRemaining[pid]: endTurnsRemaining[pid].remaining += 1
players[pid].total -= last.score
players[pid].last = null
// cancel end mode if no player now has (total>=5000 AND remaining>0)
if endMode:
  anyHigh = players.some((p,idx) => p.total>=5000 && endTurnsRemaining[idx].remaining>0)
  if !anyHigh: endMode=false; endModeTriggerIdx=-1; endTurnsRemaining=players.map(()=>({remaining:0}))
winnerDeclared = false
current = pid
```
**Caveat:** undo reverses the in-memory game only. Wins/games/comeback/stats already written to localStorage/cloud during a finished game are **not** rolled back.

---

## 7. PERSISTENCE DETAILS

### 7.1 localStorage schema
| Key | Shape | Notes |
|-----|-------|-------|
| `greed-saved-players-v1` | `string[]` (names) | merged-set on start; admin add/delete/rename |
| `greed-leaderboard-v1` | `Array<{name, wins}>` | sorted desc by wins, **top 50** kept |
| (phrase seed key removed) | — | deleted with phrase system |

### 7.2 Cloud schema (Supabase, RLS off)
**`greed_leaderboard`**
- columns: `name` (text), `wins` (int)
- read: `?select=name,wins`; write: PATCH existing (wins+1) or POST `{name,wins:1}`.

**`greed_players`**
- columns: `name` (text)
- read: `?select=name`; write: POST with `Prefer: resolution=ignore-duplicates`.

**`greed_stats`** (one row per player)
- columns: `name`, `biggest` (int, single-turn max), `games` (int), `comeback` (int, winning final-turn score), `greed` (int, $GREED hit count), `six` (int, 6-of-a-kind hit count)
- read: `?select=name,biggest,games,comeback,greed,six`
- write: PATCH existing with merge rules — `biggest`/`comeback` take **MAX**, `games`/`greed`/`six` take **SUM**; or POST new row.

### 7.3 Read precedence (cloud vs local)
- **Saved players:** cloud names merged over local (if `SB`).
- **Leaderboard:** cloud if `SB` (else local). Shown top 20 in UI.
- **Stats:** cloud if `SB` (else `{}`).
- All cloud calls are **best-effort / non-blocking**; failures fall back to local silently.

---

## 8. ADMIN (password-gated)

- Password constant `ADMIN_PASSWORD = 'roseisland'`. `session = { unlocked:false }`.
- Unlock sets `session.unlocked=true`; close re-locks if not unlocked.
- Three tabs, all edit **persistent records only** (never live in-game scores):
  - **Players:** add / rename (cascade) / delete (cascade to leaderboard + stats).
  - **Wins:** per-name `wins` integer; save (PATCH/POST) or delete from `greed_leaderboard` (+ local).
  - **Stats:** per-name `biggest, games, comeback, greed, six` integers; save (PATCH/POST) or delete from `greed_stats`.
- Admin writes go to cloud if `SB`, else local only. Changes sync to every device via the poll intervals.

---

## 9. GAME-STATE BANNER (the only on-screen announcement)

The banner shows **only** game state (no flavour text):
- Start: **"FIRST TO 5000"**
- End mode triggered: **"WE ARE IN THE END TIMES"**
- Game over: **"WINNER: name"** + total, or **"TIE"**

(The NSFW phrase/announcement system that previously overlaid random text was removed; `pickAnnouncement`/`flashAnnouncement` no longer exist.)

---

## 10. REBUILD CHECKLIST (what a from-scratch GUI must reproduce)

- [ ] Setup: 2–6 name rows, saved-name chips, Start with min/max validation.
- [ ] In-memory `players[]` of `{name,total,last}`; `current`, `history[]`, `endMode`, `endModeTriggerIdx`, `endTurnsRemaining[]`, `winnerDeclared`, `gameRunning`.
- [ ] Score entry: typed number + quick-adds (50–1000) + two bonus buttons ($GREED=1000, 6 OF A KIND=5000).
- [ ] `addScore`: clamp ≥0, update `last`/`total`, push history, write stats, trigger/complete end mode, advance (skip exhausted in end mode).
- [ ] Bonus entries keep the turn; normal entries advance.
- [ ] Undo: pop history, reverse score, restore turn, optionally cancel end mode; note it does NOT roll back cloud stats.
- [ ] NO SCORE / pass: advance, or in end mode consume final turn with score 0.
- [ ] Winner: highest total wins; tie → "TIE" (no win); record wins + games + comeback (max) + greed/six counts.
- [ ] Card states: `active` (YOUR TURN), `leader` (green, highest in end mode), `eliminated` (dim, no turns left), `winner` styling.
- [ ] Persistence: localStorage keys for saved players + leaderboard (top 50); optional Supabase with the 3-table schema and RLS-off; best-effort sync + 10s/15s polls.
- [ ] Admin: password `roseisland`; Players/Wins/Stats tabs with cascade rename/delete; never touches live scores.
- [ ] Banner: FIRST TO 5000 / END TIMES / WINNER / TIE only.

---

*Extracted from `index.html` (post phrase-removal build, 1426 lines). Use as the canonical behavioural spec when rewriting the UI.*
