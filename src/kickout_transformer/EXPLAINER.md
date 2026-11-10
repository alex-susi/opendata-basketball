# Kickout transformer: a learning exercise

**What this is:** a first, small transformer trained on SkillCorner tracking data. It predicts what a perimeter
receiver does next: shoot, drive, pass, or something else. It is a way to learn how transformers work on player
tracking before using them for screen coverages. It is **not** the competition entry, and nothing here is a
finding to publish.

**Bottom line:** the transformer learned real basketball structure. It beats every tendency baseline and attends
most to the nearest defender and the passer. But it only **ties** a plain logistic regression on ten hand-built
features. Adding the last second of movement made it slightly **worse**. With ~1,500 training catches, a model with
~19,000 weights has nothing left to gain once a few well-chosen numbers already describe the catch.

## How to run it

All steps are R (`torch`, `nnet`, `ggplot2`) and read only the play viewer's tracking cache and the event files.

```bash
Rscript src/kickout_transformer/01_build_catches.R      # ~35 s: catches, labels, player tokens
Rscript src/kickout_transformer/02_baselines.R          # seconds: five baselines, leave-one-game-out
Rscript src/kickout_transformer/03_train_transformer.R --model=freeze   # ~2 min per held-out game
Rscript src/kickout_transformer/03_train_transformer.R --model=hist
Rscript src/kickout_transformer/04_evaluate.R           # scores, intervals, figures
Rscript src/kickout_transformer/05_attention.R --model=freeze           # attention by role, example plays
Rscript src/kickout_transformer/08_timing_audit.R       # when the receiver acts; the 1.25 s horizon target
Rscript src/kickout_transformer/09_cue_features.R       # space, pass-context and screen-setup cues at the catch
Rscript src/kickout_transformer/10_cue_comparison.R     # logistic: base vs base + each cue, both targets
```

Steps 8-10 need the explore bundles (`outputs/cache/explore/`, built by `web/scripts/explore/build.R --bundles`).

Step 3 caches one file per held-out game and accepts `--fold=<gameId>`, so the 20 fits can run as separate
processes in parallel. Results are written to `outputs/kickout_transformer/`.

## Step 1: the data (`01_build_catches.R`)

**Who is in the sample.** Every completed, live-ball pass (not an inbound) caught beyond the arc: **1,738 catches**
(3 dropped for a gap in the tracking history). The strict subset, passes that end a drive SkillCorner tagged
`endType = kickout`, has **115** catches. Another 44 tagged kickouts were caught inside the arc and are left out.
115 plays are far too few to train on, so every model trains on all perimeter catches and is *also* scored on the
115 kickouts.

**The label** is the receiver's touch that starts within 1 s of the reception:

| Label | Rule | All catches | Strict kickouts |
|---|---|---|---|
| drive | the touch has a `drives` row (a drive that ends in a shot counts as a drive) | 278 (16%) | 19 (17%) |
| shot | otherwise, the touch has a `shots` row | 410 (24%) | 46 (40%) |
| pass | otherwise, the touch's outcomes include a pass | 974 (56%) | 41 (36%) |
| other | 29 fouls drawn, 18 turnovers, 29 held / nothing | 76 (4%) | 9 (8%) |

So a "drive" is only what SkillCorner's drive model tagged. A receiver who takes two dribbles and passes is a "pass".

**Checking the geometry before trusting it.** For the 235 catch-and-shoot attempts released within 1 s of the
catch, our receiver-to-hoop distance at the catch is about 1 ft larger than SkillCorner's `shots.distance` at
release. That matches a shooter stepping into the shot. Our left/right side agrees with the shot's location on 96%
of them. Positions use the viewer's corrected orientation: raw tracking y is mirrored, and the offense always
attacks +x.

**Tokens: what the transformer reads.** A *token* is one row of numbers. Here, each token is one player at the
catch frame. Every catch becomes a small table, 10 players × 13 numbers:

| Number | Meaning |
|---|---|
| `hoop_dx`, `y`, `hoop_dist` | where the player is relative to the hoop (ft) |
| `vx`, `vy`, `speed` | velocity over the previous 0.24 s (ft/s); nothing after the catch is used |
| `rel_x`, `rel_y`, `rel_dist` | where the player is relative to the receiver |
| `is_offense`, `is_receiver`, `is_passer` | who they are in this play |
| `detected` | 1 if seen by the camera, 0 if the tracker extrapolated the position |

