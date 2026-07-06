# Important Auras — project status

An addon to display an **icon** when a specific buff/debuff (by spell ID) is on
a unit, even though aura `spellId`s are now **secret values** that insecure Lua
cannot read, compare, or branch on.

## Core idea (works — SOLVED, dual punch shipped in production)
A `StatusBar` computes its fill fraction in **C** from a value that may be a
secret. We never read the secret — we let the C-side fill math do an equality
test and observe the pixels. For a tracked spell ID `X`, a **matcher** is an
unmasked-visible icon plus two **transparent punch masks** (transparent texture
under keep-outside `CLAMPTOWHITE` wrap: covered = hide, uncovered = keep), each
riding a StatusBar fill fed the secret via `SetValue`. Both punches keep
constant full area in every regime — they never collapse, they just **park**
off the icon (a collapsed mask leaks ~r of its interior; see demomask3):

- **punchLo**: bar = icon rect inflated 4px on ALL FOUR sides, `min=X-1,max=X`
  (binary); mask spans `[fill.right .. fill.right+size+2m]`. `v<X` → fill 0% →
  punch covers the icon ±m (hidden); `v>=X` → parked right of it (kept).
- **punchHi**: bar = `[iconLeft-(size+3m) .. iconRight+m] × (icon ±m)`,
  `min=X-1,max=X+1` (fills 0%/50%/100%); mask = `SetAllPoints(fill)`. `v==X` →
  50%, parked left with its right edge at `iconLeft-m` (kept); `v>=X+1` →
  covers the icon ±m (hidden). Its only collapse (`v<X`) lands where punchLo
  already zeroed the icon.

**Punch edges must be exact — two in-game-diagnosed leak modes (rounds 3.1/3.2):**
- **3.1 — flush edges leak.** Round 3's original geometry had no vertical
  inflation and punchHi ended at `iconRight` exactly → top/right/bottom edge
  lines on hides (left clean thanks to overhang). Fixed by inflating both bars
  ±m vertically and extending BHi to `iconRight+m` (widened left by 2m so the
  50% park still clears by m).
- **3.2 — LINEAR filtering bleeds past the margin.** Default texture filtering
  blends the mask's edge texel with the clamp border over **half a texel on
  EACH side** of the rect edge. The 8×8 texture stretched over punch-sized
  rects makes that ~3–6px (punchHi texel = width/8 = 12px at size 40) — wider
  than the 4px margin → residual faint LEFT line on matches (parked punchHi's
  gradient reaching the icon) and RIGHT line on `v>X` hides. Fixed with the
  4th `SetTexture` arg: **`NEAREST` filtering** on both punch masks — no
  blending, alpha edge exactly at the rect boundary. (Alternative rejected:
  bigger margins — the needed margin grows with punch width ∝ icon size.)

Net, computed entirely in C: **icon visible iff `value == X`, misses truly
transparent (alpha 0), zero residual** — verified in-game via `/ia
demomask3` round 3 (match indistinguishable from an unmasked reference icon).
Spell IDs are integers so the fills are discrete.

## Layout: stacked with priority (default) / aura-mirror row
One slot per aura index, each slot fed that one aura's secret, holding one
matcher per tracked target. Misses are truly transparent (dual punch), so
matchers never clobber — which unlocked the **stack layout (default)**: ALL
slots sit at the same point, so a tracked buff shows in one fixed spot instead
of shuffling with its aura index. When several tracked auras are up at once,
the most important wins visually: `db.order` (a plain saved priority list,
rank 1 = top; never derived from a secret) drives matcher **frame levels**, and
spell icons are opaque, so the top icon occludes the rest. Every matcher still
renders — priority only decides draw order among the (≤1 per slot) visible
icons; the same rank can't be visible in two slots (an aura has one index).
`/ia layout row` keeps the old aura-mirror strip for comparison;
`/ia prio <id> [pos]` reorders; `add` appends at lowest priority; InitDB
reconciles `db.order` against `db.targets` (drop stale, append missing sorted).

## Verified in-game (via `/ia probe`)
- Aura `spellId` is **secret even for the player's own buffs in the open world**
  (`issecretvalue()` returns true). There is no "safe zone" of plain values.
- `if value >= max` on a secret → **error** (`ok=false`). Branching on a
  secret is forbidden. This is why the comparison must happen in C.
- `StatusBar:SetValue(secret)` is **accepted**, and `GetValue()` afterward is
  **still secret** — the secret flows through the bar into C intact. This is the
  load-bearing premise and it holds.
- Aura *enumeration* works (`GetAuraDataByIndex` + nil-break); only the spellId
  *field* is secret, not the table or the count.
- **(Found via live play, not `/ia probe` — probe no longer exists.)
  `C_Spell.GetSpellCooldown(spellID)`'s returned `duration` (and presumably
  `startTime`) are secret too, even for a PLAIN, non-secret `spellID` and even
  for the player's own spell** — comparing `cd.duration > 0` errored "a secret
  number value, while execution tainted by 'ImportantAuras'" (Bug #6). Contrast
  `GetSpellBaseCooldown(spellID)` (the static/constant cooldown, same for
  everyone): its result is plain — arithmetic (`ms/1000`) on it never errors.
  So "the spell's fixed cooldown length" is public but "is this spell live
  cooling down right now, and for how long" is secret — same shape as the
  aura-spellId restriction, extended to live cooldown state. Practical
  consequence: an addon cannot read a spell's real-time cooldown remaining
  for ANY unit, including the player's own — `ResolveCastCooldown` now always
  uses the static base cooldown (see Next Features #14).

**General principle (apply proactively, don't wait to rediscover this per
API):** **any information derived from an aura is secret while in combat**
— not just the spellId (see above): duration, expirationTime, and by the
same logic any other field read off `UnitAura`/`GetAuraDataByIndex` should
be assumed secret-shaped too. And **any API call that takes a secret as an
argument should be assumed to hand back a secret as well** — taint
propagates through the call rather than being filtered out (`SetValue(secret)`
→ `GetValue()` still secret is the clean example above; the
`GetSpellCooldown` case shows the same taint can follow the surrounding
*execution context* even when the specific argument passed is plain). Don't
assume a getter "launders" a secret into something readable — none tried so
far have (see "Approaches ruled out": `GetTextureFileID` didn't launder
either). Treat any new API touching aura/cast/combat state as secret until
proven otherwise (`issecretvalue()`/`type()` checks are safe; comparisons,
arithmetic, and string formatting are not) rather than wiring it into a
branch and finding out live.

## Approaches ruled out
- **`hooksecurefunc` on `SetValue` with `if value >= max then Hide()`** — dead.
  `hooksecurefunc` protects against *taint propagation*, not *secret access*.
  When our addon calls `SetValue`, the posthook runs in an insecure context and
  branching on the secret comparison errors. (Original idea from first draft.)
- **`TextureBase:GetTextureFileID` as a launder** — dead. Idea: set a texture
  from a secret (via `C_Spell.GetSpellTexture(secretSpellId)` or an aura's `.icon`
  field), then read the fileID back as a plain integer to recover the ID. Tested
  via `/ia probe`: **did not launder.** Same propagation as `GetValue` after
  `SetValue(secret)` — the taint carries through the texture and the readback is
  still secret (or the setter rejects it). A readback getter can't escape a secret.
- **`DoesClipChildren` as a detector** — dead. It's a getter for the
  `SetClipsChildren` boolean, not an "is this child clipped" query; there is no
  `IsClipped()`. Reading a clip result would be a forbidden secret-decision anyway.
- **Clip-as-mask** (push the reveal bar out of a `SetClipsChildren` window with a
  secret-driven cutoff bar, to hide non-matches *transparently* instead of with
  an opaque square) — **tested, did not work.** Removed. The idea was to anchor a
  clip frame's edge to a cutoff bar's fill texture so the push distance is
  secret-driven in C. It didn't produce the intended clipping. (Exact failure not
  fully diagnosed — likely the fill-texture edge doesn't drive the anchored
  frame's clip geometry as hoped, and/or secret geometry doesn't propagate
  across frames.)

## MaskTexture gives a transparent hide (lower bound solved; exact-match walled)
The black squares are **beatable** with a `MaskTexture` instead of an opaque
occluder. A `MaskTexture` multiplies the target texture's alpha, so hiding a
miss goes to **alpha 0 (truly transparent)**, not an opaque paint-over — and it
works in normal blend, so matching icons stay crisp (unlike `CLAMPTOBLACKADDITIVE`,
which needs additive blend and washes the icon out).

**The load-bearing question was whether a *secret*-driven StatusBar fill could
drive a MaskTexture's coverage in C** — the same cross-frame secret-geometry bet
that clip-as-mask *lost*. Verified via `/ia demomask` that it does **not**
lose here:
- Plain-int (`demomask <value> [X]`): fill drives mask coverage; `value<X`
  renders the icon **transparent** (magenta backdrop shows through), not a square.
- **Secret** (`demomask secret <X>`): feeding a real aura secret with `X=1` shows
  the icon (fill forced full), with a huge `X` goes transparent (fill forced
  empty). So secret geometry **does** reach the mask. This is the win clip lacked.

Mechanism: one texture per (slot, target X). A `keep` StatusBar (`min=X-1,max=X`,
fed the secret via `SetValue`) has an invisible fill (colour alpha 0); a
`MaskTexture` is `SetAllPoints`'d to that bar's fill texture and `AddMaskTexture`'d
onto the icon. Fill full (`value>=X`) ⇒ mask covers ⇒ icon kept; empty ⇒ icon at
alpha 0. Why clip failed but this works is unconfirmed — likely masks and clip are
different rendering subsystems and mask geometry tracks the fill-texture edge.

### The upper-bound wall (SOLVED by demomask3's dual punch, below)
A transparent LOWER bound (`value>=X`) is solved and reliable. Exact `==X` needs
an UPPER bound too, and that is blocked by a hard constraint discovered here:

- **You cannot do arithmetic on a secret.** Verified via `/ia demomask
  negsecret`: feeding `-value` (to invert a bar) errors — negation is a forbidden
  op, same class as branching. `string.format("%d", secret)` is also out (it's a
  forbidden *observation*, and `SetValue` wants a number, not a string anyway).
  **The secret reaches C only through `SetValue`, untouched.**
- StatusBar fill = `clamp((value-min)/(max-min))` is **monotonically increasing**
  in `value`. So C can compute `value >= threshold` (rising fill) but never
  `value <= threshold`. `min>max` to flip it → engine makes the range degenerate
  (fill always empty; verified, `demomask2` match case went blank).
- MaskTextures only **AND** (intersect) and an empty mask hides everything, so
  there is no way to express a NOT from keep-masks.

Net: with only `>=` predicates and AND, you can't build the `< X+1` upper bound.
The ONE construct that yields an upper bound WITHOUT inversion is a mask **window**
spanning between TWO rising bars' fill *edges* (left = bar B `min=X,max=X+1` fill
right edge, right = bar A `min=X-1,max=X` fill right edge); the band is nonzero
only for `X <= value < X+1`. `/ia demomask2` (plain int) tested it:
- **Match (`value==X`) is crisp** — window opens, icon shows.
- **Misses leak a FAINT/partial icon** instead of full transparency. The window
  logic is exact (verified on paper); the failure is *rendering*: edge-anchoring a
  mask to a fill texture is unreliable when the bar HARD-CLAMPS (value far outside
  `[min,max]`) — likely the fill texture is hidden at 0%/100% and its anchor edge
  goes stale. `SetAllPoints(fillTex)` (whole-rect copy) stays reliable at hard
  clamp; single-edge anchors do not.

