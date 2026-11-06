<script lang="ts">
  // Section 12 of the Rebounding tab: the step-by-step rebuild of the rebounding models (the sequential manual,
  // Steps 00-11). Every step's pass rule was fixed in src/rebounding/config/experiment.yaml before its results were
  // seen, and each step left a gate record. Every number is read from rebounding_manual.json
  // (src/rebounding/run_export_manual.R copies it from outputs/rebounding/); only the explanations are written here.
  import { loadManualDoc } from "../lib/data";

  type Cell = number | string | boolean | null | undefined;
  type Row = Record<string, Cell>;
  interface Gate { step: string; file: string; status: string; scope: string; decision: string; date: string; components: { name: string; status: string }[]; deviations: number }
  interface Doc {
    built: string; manual_revision: string; gates: Gate[];
    labels: { agreement: Row[]; decisions: Row[] };
    scores: Row[]; c1: Row[]; c3: Row[]; coverage: Row[]; movement: Row[];
    opportunity: { by_role: Row[]; onset_curve: Row[]; ranks: Row[] };
    obstruction: { comparison: Row[]; geometry: Row[]; perturbation: Row[]; perturbation_context: Row[]; contribution: Row[]; pairings: Row[] };
  }
  interface Col { key: string; label: string; fmt?: (v: Cell, row: Row) => string; num?: boolean; title?: string }

  let doc = $state.raw<Doc | null>(null);
  let problem = $state("");
  loadManualDoc<Doc>().then((d) => { doc = d; }).catch((err: Error) => { problem = err.message; });

  // ---- formatting ----
  const n = (v: Cell) => (typeof v === "number" ? v : Number(v));
  const f = (d: number) => (v: Cell) => (v == null || Number.isNaN(n(v)) ? "–" : n(v).toFixed(d));
  const sf = (d: number) => (v: Cell) => (v == null || Number.isNaN(n(v)) ? "–" : `${n(v) > 0 ? "+" : ""}${n(v).toFixed(d)}`);
  const int = (v: Cell) => (v == null || Number.isNaN(n(v)) ? "–" : Math.round(n(v)).toLocaleString("en-US"));
  const pc = (d = 0) => (v: Cell) => (v == null || Number.isNaN(n(v)) ? "–" : `${(100 * n(v)).toFixed(d)}%`);
  const yes = (v: Cell) => (v === true || v === "TRUE" ? "yes" : "no");
  const one = (rows: Row[] | undefined, pred: (r: Row) => boolean) => (rows ?? []).find(pred) ?? null;
  const interval = (d: number) => (_: Cell, r: Row) => `${sf(d)(r.lo)} to ${sf(d)(r.hi)}`;

  const STEP: Record<string, string> = {
    "00": "Project set-up and pinned sources", "01": "Rebound episodes and the outcome", "02": "Contact labels (touch, tip, control)",
    "03": "Evaluation harness and baselines", "04": "Static model: who gets the ball", "05": "Where the ball goes (release map)",
    "06": "Ball filter in flight", "07": "Ball after the rim", "08": "Player movement and reach",
    "09": "Dynamic model: probabilities that update", "10": "Positioning and movement measures", "11": "Obstruction and box-outs",
  };
  const MODEL: Record<string, string> = {
    static_clogit: "Static model (Step 04)", dynamic: "Dynamic model (Step 09)", access_only: "Access only (no positions)",
    obstruction_clogit: "Static + obstruction (Step 11)", uniform: "Uniform", side_prior: "Side prior", role_prior: "Role prior",
    nearest_hoop: "Nearest the hoop", inside_rule: "Inside position", role_prior_by_range: "Role prior by shot range",
    nearest_hoop_by_range: "Nearest the hoop by shot range", selected_reference: "Best baseline per fold",
    zone_bins: "Zone histogram", pooled_kde: "Smoothed map, all shots", range_kde: "Smoothed map by shot range",
    side_range_kde: "Smoothed map by side and range", gravity_gauss: "Gravity only (reference)", empirical: "Similar past bounces",
    physics: "Rim physics", damped: "Damped momentum", stationary: "Standing still", constant_velocity: "Constant velocity",
    bounded: "Damped, speed-capped",
  };
  const model = (v: Cell) => MODEL[String(v)] ?? String(v);
  const role = (v: Cell) => String(v).replace("defence", "Defense").replace("offence", "Offense");
  const TIME: Record<string, string> = { release: "At release", "rim+0.2": "Rim + 0.2 s", "rim+0": "At the rim" };
  const time = (v: Cell) => TIME[String(v)] ?? String(v);
  const badge = (s: string) => (s.startsWith("PASS_BASELINE") ? "base" : s.startsWith("PASS") ? "pass" : s.startsWith("BLOCKED") ? "blocked" : "other");

  const BASELINES = ["uniform", "side_prior", "role_prior", "nearest_hoop", "inside_rule", "role_prior_by_range", "nearest_hoop_by_range", "selected_reference"];
  /** The models compared at one time: the two fitted models, the best baseline and the uniform one. */
  const scoreRows = (tp: string) => {
    const rows = (doc?.scores ?? []).filter((r) => r.time_point === tp);
    const base = rows.filter((r) => BASELINES.includes(String(r.model)) && r.model !== "uniform").sort((a, b) => n(a.log_loss) - n(b.log_loss))[0];
    return ["dynamic", "static_clogit"].map((m) => one(rows, (r) => r.model === m)).concat([base ?? null, one(rows, (r) => r.model === "uniform")])
      .filter((r): r is Row => r !== null);
  };
  const c3 = (test: string) => one(doc?.c3, (r) => String(r.test).startsWith(test));
  const gate = (s: string) => doc?.gates.find((g) => g.step === s);
  const counts = $derived.by(() => {
    const c: Record<string, number> = { pass: 0, base: 0, blocked: 0 };
    for (const g of doc?.gates ?? []) c[badge(g.status)] = (c[badge(g.status)] ?? 0) + 1;
    return c;
  });
  const agree = (pair: string, type: string, measure: string) => one(doc?.labels.agreement, (r) => r.pair === pair && r.type === type && String(r.measure).startsWith(measure));
  const R12 = "reviewer1_vs_reviewer2";
  const role10 = (r: string) => one(doc?.opportunity.by_role, (x) => x.role === r);
  const curveAll = $derived((doc?.opportunity.onset_curve ?? []).filter((r) => r.role === "all players"));
  const obsCmp = (tp: string) => one(doc?.obstruction.comparison, (r) => r.time_point === tp && r.metric === "ll");
  const geoAt = (tp: string) => one(doc?.obstruction.geometry, (r) => r.time_point === tp);
  const pertAt = (tp: string) => one(doc?.obstruction.perturbation, (r) => r.time_point === tp);
  const contribRP = $derived(one(doc?.obstruction.contribution, (r) => r.role === "defence: rim protector"));