The **history** model adds 8 more numbers per player: how far they moved over the last 0.24, 0.48, 0.72 and 1.00 s.

Stacked over all catches this is an array of shape **[1,738 catches, 10 players, 13 numbers]** (21 for history).
Rows are ordered: receiver first, then his teammates, then defenders, each nearest first. The transformer does not
use that order; it only makes printouts readable.

## Step 2: baselines (`02_baselines.R`)

Every model, baselines included, is fitted on nine games and scored on the tenth. Repeating that for each game
gives one honest held-out prediction per catch.

| Baseline | What it predicts |
|---|---|
| Uniform | 25% for each of the four outcomes. With four classes the naïve guess is 25%, not 33.3%. |
| League | the outcome shares in the nine training games |
| Archetype | the shares for receivers of the same offensive archetype, shrunk toward the league shares (as if 20 extra league-average catches had been seen) |
| Player | the receiver's own shares, shrunk toward his archetype (10 extra catches) |
| Logistic | multinomial logistic regression on 10 hand-built features: receiver's distance to the hoop, corner flag, receiver speed, nearest and second-nearest defender distance, nearest defender's closing speed, defenders in the paint, time to act (shot clock or game clock, whichever runs out first; the four-class results below used the shot clock), kickout flag, pass from the paint |

The archetypes were partly built from these same ten games, so the archetype baseline is slightly optimistic.

## Step 3: the transformer (`R/transformer.R`, `03_train_transformer.R`)

Follow one catch through the model:

1. **Embed.** A linear layer turns each player's 13 numbers into a 32-number vector: [10 × 13] → [10 × 32]. This
   is the same weighted sum for every player, like a regression applied row by row.
2. **Attention, written out by hand in `attention_layer`.** Each player's vector is multiplied by three learned
   matrices to give a *query* (what this row is looking for), a *key* (what it offers) and a *value* (what it hands
   over). For the receiver, his query is compared with all ten keys (a dot product, divided by √8). A softmax turns
   those ten scores into ten weights that sum to 1. His new vector is the weighted average of everyone's values.
   Every player gets the same treatment in parallel, so the weights form a 10 × 10 table.
3. **Heads.** The 32 numbers are split into 4 *heads* of 8. Each head has its own weights, so one head can track
   the closing defender while another tracks the passer.
4. **Feed-forward, residual, layer norm.** After attention, each row goes through a small two-layer network on its
   own. Each step's output is *added* to its input (residual) instead of replacing it, which keeps training stable.
   Rows are rescaled before each step (layer norm). One attention step plus one feed-forward step is a **layer**;
   there are 2 layers.
5. **Read the receiver's row.** After two layers, row 1 (the receiver) has mixed in what it needed from the other
   nine. A small output head reads that row, plus the context numbers (time to act, kickout and paint flags; the shot clock in the four-class results), and produces 4 scores.
   A softmax turns the scores into probabilities.

There are **no positional encodings**. Without them attention cannot tell row 3 from row 7, which is right for a
freeze frame because the ten players have no natural order. Position on the floor is already in each token's
numbers.

**Training.** The loss is cross-entropy, the same log loss used to score the models. The optimiser is AdamW
(learning rate 0.001, weight decay 0.01, batches of 64). One training game is held out as a *validation* game; the
test game is never touched. Training stops after 25 epochs without improvement on the validation game, and the
weights from the best epoch are kept. That usually happens around **epoch 10–30**: see
`figures/training_curves.png`. Training loss keeps falling well past that point while validation loss turns back
up. That is overfitting, and early stopping is the main defence against it here.

Two further tricks: each batch mirrors a random half of its plays left-to-right (y → −y), because the decision
should not depend on which side of the floor it is on. And each game is fitted three times from different random
starting weights, with the probabilities averaged. The model has about 18,900 weights (19,100 with history).

## Step 4: results (`04_evaluate.R`)

**Log loss** is −log(the probability the model gave to what actually happened). Lower is better, and a uniform
guess scores 1.386. It rewards good probabilities, not just right answers. Intervals come from resampling whole
games, because catches within a game are not independent.