**(Superseded by demomask3 below.)** The old plan was to harden the window with
stacked copies (residual r^2); demomask3 replaces the collapsing window outright.

### demomask3: hole-punch upper bound (round 1 TESTED; round 2 awaiting test)
Key realization: **a mask's polarity comes from its texture + wrap, not its
geometry.** A mask whose texture reads as HIDE under a keep-outside wrap
(`CLAMPTOWHITE`) is a **hole-punch**: covered = hide, uncovered = keep. Anchored
to bar B's fill, the monotone rising fill directly expresses
`hide iff value >= X+1` — the upper bound with no window and no inversion.
Exact equality = TWO masks: proven mLo + punch.

**Round 1 results (in-game 2026-07-04, screenshot verified):**
- **Masks sample the ALPHA channel.** Opaque-black (`Black8x8`) mask textures
  keep everything → useless. `Trans8x8` (alpha 0) punches. (Black variants
  dropped from the matrix.)
- **THE UPPER BOUND HIDE WORKS.** Full-area transparent punch at `v>=X+1` hides
  the icon CLEAN — first-ever transparent upper bound, zero ghost. True for
  both the anchored punch and **mask-as-fill** (`B:SetStatusBarTexture(mask)`
  **is accepted** and C drives the mask rect). `CLAMPTOWHITE` and `CLAMPTOBLACK`
  behaved identically (both keep-outside).
- **New defect: the collapsed punch DIMS the match.** At `v==X` (bar B at 0%)
  the icon renders dimmed ~half. Unified theory of the residual: a COLLAPSED
  mask blends in a fraction r of its own interior — the white window ghosted
  (`lerp(0,1,r)=r`), the collapsed punch dims (`lerp(1,0,r)=1-r`). Same
  artifact, opposite sign. (Zero-area mLo hiding "cleanly" fits too: its
  residual makes the *hide* less than perfect by r·0 — invisible.)
- **slide failed outright** (icon stayed at `v>X`): mixed frame/texture edge
  anchors don't track. Edge anchors remain the untrustworthy primitive.

**Round 2: never collapse the punch where it's visible.** Bar B went NON-binary
— frame TWICE the icon width extending LEFT of the icon, `min=X-1, max=X+1`, so
integer values land on 0% / 50% / 100% fills and the 50% (match) fill parks the
punch just left of the icon at full area instead of collapsing it.

**Round 2 results (in-game 2026-07-04, screenshot verified):**
- **Match FIXED**: `v==X` full crisp icon in wpunch, wfill AND slide2; `v>=X+1`
  stayed a clean transparent hide. The wide-bar parking trick works.
- **slide2 worked** → PURE fill-texture edge anchors DO track at 0% and at
  hard-clamp 100%; round 1's slide died only to its mixed frame/texture anchor
  pair. Edge anchors on a fill are usable after all.
- `half` diagnostic: right half-icon rendered → CLAMPTOWHITE outside = keep.
- **Defect moved to `v<X`**: faint ghost in the bar-driven columns — that's
  **mLo's own zero-area collapse residual**, no longer fully suppressed. The
  general law, confirmed three times now: **any mask that collapses while
  visible leaks ~r of its interior** (white window → ghost r; collapsed punch →
  dim 1−r; collapsed mLo → ghost r).

**Round 3 RESULTS (in-game 2026-07-04): WIN.** `dual T/CTW`, `dualf T/CTW` and
`dual T/CTB` all read GREEN / full-brightness ICON / GREEN (match matched the
unmasked `ref` column; `plo` showed its expected GREEN/ICON/ICON). Transparent
exact-match equality achieved with zero residual. **The dual punch (anchored,
CTW) is now the production matcher** (`AcquireMatcher` rewritten; mLo + window
code deleted). Remaining verification: `/ia demomask3 secret 1` and
`secret 99999999` (expect all cells clean green in both), then live tracked
buffs via the real display.

**Round 3 design: DUAL PUNCH — no keep-mask, nothing ever
collapses while visible.** The unmasked icon is visible by default; both bounds
are transparent punches at constant full area that just park off-icon when not
hiding:
- **punchLo** (replaces mLo): BLo = icon rect inflated by margin m, binary
  `min=X-1,max=X`; punch spans `[fill.right .. fill.right+size+2m]` (slide2's
  validated anchor pattern, re-anchored every feed). `v<X` → fill 0% → punch
  sits exactly over the icon (±m) → the full-area clean hide round 1 proved;
  `v>=X` → fill 100% → parked m px right of the icon.
- **punchHi**: round 2's proven wide punch (parked left at 50%=match, covers at
  100%). Its only collapse is at `v<X` — where punchLo has already zeroed the
  icon, and a collapsed punch can only dim.
Net: `v<X` punchLo covers (clean) / `v==X` both parked off-icon, NO collapse
anywhere (full icon) / `v>X` punchHi covers (clean). Two masks total.

Columns: `dual` (CTW + CTB), `dualf` (punchHi as mask-as-fill,
`SetStatusBarTexture(mask)`, accepted per round 1), `plo` (DIAGNOSTIC: punchLo
alone → wants GREEN/ICON/ICON), `ref` (DIAGNOSTIC: unmasked icon → ICON×3,
brightness ground truth). Winning look: GREEN / full ICON as bright as ref /
GREEN.

`/ia demomask3 secret [X]` feeds a real aura secret to every cell (X=1 → all
cells clean green via `value>=X+1`; huge X → clean green via `value<X`). Ships
`Textures/Trans8x8.tga` (+`Black8x8.tga`, now unused) — 8x8 32-bit TGA; masks
can't `SetColorTexture`. New texture FILES need a full client restart (none
added since round 1, so /reload suffices for Lua-only rounds).
If a round-3 column wins: rewrite `AcquireMatcher` to punchLo + punchHi (2
masks, BLo + wide BHi), delete mLo and the window code. Production note: the
wide BHi bar overhangs the slot's left edge and punchLo's parked mask overhangs
the right; fills are invisible and masks are per-icon, so overlap with
neighbouring slots is harmless.

**If/when the window is made reliable:** rewrite `BuildSlotBars` to it, drop the
opaque `WHITE8X8` mask. Bonus: transparent misses don't clobber, so overlapping
matchers stop fighting — may let the aura-mirror one-secret-per-slot layout relax.

### (Superseded) the black-squares limitation
Historically the opaque mask meant non-tracked auras rendered as opaque dark
squares, and hiding them was thought impossible without a forbidden secret-decision
(the UI draws onto the 3D scene with no per-addon alpha buffer to erase back to
transparent). The MaskTexture result above overturns this. Fallback mitigation if
integration hits a wall: a solid backing panel the same colour as the squares
(`/ia panel on`); `HARMFUL` (few debuffs) stays much cleaner than `HELPFUL`.

## Multi-stack architecture (IMPLEMENTED 2026-07-05 — awaiting in-game verification)
The matcher tech above (dual punch) is solved and unit-agnostic — it was
always just fed whatever `spellId` a scan handed it. What was hardcoded was
everything *around* it: one global unit (`player`), one filter, one priority
list, one free-floating anchor. This phase generalizes that into N independent
**stacks**, each with its own unit, aura type, spell-ID priority list, layout,
and anchor — configured through a real AceGUI/AceConfig options UI instead of
slash-only. Nameplate anchoring was initially deferred as structurally
different (plates are recycled across units at runtime, unlike a fixed frame),
then brought into this same pass once `LibNameplateRegistry-1.0` was vendored.

### Libraries vendored (copied from local sibling addons, not authored)
- **Ace3 subset** (`AceAddon-3.0`, `AceConsole-3.0`, `AceEvent-3.0`,
  `AceDB-3.0`, `AceGUI-3.0`, `AceConfig-3.0` + deps `LibStub`/
  `CallbackHandler-1.0`) — copied wholesale from `ArenaTalentReminder/Libs`
  (same author, already has exactly this subset embedded + a working
  `.pkgmeta` externals block, reused verbatim for future `svn`/packager
  refreshes).
- **`LibGetFrame-1.0`** (MINOR 74) — copied from
  `NorthernSkyRaidTools/Libs/LibGetFrame-1.0`. Resolves the actual unit-frame
  widget for a unit token across ElvUI/oUF-based addons/default Blizzard
  frames without this addon needing to know which UI the user runs. Key API:
  `lib.GetUnitFrame(unit, opt)` (alias `GetFrame`), plus callbacks
  `FRAME_UNIT_ADDED`/`FRAME_UNIT_UPDATE`/`FRAME_UNIT_REMOVED` for frames that
  resolve late. Used for **fixed-unit stacks** (player/target/focus/pet/
  partyN/arenaN/bossN) anchoring to that unit's frame.
- **`LibNameplateRegistry-1.0` — REMOVED (2026-07-05).** Was a GUID-aware
  nameplate tracker used to fan a nameplate stack out across every plate
  matching a scope (hostile/friendly/all/named-player), surviving plate
  recycling. Dropped after it started erroring on load
  (`LibNameplateRegistry-1.0.lua:508: attempt to compare field 'name' (a
  secret string value...)`): WoW now returns a **secret string** from
  `UnitName()` for nameplate unit tokens (the same class of restriction this
  addon works around for aura spellIDs — see "Verified in-game" above — now
  extended to nameplate names), and the library's own bookkeeping does a
  plain `==` compare against it, forbidden the same way `if value >= max` is
  forbidden on a secret spellId. Rather than fork and patch a library whose
  core assumption (plate names are plain comparable strings) no longer
  holds, `kind="nameplate"` was collapsed to target-only (see Bug #2 below
  and the Runtime section) — that only needs
  `C_NamePlate.GetNamePlateForUnit("target")`, a plain Blizzard API, no
  library.
- No `.pkgmeta` external URL was recovered for LibGetFrame (only found as a
  pre-vendored local copy) — it's committed to the repo instead of fetched by
  the packager; refresh manually.

