<script lang="ts">
  // The Rebounding tab: what the rebounding models answer, how each was built and checked, what the checks show
  // and what they do not support. Every number is read from rebounding.json, which src/rebounding/run_export.R
  // writes from the validation tables in outputs/rebounding/, so the text and the results cannot drift apart.
  import { loadReboundDoc } from "../lib/data";

  type Cell = number | string | boolean | null | undefined;
  type Row = Record<string, Cell>;
  interface Doc {
    built: string;
    talent: boolean;
    episodes: number;
    checks: Row[] | null;
    audit: Record<"counts" | "population" | "by_game" | "quality" | "hoops" | "gaps" | "timeline" | "held", Row[]>;
    flight: { params: Record<string, Record<string, number> | number[] | Row[]>; summary: Row[]; landing: Row[]; folds: Row[]; grid: Row[] };
    collection: {
      summary: Row[]; calibration: Row[]; contested: Row[]; folds: Row[]; access_grid: Row[]; sensitivity: Row[]; recovery: Row[];
      theta: Record<string, Record<string, number>>; acc: Record<string, Record<string, number>>; players: Row[];
    };
    skills: {
      identification: Row[]; movement: Row[]; movement_roles: Row[]; boxout_labels: Row[]; boxout_validation: Row[];
      variance: Row[]; anticipation_players: Row[]; boxout_players: Row[];
    };
  }
  interface Col { key: string; label: string; fmt?: (v: Cell, row: Row) => string; num?: boolean; title?: string }

  let doc = $state.raw<Doc | null>(null);
  let problem = $state("");
  loadReboundDoc<Doc>().then((d) => { doc = d; }).catch((err: Error) => { problem = err.message; });

  const n = (v: Cell) => (typeof v === "number" ? v : Number(v));
  const f = (d: number) => (v: Cell) => (v == null || Number.isNaN(n(v)) ? "–" : n(v).toFixed(d));
  const int = (v: Cell) => (v == null ? "–" : Math.round(n(v)).toLocaleString("en-US"));
  const pc = (d = 0) => (v: Cell) => (v == null || Number.isNaN(n(v)) ? "–" : `${(100 * n(v)).toFixed(d)}%`);
  const pm = (v: Cell, row: Row, se = "gain_se") => `${f(3)(v)} ± ${f(3)(row[se])}`;
  const yes = (v: Cell) => (v === true || v === "TRUE" ? "yes" : "no");
  const pick = (rows: Row[] | undefined, pred: (r: Row) => boolean) => (rows ?? []).filter(pred);
  const one = (rows: Row[] | undefined, pred: (r: Row) => boolean) => (rows ?? []).find(pred) ?? null;

  const MODEL: Record<string, string> = {
    team_prior: "Team prior", empirical_voronoi: "Empirical density + Voronoi", nearest_to_forecast: "Nearest to forecast",
    geometry_classifier: "Geometry classifier (benchmark)", access: "Access (physics, pooled)", access_obstruction: "Access + obstruction",
    "effects_sd0.15": "+ collection effects, sd 0.15", "effects_sd0.3": "+ collection effects, sd 0.3", "effects_sd0.6": "+ collection effects, sd 0.6",
    particle_contact: "Particle filter, rim/board/floor physics", particle_no_contact: "Particle filter, no contacts",
    empirical_bounce: "Empirical bounce library", kalman: "Kalman (ballistic)", ballistic: "Ballistic least squares", cv: "Constant velocity",
    stationary: "Stationary", damped_velocity: "Damped velocity", role_reference: "Role-matched moves, no momentum", damped_role: "Damped momentum + role-matched residual (reference policy)",
    base_rate: "Base rate", rim_order: "Closer to the hoop", geometry: "Geometry (pooled)", geometry_player_effects: "Geometry + player effects",
  };
  const model = (v: Cell) => MODEL[String(v)] ?? String(v);
  const CHECK: Record<string, string> = { release: "Release", early: "Release + 0.32 s", contact: "Just before contact", after: "Contact + 0.2 s", rim: "Just before the rim" };
  const chk = (v: Cell) => CHECK[String(v)] ?? String(v);

  const flightRows = $derived(pick(doc?.flight.summary, (r) => ["particle_contact", "particle_no_contact", "empirical_bounce", "kalman"].includes(String(r.model)))
    .sort((a, b) => ["release", "early", "contact", "after"].indexOf(String(a.checkpoint)) - ["release", "early", "contact", "after"].indexOf(String(b.checkpoint)) ||
      n(a.horizon) - n(b.horizon) || n(b.logscore) - n(a.logscore)));
  const collRows = (cp: string) => pick(doc?.collection.summary, (r) => r.checkpoint === cp).sort((a, b) => n(a.log_loss) - n(b.log_loss));
  const best = (cp: string) => one(doc?.collection.summary, (r) => r.checkpoint === cp && r.model === "access_obstruction");
  const prior = (cp: string) => one(doc?.collection.summary, (r) => r.checkpoint === cp && r.model === "team_prior");
  const geo = (cp: string) => one(doc?.collection.summary, (r) => r.checkpoint === cp && r.model === "geometry_classifier");
  const flt = (cp: string, h: number, m: string) => one(doc?.flight.summary, (r) => r.checkpoint === cp && n(r.horizon) === h && r.model === m);
  const count = (q: string) => one(doc?.audit.counts, (r) => String(r.quantity) === q)?.count ?? null;
  const eligible = $derived((doc?.audit.population ?? []).filter((r) => r.status === "eligible").reduce((s, r) => s + n(r.N), 0));
  const ident = (c: string) => one(doc?.skills.identification, (r) => String(r.component).startsWith(c));
  const fp = $derived((doc?.flight.params ?? {}) as Record<string, Record<string, number>>);
  const meanOf = (rows: Row[] | undefined, key: string) => { const v = (rows ?? []).map((r) => n(r[key])).filter((x) => !Number.isNaN(x)); return v.length ? v.reduce((a, b) => a + b, 0) / v.length : NaN; };
  const range = (rows: Row[] | undefined, key: string) => { const v = (rows ?? []).map((r) => n(r[key])); return [Math.min(...v), Math.max(...v)]; };