| Model | Log loss, all 1,738 | 95% interval | Log loss, 115 kickouts | Accuracy, all |
|---|---|---|---|---|
| Uniform | 1.386 | – | 1.386 | 24% |
| League average | 1.099 | 1.073–1.129 | 1.336 | 56% |
| Archetype average | 1.097 | 1.069–1.126 | 1.308 | 56% |
| Player average | 1.101 | 1.075–1.132 | 1.324 | 56% |
| **Logistic, 10 features** | **0.980** | 0.955–1.009 | **1.170** | 64% |
| Transformer, freeze frame | 0.985 | 0.961–1.012 | 1.176 | 63% |
| Transformer, + last 1 s | 1.003 | 0.979–1.029 | 1.227 | 61% |

Paired differences use the same catches scored by two models, so differences in game difficulty cancel out
(`paired_logloss_differences.csv`):

- **Transformer (freeze) vs logistic:** +0.005 (−0.006 to +0.015). A tie.
- **History vs freeze:** +0.019 (+0.007 to +0.032). Adding movement history made it *worse* on held-out games.
- **Transformer (freeze) vs league average:** −0.114 (−0.130 to −0.095). A clear improvement.
- **Archetype vs league:** −0.001; **player vs archetype:** +0.004. Who catches the ball adds almost nothing once
  you know the league shares, at this sample size.
- On the 115 strict kickouts, every interval is wide (about ±0.1). The transformer and the logistic model are again
  indistinguishable there.

Per game (`per_game_logloss.csv`), the freeze transformer beats the logistic model in 3 of 10 games, by small
margins either way (at most 0.025). That is another sign they are level.

**Calibration** (`calibration.csv`): when either model says "about 65% pass", about 65% of those catches are
passes. Both models' probabilities can be taken roughly at face value. Their main weakness is predicted drive rates
of 30–40%, which happen only about 20% of the time.

## Step 5: what the attention looks at (`05_attention.R`)

Average weight the receiver's row gives to each player, on held-out catches, freeze model. If attention were
spread evenly, each player would get 0.10.

| Role | Layer 1 | Layer 2 |
|---|---|---|
| Nearest defender | 0.21 | 0.22 |
| Passer | 0.13 | 0.17 |
| 2nd-nearest defender | 0.14 | 0.12 |
| Receiver himself | 0.10 | 0.08 |
| Each other defender | 0.08 | 0.07 |
| Each other teammate | 0.06 | 0.07 |

Nobody told the model which players matter. It learned to look at the closest defender and the passer, the same
players a coach would point to. That is a useful sanity check: the attention has learned something sensible.

`figures/attention_two_kickouts_freeze.png` shows two strict kickouts with a 6–8 ft gap, the example from the
brainstorm. In the first, a corner catch with the defender closing at 4.7 ft/s, the transformer gives 48% shot and
puts 35% of the receiver's attention on that defender. The receiver shot. The logistic model said only 22% shot. In
the second, the receiver catches at the top with the passer behind him. Both models say about 60% pass. He drove.

**What attention weights are not.** A weight of 35% means that defender's information made up 35% of the average
in that head. It does not mean the defender caused 35% of the decision. Weights are averaged here over heads,
seeds and catches; single plays are noisy.

## How to tell whether to trust this

- **Trust the comparison, not the absolute numbers.** All seven models are scored on the same held-out games with
  the same rows, and the paired intervals account for game-to-game variation.
- **The transformer is not memorising.** It is scored only on games it never saw, and its probabilities are about
  as well calibrated as the logistic model's.
- **Ten games is the limit.** Every number describes these ten ACB games. Nothing here says the transformer would
  stay level with logistic on a full season. With much more data it might pull ahead, or it might not.
- **The labels are SkillCorner's.** "Drive" means a SkillCorner-tagged drive. Errors in those tags feed straight
  into every model.

## What this teaches for screen coverages

1. **Hand-built geometry is a strong opponent.** The logistic model's 10 features already capture most of what the
   freeze frame contains. Any coverage transformer must be compared against a regularised multinomial on the
   obvious features (big's depth, guard's position against the screen), on held-out games.
2. **More inputs need more data.** Movement history hurt here because it gave ~19,000 weights more ways to fit
   noise. Picks have more labels (about 1,500 across the ten games, comparable to this sample). Start with a few
   players (handler, screener, two defenders) and a short window, and grow only if held-out loss improves.
3. **The machinery transfers unchanged.** Tokens, attention, the readout row, leave-one-game-out training, early
   stopping, mirroring, seed averaging and paired game-bootstrap scoring all carry over. Coverage prediction would
   read the *on-ball defender's* row, or a combined row, instead of the receiver's. With movement history as separate
   time-step tokens, positional (time) encodings become necessary.