### Data model — AceDB, replaces the flat `ImportantAurasDB`
`profile.stacks[stackID] = { kind, ... }`, `stackID` a stable string key (not
an array index) so stacks survive reorder/delete cleanly.
- `kind = "unit"` (fixed frame): `units` (ORDERED array of tokens drawn from
  `ID.UNIT_TOKEN_ORDER` in Config.lua — player/target/focus/pet/party1-4/
  arena1-3/arenapet1-3/boss1-5; the stack fans out to ONE DISPLAY INSTANCE
  PER TOKEN — Next Features #12, replaced the old single `unit` field
  2026-07-05, per-stack migration in InitDB. Note: WoW has no "party5" token
  — a full 5-player group is player + party1-4 — and modern arenas cap at 3
  enemies), `group` (free-text label, Next Features #5: stacks sharing one
  nest under a tree node in the GUI and export/import as a set; "" = none),
  `filter` (HARMFUL/HELPFUL/CAST), `targets`/`order` (unchanged
  priority-list semantics), `layout`, `iconSize`, `spacing`, `bg`, `panel`,
  `panelPad`, `locked`, `anchor = { useFrame, myPoint, relPoint, x, y, point
  (free-float fallback) }`. `useFrame=true` resolves via LibGetFrame
  PER-INSTANCE (each instance follows its own unit's frame) and falls back
  to the free-float point if resolution fails; free-floating instances of a
  multi-unit stack share the one saved point, offset vertically by instance
  index into a column, and only instance 1 is draggable (its drag-stop
  calls `FrameAnchor.RepositionAll()` so siblings resettle immediately).
- `kind = "nameplate"`: same targets/order/filter/layout/iconSize/spacing/
  group, no `units` used — always follows the current target's nameplate
  (see Runtime section below) — and `anchor = { myPoint, relPoint, x, y }`
  only (a plate IS the anchor — no free-float fallback, no lock/drag).
- **Migration**: on load, if `ImportantAurasDB` is in the old flat shape
  (`.targets` at the top level, no `.profiles`), stash it before `AceDB:New`,
  then seed exactly one `kind="unit"`, `unit="player"`, `useFrame=false` stack
  from the stashed values post-init, so upgrading users keep their tracked IDs
  and position.

### Runtime — per-instance `Stack`, two managers
`Core.lua` used module-level locals (`anchor`/`slots`/`pool`) — one instance
only. Split:
- **`Stack.lua`**: the existing production machinery (`AcquireMatcher`,
  `SetMatcherTarget`, `BuildSlotBars`, `AcquireSlot`, `FeedSlot`, `Layout`,
  `Scan`, anchor creation/drag) lifted out and parameterized on a `self`
  instance instead of module locals. Punch-mask mechanics are untouched by
  this refactor. The matcher **pool stays one shared/global pool** across all
  stacks (matchers are generic, keyed only by icon+geometry, not by unit) —
  slots stay per-instance (aura index is per-unit-scan).
- **`StackManager.lua`**: reads `profile.stacks` where `kind="unit"`,
  creates/destroys `Stack` instances — since Next Features #12 (2026-07-05)
  no longer 1:1 but ONE PER TOKEN in `sdb.units`, each instance owning a
  `CreateFrame` that self-registers `UNIT_AURA` (or the global
  `UNIT_SPELLCAST_SUCCEEDED` + Lua token compare, for CAST) for its own
  unit token, with `stack.unitToken`/`stack.freeIndex` stamped on the
  instance. `live[id] = { sig, instances }` where `sig` is
  `concat(units)|filter` — any edit to either tears the whole entry down.
  Anchoring goes through `FrameAnchor.lua` (the `LibGetFrame` wrapper).
- **`NameplateStackManager.lua`**: `kind="nameplate"` configs always follow
  the player's current target (see the library-removal note above) — at most
  one live `Stack` instance per stack id, no fan-out. Resolves the target's
  plate directly via `C_NamePlate.GetNamePlateForUnit("target")` (no library,
  no `FrameAnchor`/LibGetFrame — the plate frame IS the anchor target) and
  registers `UNIT_AURA`/`UNIT_SPELLCAST_SUCCEEDED` against the `"target"`
  token. `PLAYER_TARGET_CHANGED`/`NAME_PLATE_UNIT_ADDED`/
  `NAME_PLATE_UNIT_REMOVED` all drive one `RepositionAll()` that destroys and
  recreates the instance whenever the resolved plate frame's identity changes
  (target changed, or the plate recycled while still targeted), and destroys
  it outright when there's no target or the target's plate isn't on screen.
- **`Options.lua`**: `AceConfig`/`AceGUI` options tree — a stack list/select
  group, each stack's fields (`kind` selector swaps unit-token vs
  nameplate-scope fields; spell-ID priority editor reuses the existing
  add/remove/reorder semantics), add/delete stack, registered via
  `AceConfigDialog:AddToBlizOptions`. `/ia` (no args) opens this GUI;
  `/ia lock|unlock` stayed as a quick global toggle at the time. The old
  per-target slash commands (`add`/`remove`/`prio`/`layout`/`filter`/`size`)
  moved into the GUI since they're per-stack now; the diagnostic commands
  (`demo`/`demomask*`/`sweep`/`probe`) stayed as-is at the time (all later
  removed — see Next Features #10 and the current Slash commands section).
- **`Core.lua`** shrank to bootstrap glue (`ADDON_LOADED`/`PLAYER_LOGIN` →
  `InitDB` → `StackManager`/`NameplateStackManager` rebuild); the diagnostic
  demo functions stayed put, untouched, at the time (later fully removed).

Before wiring calls against any vendored library, read its actual source for
exact signatures (`AceAddon-3.0.lua`'s `NewAddon`, `AceDB-3.0.lua`'s `New`) —
don't trust remembered API shapes for argument order.

### Implementation status
All of the above is written and in the tree (`Libs/`, `.pkgmeta`, `Config.lua`,
`FrameAnchor.lua`, `Stack.lua`, `StackManager.lua`,
`NameplateStackManager.lua`, `Options.lua`, trimmed `Core.lua`). Statically
verified: every new/vendored `.lua` file parses clean under `luac5.1 -p`
(WoW's Lua 5.1), every file the `.toc` lists resolves on disk, the vendored
Ace3 tree matches `ArenaTalentReminder`'s known-working copy file-for-file,
and `Textures/Trans8x8.tga` (referenced by `Stack.lua`) exists. **Not yet
verified: actually loading in the WoW client** — no in-game testing has
happened yet (see Possible next steps).

**Gotcha hit and fixed during implementation**: AceDB-3.0's `defaults` table
is re-applied via `copyDefaults` on *every* login for any key still missing
from the profile — so a starter/example stack must NOT live under
`DEFAULTS.profile.stacks["1"]`, or deleting it in the GUI would silently
resurrect it on the next `/reload`. Fixed by seeding the starter stack
manually in `ID.InitDB()` (only when `profile.stacks` is empty and there's no
legacy data to migrate), with `DEFAULTS.profile.stacks = {}` staying inert.
Worth remembering if any future default-seeded content is added.

## Files
- `ImportantAuras.toc` — set `## Interface` to the live build if out-of-date;
  lists vendored `Libs/` + all addon Lua files in load order.
- `.pkgmeta` — Ace3 externals (packager refresh); LibGetFrame committed
  directly (no recovered external URL).
- `Libs/` — vendored Ace3 subset, `LibGetFrame-1.0`.
- `Config.lua` — AceDB defaults/migration + `/ia` slash config (`reset`).
- `FrameAnchor.lua` — `LibGetFrame` wrapper for fixed-unit stack anchoring.
- `Stack.lua` — per-instance matcher (reveal+mask) pool, slots, layout, scan.
- `StackManager.lua` — creates/destroys `kind="unit"` `Stack` instances.
- `NameplateStackManager.lua` — target-only nameplate anchoring (via
  `C_NamePlate.GetNamePlateForUnit`) for `kind="nameplate"` configs.
- `SpellSearch.lua` — spellbook + `ID.SpellDB` name search, harmful/helpful
  filtering, and by-id name/icon lookup for the "Add spell" box (Next
  Features #8/#8.1/#13).
- `SpellSearchBox.lua` — custom AceGUI widget (`"IA-SpellSearchBox"`) giving
  the "Add spell" box a live-as-you-type results dropdown, styled after
  TellMeWhen_Options's Suggester (Next Features #8.1 addendum).
- `Data/SpellDB.lua` — static, offline-generated `{id, name}` table (Next
  Features #13). **Regenerated 2026-07-05 from simc data: 31,044 spells**
  (1.5MB, client build 12.0.7.68275, simc `midnight` branch) — baseline
  abilities, talents, PvP talents, and separately-id'd aura spells all
  covered; see the simc-rewrite bullet under Next Features #13 for the
  source switch and remaining edge cases.
- `Tools/generate_spelldb.js` — offline Node script that regenerates
  `Data/SpellDB.lua`. Not run by the game — the addon can't make network
  calls, so this is a manual step: `node Tools/generate_spelldb.js` (no
  credentials; `--branch <simc-branch>` to match another expansion,
  `--file <allspells.txt>` for fully-offline runs). **Rewritten 2026-07-05**
  to parse SimulationCraft's `SpellDataDump/allspells.txt` (client-extracted
  DB2 spell data, regenerated per build, fetched from GitHub) instead of
  walking the Battle.net Game Data API — ~31k spells vs ~3k, now covering
  baseline abilities and PvP talents the API walk structurally missed; an
  `EXTRA_SPELLS` list in the script hand-patches known simc-whitelist gaps
  (Polymorph 118 etc.).
- `Transfer.lua` — import/export (Next Features #4/#5): a Lua-literal-subset
  serializer + a no-loadstring recursive-descent parser ("IA1:" prefix), a
  whitelist/clamp sanitizer every imported stack is rebuilt through, and the
  copy/paste dialog frame. Round-trip + hostile-input tested offline under
  lua5.1 (see Possible next steps).
- `Presets.lua` — one-click presets (Next Features #6): data-driven
  `ID.Presets` list consumed by the Options "Presets" page; ships Arena Kick
  Tracker (CAST stack over arena1-3+arenapet1-3) and Party Kick Tracker
  (player+party1-4), both built on the multi-unit fan-out.
- `Options.lua` — AceConfig/AceGUI options UI + slash entry point.
- `Core.lua` — bootstrap glue only (`ADDON_LOADED`/`PLAYER_LOGIN` handler); the
  diagnostic mask demos it used to hold were removed 2026-07-05.

## Slash commands
`/ia` (opens the AceConfig GUI), `/ia reset` (wipes the saved profile back to
a fresh install: one default `player`/`HARMFUL` stack, same seed
`NewDefaultStack` uses on first install). Per-stack target/priority/layout/
filter/size editing lives in the GUI (see Multi-stack architecture above) —
no longer slash commands. `/ia lock`/`unlock` and all diagnostic commands
(`demo`/`demomask`/`demomask2`/`demomask3`/`sweep`/`probe`) were removed
2026-07-05 (Next Features #10) now that the mask design is
production-verified and stable; the per-stack "locked" checkbox in the GUI
(for free-floating unit stacks) still works exactly as before, only the
global slash shortcut is gone.

## Possible next steps
- **In-game verification of the 2026-07-05 feature pass (#4/#5/#6/#9/#12 +
  Bug #3 hardening — all luac5.1-clean and, for Transfer.lua's
  serializer/parser/sanitizer, offline-tested 18/18 under real lua5.1, but
  none of it loaded in the client yet)**:
  1. `/reload`, confirm no errors; existing stacks migrate `unit` →
     `units={unit}` silently (icons show exactly where they did before).
  2. Multi-unit (#12): on a stack, check Player + Party1 toggles; confirm
     one icon column free-floating (only the top instance draggable, drag
     moves the column) and per-unit frames when "Attach to unit frame" is
     on. Confirm arena pet toggles exist.
  3. Preview (#9): click Preview on a stack with tracked spells; top-
     priority icon flashes ~3s on every instance, then normal scanning
     resumes (no stuck icon; no flash on a nameplate stack with no target).
  4. Groups (#5): set the same Group name on two stacks, confirm they nest
     under a tree node; Export group → dialog with selectable string.
  5. Import/Export (#4): export a stack, `/ia reset`, import the string,
     confirm it comes back intact (targets, order, units, anchor). Try
     pasting garbage → red-error-free "import failed" chat message.
  6. Presets (#6): open Presets page, create the Party Kick Tracker; in a
     party (or solo — the player toggle alone suffices), have someone (or
     yourself) interrupt: icon flashes on the caster's frame for ~4s.
  7. Bug #3: with "Attach to unit frame" on, confirm no blue drag-hint
     square appears at any point after `/reload`, even before unit frames
     resolve.
- **Verify the simc-based SpellDB in-game** (generator rewritten + run
  2026-07-05: 31,044 spells from simc's `midnight` allspells.txt): `/reload`,
  confirm no errors loading the now-1.5MB `Data/SpellDB.lua`; search "Kick"
  and "Polymorph" (baseline, previously impossible) and "Precognition" (PvP
  talent) on a class that doesn't know them; watch for typing lag in the
  search box — the linear scan in `SpellSearch.Search` is now over ~31k
  entries per (debounced) keystroke, expected fine but unmeasured.
- **Verify the broadened spell search in-game (Next Features #13)**:
  3. `/reload`, confirm no Lua errors loading the regenerated `Data/SpellDB.lua`.
  4. In a stack's "Add spell" box, search for a spell from a class/spec you
     don't play (e.g. "Kingsbane" as a non-Rogue) and confirm it now appears.
  5. On a HARMFUL stack, search a friendly-only buff name and confirm it's
     filtered out; on a HELPFUL stack, confirm a debuff name is filtered out;
     on a CAST stack, confirm both show (no filtering).
  6. Type a bare spell id that doesn't match the stack's filter type and
     confirm it's still offered (numeric entry is intentionally unfiltered).
- **In-game verification of the multi-stack system (nothing below has been
  tested live yet)**:
  1. `/reload`, confirm no Lua errors on load (old `ImportantAurasDB` — if any
     — migrates into one `player`/`HARMFUL` stack with prior targets intact;
     a truly fresh install seeds the same example stack as before).
  2. Bare `/ia` opens the AceConfig GUI; add a second stack targeting
     `target` with a known debuff ID and confirm it shows/hides correctly.
  3. If in a group/arena, set a stack's unit to `party1`/`arena1` with
     "Attach to unit frame" on and confirm it anchors to the resolved unit
     frame; otherwise confirm the free-float fallback still drags/saves
     position like before.
  4. Toggle lock/unlock, delete a stack, confirm clean teardown (no orphaned
     visible icons).
  5. Create a `kind="nameplate"` stack (a known debuff ID), target a hostile
     mob, and confirm the icon appears anchored to its nameplate; change
     target and confirm it moves to the new target's plate (or disappears if
     you clear target / the plate isn't on screen).
  6. Set a stack's Aura type to "Spell Cast" with a known spell ID for that
     unit (e.g. your own player casting a tracked spell, or an interrupt kick
     ID on target/arena); confirm the icon flashes on cast and clears itself
     after `castDuration` seconds, with no persistent icon left behind and no
     errors from feeding a cast's spellID (may be secret) into the matcher.
- Verify secrets through the dual punch (`/ia demomask3 secret 1` +
  `secret 99999999`) and the live display with real tracked buffs.
- **In-game verification of the cooldown DRAIN (Next Features #16 — the
  DurationObject rework that replaced the #7/#14 swipe; nothing below has
  been tested live yet)**:
  1. `/reload`, confirm no Lua errors and NO red warning prints ("cooldown
     display unavailable" = DurationObject API missing; "cooldown drain
     disabled" = SetTimerDuration rejected a value — report either).
  2. Aura stack tracking a real buff/debuff: confirm a dark vertical drain
     over the matched icon that empties as the aura runs out, updates
     correctly on aura refresh, and shows NOTHING over untracked auras'
     (transparent) slots — the leak check.
  3. If the bar renders statically full or empty instead of animating,
     suspect the SetTimerDuration min/max assumption (bar is 0..1) and
     report what it looks like.
  4. A PERMANENT tracked buff (no expiration) should show a clean icon with
     no dark overlay (DoesAuraHaveExpirationTime skip).
  5. CAST stack (own Kick): icon + drain for the kick's base cooldown, no
     Lua error, drain hidden again after the hide timer collapses the slot.
  6. Toggle "Cooldown drain" off/on, confirm hide/show without errors, in
     both aura and CAST stacks.
- **In-game verification of the spell table + search (Next Features #8/#8.1,
  nothing below has been tested live yet)**:
  1. `/reload`, confirm no Lua errors; open a stack, confirm existing tracked
     spell ids render as a table (icon + id + name) in priority order instead
     of the old text box.
  2. Click Up/Down on a couple of rows, confirm the priority order actually
     changes (highest-priority icon still wins on-screen when two tracked
     auras are up at once).
  3. Click Remove on a row, confirm it disappears from both the table and the
     live display.
  4. In "Add spell", type a plain number and press Enter -- confirm it's
     appended at the bottom of the table; type several comma-separated
     numbers and confirm all get added (bulk paste path).
  5. Type part of the name of a spell you know (e.g. a class ability) and
     press Enter -- confirm a results list appears below with icon/id/name,
     and clicking one adds it to the table and clears the search box.
  6. Type a name that matches nothing (or check with `C_SpellBook` simply not
     existing on this client) -- confirm "No known spells match." instead of
     an error, and that the row-icon lookup (`C_Spell.GetSpellInfo`) still
     shows a name/icon for ids added by number even though they weren't found
     via search.
  7. **8.1 addendum, nothing below has been tested live yet**: confirm the
     "Add spell" box now shows a floating dropdown of results *while typing*
     a spell name (no need to press Enter), that it's drawn above the
     Interface Options panel and not clipped by the scrolling options pane,
     and that clicking a result row adds it and clears the box. Type a
     single numeric id and confirm one preview row (icon + id + name, or
     "Unknown spell" for a bogus id) appears immediately; click it and
     confirm it's added. Type several comma/space-separated ids and press
     Enter -- confirm all get added in bulk with no dropdown shown for that
     case (unchanged from before the addendum). Watch for any Lua error on
     opening a stack's options, typing, or closing/reopening the panel
     (checks that the dropdown is properly hidden/cleaned up on
     `OnRelease` and doesn't leak a visible orphaned frame).
- Verify `## Interface` against current client.
- **DONE (2026-07-05, Next Features #10/#11).** Legacy demos (`demo`,
  `demomask`, `demomask2`, `demomask3`, `sweep`, `probe`) and `/ia
  lock`/`unlock` removed from `Config.lua`/`Core.lua`; `Textures/Black8x8.tga`
  (unused) deleted. `/ia reset` added (see Slash commands section). All
  three files parse clean under `luac5.1 -p`. **Not yet verified in-game.**



## Next Features
1. **REVERTED (2026-07-05).** Was: a `nameplateScope = "name"` option
   matching named players via `LibNameplateRegistry`-provided plate names.
   Reverted along with the rest of the nameplate fan-out scopes (hostile/
   friendly/all) when that library started erroring — see the "REMOVED"
   library note above and Bug #2. Matching arbitrary player-name STRINGS
   against a value that may now be secret has no known solution analogous to
   the dual-punch spellID trick (strings aren't StatusBar-fillable), so this
   is shelved, not just reimplemented without the library.
2. **IMPLEMENTED (2026-07-05, awaiting in-game verification)**: `filter`
   gained a third value, `"CAST"` ("Spell Cast" in the Aura Type dropdown),
   for both `kind="unit"` and `kind="nameplate"` stacks. Unlike HARMFUL/
   HELPFUL, which continuously scan aura presence off `UNIT_AURA`, CAST has
   no ongoing state to scan back down from — a cast is a momentary event —
   so it works differently end to end:
   - `StackManager`/`NameplateStackManager` register `UNIT_SPELLCAST_SUCCEEDED`
     instead of `UNIT_AURA` when `sdb.filter == "CAST"` (global `RegisterEvent`
     + a plain string unit-token compare in Lua, since `RegisterUnitEvent` has
     no cast-event support; the payload spellID is left untouched and may
     still be secret). Both managers now track which `filter` an event frame
     was registered for, alongside `unit`, so a filter edit tears down and
     recreates the entry like a unit-token change would.
   - `Stack:OnCast(spellID)` (new, `Stack.lua`) feeds the cast's spellID into
     slot 1's matchers (same `FeedSlot`/dual-punch mechanics as aura mode,
     unmodified) and shows it for `sdb.castDuration` seconds via
     `C_Timer.After`, then calls `Layout(0)` to hide — a monotonically
     increasing token guards against an earlier timer hiding a later cast's
     flash. `Stack:Rebuild()` branches: CAST mode calls `Layout(0)` (no
     persistent state to rescan) instead of `Scan()`.
   - New per-stack field `castDuration` (seconds, default 2) in the schema,
     `NewDefaultStack`/`ExtractLegacyStack`/the GUI's "Add stack" defaults,
     and a new range option in `Options.lua` (hidden unless filter=="CAST");
     the Layout dropdown and its Spacing option are hidden in CAST mode since
     only one slot is ever active.
   - For `kind="nameplate"` stacks (now target-only, see the library-removal
     note above): a filter edit tears down the live instance and
     `NameplateStackManager.Rebuild()`'s trailing `RepositionAll()` recreates
     it immediately against the same target plate if one is current — no
     "wait for a recycle" limitation here since there's no fan-out to
     rescan.
3. **IMPLEMENTED (2026-07-05, awaiting in-game verification)**: `kind`
   (Anchor kind select) and `unit` moved in `Options.lua`'s `BuildStackArgs`
   to right after `anchorHeader` (orders 10.1/10.2), inside the Anchor
   section instead of up near Name/Enabled/Aura type. Same fields, same
   `hidden` logic, just relocated. (`nameplateScope`/`names` no longer exist
   — see Next Features #1.)
  3.1. **IMPLEMENTED (2026-07-05, awaiting in-game verification)**: `locked`'s
   `hidden` now also returns true when `sdb.kind == "unit" and
   sdb.anchor.useFrame` (previously only hid for `kind == "nameplate"`) — the
   checkbox now only shows for a free-floating unit stack, since
   frame/plate-attached stacks have no draggable position to lock.
4. **IMPLEMENTED (2026-07-05, awaiting in-game verification).** Import/Export
   stack feature — new file `Transfer.lua`. Export: "Export stack" button per
   stack (and "Export group" on each group node) opens a dialog with a
   selectable `"IA1:"`-prefixed string (auto-highlighted for Ctrl+C). Import:
   "Import" button at the options root opens the same dialog in paste mode.
   Format is a Lua-table-literal SUBSET serialized by hand and parsed by a
   small recursive-descent parser — **never loadstring'd** (untrusted input);
   every imported stack is rebuilt field-by-field onto `ID.NewDefaultStack()`
   by `SanitizeStack` (whitelisted keys, type checks, numeric clamps, unit
   tokens/anchor points restricted to known sets, free-float anchor forced
   relative to UIParent, order/targets reconciled+deduped). Serializer,
   parser, sanitizer, and group round-trip all covered by an offline lua5.1
   test (escape-heavy names, floats, injection attempt, 50-deep nesting bomb
   → depth-capped, malformed-field clamping) — 18/18 passed; only the dialog
   frame itself needs in-game eyes. `SanitizeStack` is also run on EXPORT so
   shared strings carry exactly the schema, no junk keys.
5. **IMPLEMENTED (2026-07-05, awaiting in-game verification).** Stack groups
   — new per-stack `group` string (input field next to Name; empty = none).
   `BuildOptions` sorts stack ids numerically then hangs stacks with a group
   under a `group_<name>` tree node (childGroups="tree", so stacks appear as
   its children) carrying an "Export group" button;
   `Transfer.ExportGroup(name)` serializes every member as
   `{type="group",group=name,stacks={...}}` and import re-creates all of
   them with the group name applied. Editing the Group field calls
   `Options.Rebuild()` (tree topology change, same reason as rename).
6. **IMPLEMENTED (2026-07-05, awaiting in-game verification).** Presets page
   — new file `Presets.lua` defines `ID.Presets` (name/desc/create per
   entry); Options root gained a "Presets" tree node with a description +
   Create button per preset. Ships two: **Arena Kick Tracker** (one CAST
   stack, units arena1-3 + arenapet1-3 — pets covered for Spell Lock/Axe
   Toss — group "Arena Kicks", frame-attached RIGHT→LEFT of each arena
   frame) and **Party Kick Tracker (M+)** (player+party1-4, group "Party
   Kicks"), both tracking every class interrupt by its well-known CAST id
   (`INTERRUPT_IDS` in Presets.lua: Pummel 6552, Rebuke 96231, Counter Shot
   147362, Muzzle 187707, Kick 1766, Silence 15487, Mind Freeze 47528, Wind
   Shear 57994, Counterspell 2139, Spell Lock 19647, Axe Toss 89766, Spell
   Lock-sacrifice 132409, Spear Hand Strike 116705, Skull Bash 106839, Solar
   Beam 78675, Disrupt 183752, Quell 351338 — CAST ids are exactly right
   here since UNIT_SPELLCAST_SUCCEEDED payloads carry the cast id),
   castDuration 4s ≈ lockout. Presets just create normal stacks; users
   tweak/delete them like any other.
7. **Cooldown swipe IMPLEMENTED (2026-07-05, awaiting in-game verification),
   text/stack count deferred.** The swipe is a `Texture`
   (`Cooldown:GetSwipeTexture()`), so it reuses the exact same `m.pLo`/`m.pHi`
   dual-punch masks already built for the icon -- one `CooldownFrameTemplate`
   per matcher (`m.cd` in `Stack.lua`'s `AcquireMatcher`), masked once at
   creation; if `GetSwipeTexture()` doesn't return a maskable texture on this
   client build, `m.cdMaskable` stays false and the widget is hidden forever
   (fail closed, not open). Fed via `Stack:FeedSlot(slot, spellId, duration,
   expirationTime)` -- `Scan` passes the real (possibly secret) aura fields;
   `OnCast` (CAST mode has no duration data) passes plain `0, 0` literals,
   never an `or`-fallback on the real fields (an `or` is a truthiness check,
   which errors on a secret same as `if value >= max`). A `self.cdBroken`
   latch disables the swipe stack-wide (with one warning print) if
   `SetCooldown` ever rejects the values, in case `duration`/`expirationTime`
   turn out to be secret after all -- unconfirmed, but Blizzard's own default
   UI renders live cooldown swipes off this same data today, so it's unlikely.
   New per-stack field `showCooldown` (bool, default true, hidden for CAST).
   **Text (cooldown countdown number) and stack count are NOT implemented**:
   both need a `FontString:SetText`, and FontStrings can't be masked, so
   there's no way to hide a count/countdown for an aura that isn't one of the
   slot's tracked targets without leaking "something is here" for every aura
   on the unit -- the same wall this item's own parenthetical already flags
   for spell-name text. A future fix would render the count as a pre-baked
   digit *icon* matched via the existing dual-punch mechanism (bounded values,
   same trick already used for spell IDs), not as text.
8. **IMPLEMENTED (2026-07-05, awaiting in-game verification), scope note
   below.** / 8.1 **IMPLEMENTED same pass** -- the two were built together
   since the search box and the table share one `sdb.order`/`sdb.targets`
   edit path. New file `SpellSearch.lua`, wired into `Options.lua`'s
   `BuildSpellListArgs` (replaces the old single multiline comma/space text
   box).
   - **8.1 table**: one AceConfig `inline` group per tracked spell id
     (`spellRow<i>`, forces its own line regardless of pane width), each a
     `description` (icon via a `|TfileID:16:16:0:0|t` escape baked straight
     into the label text, not the widget's separate `image` field -- that
     field's own layout code puts the icon *above* the text instead of
     beside it once the control is narrower than ~200px, which every
     reasonably-sized row here is) plus three `execute` buttons (Up/Down/
     Remove). Up/Down swap adjacent entries in `sdb.order`; all three call
     `ID.RefreshAll()` (rescans/repositions) then `ID.Options.Rebuild()`
     (rows are keyed/ordered by array index at build time, so a reorder or
     delete needs the args table regenerated, not just `NotifyChange` --
     same reason add/delete-stack already call `Rebuild()`).
   - **8 search**: one `input` box ("Add spell (ID, or name to search your
     spellbook)") below the table. Digits/commas/spaces only -> bulk numeric
     add (old paste-many-ids-at-once behavior, preserved). Any letters ->
     `ID.SpellSearch.Search(query)`, results rendered as clickable
     full-width `execute` rows underneath (icon + id + name), click to add.
     **Superseded by the 8.1 addendum below** (this AceConfig-native version
     only refreshed results on Enter/tab-out).

   **8.1 Addendum (IMPLEMENTED 2026-07-05, awaiting in-game verification):
   live-as-you-type search, styled after TellMeWhen_Options's Suggester.**
   Confirmed by reading `AceConfigDialog-3.0.lua`'s `FeedOptions` directly:
   for `type="input"` it wires only `control:SetCallback("OnEnterPressed",
   ActivateControl)` -- never `"OnTextChanged"` -- so the AceConfig-native
   search box above could only ever refresh on Enter/tab-out. TellMeWhen's
   own spell/item/aura search box (`Components/Core/Suggester/Suggester.lua`
   + `Suggester.xml`) solves the identical problem by not going through
   AceConfig at all: a plain `EditBox` with `OnTextChanged` hooked directly
   (debounced 0.05s), feeding a floating results list (`SuggestionList`,
   parented straight to a top-level frame, `FULLSCREEN_DIALOG`-esque
   strata) that shows/hides live, with icon+id+name rows, click-to-insert,
   arrow-key/Tab navigation, and per-category row coloring (buff/debuff/
   class spell/item/etc, since TMW searches across many spell/item/aura
   sources at once).
   - New file **`SpellSearchBox.lua`** registers a custom AceGUI widget
     type, `"IA-SpellSearchBox"`, modeled on the stock `AceGUIWidget-
     EditBox.lua` (copied structure: `frame`/`editbox`/`label`, same
     `OnAcquire`/`SetDisabled`/`SetText`/`GetText`/`SetLabel` method
     surface) plus a `dropdown` results frame. `BuildSpellListArgs`'s
     `addSpell` field now sets `dialogControl = "IA-SpellSearchBox"`
     (AceConfigDialog's documented escape hatch for swapping in a custom
     widget per-field: `CreateControl(v.dialogControl or v.control, ...)`)
     with `get()` always returning `""` and `set()` a no-op -- the widget
     manages everything itself and is passed its real callbacks via
     `arg = { onAdd = ..., onCommit = ... }`, using AceConfigDialog's other
     documented extension point, `control.SetCustomData` /
     `option.arg` (`InjectInfo`: `if control.SetCustomData and option.arg
     then safecall(control.SetCustomData, control, option.arg) end`).
   - **Why raw `HookScript`, not AceGUI's `Fire`/`SetCallback`.**
     AceConfigDialog unconditionally calls `control:SetCallback
     ("OnEnterPressed", ActivateControl)` on every `type="input"` field --
     a second `self:SetCallback("OnEnterPressed", ...)` from inside the
     widget would just overwrite that registration (Ace's callback table
     holds one function per event name per object). So the widget never
     calls `self:Fire(...)` at all; instead it hooks the underlying
     Blizzard `EditBox`'s native scripts directly with `editbox:HookScript
     ("OnTextChanged"/"OnEnterPressed"/"OnEscapePressed"/"OnEditFocusLost",
     ...)`, which layers on top of (rather than replacing) whatever AceGUI
     itself wires -- since this widget's constructor never wires those
     scripts itself either, there's nothing to conflict with. `set()`
     being a no-op means `ActivateControl`'s eventual `option.set(info,
     "")` call (which never actually fires, since `Fire` is never called)
     wouldn't have mattered anyway.
   - **Query routing**, decided in `OnQueryChanged`: all-digits -> single
     spell id, preview immediately via `ID.SpellSearch.GetDisplay(id)` (no
     debounce needed, it's a cheap by-id lookup) as one clickable dropdown
     row; digits/commas/spaces (multiple ids) -> no preview, committed in
     bulk on Enter only (old paste-many-ids behavior, unchanged, handled by
     the `OnEnterPressed` hook); anything with letters -> debounced (0.15s,
     `C_Timer.NewTimer`, cancels the previous timer the same way TMW's
     `SUGTimer` does) call to `ID.SpellSearch.Search(query, 8)`, results
     rendered into pooled row buttons in the `dropdown` frame.
   - **Dropdown positioning avoids the options-pane scrollframe entirely.**
     `dropdown` is parented directly to `UIParent` (not to the widget's own
     `frame`, which AceGUI reparents into the options tree's scrolling
     content area) with `SetFrameStrata("FULLSCREEN_DIALOG")`, anchored
     with a two-point `TOPLEFT`/`TOPRIGHT` -> widget-frame `BOTTOMLEFT`/
     `BOTTOMRIGHT` pair so its width auto-tracks the control without manual
     `SetWidth` calls -- same pattern AceGUI's own `Dropdown-Pullout`
     widget uses for its popout list, and the same reason TMW's own
     `SuggestionList` is parented to a top-level frame rather than nested
     under the in-editor scrollframe.
   - **Row-click vs. losing edit focus race**: clicking a dropdown row is a
     mouse-down (which would normally blur the `EditBox` via
     `OnEditFocusLost`, hiding `dropdown` before the button's `OnClick`
     fires) followed by a mouse-up. Fixed with the exact same override TMW
     uses: `editbox:HasStickyFocus()` returns true whenever `dropdown` is
     shown and the left mouse button is currently held, which Blizzard's
     `EditBox` checks before actually clearing focus -- unverified against
     a live client this session (no game client available), but taken on
     faith from a widely-used, actively-maintained addon's real,
     presumably-tested source rather than re-derived from scratch.
   - Simplification vs. TMW: no arrow-key/Tab navigation, no per-category
     row coloring (our search only spans the player+pet spellbook, so
     there's no buff/debuff/class-spell/item source to color-differentiate
     the way TMW's multi-source suggester does) -- click-to-add only, per
     explicit scope decision when this addendum was requested.
   - **Search scope is the player's own spellbook (+ pet), not the whole
     game's spells** -- `C_Spell.GetSpellInfo(id)` (used for 8.1's
     name/icon-by-id display) resolves ANY spell id in the game, but there
     is no Blizzard API to search all spell *names* without already knowing
     the id, so `SpellSearch.BuildCache()` enumerates
     `C_SpellBook.GetNumSpellBookSkillLines()` /
     `GetSpellBookSkillLineInfo()` / `GetSpellBookItemInfo()` (11.0's
     `C_SpellBook` namespace, filtered to `Enum.SpellBookItemType.Spell` to
     skip flyouts/pet-action entries whose `actionID` isn't a real spell
     id), which only finds spells the player has learned. Fine for personal
     cooldown/interrupt tracking; won't find an enemy-only ability by name
     (type its numeric id instead). Cache is lazy + invalidated on
     `SPELLS_CHANGED`/`LEARNED_SPELL_IN_TAB`/`PLAYER_TALENT_UPDATE`/
     `PLAYER_ENTERING_WORLD`, not rebuilt per keystroke.
   - All `C_SpellBook`/`Enum.SpellBookItemType` access is `pcall`-wrapped and
     presence-checked; if the namespace doesn't exist or errors on this
     client build, `Search()` just returns no results (fails closed, same
     pattern as the cooldown-swipe latch) rather than erroring the options
     panel.
9. **IMPLEMENTED (2026-07-05, awaiting in-game verification)** as a button,
   not an always-on edit mode. "Preview" execute per stack (next to
   Group) → `ID.PreviewStack(id)` → `Stack:Preview()` on every live
   instance via both managers' new `ForStack(id, fn)`. Preview feeds the
   top-priority tracked id into slot 1 — the fed value is the tracked id
   itself, a PLAIN int the user typed, so the dual punch trivially matches
   (`value == X`) with no secret anywhere in the path — shows `Layout(1)`
   for 3s, then `Rebuild()` restores reality. A `self.previewing` flag makes
   `Scan()` early-return so a UNIT_AURA firing mid-preview can't stomp it;
   a token guards stacked previews the same way `OnCast` timers do. For a
   nameplate stack with no current target plate there's no live instance, so
   the button silently does nothing (nothing exists to show the icon on).
10. **IMPLEMENTED (2026-07-05, awaiting in-game verification).** Removed
    `probe`, all `demo*`/`sweep` prototype functions (`Core.lua`), and `/ia
    lock`/`unlock` (`Config.lua`). The per-stack `locked` checkbox in the GUI
    (Options.lua) is untouched — it's what actually drives dragging now (see
    `FrameAnchor.lua`); only the global slash shortcut is gone. `Core.lua` is
    now just the `ADDON_LOADED`/`PLAYER_LOGIN` bootstrap. Also deleted the
    now-fully-unused `Textures/Black8x8.tga`.
11. **IMPLEMENTED (2026-07-05, awaiting in-game verification).** `/ia reset`
    calls `ID.db:ResetProfile()` then reseeds one default stack via the
    existing `NewDefaultStack()` (same helper `InitDB` uses for a fresh
    install), reconciles its order, and calls `ID.RefreshAll()` +
    `ID.Options.Rebuild()` so the GUI and live display both reflect the reset
    immediately.

12. **IMPLEMENTED (2026-07-05, awaiting in-game verification).** Multi-frame
    targeting for a single stack (e.g. Kingsbane on player+party1+party2 in
    arena). Schema: `unit` → ordered `units` array (see the Data model
    section; migrated per-stack in InitDB). `StackManager` fans a config out
    to one Stack instance + event frame per token (see the Runtime section).
    GUI: the Unit dropdown was replaced by ONE TOGGLE PER TOKEN in canonical
    order (an AceConfig multiselect renders its values in `pairs()` order,
    i.e. randomly — individual toggles with explicit `order` keep the grid
    stable), with token list per the request: arena1-3 and arenapet1-3 added;
    **party1-4, not party1-5** — WoW has no "party5" token (a 5-player group
    is player + party1-4); arena4/arena5 dropped from the picker to match
    modern 3-cap arenas (an old saved stack with arena4 keeps working — the
    migration/manager don't validate tokens, only the GUI toggles and the
    import sanitizer restrict to `ID.UNIT_TOKEN_ORDER`). Frame-attach
    resolves per-instance; free-float instances form a column under the one
    saved point with only instance 1 draggable.

13. **IMPLEMENTED (2026-07-05); generator later rewritten to simc data and
    run for real the same day (31,044 spells — see final bullet); in-game
    unverified.**
    "Add spell" search broadened beyond the player's own spellbook, plus
    live buff/debuff filtering, addressing the gap where e.g. searching
    "Kingsbane" found nothing on a non-Rogue.
    - **Broader search corpus**: WoW's in-game Lua has no "search all spells"
      API and addons can't make network calls, so the fix is a static data
      file, `Data/SpellDB.lua` (`ID.SpellDB = {{id=,name=},...}`), built
      **offline** by a new script, `Tools/generate_spelldb.js` (plain Node
      18+, no deps), which the user runs manually against Blizzard's
      Battle.net Game Data API (`BNET_CLIENT_ID`/`BNET_CLIENT_SECRET` env
      vars from a free app at develop.battle.net/access/clients). It walks
      `playable-class/index` → each class's specializations →
      `playable-specialization/{id}` and every matching
      `talent-tree/{treeId}/playable-specialization/{specId}`, and
      recursively scans every response for `{spell:{id,name}}` sub-objects
      rather than hardcoding a specific array path — the exact nested field
      names in those endpoints' JSON couldn't be verified live (Blizzard's
      dev portal docs are a JS SPA that plain fetches can't render, and no
      API credentials were available while writing the script), so the
      recursive walk is a deliberate hedge against a guessed schema being
      wrong. `SpellSearch.lua`'s `BuildCache()` now seeds from the player's
      live spellbook first (keeps real icon data), then layers in
      `ID.SpellDB` entries for anything not already known (icon intentionally
      left nil in the data file and always resolved live via
      `C_Spell.GetSpellInfo`, so it can't go stale across content patches).
      Ships with `Data/SpellDB.lua` empty (`ID.SpellDB = {}`) until someone
      runs the generator — search still works at the old spellbook-only
      scope until then.
    - **Buff/debuff filtering**: `C_Spell.IsSpellHarmful(id)` /
      `IsSpellHelpful(id)` — confirmed via Warcraft Wiki to exist and work for
      *any* spell id, not just ones on an active aura — let filtering happen
      live with no curated metadata needed. `SpellSearch.lua`'s `Search`
      gained a third `filterType` param (`"HARMFUL"`/`"HELPFUL"`, or nil for
      `"CAST"` stacks which have no aura polarity); non-matching entries are
      dropped before the result cap, failing OPEN (kept, not hidden) if the
      `pcall`'d check errors, since this is a search UI, not a security
      boundary. Threaded through from `Options.lua`'s `BuildSpellListArgs` —
      `addSpell`'s `arg.getFilter = function() return sdb.filter end` (a
      closure, not a captured value, so it tracks the stack's current filter
      live without needing a full `Options.Rebuild()` on every filter
      change) — into `SpellSearchBox.lua`'s `SetCustomData`/`OnQueryChanged`.
      A bare numeric spell id typed directly is **not** filtered (an explicit
      typed id is a deliberate action, not an ambiguous name match).
    - **GENERATOR HAS NOW BEEN RUN (2026-07-05): 3,158 spells in
      `Data/SpellDB.lua`.** The recursive-walk hedge worked. Coverage audit
      of the real output (sanity-check session, same day):
      - **Talent spells: covered.** Kingsbane (385627), Hex, Mass Polymorph,
        talent-based interrupts (Mind Freeze/Wind Shear/Rebuke/Skull Bash/
        Spear Hand Strike/Counter Shot/Muzzle/Solar Beam/Quell) all present.
      - **Baseline (non-talent) class abilities: NOT covered** — Kick 1766,
        Pummel 6552, Counterspell 2139, Silence 15487, Disrupt 183752,
        Polymorph 118, Fear 5782 were all absent. No Game Data endpoint lists
        a class's baseline spells. **Gap CLOSED by the simc rewrite (final
        bullet)** — all of these are now in SpellDB.
      - **PvP talents: NOT covered by the original walk** (no Precognition/
        Thoughtsteal in the output — they are NOT inlined in the
        playable-specialization or talent-tree responses after all). The
        generator was extended same-day to walk `pvp-talent/index` →
        `pvp-talent/{id}`, but that walk was never re-run — **moot after the
        simc rewrite (final bullet)**, whose corpus includes PvP talents.
      - **THE KINGSBANE ID TRAP — DEBUNKED (same day, via simc effect
        data).** The original audit believed the debuff Kingsbane applies
        was **192853**, a different id from the cast (385627), with no
        harvestable source mapping cast→aura. simc's per-effect dump
        (extracted from the client's own SpellEffect.db2) settles it:
        385627's effect #4 is `Apply Aura | Periodic Damage: nature every 2
        seconds, Target: Targeted Enemy` — **the debuff IS 385627, same id
        as the cast**. 192853 is a dead Legion-era leftover (still named
        "Kingsbane" in the client's 413k-row SpellName table, hence the
        confusion; Wowhead's 192759 likewise). General rules learned from
        the same data: (a) a cast whose own effect list has `Apply Aura`
        applies that aura under ITS OWN id — the common case; (b) where a
        cast triggers a separately-id'd spell, the link is
        `SpellEffect.db2`'s EffectTriggerSpell (7,679 `Trigger Spell:`
        lines in allspells.txt) and the triggered spell usually shares the
        cast's name, so BOTH ids surface in name search; (c) only
        server-side dummy-script auras are unmappable from ANY data source
        (not simc, not Wowhead, not the client files) — for those the
        addon-as-probe trick ("add all candidate ids, get the aura applied
        once, remove the ones that stay dark") remains the only way, since
        aura spellIds are secret in-game and can't be dumped. The Options
        note under the spell list was rewritten accordingly (rare-case
        wording, Kingsbane example removed).
      - Also fixed this pass: `SpellSearch.BuildCache()`'s pet-bank scan was
        iterating the PLAYER's skill-line index ranges against the Pet bank
        (mostly out-of-range reads); pet spells are indexed
        `1..HasPetSpells()` directly, now scanned that way.
      In-game verification of the broadened search UX and harmful/helpful
      filtering still hasn't happened.
    - **GENERATOR REWRITTEN + RE-RUN (2026-07-05, later the same day):
      source switched from the Battle.net API walk to SimulationCraft's
      `SpellDataDump/allspells.txt`** — a plain-text dump of the spell data
      simc extracts from the game client's own DB2 files, regenerated per
      build by the simc team and fetched with one HTTPS GET from GitHub (no
      API keys; the old Battle.net OAuth flow is gone — see git history for
      that version). The `midnight` branch matches the 12.x client
      (`--branch thewarwithin` etc. for older ones). Result: **31,044
      spells**
      in `Data/SpellDB.lua` (1.5MB, luac5.1-clean, source build
      12.0.7.68275) vs the API walk's 3,158 — baseline abilities
      (Kick/Pummel/Counterspell/Silence/Disrupt/Fear/Sap/Blind/...), PvP
      talents (Precognition 377360 AND its separately-id'd 4s aura 377362),
      and hidden/separately-id'd aura spells all present ([Hidden]/[Passive]
      dump entries deliberately kept — aura spells are often flagged
      hidden). simc's corpus is a combat-sim whitelist, not the client's
      full ~413k-row SpellName table (deliberately NOT used as the source:
      overwhelmingly internal junk that would flood name search, and
      id→name display already resolves live via `C_Spell.GetSpellInfo`);
      whitelist gaps found by spot-checking ~50 common trackable spells are
      hand-patched via `EXTRA_SPELLS` in the script — Polymorph 118,
      Repentance 20066, Mesmerize 115268, Spell Lock-sacrifice 132409 were
      the only misses. For future needs beyond names: wago.tools serves the
      raw client DB2 tables as CSV (`https://wago.tools/db2/SpellName/csv`,
      `.../SpellEffect/csv` incl. EffectTriggerSpell for cast→aura links).
      In-game verification pending (see Possible next steps).
  14. **IMPLEMENTED (2026-07-05, awaiting in-game verification).** CAST-mode
    icons now show for the cast spell's COOLDOWN with a cooldown swipe,
    instead of a fixed `castDuration` flash. The secret-safety trick: the
    cast payload spellID may be secret, so we never look up ITS cooldown —
    but each matcher owns one PLAIN tracked id (`m.targetID`, stamped in
    `SetMatcherTarget`), so `Stack:OnCast` gives EVERY matcher its own
    spell's cooldown swipe and its own plain `C_Timer` hide; for the one
    visible (matched, decided in C by the dual punch) matcher those are
    exactly right, and for the transparent misses they're invisible no-ops.
    Cooldown source (`Stack:ResolveCastCooldown(id)`, all pcall-guarded):
    **originally** `C_Spell.GetSpellCooldown` (as requested) ONLY when the
    instance's `unitToken == "player"` — it reflects the player's OWN live
    cooldown state (already ticking, includes talent CDR), which is
    meaningless or actively wrong for another unit's cast (e.g. an enemy
    rogue's Kick would read the player's Kick CD) — otherwise the static base
    cooldown via `GetSpellBaseCooldown(id)` (global API, resolves ANY spell
    id, learned or not; enemy talent CDR invisible to us, acceptable).
    **REVERTED (2026-07-06, Bug #6)**: `C_Spell.GetSpellCooldown`'s `duration`
    field turned out to be secret even for the player's own spell — see the
    new "Verified in-game" bullet — so `ResolveCastCooldown` now ALWAYS uses
    the static base cooldown, for every unit including the player (talent CDR
    invisible to us across the board, not just for other units). If the spell
    has no base cooldown at all (e.g. tracking a no-CD cast), falls back to
    the old `db.castDuration` flash (that field is now fallback-only; it has
    no GUI option). Supporting changes: per-matcher `castHideToken` invalidated
    on `ReleaseMatcher` (a pooled matcher reacquired elsewhere can't be hidden
    by a stale timer) and on every `FeedSlot` feed (a fresh feed/Preview
    supersedes a pending cast-expiry hide; `FeedSlot` also re-`Show()`s
    matchers for the CAST-stack Preview path); slot-level `castToken` backstop
    `Layout(0)` now fires after the LONGEST per-matcher remaining time. The
    "Cooldown swipe" toggle (`showCooldown`) is no longer hidden for CAST
    stacks and gates the swipe there too; the kick presets' `castDuration=4`
    kept as fallback. In-game checks: party/arena kick cast → icon with swipe
    for the kick's real CD (own casts: exact incl. CDR; others: base CD);
    two casts of different-CD tracked spells in a row → second cast replaces
    the first, each hides on its own schedule; a no-CD tracked cast still
    flashes ~castDuration; toggle off → icon shows for the CD but no swipe;
    watch for the red "cooldown swipe disabled" print (SetCooldown rejected
    values).

15. **IMPLEMENTED (2026-07-06, awaiting in-game verification).** CAST-mode's
    per-matcher/per-slot timers (Next Features #14) are sized off the round's
    cooldown state, so they go stale across a zone change or a new arena
    round (opponents/cooldowns reset, but a pending `C_Timer.After` from the
    old round would still fire and hide/collapse based on the old timing).
    `Core.lua`'s bootstrap frame now also listens for `PLAYER_ENTERING_WORLD`,
    `ZONE_CHANGED_NEW_AREA`, and `UNIT_SPELLCAST_SUCCEEDED` filtered to
    `unit=="player"` and `spellID==228212` ("Arena Starting Area Marker" —
    the round-start marker, ported from **ArenaTalentReminder**, a sibling
    addon by the same author; it's a spell CAST the player auto-casts at the
    start of every round including Solo Shuffle, not a buff/aura, despite
    that being the original assumption). All three call the existing
    `ID.RefreshAll()` (`Options.lua:53`, already used by every options-GUI
    edit), which `Rebuild()`s every live stack instance — `BuildSlotBars`
    releases every matcher (bumping `castHideToken`, so any pending cast-hide
    or backstop timer referencing the old matcher becomes a no-op) and either
    `Layout(0)`s (CAST stacks, nothing to rescan) or re-`Scan()`s (aura
    stacks). No new cleanup method was needed — this reuses the same
    Rebuild path config edits already exercise. In-game checks: mid-swipe on
    a CAST stack, zone out of the arena (or wait for a new Solo Shuffle
    round) and confirm the icon clears immediately with no stale swipe
    surviving into the new zone/round, and no Lua errors from the new event
    registrations.

16. **IMPLEMENTED (2026-07-06, awaiting in-game verification): cooldown
    display reworked from the radial Cooldown widget to a masked StatusBar
    "drain", via 12.0's DurationObject API.** This replaces Next Features
    #7/#14's swipe rendering wholesale and closes Bug #6's still-open
    follow-up. Two independent reasons the swipe could never render:
    - **`Cooldown:GetSwipeTexture` does not exist** (confirmed on
      warcraft.wiki: not in the Cooldown widget method list, its API page
      404s). The swipe is internal to the widget, not a retrievable Texture,
      so `m.cdMaskable` was ALWAYS false on every client and `m.cd` stayed
      permanently hidden (fail-closed) — that's exactly what Bug #6's
      "couldn't mask the swipe texture" print was reporting. No masking
      means no way to hide a miss-matcher's swipe, so the widget is
      unusable for this addon, period.
    - **The aura path computed `expirationTime - duration` in Lua** —
      arithmetic on secrets, which always errored in combat; the pcall
      turned that into a permanent `cdBroken` latch instead of a swipe.
      Also moot since 12.0.1: `SetCooldown`/`SetCooldownFromExpirationTime`/
      `SetCooldownDuration`/`SetCooldownUNIX` no longer accept secrets from
      tainted code at all — `SetCooldownFromDurationObject` is the only
      sanctioned secret path into a Cooldown widget.
    **The sanctioned 12.0 machinery (researched on warcraft.wiki
    2026-07-06):** DurationObjects (`C_DurationUtil.CreateDuration()`,
    setters `SetTimeFromStart(startTime, duration[, modRate])`/
    `SetTimeFromEnd(endTime, duration[, modRate])`/`SetTimeSpan(start,
    end)`) carry possibly-secret timings from C to C without Lua reading
    them; `C_UnitAuras.GetAuraDuration(unit, auraInstanceID)` builds one
    for an aura from PLAIN args; `StatusBar:SetTimerDuration(durObj,
    interpolation, direction)` (Enum.StatusBarInterpolation.Immediate=0,
    Enum.StatusBarTimerDirection.RemainingTime=1) animates a bar fill from
    one entirely in C. A StatusBar fill texture is a texture WE own — so it
    takes the dual-punch masks, unlike the swipe.
    **New design (`Stack.lua`):** per-matcher `m.cdBar`, a VERTICAL
    StatusBar `SetAllPoints`'d over the icon, fill = dark translucent
    (0,0,0,0.6), min/max 0..1, direction RemainingTime (dark fill height =
    remaining fraction, drains downward). Its fill texture carries its OWN
    clones of both punch masks (`m.cdLo`/`m.cdHi` — not shared with the
    icon's `m.pLo`/`m.pHi`, to avoid betting on cross-frame AddMaskTexture;
    `m.cdLo` is re-anchored alongside `m.pLo` in `RefreshPunchLoAnchors`,
    `m.cdHi` rides `bhi`'s fill like `m.pHi` does), so the drain is
    transparent exactly when the icon is. Gated on `C_DurationUtil` +
    `SetTimerDuration` existing (`m.cdOK`; one-time warning print if not).
    Feeds: aura path — `Scan` calls `C_UnitAuras.GetAuraDuration(unit,
    data.auraInstanceID)` (pcall'd) and passes the DurationObject to the
    reshaped `FeedSlot(slot, secretSpellId, durObj)`; permanent auras are
    skipped via `C_UnitAuras.DoesAuraHaveExpirationTime` (pcall'd +
    `issecretvalue`-guarded, fails open) so a never-expiring buff doesn't
    park a full dark bar on its icon. CAST path — `OnCast` sets the
    matcher's own reusable `m.durObj:SetTimeFromStart(now, baseCD)` from
    ResolveCastCooldown's PLAIN numbers (that function is unchanged — its
    pcall'd GetSpellBaseCooldown + castDuration fallback semantics were
    already correct) and hands it to the same bar, so both modes share one
    display path; the plain hide-timer arithmetic in OnCast is untouched.
    `Preview` passes nil durObj (no drain). The Cooldown widget, `m.cd`,
    `cdMaskable`, and the `ID.cdMaskWarned` diagnostic are DELETED; the
    `cdBroken` latch stays (now trips only if SetTimerDuration/
    SetTimeFromStart themselves reject values). Options toggle renamed
    "Cooldown drain" (same `showCooldown` field). Known cosmetic change:
    it's a linear drain, not a radial swipe — a radial swipe is
    structurally impossible to mask. **RADIAL CONSIDERED AND DECLINED
    (2026-07-06, user decision).** Recap of why radial is off the table so it
    doesn't resurface: the rotation swipe is the internal `Cooldown` widget,
    whose swipe is not a retrievable/maskable Texture, so it can't be hidden
    on the (secret) non-matching auras. For AURA stacks it's impossible — we
    never know in Lua which auras match our tracked list (spellId secret), so
    an unmaskable swipe would render on every aura's slot and leak "something
    is here" on untracked buffs; `SetCooldownFromDurationObject` could DRIVE
    it secret-safely, but driving was never the blocker, hiding-on-miss is.
    For plain-payload CAST stacks it WOULD be technically doable (own casts
    are plain post-Bug #7, so the exact matched matcher + its cooldown are
    known in Lua — a normal `Cooldown` widget on just that one matcher, no
    masking needed), but the user chose the uniform linear drain over a
    CAST-radial / aura-linear split appearance. So: linear everywhere,
    deliberately. The min/max assumption was RESOLVED
    2026-07-06 by reading Blizzard's own code (Bug #7 follow-up, below):
    `SetTimerDuration` puts the bar in a self-managed timer mode (min/max
    irrelevant while attached), and calling `SetMinMaxValues` afterwards is
    how Blizzard CANCELS timer mode / releases the duration object
    (`EncounterTimelineTimerEvent.lua`'s `Reset` does `SetMinMaxValues(0,0)`
    exactly for that) — so never touch the drain bar's min/max after feeding
    it a timer. NEW RISK found in `SimpleStatusBarAPIDocumentation.lua`:
    `SetTimerDuration` is marked `SecretArguments = "AllowedWhenUntainted"`
    (contrast `SetValue`: `"AllowedWhenTainted"`), suggesting tainted addon
    code may NOT pass a SECRET-carrying DurationObject — fine for the CAST
    path (plain values), but the aura path's `GetAuraDuration` objects carry
    secret timings and may be rejected → the `cdBroken` latch + "drain
    disabled" print would fire on the first real aura scan. Watch for that
    in-game; if it fires, the aura drain needs a different sanctioned path.

## Bugs
1. **FIXED (2026-07-05).** Updating stack name in the stack edit screen
   didn't update the stack name in the left hand stack list. Root cause:
   `Options.lua`'s `name` field setter only called `NotifyOptionsChanged()`
   (`AceConfigRegistry:NotifyChange`), but the tree's group label string is
   baked in once by `BuildStackArgs` at `ID.Options.Rebuild()` time —
   `NotifyChange` alone can't refresh a label that was never regenerated.
   Fixed by calling `ID.Options.Rebuild()` directly from the setter (same
   pattern already used by add/delete/reorder-spell handlers).
2. **FIXED (2026-07-05) via removing the fan-out nameplate feature**, not a
   patch. Was: a Lua error using nameplates —
   `LibNameplateRegistry-1.0.lua:508: attempt to compare field 'name' (a
   secret string value, while execution tainted by 'ImportantAuras')`, fired
   from `NAME_PLATE_UNIT_ADDED`. Root cause: WoW now returns a **secret
   string** from `UnitName()` for nameplate unit tokens — the same class of
   restriction this addon works around for aura spellIDs, now extended to
   nameplate names — and the vendored library's own bookkeeping does a plain
   `==` compare against it, forbidden the same way `if value >= max` is on a
   secret spellId. Rather than fork/patch the library, `kind="nameplate"`
   was collapsed to target-only (see the "REMOVED" library note and Next
   Features #1) — that only needs a plain Blizzard API
   (`C_NamePlate.GetNamePlateForUnit`), no library, no name comparisons.
3. **HARDENED (2026-07-05, awaiting in-game verification).** When attaching
   to unit frames, a blue square drag-hint anchor was still visible. Static
   review had found no bug in the resolved-frame path; leading theory was
   the FALLBACK path: `LibGetFrame`'s cache fills asynchronously after
   login, so early `Reposition()` calls (and any unit whose frame never
   resolves — empty party slot, unsupported frame addon) drop into
   `ApplyFreeFloat`, which used to show the drag hint purely off
   `db.locked`. Fixed by policy rather than by chasing the race:
   `ApplyFreeFloat` now never shows the hint nor enables dragging while
   `db.anchor.useFrame` is true — an "attached" stack positions at the
   fallback point if it must, but it never presents as draggable (its
   offset is GUI-set, so dragging it had no stable meaning anyway; this
   matches the existing decision to hide the "Locked" toggle for attached
   stacks, Next Features #3.1). If a blue square still appears after this,
   the repro questions from the original report still apply.
4. **FIXED (2026-07-05).** Two Lua errors seen together in-game: repeated
   (7x) `Options.lua:83: attempt to call a nil value` down through
   `BuildSpellListArgs`/`BuildStackArgs`/`BuildOptions`/`Init`, plus
   `Frame:RegisterEvent(): Attempt to register unknown event
   "LEARNED_SPELL_IN_TAB"`. One root cause: `SpellSearch.lua`'s top-level
   `watcher:RegisterEvent(event)` loop errored on `LEARNED_SPELL_IN_TAB` (not
   a valid event on this client), and since that call sits at file-scope
   (outside any function), the error aborted the rest of `SpellSearch.lua`'s
   execution — `ID.SpellSearch.GetDisplay`/`.Search` (defined further down
   the file) never got assigned, leaving `ID.SpellSearch` an empty table.
   Every tracked-spell row `Options.lua` builds calls
   `ID.SpellSearch.GetDisplay(spellID)`, hence one nil-call error per tracked
   spell (7 total across the user's stacks) on every `Init`/`Options.Open`.
   Fixed by wrapping each `RegisterEvent` call in `pcall` so one bad/removed
   event name can't take down the rest of the file.
5. **FIXED (2026-07-06), first real in-game test of a `useFrame` unit stack.**
   User reported a frame-attached stack (player, own Kick) not anchoring
   correctly under **Ellesmere UI**. Root cause found by reading
   `EllesmereUIUnitFrames.lua`: it builds its own `oUF` frames but spawns
   them under fixed, addon-prefixed global names
   (`EllesmereUIUnitFrames_Player`/`_Target`/`_Focus`/`_Pet`/`_TargetTarget`/
   `_FocusTarget`/`_Boss<n>`), not the `oUF_<suffix><Unit>`-style names
   `LibGetFrame-1.0`'s generic-oUF regexes match — not a stale-version
   problem, just a naming convention LibGetFrame's author never saw. Fixed
   in `FrameAnchor.lua` (not the vendored library, which is refreshed from
   upstream and shouldn't carry local patches — see the Files section):
   `GetEllesmereFrame(unit)`, a small table of the fixed names above, gated
   on `C_AddOns.IsAddOnLoaded("EllesmereUIUnitFrames")` so it can't misfire
   under any other UI, checked *before* `LGF.GetUnitFrame(unit)` in
   `FrameAnchor.Reposition`. party/arena tokens aren't covered — Ellesmere's
   own unit-frames module doesn't spawn those (its separate
   `EllesmereUIRaidFrames` addon skins Blizzard's default `CompactParty`/
   `CompactRaid` frames instead, which LibGetFrame already matches
   natively) — untested but should already work. Arena enemy frames have no
   LibGetFrame support at all (not Ellesmere-specific, a pre-existing gap);
   those stacks fall back to free-float regardless of UI addon.
6. **ROOT-CAUSED AND FIXED (2026-07-06).** User reported no cooldown swipe on
   a CAST-mode stack tracking their own Kick (icon itself showed/hid
   correctly). First pass added the diagnostic described below and the user's
   next report was the new "cooldown swipe unavailable... couldn't mask the
   swipe texture" message — but the REAL error, caught separately in the same
   session, was a raw Lua error one call further down the stack:
   `Stack.lua:342: attempt to compare field 'duration' (a secret number
   value...)` in `ResolveCastCooldown`. Root cause: `C_Spell.GetSpellCooldown`
   (only ever called for the player's own cast, per Next Features #14's
   original design) returns a secret `duration` field — comparing
   `cd.duration > 0` to decide whether the live data was usable is exactly
   the forbidden secret-branch this addon has hit before for aura spellIds
   (see "Verified in-game"), just newly discovered on cooldown state. That
   error aborted `OnCast` before it ever reached `SetCooldown` — the masking
   diagnostic below was a real-but-secondary symptom (the mask/texture setup
   at matcher-creation time is unrelated and may still be worth revisiting,
   but wasn't the actual blocker for a swipe ever appearing). Fixed by
   dropping `C_Spell.GetSpellCooldown` entirely — `ResolveCastCooldown` now
   always uses the static `GetSpellBaseCooldown` value, for every unit
   including the player (see Next Features #14 and "Verified in-game" for the
   full writeup). The masking diagnostics added during triage stay in place
   (harmless, and useful if the swipe still doesn't render now that
   `SetCooldown` will actually be reached): `Stack.lua`'s `AcquireMatcher`
   pcall-guards `Cooldown:AddMaskTexture` alongside `GetSwipeTexture` and
   prints a one-time red message (`ID.cdMaskWarned` latch) if either fails.
   In-game check: cast Kick again, confirm the swipe now animates over the
   real base-cooldown duration with no Lua error. If the masking diagnostic
   fires instead, the swipe stays permanently hidden (fail-closed — `m.cd` is
   `Hide()`'d at matcher-creation time and `OnCast` never un-hides it) even
   though `SetCooldown` itself will now succeed — that's a separate,
   still-open problem worth a follow-up.
7. **FIXED (2026-07-06, awaiting in-game verification).** CAST-mode icon
   appeared for a split second then vanished (user testing own Kick, no Lua
   errors). Root cause: `Stack:OnCast` fed EVERY `UNIT_SPELLCAST_SUCCEEDED`
   payload into slot 1's matchers — and that event fires for every successful
   cast on the unit, including hidden proc/internal spells and whatever the
   player presses on the next GCD. Each new cast overwrote the bars' values
   and the dual punch (correctly) blanked the icon on the mismatch, so a
   tracked cast's display only survived until the unit's next cast event. The
   hide timers (#14) were never the problem. Fixed with a Lua-side guard at
   the top of `OnCast`: when the payload spellID is PLAIN (checked via
   `issecretvalue`; own-cast payloads are verified plain in-game — Core.lua's
   `a3 == ROUND_START_SPELL` compare on this same payload never errored
   during the user's kick testing), an id not found in `db.order` returns
   early without touching the bars. A SECRET payload can't be compared, so it
   falls through and feeds C exactly as before — meaning for units whose cast
   payloads are secret, an untracked cast still blanks a live display
   (StatusBars have no latch; no known C-side fix — same class of limitation
   as the shelved name-matching in Next Features #1). In-game check: cast
   Kick then keep attacking/casting — icon + drain should persist the full
   base CD (~15s) through other casts and procs; a second cast of a
   DIFFERENT tracked spell should still replace it.
   **Follow-up (same day, VERIFIED-in-game the icon persists now): the drain
   bar was still invisible.** Root cause: `m.cdBar.tex` was created with
   `CreateTexture(nil, "ARTWORK")` but never given texture CONTENT —
   `SetStatusBarColor` is only a vertex color multiplied over the texels,
   and a file-less texture has no texels, so the fill rendered nothing (the
   punch bars `blo`/`bhi` use the same pattern but are invisible BY DESIGN —
   only their fill rects matter — which is why this never showed up before).
   Fixed with `m.cdBar.tex:SetTexture("Interface\\Buttons\\WHITE8X8")` at
   creation. Everything else checked out against Blizzard's own source
   (Gethe/wow-ui-source mirror, researched same day): `SetTimeFromStart
   (startTime, duration [, modRate=1])` signature confirmed
   (`LuaDurationObjectAPI`; default clock "equivalent to GetTime()"), enum
   fallbacks confirmed (Interpolation Immediate=0/ExponentialEaseOut=1;
   Direction ElapsedTime=0/RemainingTime=1), and the min/max question
   resolved — see the #16 update. In-game check: kick → icon + dark
   vertical drain emptying downward over ~15s.

   ## Outstanding Questions
   For spells where a single text string matches multiple spells, is there some way to know which is the "right" one? I see 5 rushing wind kick for example. 