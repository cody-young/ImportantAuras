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
- `kind = "unit"` (fixed frame): `unit` (player/target/focus/pet/partyN/
  arenaN/bossN), `filter` (HARMFUL/HELPFUL), `targets`/`order` (unchanged
  priority-list semantics), `layout`, `iconSize`, `spacing`, `bg`, `panel`,
  `panelPad`, `locked`, `anchor = { useFrame, myPoint, relPoint, x, y, point
  (free-float fallback) }`. `useFrame=true` resolves via LibGetFrame and
  falls back to the legacy free-float drag-anywhere point if resolution
  fails; dragging while frame-attached adjusts the saved `x,y` offset instead
  of an absolute `UIParent` point.
- `kind = "nameplate"`: same targets/order/filter/layout/iconSize/spacing, no
  `unit` field — always follows the current target's nameplate (see Runtime
  section below) — and `anchor = { myPoint, relPoint, x, y }` only (a plate
  IS the anchor — no free-float fallback, no lock/drag).
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
  creates/destroys `Stack` instances 1:1, each owning a `CreateFrame` that
  self-registers `UNIT_AURA` for its own unit token (today's single-event-frame
  pattern, just N of them). Anchoring for these goes through `FrameAnchor.lua`
  (the `LibGetFrame` wrapper described above).
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
- `Data/SpellDB.lua` — static, offline-generated `{id, name}` table of every
  class/spec/hero-talent/pvp-talent spell (Next Features #13); ships empty
  until `Tools/generate_spelldb.js` is run against real credentials.
- `Tools/generate_spelldb.js` — offline Node script that regenerates
  `Data/SpellDB.lua` from Blizzard's Battle.net Game Data API. Not run by the
  game or by Claude — the addon itself can't make network calls, so this is a
  manual, user-run step (see Next Features #13 for invocation).
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
- **Run `Tools/generate_spelldb.js` and verify the broadened spell search
  (Next Features #13, nothing below has been tested/run yet)**:
  1. Create a free Battle.net API client at develop.battle.net/access/clients,
     then run `BNET_CLIENT_ID=... BNET_CLIENT_SECRET=... node
     Tools/generate_spelldb.js` from the addon folder.
  2. Check the printed summary count — if it's 0 or suspiciously low, re-run
     with `--dump` on the console output for one class and compare the real
     JSON shape against `walkForSpells()`'s assumption in the script
     (`{spell:{id,name}}` sub-objects anywhere in the response).
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
- **In-game verification of the cooldown swipe (Next Features #7, nothing
  below has been tested live yet)**:
  1. `/reload`, confirm no Lua errors; existing stacks show the new "Cooldown
     swipe" toggle (default on) under Display.
  2. With a stack tracking a real buff/debuff, confirm the swipe animates
     over the icon while it's up, and is absent (no leaked pie/edge) for
     slots holding auras that aren't tracked targets.
  3. Toggle "Cooldown swipe" off/on, confirm it hides/shows without errors.
  4. Watch chat for the red "cooldown swipe disabled" warning -- if it
     prints, `SetCooldown` rejected a secret timing value; report back so
     the approach for that case can be revisited.
  5. Confirm CAST-mode stacks never show the toggle and never error (no
     duration data in that path).
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
4. Import/Export stack feature
5. Stack groups -> This would let you group like stacks together. For example, if I wanted to recreate OmniBar's kick tracker, I would put all of the different kicks into a single group. This would also allow exporting and importing of a group.
6. A page to load presets. This would allow me to say add a button to create an arena kick tracker, or a M+ allied kick tracker.
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
9. A preview button, or perhaps just always showing the highest prio spellId icon in edit mode.
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

  8.1.Addendum -> I want it implemented like "TellMeWhen_Options" (copy available in ~/Downloads)

12. I want the ability added back in where I can target multiple frames with a single stack. For example, if I make a stack with kingsbane, I want to be able to target player,party1,party2 so I can see in arena who has kingsbane. Also, the unit dropdown should have arena1-3 and party1-5 and arenapet1-3

13. **IMPLEMENTED (2026-07-05), generator not yet run, in-game unverified.**
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
    - **Not done this pass**: nobody has run `generate_spelldb.js` against
      real credentials yet (needs the user's own Battle.net app), so the
      recursive-walk schema guess is unverified against real API responses —
      if a real run comes back with far fewer spells than expected, re-run
      with `--dump` on one class and adjust `walkForSpells()` to match the
      actual JSON shape. In-game verification of the broadened search UX and
      the harmful/helpful filtering also hasn't happened.

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
3. **Still open.** When attaching to unit frames, there is still a blue
   square drag-hint anchor visible. It shouldn't be there for "Attached"
   stacks. Static review of `FrameAnchor.lua` found `ApplyFrameAttach`
   already calls `stack.anchor.moveHint:Hide()` whenever
   `LGF.GetUnitFrame(...)` resolves a frame, with no apparent logic bug in
   that path or in how/when `Reposition` is called. Leading theory (unverified,
   couldn't reproduce from reading code alone): `LibGetFrame`'s internal frame
   cache populates asynchronously off game events, so the very first
   `Reposition()` call right after login/reload could see a nil frame before
   the library's scan completes, and something in that self-heal path (the
   `FRAME_UNIT_ADDED`/`GETFRAME_REFRESH` callbacks `FrameAnchor.lua` already
   listens for) may not be firing/resolving as expected. Needs to actually be
   reproduced live (does it clear after a few seconds? only for certain unit
   tokens like party/arena vs. player? does re-toggling "Attach to unit
   frame" fix it?) before attempting a fix.
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