4. **Things to try on this problem first** (each is one change): fewer weights (d = 16, 1 layer), dropping the
   history model's raw displacements in favour of 2–3 summary numbers, or treating each (player, time) as its own
   token with a time encoding.

## Three-class variant: shot / drive / pass only

Add `--drop-other` to steps 2-5 (step 1 is shared). The 76 catches that ended in a foul, turnover, timeout or held
ball are removed, leaving 1,662 catches (106 strict kickouts), and every model predicts three classes. Results go to
`outputs/kickout_transformer_3class/` and `outputs/cache/kickout_transformer_3class/`; the four-class files are untouched.

    Rscript src/kickout_transformer/02_baselines.R --drop-other
    Rscript src/kickout_transformer/03_train_transformer.R --model=freeze --drop-other
    Rscript src/kickout_transformer/03_train_transformer.R --model=hist --drop-other
    Rscript src/kickout_transformer/04_evaluate.R --drop-other
    Rscript src/kickout_transformer/05_attention.R --model=freeze --drop-other

Held-out log loss with the shot clock as the clock input (uniform guessing now scores log(3) = 1.099; see the next
section for the run with time to act):

| Model | All 1,662 catches | 106 strict kickouts |
|---|---|---|
| Uniform (33% each) | 1.099 | 1.099 |
| League / archetype / player | 0.961 / 0.955 / 0.957 | 1.138 / 1.130 / 1.138 |
| Logistic | **0.833** | **0.949** |
| Transformer, freeze frame | 0.838 | 0.992 |
| Transformer, + last 1 s | 0.861 | 1.015 |

The picture is the same as with four classes. The freeze-frame transformer ties the logistic model on all catches
(paired difference +0.005, 95% interval -0.003 to +0.013), history still hurts (+0.023, interval 0.014 to 0.034), and
player or archetype tendencies add nothing beyond league shares. On kickouts the tendency baselines are worse than an
even guess because kickouts end in a shot far more often (43%) than perimeter catches in general (25%). The receiver's
attention concentrates even more on the nearest defender (0.22 per player in layer 2, versus 0.12 for the passer).

## Film study: confident misses (step 6)

    Rscript src/kickout_transformer/06_film_study.R --drop-other