</script>

{#snippet table(cols: Col[], rows: Row[], wide = false)}
  <div class="table-wrap">
    <table class="scores mn-table" class:narrow={!wide}>
      <thead><tr>{#each cols as c (c.key)}<th class:count={c.num} title={c.title}>{c.label}</th>{/each}</tr></thead>
      <tbody>
        {#each rows as row, i (i)}
          <tr>{#each cols as c (c.key)}<td class:count={c.num}>{c.fmt ? c.fmt(row[c.key], row) : row[c.key] ?? "–"}</td>{/each}</tr>
        {/each}
      </tbody>
    </table>
  </div>
{/snippet}

{#snippet status(s: string)}<span class="st {badge(s)}">{s.replace("_", " ")}</span>{/snippet}

{#snippet decision(text: string)}
  <div class="decision"><b>Decision</b><span>{text}</span></div>
{/snippet}

<section id="rb-manual">
  <h2>12. The step-by-step rebuild: what passed its gates</h2>
  {#if !doc}
    <p class="lead">{problem || "Loading…"}</p>
  {:else}
    {@const g04 = gate("04")}
    {@const a = c3("C3a")}
    {@const b = c3("C3b")}
    <p>
      After the first build (sections 1–11), every piece was rebuilt in a fixed order, one step at a time. Each step's
      pass rule was written into the project's configuration <b>before</b> its results were seen; every model was scored on
      games it never saw (leave one game out, ten folds) against the same baselines; and each step left a gate record.
      A step <b>passes</b> when its rule is met, <b>passes on a baseline</b> when only a simpler fallback is met, and is
      <b>blocked</b> otherwise. A blocked piece is reported, not used. Where this section and the earlier ones disagree,
      this section holds.
    </p>
    <p class="mn-sum">
      {counts.pass} steps pass, {counts.base} pass on a baseline, {counts.blocked} are blocked
      <span class="rb-note">(manual revision {doc.manual_revision}; exported {doc.built.slice(0, 10)})</span>
    </p>
    <div class="table-wrap">
      <table class="scores mn-table mn-gates">
        <thead><tr><th>Step</th><th>What it tests</th><th>Gate</th><th>Parts</th></tr></thead>
        <tbody>
          {#each doc.gates as g (g.file)}
            <tr>
              <td class="count">{g.step}</td>
              <td><span class="mn-title">{STEP[g.step] ?? g.file}</span><span class="mn-scope">{g.scope}</span></td>
              <td>{@render status(g.status)}</td>
              <td class="mn-parts">
                {#each g.components as c (c.name)}<span class="mn-part">{c.name.replaceAll("_", " ")} {@render status(c.status)}</span>{/each}
              </td>
            </tr>
          {/each}
        </tbody>
      </table>
    </div>

    <h3>Who gets the ball (Steps 03, 04 and 09)</h3>
    <p>
      The question is the same as in section 1: which of the twelve outcomes (ten players, two team awards) follows a miss.
      The static model (Step 04) is a conditional logit on the ten players' positions at the moment of the forecast. It
      had to beat <b>every</b> baseline at release, each on its own, and it did ({doc.c1.filter((r) => r.pass === true || r.pass === "TRUE").length}
      of {doc.c1.length}). The dynamic model (Step 09) adds each player's access to simulated ball positions. At release it
      only had to be no worse than the static model; at rim + 0.2 s it had to be better.
    </p>
    <div class="mn-grid two">
      {#each ["release", "rim+0.2"] as tp (tp)}
        <div>
          <h4>{time(tp)} (held-out games)</h4>
          {@render table([
            { key: "model", label: "Model", fmt: model }, { key: "log_loss", label: "Log loss", num: true, fmt: f(3), title: "Lower is better" },
            { key: "top1", label: "Top pick right", num: true, fmt: pc(1) }, { key: "team_log_loss", label: "Team log loss", num: true, fmt: f(3), title: "Offense vs defense" },
            { key: "ece", label: "Calibration error", num: true, fmt: f(3) },
          ], scoreRows(tp))}
        </div>
      {/each}
    </div>
    {#if a && b}
      <p>
        The dynamic model's log loss is {f(3)(Math.abs(n(a.mean_diff)))} lower than the static model's at release (interval
        {interval(3)(null, a)}) and {f(3)(Math.abs(n(b.mean_diff)))} lower at rim + 0.2 s (interval {interval(3)(null, b)}), better in
        {int(b.games_better)} of 10 held-out games. Both confirmatory tests are met. Its top pick is right
        {pc(0)(one(doc.scores, (r) => r.model === "dynamic" && r.time_point === "rim+0.2")?.top1)} of the time at rim + 0.2 s, against
        {pc(0)(one(doc.scores, (r) => r.model === "static_clogit" && r.time_point === "rim+0.2")?.top1)} for the static model.
      </p>
    {/if}
    {@render decision(`The dynamic model is the shipped model of who gets the ball (${gate("09")?.status ?? "?"}); the static model (${g04?.status ?? "?"}) is its fallback. A separate offense-vs-defense model did not beat a constant rate and is not used.`)}

    <h3>The ball (Steps 05, 06 and 07)</h3>
    <p>
      A forecast region is honest when its stated share comes true: half of the real outcomes inside the 50% region, 80%
      inside the 80% region. Each candidate ball model had to hit those shares within a tolerance fixed in advance, and
      none did at every level (the coarse zone histogram does, but it was kept only as a reference). So the ball inputs of
      the dynamic model are labelled exploratory: the model is judged on its final probabilities, not on the ball
      forecasts it uses.
    </p>
    {@render table([
      { key: "step", label: "Step" }, { key: "model", label: "Model", fmt: model }, { key: "level", label: "Stated share", num: true, fmt: pc(0) },
      { key: "coverage", label: "Came true", num: true, fmt: pc(1) }, { key: "n", label: "n", num: true, fmt: int }, { key: "within_tol", label: "Within tolerance", fmt: yes },
    ], doc.coverage.filter((r) => r.model !== "uniform"), true)}
    <p class="rb-note">
      Step 05: where the credited rebound happens, from the shot alone. Step 06: the ball's next 2–10 frames in free
      flight. Step 07: the ball after the rim; "rim physics" also needs contact labels, which Step 02 could not supply.
    </p>

    <h3>Players' movement (Step 08)</h3>
    <p>
      Where a player will be 0.2–1 s from now: momentum that fades (damped) beats both standing still and carrying on at
      the same speed at every horizon, in every held-out game. Capping speed on top of it changes nothing. Whether a player
      can physically reach the ball (interception) needs first-contact labels and stays blocked.
    </p>
    {@render table([
      { key: "candidate", label: "Model", fmt: model }, { key: "reference", label: "Against", fmt: model }, { key: "horizon", label: "Horizon", fmt: (v) => `${String(v).slice(1)} frames` },
      { key: "mean_diff", label: "Error difference (ft)", num: true, fmt: sf(2) }, { key: "games_better", label: "Games better", num: true }, { key: "superior", label: "Better", fmt: yes },
    ], doc.movement.filter((r) => r.candidate === "damped"))}

    <h3>Contact labels (Step 02)</h3>
    <p>
      Who touched the ball first, whether it was a tip or a catch, and when control started can only be read from the
      tracking here (no video). Two reviewers labelled the same 30 held-aside misses without seeing each other's labels.
    </p>
    {@render table([
      { key: "type", label: "Label" }, { key: "measure", label: "Measure" }, { key: "agree", label: "Agree", num: true }, { key: "n", label: "Of", num: true },
      { key: "value", label: "Value", num: true, fmt: (v, r) => (String(r.measure).includes("kappa") ? f(2)(v) : String(r.measure).startsWith("episodes") ? int(v) : pc(0)(v)) },
      { key: "target", label: "Needed", num: true, fmt: (v, r) => (v == null ? "–" : String(r.measure).includes("kappa") ? f(2)(v) : String(r.measure).startsWith("episodes") ? int(v) : pc(0)(v)) },
    ], doc.labels.agreement.filter((r) => r.pair === R12 && r.target != null), true)}
    <p>
      The reviewers agree on rim or board contact ({int(agree(R12, "contact", "contact vs none, raw")?.agree)} of
      {int(agree(R12, "contact", "contact vs none, raw")?.n)}), and when both name a player they almost always name the same one. What they
      cannot agree on is <i>when</i> a touch or control happens and whether it can be named at all, and tip versus catch is no
      better than chance. The automated labeler that would cover every miss misses the targets against both reviewers.
    </p>
    {@render decision("Contact labels pass where reviewed, nothing else. Every model above is trained on the credited rebounder only; tip physics, a controlled-catch model and the reach check stay blocked.")}

    <h3>Positioning and movement (Step 10)</h3>
    <p>
      Each player's <b>opportunity</b> is his chance of reaching the ball before it can be collected, averaged over the
      places it may land. <b>Access gained</b> compares his opportunity when the ball reaches the rim with where his
      momentum alone would have taken him: what he gained by reading the shot. Intervals resample whole games.
    </p>
    {@render table([
      { key: "role", label: "Role at release", fmt: role }, { key: "n", label: "n", num: true, fmt: int },
      { key: "q_release", label: "Opportunity at release", num: true, fmt: pc(0) },
      { key: "vs_baseline", label: "Access gained", num: true, fmt: sf(3) }, { key: "vs_lo", label: "Interval", fmt: (_, r) => `${sf(3)(r.vs_lo)} to ${sf(3)(r.vs_hi)}` },
      { key: "responded", label: "Sustained move to the ball", num: true, fmt: pc(0) }, { key: "median_onset_s", label: "Median onset (s)", num: true, fmt: f(2) },
    ], [...doc.opportunity.by_role].sort((x, y) => n(y.vs_baseline) - n(x.vs_baseline)), true)}
    <p>
      Offensive players away from the hoop gain the most access ({sf(3)(role10("offence: other")?.vs_baseline)}); the shooter loses
      it ({sf(3)(role10("offence: shooter")?.vs_baseline)}). Most players make no sustained move toward the ball before it reaches the
      rim. When they do, the onset depends on the speed that counts as a move, so it is reported as a curve, not one time:
    </p>
    {@render table([
      { key: "threshold_ft_s", label: "Speed that counts (ft/s)", num: true }, { key: "responded", label: "Players who move", num: true, fmt: pc(1) },
      { key: "onset_q25_s", label: "Onset, 25th pct (s)", num: true, fmt: f(2) }, { key: "onset_median_s", label: "Median (s)", num: true, fmt: f(2) },
      { key: "onset_q75_s", label: "75th pct (s)", num: true, fmt: f(2) },
    ], curveAll)}
    <p class="rb-note">
      An onset is an observed response, not a reaction time: players who anticipate move before the release, and players
      sent back on defense do not crash by design.
    </p>

    <h3>Obstruction and box-outs (Step 11)</h3>
    <p>
      <b>Obstruction</b> measures how much a player stands on an opponent's route to the area around the hoop, from floor
      positions only. It is not a box-out: there is no video, no body orientation and no contact in the data. Its geometry
      passes mirroring and rotation exactly, but it fails two checks fixed in advance:
    </p>
    {#if pertAt("rim+0.2") && geoAt("rim+0.2")}
      <ul class="mn-list">
        <li>
          Moving every player one foot (about the tracking error) changes it by {f(3)(pertAt("rim+0.2")?.mean_abs_change_blocked)} on average
          (limit 0.05), and {pc(0)(pertAt("rim+0.2")?.pairing_changed_among_paired)} of players with a matched opponent change that match.
        </li>
        <li>
          Measured toward the hoop alone instead of the area around it, being blocked ranks players differently
          (correlation {f(2)(geoAt("rim+0.2")?.rho_blocked_hoop_only)}, limit 0.8): the answer depends on where a player is assumed to be going.
        </li>
      </ul>
    {/if}
    {@render table([
      { key: "time_point", label: "Time", fmt: time }, { key: "mean_diff", label: "Log loss change vs static", num: true, fmt: sf(4) },
      { key: "lo", label: "Interval", fmt: interval(4) }, { key: "games_better", label: "Games better", num: true },
      { key: "non_inferior", label: "No worse", fmt: yes }, { key: "superior", label: "Better", fmt: yes },
    ], doc.obstruction.comparison.filter((r) => r.metric === "ll"))}
    {#if contribRP && obsCmp("rim+0.2")}
      <p>
        Added to the static model it neither helps nor hurts on held-out games. In that model, a rim protector's blocking
        is associated with a lower chance for himself ({sf(3)(contribRP.contrib_own)}) and a higher one for his teammates
        ({sf(3)(contribRP.contrib_mates)}): an association with helping the team, not what a box-out causes.
      </p>
    {/if}
    {@render decision(`Obstruction is ${gate("11")?.status ?? "?"} and is shown as a description only. Box-out detection and box-out skill are blocked: no permitted data shows contact. The box-out labels and links in section 9 and in the play panel are the same kind of geometric rule, not validated box-outs.`)}
  {/if}
</section>

<style>
  .mn-sum { margin: 10px 0; font-weight: 600; }
  .mn-grid { display: grid; gap: 20px; margin: 14px 0; align-items: start; }
  .mn-grid.two { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .mn-grid h4 { margin-top: 0; }
  .mn-table.narrow { min-width: 0; width: auto; }
  .mn-table td { font-size: 13px; }
  .mn-gates td { vertical-align: top; }
  .mn-gates td:nth-child(2) { min-width: 280px; }
  .mn-title { display: block; font-weight: 600; }
  .mn-scope { display: block; margin-top: 2px; color: var(--muted); font-size: 12px; line-height: 1.4; }
  .mn-parts { font-size: 12px; }
  .mn-part { display: inline-flex; align-items: center; gap: 4px; margin: 0 10px 4px 0; color: var(--muted); white-space: nowrap; }
  .st { display: inline-block; padding: 1px 7px; border-radius: 999px; font-size: 10.5px; font-weight: 700; letter-spacing: .03em; white-space: nowrap; }
  .st.pass { background: rgba(79, 208, 143, .16); color: var(--made); }
  .st.base { background: rgba(76, 154, 255, .16); color: var(--off); }
  .st.blocked { background: rgba(255, 138, 128, .16); color: var(--missed); }
  .st.other { background: var(--raised); color: var(--muted); }
  .mn-list { margin: 8px 0; padding-left: 20px; color: var(--muted); }
  .mn-list li + li { margin-top: 4px; }
  .rb-note { color: var(--muted); font-size: 12.5px; }
  .decision { display: flex; gap: 12px; margin: 14px 0; padding: 10px 14px; border-left: 3px solid var(--off); border-radius: 0 8px 8px 0; background: rgba(76, 154, 255, .08); }
  .decision b { flex: none; color: var(--off); font-size: 12px; letter-spacing: .04em; text-transform: uppercase; line-height: 1.55; }
  section > h3 { margin-top: 22px; }
  @media (max-width: 860px) {
    .mn-grid.two { grid-template-columns: minmax(0, 1fr); }
  }
</style>