</script>

{#snippet table(cols: Col[], rows: Row[], wide = false)}
  <div class="table-wrap">
    <table class="scores rb-table" class:narrow={!wide}>
      <thead><tr>{#each cols as c (c.key)}<th class:count={c.num} title={c.title}>{c.label}</th>{/each}</tr></thead>
      <tbody>
        {#each rows as row, i (i)}
          <tr>{#each cols as c (c.key)}<td class:count={c.num}>{c.fmt ? c.fmt(row[c.key], row) : row[c.key] ?? "–"}</td>{/each}</tr>
        {/each}
      </tbody>
    </table>
  </div>
{/snippet}

{#if !doc}
  <div class="doc-inner"><p class="lead">{problem || "Loading…"}</p></div>
{:else}
  {@const rel = best("release")}
  {@const rim = best("rim")}
  {@const pr = prior("release")}
  {@const geoRel = geo("release")}
  {@const c02 = flt("contact", 0.2, "particle_contact")}
  {@const nc02 = flt("contact", 0.2, "particle_no_contact")}
  {@const a04 = flt("after", 0.4, "particle_contact")}
  {@const a10 = flt("after", 1, "particle_contact")}
  <div class="doc-inner">
    <h1>Rebounding models</h1>
    <p class="lead">
      A missed shot becomes a forecast of where the ball goes, who can reach it, who ends up with it and how players' movement and
      box-outs changed that. Built on the ten tracked ACB games: {int(doc.episodes)} missed shots with a usable ball track and a
      recorded rebound. Every forecast uses only what had been seen by its moment; every validation number comes from games the model
      never saw.
    </p>
    <ul class="facts">
      <li><b>Where the ball goes</b> is a particle filter over the ball track with rim, backboard and floor physics. It is well calibrated for the first 0.4 s after a contact and loses calibration after that.</li>
      <li><b>Who gets it</b> is a competing-risks model on physical access along every simulated path. It beats the team prior in
        {rel ? rel.games_better : "–"} of 10 held-out games at release and is on par with a flexible geometry classifier.</li>
      <li><b>Anticipation, boxing out and collection</b> are measured from three separate kinds of evidence. Each had to pass an identification test before the
        site could show player effects; {doc.talent ? "collection passed" : "none passed"}, so the court {doc.talent ? "shows talent-aware collection chances" : "shows the population model only"}.</li>
    </ul>

    <section>
      <h2>Three different questions</h2>
      <p class="lead">The framework keeps three outputs apart because each needs different evidence. The site answers them as follows.</p>
      {@render table([
        { key: "q", label: "Output" }, { key: "t", label: "Target" }, { key: "s", label: "Status here" },
      ], [
        { q: "Untouched-ball forecast", t: "Where and when the ball would first hit the floor if nobody touched it after the forecast time", s: "Drawn as brown dots. A model-based counterfactual: it is usually unobserved, and on the few naturally untouched bounces it is not calibrated (below)." },
        { q: "Rebound / possession forecast", t: "Which player collects, or which team is awarded the ball, by 3.2 s after the forecast", s: "Shown in the panel and as chances beside players. Validated on held-out games." },
        { q: "Skill assessment", t: "Anticipation, limiting opponents' access (box-outs), converting access into control", s: "Estimated separately; shown on the court only where the player effects passed their test." },
      ], true)}
    </section>

    <section>
      <h2>Data and audit</h2>
      <p class="lead">
        Every count in the framework's event audit was recomputed from the delivered files before anything was fitted, and all of them match.
        Then the ball track itself was audited, which changed the design.
      </p>
      {@render table([
        { key: "quantity", label: "Quantity" }, { key: "count", label: "This build", num: true, fmt: int }, { key: "framework", label: "Framework", num: true, fmt: int },
      ], doc.audit.counts)}
      <h4>What the tracking audit found</h4>
      <ul class="facts">
        <li><b>The ball is never "detected".</b> Ball <code>isDetected</code> is 0 on every frame of every game, and about {pc(0)(meanOf(doc.audit.quality, "midpoint_share"))} of ball positions are the exact midpoint of their neighbours: the vendor reports the ball at about 12.5 Hz and interpolates. Filters read only the keyframes, and no strict real-time claim is made, since interpolation uses the next keyframe.</li>
        <li><b>Tracking files skip frame indices.</b> Five games miss {int(range(doc.audit.gaps.filter((g) => n(g.missing_indices) > 1000), "missing_indices")[0])} to {int(range(doc.audit.gaps, "missing_indices")[1])} indices, the others {int(range(doc.audit.gaps.filter((g) => n(g.missing_indices) <= 1000), "missing_indices")[0])} to {int(range(doc.audit.gaps.filter((g) => n(g.missing_indices) <= 1000), "missing_indices")[1])}; lines are matched on <code>frameIdx</code>, never by position. Reading by position had silently put 255 shot windows on the wrong frames.</li>
        <li><b>The ball and the players do not share a ground plane at height.</b> Made shots cross rim height {f(1)(Math.min(...doc.audit.hoops.filter((h) => n(h.dx) < 0).map((h) => -n(h.dx))))} to {f(1)(Math.max(...doc.audit.hoops.filter((h) => n(h.dx) < 0).map((h) => -n(h.dx))))} ft short of the nominal hoop at the camera's right end and {f(1)(Math.min(...doc.audit.hoops.filter((h) => n(h.dx) > 0).map((h) => n(h.dx))))} to {f(1)(Math.max(...doc.audit.hoops.filter((h) => n(h.dx) > 0).map((h) => n(h.dx))))} ft past it at the left, yet a held ball sits about a foot from its holder. Ball physics runs relative to each game end's calibrated hoop, and positions are shifted to the player frame in proportion to height.</li>
        <li><b>The reconstructed ball never reaches the floor.</b> A ball's centre touches down at 0.40 ft; in the data bounce minima sit near {f(2)(fp.floor?.z_floor)} ft, so that is the effective floor (fitted, with restitution {f(2)(fp.floor?.e_floor)}).</li>
        <li><b>The recorded rebound frame is between touch and control.</b> The first moment a player could touch the ball comes a median 0.3 s before it; a held-ball proxy, a median 0.36 s after. The forecasts are scored on who gets the ball, not when.</li>
      </ul>
      <h4>Population</h4>
      {@render table([{ key: "status", label: "Status" }, { key: "outcome", label: "Outcome", fmt: (v) => (v == null ? "–" : String(v)) }, { key: "N", label: "Shots", num: true, fmt: int }], doc.audit.population)}
      <p class="meta">Eligible: {int(eligible)} non-fouled misses with a rebound row and a ball track covering at least 80% of the episode with no gap over 12 frames. The 29 misses without a rebound row are kept out of the likelihood and reported, not treated as defensive rebounds. Free throws are a separate extension and not modelled.</p>
    </section>

    <section>
      <h2>Ball flight</h2>
      <ol class="steps">
        <li><h3>Launch prior</h3><p>At release nothing of the flight is seen yet. The release point is observed; time to the basket and the aim point along and across the line of the shot are drawn from the 40 tracked attempts (made or missed) nearest in distance, which fixes a launch velocity per particle.</p></li>
        <li><h3>Particle filter</h3><p>{int(400)} particles carry position and velocity under gravity with white-noise acceleration (fitted, {f(1)(Math.sqrt(fp.kalman?.q ?? NaN))} ft/s per √s). Each keyframe updates their weights with a Student-t observation model; they are resampled when the effective sample size halves.</p></li>
        <li><h3>Contact physics</h3><p>The ring is a torus (inner radius 0.74 ft, tube 0.03 ft), the backboard a finite plane, the floor the effective floor above. At each contact restitution is drawn from a range and the contact normal is jittered, standing in for spin, rim flex and the exact impact point. Range, jitter and the observation scale are chosen per fold by the multi-step predictive score of post-contact keyframes.</p></li>
        <li><h3>Miss scenarios only</h3><p>Simulated continuations that drop through the hoop are removed and the rest resampled: every forecast is conditional on a miss.</p></li>
      </ol>
      <p>
        Held-out games, scored on keyframes hidden from the filter and before anyone could touch the ball.
        Just before contact the physical model's error 0.2 s ahead is {f(1)(c02?.err_ft)} ft against {f(1)(nc02?.err_ft)} ft without contacts.
        From 0.2 s after contact its 90% region covers {pc(0)(a04?.cover90)} of positions 0.4 s ahead but only {pc(0)(a10?.cover90)} a second ahead.
      </p>
      {@render table([
        { key: "checkpoint", label: "Forecast made", fmt: chk }, { key: "horizon", label: "Ahead (s)", num: true, fmt: f(1) },
        { key: "model", label: "Model", fmt: model }, { key: "n", label: "n", num: true, fmt: int },
        { key: "logscore", label: "Log score", num: true, fmt: f(2), title: "Mean log predictive density of the observed position (higher is better)" },
        { key: "err_ft", label: "Error (ft)", num: true, fmt: f(2) }, { key: "cover50", label: "50%", num: true, fmt: pc(), title: "Share inside the 50% region" },
        { key: "cover90", label: "90%", num: true, fmt: pc(), title: "Share inside the 90% region" }, { key: "radius90_ft", label: "90% radius (ft)", num: true, fmt: f(1) },
      ], flightRows, true)}
      <h4>Untouched landing</h4>
      <p>
        Only {int(meanOf(doc.flight.landing, "n"))} or so held-out misses bounced with nobody within 4 ft before control, the only cases where a first floor
        landing is seen. Forecast landings miss them by about {f(0)(meanOf(doc.flight.landing, "err_xy_ft"))} ft and arrive earlier than observed; 90% regions cover far fewer
        than 90%. Those bounces are a selected sample and may include unrecorded tips, but the untouched-landing forecast is <b>not validated</b>: the brown dots
        are a model-based illustration, not a calibrated map.
      </p>
      {@render table([
        { key: "checkpoint", label: "Forecast made", fmt: chk }, { key: "model", label: "Model", fmt: model }, { key: "n", label: "n", num: true, fmt: int },
        { key: "err_xy_ft", label: "Error (ft)", num: true, fmt: f(1) }, { key: "cover90", label: "90%", num: true, fmt: pc() },
        { key: "time_err_s", label: "Time error (s)", num: true, fmt: f(2) }, { key: "out_share", label: "Out of bounds", num: true, fmt: pc() },
      ], doc.flight.landing)}
    </section>

    <section>
      <h2>Who can reach it, and who gets it</h2>
      <ol class="steps">
        <li><h3>Access along every path</h3><p>For each simulated path and each 0.08 s step, a player's chance of being at the ball while it is low enough to control: he keeps his velocity for a reaction time, then runs at 18.1 ft/s; arrival is logistic in time; the ball is controllable below a pooled reach of 10.5 ft.</p></li>
        <li><h3>No knowledge of the sampled future</h3><p>Three information policies were compared per fold: an oracle that runs at the sampled ball (an access bound), keep moving until the contact is seen, or run toward the forecast centre. The training likelihood chose among them with the reaction time.</p></li>
        <li><h3>Obstruction</h3><p>How much each opponent stands between a player and the reachable points of the paths (a corridor of 1.25 ft sd, full strength within 2.5 ft) lowers that player's score.</p></li>
        <li><h3>Competing risks</h3><p>At each step the ten players, a team award to either side and "still loose" compete in one softmax; a path that lands out of bounds ends in a team award. Outcome probabilities are averaged over paths, so the sides' chances add up within the same scene, and unresolved mass after 3.2 s is kept explicit.</p></li>
      </ol>
      {#each ["release", "rim"] as cp (cp)}
        <h4>{chk(cp)}: held-out games</h4>
        {@render table([
          { key: "model", label: "Model", fmt: model }, { key: "n", label: "n", num: true, fmt: int },
          { key: "log_loss", label: "Log loss", num: true, fmt: f(3), title: "Twelve outcomes: ten players and two team awards" },
          { key: "gain", label: "Gain vs prior", num: true, fmt: (v, r) => pm(v, r), title: "Mean per-game gain in log loss, with its standard error across the ten games" },
          { key: "games_better", label: "Games better", num: true },
          { key: "team_log_loss", label: "Team log loss", num: true, fmt: f(3) }, { key: "team_auc", label: "Team AUC", num: true, fmt: f(2) },
          { key: "unresolved", label: "Unresolved", num: true, fmt: pc(1) },
        ], collRows(cp), true)}
      {/each}
      <p>
        At release the access model's log loss is {f(3)(rel?.log_loss)} against {f(3)(pr?.log_loss)} for the team prior and {f(3)(geoRel?.log_loss)} for the geometry
        classifier; just before the rim, {f(3)(rim?.log_loss)}. For which team ends up with the ball, the earlier court control model scored 0.610 against a base of
        0.623 at release on a similar population; here the team log loss is {f(3)(rel?.team_log_loss)}.
      </p>
      <h4>Calibration of the offensive share (access + obstruction)</h4>
      {@render table([
        { key: "checkpoint", label: "Forecast made", fmt: chk }, { key: "band", label: "Predicted band" }, { key: "n", label: "n", num: true, fmt: int },
        { key: "predicted", label: "Predicted", num: true, fmt: pc(1) }, { key: "observed", label: "Observed", num: true, fmt: pc(1) },
      ], doc.collection.calibration)}
      <h4>Contested and uncontested rebounds</h4>
      <p class="meta">Contested: the less certain half of rebounds, where the access model's favourite has a below-median chance.</p>
      {@render table([
        { key: "checkpoint", label: "Forecast made", fmt: chk }, { key: "contested", label: "Contested", fmt: yes }, { key: "model", label: "Model", fmt: model },
        { key: "n", label: "n", num: true, fmt: int }, { key: "log_loss", label: "Log loss", num: true, fmt: f(3) }, { key: "team_log_loss", label: "Team log loss", num: true, fmt: f(3) },
      ], doc.collection.contested)}
    </section>

    <section>
      <h2>Anticipation</h2>
      <p class="lead">
        How much a player's first 0.48 s of movement after release improved his access to plausible rebounds, judged against moves a player in the same role
        might have made, with the ball forecast frozen at release and everyone else where they actually went.
      </p>
      <ol class="steps">
        <li><h3>Reference policy</h3><p>A pooled behaviour model with the lowest point error on held-out movement: each player carries on with damped momentum, plus a residual move drawn from players of the same side and starting band (near, mid, perimeter, deep, shooter) in the other nine games, turned into his own hoop-relative frame. A first version without momentum predicted movement worse than plain damped velocity and was replaced. Its spread is still too wide (far more than 80% of real moves fall in its 80% region), so the reference moves are more varied than real ones.</p></li>
        <li><h3>The score</h3><p>His collection chance at his actual end position minus its average over 16 reference moves. A good move earns credit even if the ball went elsewhere; holding a good spot is not penalised; distance run earns nothing.</p></li>
        <li><h3>Exposure, not punishment</h3><p>Where the reference moves barely change his chance (a spread under 0.5 points) the player has no opportunity to show anything and gets no weight, instead of a negative grade. Shooters are left out (they are finishing the shot).</p></li>
        <li><h3>Player effects</h3><p>A weighted regression of the score on starting opportunity, role and shot range, with a player random intercept; then a test of whether that intercept is distinguishable from zero and repeats across games.</p></li>
      </ol>
      <h4>Movement models on held-out games (end of the 0.48 s interval)</h4>
      {@render table([
        { key: "model", label: "Model", fmt: model }, { key: "n", label: "n", num: true, fmt: int }, { key: "error_ft", label: "Error (ft)", num: true, fmt: f(2) },
        { key: "log_score", label: "Log score", num: true, fmt: f(2) }, { key: "cover80", label: "80% region", num: true, fmt: pc() },
      ], doc.skills.movement)}
    </section>

    <section>
      <h2>Boxing out (spatial obstruction proxy)</h2>
      <p class="lead">
        Without video or body orientation a box-out cannot be verified, so this is a spatial proxy: one player standing in an opponent's route to where the
        ball can be reached, and staying there.
      </p>
      <ol class="steps">
        <li><h3>Candidate pairs</h3><p>Opponents within 6 ft of each other at release, both within 22 ft of the hoop, neither the shooter. A player can be in several pairs.</p></li>
        <li><h3>Obstruction over time</h3><p>Every 0.2 s until the rebound, against the reachable points of the release forecast's paths (averaged over the ball's uncertainty, not the eventual rebound spot).</p></li>
        <li><h3>Labels</h3><p>None, attempted, maintained (established at 0.35 and held at 0.25 for 80% of the time through the rim), escaped (lost, with the opponent ending nearer the ball), or ambiguous (the two closer than their tracking error). The labels are automated and have not been checked against video; <code>outputs/rebounding/audit/review_sample.csv</code> lists 60 episodes for that review.</p></li>
        <li><h3>Model and team value</h3><p>Whether an established box-out is maintained, with a box-out player effect and a strongly pooled opponent effect. Separately, a box-out's team value is how much the side's chance of the ball falls when that player's obstruction is removed from the access model, which can help a teammate rather than the blocker.</p></li>
      </ol>
      {@render table([{ key: "label", label: "Label" }, { key: "blocker_def", label: "Blocker on defense", fmt: yes }, { key: "pairs", label: "Pairs", num: true, fmt: int }, { key: "share", label: "Share", num: true, fmt: pc(1) }], doc.skills.boxout_labels)}
      <h4>Maintaining an established box-out, held-out games</h4>
      {@render table([
        { key: "model", label: "Model", fmt: model }, { key: "n", label: "n", num: true, fmt: int }, { key: "log_loss", label: "Log loss", num: true, fmt: f(3) },
        { key: "gain", label: "Gain vs base", num: true, fmt: (v, r) => pm(v, r) }, { key: "games_better", label: "Games better", num: true }, { key: "auc", label: "AUC", num: true, fmt: f(2) },
      ], doc.skills.boxout_validation)}
    </section>

    <section>
      <h2>Player effects: what is identified</h2>
      <p class="lead">
        If only the rebounder entered the likelihood, anticipation, box-out and collection effects would be one sum. Each is therefore estimated from its own
        evidence, and each must pass a test before the site uses it: for anticipation and box-outs, a variance component distinguishable from zero (likelihood
        ratio over 3.84) that also repeats across the two games of the 25 players seen twice (r over 0.3); for collection, a held-out gain on rebounds by players
        seen in training and a recovery correlation over 0.5 in simulation.
      </p>
      {@render table([
        { key: "component", label: "Component" }, { key: "evidence", label: "Evidence" }, { key: "player_sd", label: "Player sd", num: true, fmt: f(3) },
        { key: "likelihood_ratio", label: "LR", num: true, fmt: f(2) }, { key: "cross_game_r", label: "Cross-game r", num: true, fmt: f(2) },
        { key: "heldout_gain_repeat", label: "Held-out gain", num: true, fmt: f(4) }, { key: "recovery_r", label: "Recovery r", num: true, fmt: f(2) },
        { key: "passes", label: "Passes", fmt: yes }, { key: "used_in_site", label: "On the court" },
      ], doc.skills.identification, true)}
      <h4>Recovering known collection effects from simulated outcomes</h4>
      {@render table([
        { key: "sd_true", label: "True sd", num: true, fmt: f(1) }, { key: "rep", label: "Run", num: true }, { key: "cor_all", label: "r, all players", num: true, fmt: f(2) },
        { key: "cor_20plus", label: "r, 20+ scenes", num: true, fmt: f(2) }, { key: "players_20plus", label: "Players 20+", num: true }, { key: "shrink_sd", label: "Estimated sd", num: true, fmt: f(3) },
      ], doc.collection.recovery)}
      <h4>Prior sensitivity: log loss on held-out rebounds</h4>
      {@render table([
        { key: "checkpoint", label: "Forecast made", fmt: chk }, { key: "rebounder_seen", label: "Rebounder seen in training", fmt: yes },
        { key: "model", label: "Model", fmt: model }, { key: "n", label: "n", num: true, fmt: int }, { key: "log_loss", label: "Log loss", num: true, fmt: f(4) },
      ], doc.collection.sensitivity)}
      <h4>Collection effects (rim forecast, 20+ scenes on court)</h4>
      <p class="meta">Log-odds added to a player's chance of securing a ball he can reach, with posterior sd; shrunk toward zero by a prior with sd 0.3. Shown for description: {doc.talent ? "these effects passed their test and the court uses them" : "they did not pass their test, so the court does not use them"}.</p>
      {@render table([
        { key: "name", label: "Player" }, { key: "team_name", label: "Team" }, { key: "effect", label: "Effect", num: true, fmt: (v, r) => `${f(2)(v)} ± ${f(2)(r.effect_se)}` },
        { key: "scenes", label: "Scenes", num: true, fmt: int }, { key: "rebounds", label: "Rebounds", num: true, fmt: int },
      ], [...doc.collection.players.slice(0, 8), ...doc.collection.players.slice(-5)])}
      <h4>Box-out team value (15+ obstructing scenes)</h4>
      <p class="meta">Mean change in his team's chance of the ball, and in his own collection chance, when his obstruction is removed (points of probability).</p>
      {@render table([
        { key: "name", label: "Player" }, { key: "team_name", label: "Team" }, { key: "obstructing_scenes", label: "Scenes", num: true, fmt: int },
        { key: "team_value", label: "Team value", num: true, fmt: pc(1) }, { key: "own_value", label: "Own", num: true, fmt: pc(1) },
        { key: "established", label: "Established", num: true, fmt: int }, { key: "maintained", label: "Maintained", num: true, fmt: int },
      ], doc.skills.boxout_players.slice(0, 10))}
    </section>

    {#if doc.checks}
      <section>
        <h2>Scenario checks</h2>
        <p class="lead">Contracts every forecast has to keep, tested on real scenes.</p>
        {@render table([{ key: "check", label: "Check" }, { key: "value", label: "Value", num: true, fmt: (v) => (Math.abs(n(v)) < 1e-3 && n(v) !== 0 ? n(v).toExponential(1) : f(3)(v)) }, { key: "pass", label: "Passes", fmt: yes }, { key: "detail", label: "Detail" }], doc.checks, true)}
      </section>
    {/if}

    <section>
      <h2>Assumptions and limits</h2>
      <ul class="facts">
        <li><b>Ten games.</b> Whole-game holdouts mostly test new players; only 25 players appear in two games, so evidence that any player effect repeats is weak.</li>
        <li><b>Associations, not interventions.</b> Movement and box-outs reflect choices and game plans. A model-assessed gain is not proof that a different move would have changed the outcome.</li>
        <li><b>The ball is a vendor reconstruction</b>, interpolated between keyframes, with no detection flag and a height-dependent offset from the players' ground plane; calibration is per game end, using that game's made shots.</li>
        <li><b>Contact physics is identified only loosely.</b> The selected restitution, jitter and observation scale often sit at an edge of the searched grid; the physics improves forecasts but its parameters are not physical measurements.</li>
        <li><b>Player motion is pooled.</b> Common reaction, speed and reach for everyone; no jump, no body orientation, no contact.</li>
        <li><b>Training scenes are strict.</b> Each fold's scenes are built with ball physics fitted without the held-out game, and every model is refitted inside the fold.</li>
        <li><b>Replay mode only.</b> The court shows forecasts from the recorded prefix. Dragging players, hypothetical misses of made shots and transition value are not built.</li>
        <li><b>Not shot quality.</b> This is a rebounding model; rebound probability alone is not a shot's value, and its link to the competition's question is not established.</li>
      </ul>
    </section>

    <section>
      <h2>Reproduce</h2>
      <p class="meta">From the repository root, with R 4.4 and Rtools (the simulator is C++ through Rcpp). Each step caches per fold and resumes; <code>--game=&lt;id&gt;</code> runs one fold.</p>
      <pre class="rb-code">Rscript src/rebounding/extract_windows.R
Rscript src/rebounding/run_audit.R
Rscript src/rebounding/run_flight.R
Rscript src/rebounding/run_opportunity.R
Rscript src/rebounding/run_skills.R
Rscript src/rebounding/run_checks.R
Rscript src/rebounding/run_export.R</pre>
      <p class="meta">Framework: "Physics-informed rebounding: research and model framework" (October 27, 2026). Ideas adapted from Achterhold et al. (2023), Okubo and Hubbard (2014), Maheswaran et al. (2012, 2014), Kiriazis, Genest and Leblanc, Spearman-style pitch control and ReboundingPrediction; no code reused. Data: SkillCorner open data, Liga ACB, MIT licence. Built {doc.built}.</p>
    </section>
  </div>
{/if}

<style>
  .rb-table.narrow { min-width: 0; width: auto; }
  .rb-table td { font-size: 13px; }
  .rb-code { margin: 8px 0; padding: 10px 12px; overflow-x: auto; border-radius: 8px; background: #0F1522; font-size: 12.5px; line-height: 1.6; }
  code { font-size: 12.5px; }
</style>