Picks plays where a model put at least 60% on an outcome that did not happen, by category (both models expected a
pass and the receiver drove; both expected a pass and he shot; both expected a shot; only the transformer was wrong;
only the logistic model was wrong; the most confident miss on a strict kickout), and draws one card per play in
`figures/film_study/`. Each card has the court at the catch (jerseys, names, where everyone is moving, the
transformer's attention), both models' probabilities, the numbers the logistic model sees, and the dashboard link.
`film_study_plays.csv` lists the plays; `film_study_miss_counts.csv` counts every confident miss by kind.

Catches drawn more than 40 ft from the hoop are broken positions, not model mistakes; they are listed in
`film_study_data_issues.csv` and left out of the set (two in the three-class run, including the opening possession of
game 179612).

Two things the cards made obvious that the models never see: the **game clock** (3 of the 8 plays are in the last
6 seconds of a quarter, when receivers shoot far more often) and a missing shot clock, which step 1 fills with 24 s.

## Time to act (three-class run, current)

Step 1 used to fill a missing shot clock with 24 s, so a catch with 0:06 left in the quarter and the shot clock off
looked like a fresh possession. `time_to_act` is now the clock input for both models: the shot clock or the game
clock, whichever runs out first, capped at 24 s. For the logistic model it replaces `shot_clock` in its ten features.
For the transformer it replaces `shot_clock` in the **context vector**: the play-level numbers that are joined to the
receiver's row after the attention layers, just before the output head. So the clock changes the final call, not
where the receiver looks.

It changes the input on only 5 of 1,662 catches; elsewhere the shot clock already runs down with the game clock.
`07_compare_runs.R` scores the old and new predictions on the same catches (the old run is saved in
`outputs/*/kickout_transformer_3class_before_time_to_act/`):

| Subset | Logistic | Transformer, freeze | Transformer, + last 1 s |
|---|---|---|---|
| All 1,662 catches | 0.833 → 0.829 | 0.838 → 0.840 | 0.861 → 0.855 |
| 5 catches whose clock input changed | 3.13 → 2.03 | 2.52 → 1.65 | 2.47 → 1.78 |
| 37 catches with under 24 s left | 1.16 → 1.01 | 1.17 → 1.03 | 1.23 → 1.07 |

The fix does what it should on the plays it touches (on the old film-study card 03, with 0:01 left, both models went
from 4% to 23-33% on the shot), and nothing else moves beyond retraining noise. The freeze-frame transformer is now
slightly behind the logistic model on all catches (+0.011, interval 0.001 to 0.021). Because the end-of-period plays
are now predicted better, the film-study set (step 6) picks different plays than before.

## When does the receiver act? (step 8)

The film cards showed that the current label is about the receiver's **whole touch**, not the catch. Marcos's
"drive" (game 188630) started 3.68 s after the catch, behind a Fall ball screen at +2.40 s. Howard's "shot" came at
+4.80 s, after a screen at +3.20 s. `08_timing_audit.R` records for every catch (all 1,738) when the receiver's
drive started, when he released a shot or pass, any turnover or foul, the touch end, and the first ball screen on
the same touch. It reproduces the event times quoted for all eight film cards and for Marcos.

| Same-touch label | Catches | Median time to the action | Share after 1.25 s | Share after 2.5 s | A ball screen came first |
|---|---|---|---|---|---|
| shot | 410 | 0.88 s | 32% | 17% | 11% |
| drive | 278 | 0.80 s | 37% | 15% | 18% |
| pass | 974 | 1.60 s | 58% | 30% | 22% |
| other | 76 | 2.24 s | 71% | 49% | 15% |

So about a third of shots and drives, and more than half of passes, happen well after the catch, and 18% of all
labelled actions follow a ball screen the catch could not see. That is a ceiling on any model of "what the catch set
up".

**A second target at a fixed horizon.** At 1.25 s after the catch each receiver is in one of five states: shot
released (16%), drive started (10%), pass thrown (23%), turnover/foul/whistle (1%), or **still holding with nothing
tagged** (49%). Every catch gets a state, so a forecast at 1.25 s covers all eligible catches, including the "other"
ones. Aranitović (game 191313) is a shot at 1.25 s, Nogues a drive, and Marcos and Howard are "hold". The 0.75 s and
2.0 s horizons are in `horizon_shares.csv`; `figures/acted_by_time.png` shows the whole curve.

## Three cues from the film (steps 9 and 10)

Each cue is computed from positions and velocities at or before the catch (the same token arrays the transformer
uses). The later screen tag is used only to check the screen cue:

- **Directional space:** the gap to the nearest defender projected 0.5 s ahead, and the room in the better and worse
  of two driving lanes (segments toward the hoop on either side of the receiver; room = distance from the nearest
  defender to the segment).
- **Pass context:** a quick return (A passes to B, B sends it straight back within 2 s; 9% of catches), how long the
  passer held the ball, and seconds since the change of possession. Aranitović's catch is a return after Mavra held
  it 0.4 s, 4.8 s into the possession.
- **Screen setup:** for each teammate, his distance to the nearer "shoulder" of the on-ball defender (2.5 ft either
  side) and how fast it is shrinking; the logistic model gets the smallest distance now and the smallest projected
  distance in 1 s. **Check against the later tags:** the top candidate is the actual screener on 55% of catches that
  get a screen within 3 s (25% by chance), and it ranks "screen within 1.5 s" above "no screen" 68% of the time.
  On Marcos's catch, Fall is the top candidate but only closing at 2.5 ft/s, so most of the setup came after the
  catch.

`10_cue_comparison.R` adds each group to the step-2 logistic model on its own, with the same held-out games. Change
in log loss vs base (negative = helped, 95% game-bootstrap interval):

| Added | Same-touch target (1,662) | 1.25 s target (1,738) |
|---|---|---|
| space | −0.001 (−0.005 to 0.003) | −0.002 (−0.006 to 0.003) |
| pass context | −0.001 (−0.003 to 0.002) | +0.001 (−0.003 to 0.007) |
| screen setup | −0.001 (−0.004 to 0.002) | **−0.007 (−0.011 to −0.001)** |
| all three | −0.003 (−0.010 to 0.004) | −0.007 (−0.015 to 0.005) |

Only the screen cue on the 1.25 s target clears zero, and it is small. On strict kickouts (106-115 catches) every
interval spans zero. Confident calls (≥60%) are close to calibrated with and without the cues
(`figures/cue_calibration.png`). The cues barely move the film plays (Aranitović's shot: 9% → 14%), so these misses
are not explained by these summaries. The transformer versions of the cues (per-player tokens) are not built yet.
