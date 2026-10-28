<script lang="ts">
  // The Rebounding tab: a walk through the rebounding models in the order they were built. Each stage shows what the
  // ten games' data say, the modelling decision that follows from it, and how that decision was checked on games the
  // model never saw. Every number is read from rebounding.json (src/rebounding/run_eda.R and run_export.R write it
  // from outputs/rebounding/), so the text cannot drift from the results; only the explanations are written here.
  import { loadReboundDoc } from "../lib/data";
  import Columns from "./charts/Columns.svelte";
  import CourtMap from "./charts/CourtMap.svelte";
  import { gridOf, kde, peak } from "./charts/kde";
  import RateDots from "./charts/RateDots.svelte";
  import Scatter from "./charts/Scatter.svelte";
  import ReboundFinder from "./ReboundFinder.svelte";
  import { SERIES } from "./charts/scale";

  type Cell = number | string | boolean | null | undefined;
  type Row = Record<string, Cell>;
  interface Doc {
    built: string;
    talent: boolean;
    episodes: number;
    checks: Row[] | null;
    eda: Record<string, Row[]>;
    audit: Record<"counts" | "population" | "by_game" | "quality" | "hoops" | "gaps" | "timeline" | "held", Row[]>;
    flight: { params: Record<string, Record<string, number>>; summary: Row[]; landing: Row[]; folds: Row[]; grid: Row[] };
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

  // ---- formatting ----
  const n = (v: Cell) => (typeof v === "number" ? v : Number(v));
  const f = (d: number) => (v: Cell) => (v == null || Number.isNaN(n(v)) ? "–" : n(v).toFixed(d));
  const int = (v: Cell) => (v == null || Number.isNaN(n(v)) ? "–" : Math.round(n(v)).toLocaleString("en-US"));
  const pc = (d = 0) => (v: Cell) => (v == null || Number.isNaN(n(v)) ? "–" : `${(100 * n(v)).toFixed(d)}%`);
  const pm = (v: Cell, row: Row, se = "gain_se") => `${f(3)(v)} ± ${f(3)(row[se])}`;
  const yes = (v: Cell) => (v === true || v === "TRUE" ? "yes" : "no");
  const one = (rows: Row[] | undefined, pred: (r: Row) => boolean) => (rows ?? []).find(pred) ?? null;
  const E = (name: string): Row[] => doc?.eda?.[name] ?? [];
  const val = (name: string, key: string, term: string) => n(one(E(name), (r) => r.term === term)?.[key]);

  const MODEL: Record<string, string> = {
    team_prior: "Team prior", empirical_voronoi: "Empirical density + Voronoi", nearest_to_forecast: "Nearest to the forecast",
    geometry_classifier: "Geometry classifier (benchmark)", access: "Access (physics)", access_obstruction: "Access + obstruction (used)",
    "effects_sd0.15": "+ player effects, sd 0.15", "effects_sd0.3": "+ player effects, sd 0.3", "effects_sd0.6": "+ player effects, sd 0.6",
    particle_contact: "Particle filter with contacts (used)", particle_no_contact: "Particle filter, no contacts",
    empirical_bounce: "Empirical bounce library", kalman: "Kalman filter", ballistic: "Ballistic fit", cv: "Constant velocity",
    stationary: "Stationary", damped_velocity: "Damped velocity", role_reference: "Typical moves, no momentum",
    damped_role: "Damped momentum + typical move (used)",
    base_rate: "Base rate", rim_order: "Closer to the hoop", geometry: "Geometry", geometry_player_effects: "Geometry + player effects",
  };
  const model = (v: Cell) => MODEL[String(v)] ?? String(v);
  const CHECK: Record<string, string> = { release: "At release", early: "Release + 0.32 s", contact: "Just before contact", after: "Contact + 0.2 s", rim: "Just before the rim" };
  const chk = (v: Cell) => CHECK[String(v)] ?? String(v);
  const OUT: Record<string, string> = { "def player": "Defense collects", "off player": "Offense collects", "off team award": "Offense awarded", "def team award": "Defense awarded" };

  // ---- derived inputs for charts ----
  const rates = (rows: Row[], key: string, label = (v: Cell) => String(v)) =>
    rows.map((r) => ({ label: label(r[key]), rate: n(r.rate), lo: n(r.lo), hi: n(r.hi), n: n(r.n) }));
  const overall = $derived.by(() => {
    const o = E("outcomes");
    const tot = o.reduce((s, r) => s + n(r.N), 0);
    const off = o.filter((r) => String(r.outcome).startsWith("off")).reduce((s, r) => s + n(r.N), 0);
    return tot ? off / tot : NaN;
  });
  const spots = $derived(E("rebound_spots"));
  const byRange = (range: string) => spots.filter((r) => r.range === range).map((r) => ({ x: n(r.rx), y: n(r.ry) }));
  // Shots are described by range: at the rim (under 5 ft), midrange (every other two) and three.
  const RANGES = ["rim (<5 ft)", "midrange (other 2s)", "three"];
  const RANGE_TITLE: Record<string, string> = { "rim (<5 ft)": "Rim (under 5 ft)", "midrange (other 2s)": "Midrange (other 2s)", three: "Three" };
  // One colour scale for the three maps (their densest cell), so the same shade means the same share in each.
  const mapMax = $derived(Math.max(...RANGES.map((rg) => peak(kde(byRange(rg), gridOf(-30, 5.6, -24.6, 24.6), 1.5)))));
  const finderSpots = $derived(spots.map((r) => ({ sx: n(r.sx), sy: n(r.sy), rx: n(r.rx), ry: n(r.ry), off: r.off === true || r.off === "TRUE" })));
  const spotScatter = $derived(spots.map((r) => ({ x: n(r.shot_dist), y: n(r.r), g: r.off === true || r.off === "TRUE" ? 0 : 1,
                                                   tip: `Shot from ${f(0)(r.shot_dist)} ft, rebound ${f(1)(r.r)} ft from the hoop` })));
  // Each range's median rebound distance, drawn across the shot distances that range covers.
  const medianLines = $derived(RANGES.map((rg) => {
    const rows = spots.filter((r) => r.range === rg), d = rows.map((r) => n(r.shot_dist));
    const m = n(one(E("rebound_distance_by_range"), (r) => r.range === rg)?.median_r);
    return { points: [[Math.min(...d), m], [Math.max(...d), m]] as [number, number][], label: `median ${f(1)(m)} ft`, color: "var(--ink)" };
  }).filter((l) => l.points.every((q) => Number.isFinite(q[0]) && Number.isFinite(q[1]))));
  const angleCats = ["0-30°", "30-60°", "60-90°", "90-120°", "120-150°", "150-180°"];
  const angleSeries = $derived(RANGES.map((rg, j) => {
    const rows = E("rebound_angle").filter((r) => r.range === rg);
    const tot = rows.reduce((s, r) => s + n(r.n), 0);
    return { name: RANGE_TITLE[rg], values: rows.map((r) => n(r.n) / tot), color: SERIES[j] };
  }));
  const timing = $derived(E("timing"));
  const flightPts = $derived(timing.filter((r) => r.t_contact != null && !Number.isNaN(n(r.t_contact)))
    .map((r) => ({ x: n(r.shot_dist), y: n(r.t_contact) })));
  const flightLine = $derived.by((): [number, number][] => {
    const a = val("flight_time_fit", "value", "intercept"), b = val("flight_time_fit", "value", "per_ft");
    return [[0, a], [30, a + 30 * b]];
  });
  const hist = (key: string, lo: number, hi: number, step: number) => {
    const cats: string[] = [], vals: number[] = [];
    for (let v = lo; v < hi - 1e-9; v += step) {
      cats.push(v.toFixed(1));
      vals.push(timing.filter((r) => r[key] != null && n(r[key]) >= v && n(r[key]) < v + step).length);
    }
    return { cats, vals };
  };
  const touchHist = $derived(hist("touch_vs_rebound", -1.6, 1.6, 0.2));
  const controlHist = $derived(hist("control_vs_rebound", -1.6, 1.6, 0.2));
  const example = $derived(E("example_track"));
  const exEvents = $derived(E("example_events").filter((r) => r.t != null && !Number.isNaN(n(r.t))).map((r) => ({ x: n(r.t), label: String(r.event) })));
  const minima = $derived(E("bounce_minima").filter((r) => n(r.z) >= 0 && n(r.z) <= 4));
  const belowZero = $derived(E("bounce_minima").filter((r) => n(r.z) < 0).reduce((s, r) => s + n(r.n), 0));
  const allMinima = $derived(E("bounce_minima").reduce((s, r) => s + n(r.n), 0));
  const crossings = $derived(E("hoop_crossings").map((r) => ({ x: n(r.dx), y: n(r.dy), g: r.end === "camera right" ? 0 : 1,
                                                               tip: `Game ${r.game_id}, ${r.end}: ${f(2)(r.dx)} ft along, ${f(2)(r.dy)} ft across` })));
  const rankCats = Array.from({ length: 10 }, (_, i) => String(i + 1));
  const rankSeries = (name: string) => ["release", "rim"].map((cp, j) => ({
    name: chk(cp), color: SERIES[j],
    values: rankCats.map((k) => n(one(E(name), (r) => r.checkpoint === cp && String(r.rank) === k)?.share ?? 0)),
  }));
  const nearestWins = (cp: string) => n(one(E("nearest_team_wins"), (r) => r.checkpoint === cp)?.nearest_team_wins);
  const movePts = $derived(E("movement_sample").map((r) => ({ x: n(r.proj), y: n(r.moved), g: r.off === true || r.off === "TRUE" ? 0 : 1 })));
  const damp = $derived(val("damping", "value", "position_factor"));
  const roleRows = $derived(E("movement_by_role"));
  const players = $derived(E("player_evidence"));
  const league = $derived(n(E("player_league_rate")[0]?.league_rate));
  const funnel = $derived(players.map((r) => ({ x: n(r.scenes), y: n(r.rebounds) / n(r.scenes), g: n(r.def_share) >= 0.5 ? 1 : 0,
                                                tip: `${r.rebounds} rebounds in ${r.scenes} misses on court (${r.games} game${n(r.games) > 1 ? "s" : ""})` })));
  const band = (sign: number): [number, number][] => Array.from({ length: 46 }, (_, i) => {
    const m = 2 + 2 * i;
    return [m, Math.max(0, league + sign * 1.645 * Math.sqrt((league * (1 - league)) / m))];
  });
  const flightCover = $derived.by(() => ["particle_contact", "particle_no_contact", "kalman"].map((m, j) => ({
    label: model(m), color: SERIES[j],
    points: (doc?.flight.summary ?? []).filter((r) => r.checkpoint === "contact" && r.model === m)
      .map((r): [number, number] => [n(r.horizon), n(r.cover90)]).sort((a, b) => a[0] - b[0]),
  })));
  const calPts = (cp: string) => (doc?.collection.calibration ?? []).filter((r) => r.checkpoint === cp && n(r.n) >= 10)
    .map((r) => ({ x: n(r.predicted), y: n(r.observed), g: cp === "release" ? 0 : 1, tip: `${chk(cp)}: predicted ${pc(1)(r.predicted)}, observed ${pc(1)(r.observed)} (n ${r.n})` }));
  const ladder = (cp: string) => (doc?.collection.summary ?? []).filter((r) => r.checkpoint === cp && r.model !== "team_prior")
    .sort((a, b) => n(b.gain) - n(a.gain))
    .map((r) => ({ label: model(r.model), rate: n(r.gain), lo: n(r.gain) - 1.645 * n(r.gain_se), hi: n(r.gain) + 1.645 * n(r.gain_se), n: n(r.n) }));
  const best = (cp: string, m = "access_obstruction") => one(doc?.collection.summary, (r) => r.checkpoint === cp && r.model === m);
  const flt = (cp: string, h: number, m: string) => one(doc?.flight.summary, (r) => r.checkpoint === cp && n(r.horizon) === h && r.model === m);
  const ident = (c: string) => one(doc?.skills.identification, (r) => String(r.component).startsWith(c));
  const fp = $derived((doc?.flight.params ?? {}) as Record<string, Record<string, number>>);
  const meanOf = (rows: Row[] | undefined, key: string) => { const v = (rows ?? []).map((r) => n(r[key])).filter((x) => !Number.isNaN(x)); return v.length ? v.reduce((a, b) => a + b, 0) / v.length : NaN; };
  const rangeOf = (rows: Row[] | undefined, key: string) => { const v = (rows ?? []).map((r) => n(r[key])); return [Math.min(...v), Math.max(...v)]; };
  const median = (rows: Row[], key: string) => { const v = rows.map((r) => n(r[key])).filter((x) => !Number.isNaN(x)).sort((a, b) => a - b); return v.length ? v[Math.floor(v.length / 2)] : NaN; };

  const SECTIONS = [
    ["rb-question", "1. The question"], ["rb-data", "2. The data"], ["rb-ball", "3. Can we trust the ball?"],
    ["rb-where", "4. Where misses go"], ["rb-flight", "5. Ball-flight model"], ["rb-who", "6. Who gets the ball"],
    ["rb-collect", "7. Collection model"], ["rb-move", "8. Movement and anticipation"], ["rb-box", "9. Box-outs"],
    ["rb-players", "10. Player effects"], ["rb-checks", "11. Checks and limits"],
  ];
  // Plain scrolling: the page's address names the tab (#/rebounding), so section links must not change it.
  const go = (id: string) => document.getElementById(id)?.scrollIntoView({ behavior: "smooth", block: "start" });
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

{#snippet decision(text: string)}
  <div class="decision"><b>Decision</b><span>{text}</span></div>
{/snippet}

{#if !doc}
  <div class="doc-inner"><p class="lead">{problem || "Loading…"}</p></div>
{:else}
  {@const rel = best("release")}
  {@const rim = best("rim")}
  {@const pr = best("release", "team_prior")}
  {@const geoRel = best("release", "geometry_classifier")}
  {@const geoRim = best("rim", "geometry_classifier")}
  {@const c02 = flt("contact", 0.2, "particle_contact")}
  {@const nc02 = flt("contact", 0.2, "particle_no_contact")}
  {@const k02 = flt("contact", 0.2, "kalman")}
  {@const a04 = flt("after", 0.4, "particle_contact")}
  {@const a10 = flt("after", 1, "particle_contact")}
  {@const shortR = one(E("rebound_distance_by_range"), (r) => r.range === RANGES[0])}
  {@const midR = one(E("rebound_distance_by_range"), (r) => r.range === RANGES[1])}
  {@const longR = one(E("rebound_distance_by_range"), (r) => r.range === RANGES[2])}
  <div class="doc-inner rb-doc">
    <h1>Rebounding: from data to model</h1>
    <p class="lead">
      A missed shot becomes a forecast: where the ball goes, who can reach it, and who ends up with it. This page walks
      through how that forecast was built from the ten tracked ACB games, in the order the decisions were made. Each step
      shows <b>what the data say</b>, the <b>decision</b> that follows, and <b>how it was checked</b> on games the model
      never saw. It doubles as a tutorial: the modelling ideas are explained where they first appear.
    </p>
    <nav class="rb-toc" aria-label="On this page">
      {#each SECTIONS as [id, label] (id)}<button type="button" class="link" onclick={() => go(id)}>{label}</button>{/each}
    </nav>

    <!-- 1 ------------------------------------------------------------------------------------------------- -->
    <section id="rb-question">
      <h2>1. The question</h2>
      <p>
        When a shot goes up, two things are uncertain: whether it goes in, and if it misses, which team gets the ball.
        This work is only about the second. Every forecast here assumes the shot misses, and is made at a moment
        <i>t</i> after the release using only the tracking seen up to <i>t</i>. The forecast at release knows where everyone
        stands and where the shot came from; the forecast a second later also knows how the ball came off the rim.
      </p>
      <p>The framework asks for three outputs and keeps them apart, because each needs different evidence:</p>
      {@render table([{ key: "q", label: "Output" }, { key: "t", label: "What it means" }, { key: "s", label: "Where it stands" }], [
        { q: "Untouched landing", t: "Where the ball would first hit the floor if nobody touched it", s: "On the court in violet. Almost never observed (someone usually touches it first), and where it is observed the forecast is off: treat it as an illustration (section 5)." },
        { q: "Who gets the ball", t: "Each player's chance of collecting it, and each team's chance of being awarded it, within 3.2 s", s: "In the panel and beside the players. Validated on held-out games (section 7)." },
        { q: "Player skills", t: "Anticipation, boxing out, converting access into the ball", s: "Estimated, but none could be told apart from noise with ten games, so none is used (section 10)." },
      ], true)}
    </section>

    <!-- 2 ------------------------------------------------------------------------------------------------- -->
    <section id="rb-data">
      <h2>2. The data</h2>
      <p>
        The ten games have {int(one(doc.audit.counts, (r) => r.quantity === "Shot records, including fouled misses")?.count)} shot records.
        Fouled misses go to the free-throw line and made shots have no rebound, which leaves
        {int(one(doc.audit.counts, (r) => r.quantity === "Non-fouled misses")?.count)} live misses. Of those, {int(doc.episodes)}
        have a recorded rebound and a usable ball track; they are the population every model and chart below uses.
      </p>
      <div class="rb-grid two">
        <div>
          <h4>How the {int(doc.episodes)} misses ended</h4>
          <Columns categories={E("outcomes").map((r) => OUT[String(r.outcome)] ?? String(r.outcome))}
                   series={[{ name: "Share", values: E("outcomes").map((r) => n(r.share)) }]} format={(v) => `${Math.round(100 * v)}%`} labels />
        </div>
        <div class="rb-explain">
          <h4>Collected or awarded</h4>
          <p>
            <b>Collected</b>: a player secures the ball (a rebound credited to him). <b>Awarded</b>: nobody secures it and the
            referees give the ball to a team, usually because it went out of bounds, sometimes after a held ball or a foul.
            The box score calls that a team rebound. Awards are {pc(0)(E("outcomes").filter((r) => String(r.outcome).includes("award")).reduce((s, r) => s + n(r.share), 0))}
            of misses and go to the offense more often than not.
          </p>
          <p>
            Overall the offense keeps the ball after {pc(0)(overall)} of misses. That base rate is the "team prior" every
            model below has to beat.
          </p>
        </div>
      </div>
      {@render decision("Predict one of twelve outcomes: which of the ten players collects, or which team is awarded the ball. Team chances are sums of those. The 29 misses with no rebound row are left out and reported, not counted as defensive rebounds.")}
      <details class="rb-more">
        <summary>The framework's event audit, recomputed</summary>
        {@render table([{ key: "quantity", label: "Quantity" }, { key: "count", label: "This build", num: true, fmt: int }, { key: "framework", label: "Framework", num: true, fmt: int }], doc.audit.counts)}
        {@render table([{ key: "status", label: "Status" }, { key: "outcome", label: "Outcome", fmt: (v) => (v == null ? "–" : String(v)) }, { key: "N", label: "Shots", num: true, fmt: int }], doc.audit.population)}
      </details>
    </section>

    <!-- 3 ------------------------------------------------------------------------------------------------- -->
    <section id="rb-ball">
      <h2>3. Can we trust the ball?</h2>
      <p>
        A physics model of the ball is only as good as the ball's track, so the track was audited before anything was
        fitted. Four findings shaped the models.
      </p>
      <div class="rb-grid two">
        <div>
          <h4>One miss, ball height over time</h4>
          <Scatter points={example.map((r) => ({ x: n(r.t), y: n(r.z), g: r.key === true || r.key === "TRUE" ? 0 : 1,
                                                  tip: `${f(2)(r.t)} s: ${f(2)(r.z)} ft${r.key === true || r.key === "TRUE" ? "" : " (interpolated)"}` }))}
                   lines={[{ points: example.map((r): [number, number] => [n(r.t), n(r.z)]), color: "var(--muted)" }]}
                   groups={["Keyframe", "Midpoint of its neighbours"]} events={exEvents} xlabel="Seconds after release" ylabel="Ball height (ft)"
                   radius={3.5} opacity={0.9} />
        </div>
        <div class="rb-explain">
          <h4>The ball is reconstructed, not seen</h4>
          <p>
            The ball's <code>isDetected</code> flag is 0 on every frame of every game, and
            {pc(0)(meanOf(doc.audit.quality, "midpoint_share"))} of its positions sit exactly halfway between their neighbours: the
            vendor reports the ball about 12.5 times a second and fills the frames between by straight lines. Notice the
            orange points on the chart. They add no information, and the interpolation uses the <i>next</i> keyframe, so the
            track is not strictly real-time.
          </p>
        </div>
      </div>
      {@render decision("Filters read keyframes only, and no strict real-time claim is made.")}
      <div class="rb-grid two">
        <div>
          <h4>Lowest point of the ball at each bounce</h4>
          <Columns categories={minima.map((r) => f(1)(r.z))} series={[{ name: "Bounces", values: minima.map((r) => n(r.n)) }]}
                   xlabel="Height of the ball's centre at the bottom of a bounce (ft)" format={(v) => String(Math.round(v))}
                   marks={minima.findIndex((r) => Math.abs(n(r.z) - 0.4) < 1e-6) >= 0 ? [{ at: minima.findIndex((r) => Math.abs(n(r.z) - 0.4) < 1e-6), label: "ball radius 0.40 ft" }] : []} />
        </div>
        <div class="rb-explain">
          <h4>It never reaches the floor</h4>
          <p>
            A ball's centre touches down at its radius, 0.40 ft. In the data, bounce minima pile up between 1.0 and 1.6 ft,
            consistent with keyframes skipping the instant of contact ({pc(0)(belowZero / allMinima)} of minima are even below zero, calibration noise, and left off the chart). The fitted effective floor is
            {f(2)(fp.floor?.z_floor)} ft with restitution {f(2)(fp.floor?.e_floor)} (how much vertical speed survives a bounce).
          </p>
        </div>
      </div>
      {@render decision(`The simulated ball bounces at an effective floor of ${f(2)(fp.floor?.z_floor)} ft, fitted from observed bounces, not at its true radius.`)}
      <div class="rb-grid two">
        <div>
          <h4>Where made shots pass rim height, relative to the nominal hoop</h4>
          <Scatter points={crossings} groups={["Camera's right basket", "Camera's left basket"]} xlabel="Along the court (ft, + = toward the endline)"
                   ylabel="Across (ft)" xdomain={[-3, 3]} ydomain={[-2.5, 2.5]}
                   lines={[{ points: [[0, -2.5], [0, 2.5]], color: "var(--muted)", dashed: true }]} radius={3.5} />
        </div>
        <div class="rb-explain">
          <h4>The ball and the players disagree at height</h4>
          <p>
            A made shot must pass within a few inches of the hoop's centre. In the data it crosses rim height about
            {f(1)(-meanOf(doc.audit.hoops.filter((h) => n(h.dx) < 0), "dx"))} ft short of the nominal hoop at one end and
            {f(1)(meanOf(doc.audit.hoops.filter((h) => n(h.dx) > 0), "dx"))} ft past it at the other, in every game. A ball being held,
            by contrast, sits about a foot from its holder. So the error grows with height: the 3D reconstruction is biased
            up in the air.
          </p>
        </div>
      </div>
      {@render decision("Ball physics runs relative to each game end's calibrated hoop (the median crossing point). Ball positions are shifted back to the players' frame in proportion to height: none at 4 ft, the full offset at 10 ft.")}
      <p class="rb-note">
        <b>Also found:</b> the tracking files skip frame numbers (up to {int(rangeOf(doc.audit.gaps, "missing_indices")[1])} in one game). The first
        version of the reader assumed line number equals frame number and silently put 255 shots on the wrong frames. Lines
        are now matched on their frame number.
      </p>
    </section>

    <!-- 4 ------------------------------------------------------------------------------------------------- -->
    <section id="rb-where">
      <h2>4. Where misses go</h2>
      <p>
        Where rebounds are secured (the rebounder's position at the recorded rebound frame), by the range of the shot:
        at the rim (under 5 ft), midrange (every other two) and three. The hoop is at the right. Each map is smoothed
        (every rebound spreads as a soft 1.5 ft blob) and all three share one colour scale, so the same shade means the same
        share of that range's rebounds per square foot. Hover a map to read the share within 3 ft of the pointer.
      </p>
      <div class="rb-grid three">
        {#each RANGES as rg (rg)}<CourtMap points={byRange(rg)} title={RANGE_TITLE[rg]} vmax={mapMax} />{/each}
      </div>
      <div class="rb-grid two">
        <div>
          <h4>Rebound distance from the hoop against shot distance</h4>
          <Scatter points={spotScatter} groups={["Offensive rebound", "Defensive rebound"]} xlabel="Shot distance (ft)" ylabel="Rebound distance (ft)"
                   lines={medianLines} radius={2.5} opacity={0.45} />
        </div>
        <div>
          <h4>Angle from the shooter's side (0° = same side as the shot)</h4>
          <Columns categories={angleCats} series={angleSeries} format={(v) => `${Math.round(100 * v)}%`} />
        </div>
      </div>
      <ul class="facts">
        <li><b>Longer shots, longer rebounds.</b> The median rebound is {f(1)(shortR?.median_r)} ft from the hoop after a shot at the rim, {f(1)(midR?.median_r)} ft after a midrange shot and {f(1)(longR?.median_r)} ft after a three; {pc(0)(longR?.long_share)} of three-point rebounds are more than 12 ft out against {pc(0)(shortR?.long_share)} at the rim.</li>
        <li><b>Rebounds stay on the shooter's side.</b> The most common direction is within 30° of the shot's own line, for every range. The belief that misses bounce long to the opposite side does not show here.</li>
        <li><b>Most rebounds are close.</b> Even after threes, three quarters are secured within about {f(0)(longR?.q75)} ft of the hoop: the contest happens in a small area.</li>
      </ul>

      <h3>Try it: where do misses from a given spot go?</h3>
      <p>
        The maps above pool every shot in a range. Here you pick the shot: click a spot (or a preset) and the map shows
        where misses from shots like it were rebounded in these ten games.
      </p>
      <ReboundFinder spots={finderSpots} />
      <aside class="concept">
        <h4>Concept: a conditional density, and how much data backs it</h4>
        <p>
          Every real miss votes for the spot where its rebound was secured. Its vote counts more the closer its shot was to
          the one you clicked (the weight falls off as a bell curve whose width is the slider). The weighted votes are then
          smoothed into a map, exactly like the maps above. Nothing is fitted: this is the data, smoothed.
        </p>
        <p>
          The width is the classic trade-off. Narrow, and the map uses only near-identical shots: faithful to the spot but
          built on few misses, so noisy. Wide, and it borrows from shots that are less alike: steadier, but blurred toward
          the overall pattern. <b>"Worth N misses"</b> is the effective sample size, (sum of weights)² / sum of squared
          weights: how many equally weighted misses the weights add up to. Below about 15, read the map as a rough sketch.
        </p>
        <p>
          <b>Mirroring</b> assumes a miss from the left behaves like the same miss from the right, reflected. It doubles the
          data, and it is an assumption: untick it to see what the ten games say on each side alone. This map is also the
          baseline any landing model should beat; the ball-flight model's untouched-landing forecast has not yet been
          compared against it.
        </p>
      </aside>

      <div class="rb-grid two">
        <div>
          <h4>Offensive ball by shot range</h4>
          <RateDots rows={rates(E("oreb_by_distance"), "shot_range", (v) => RANGE_TITLE[String(v)] ?? String(v))} reference={overall} />
        </div>
        <div>
          <h4>Offensive ball by what the ball hit first</h4>
          <RateDots rows={rates(E("oreb_by_kind").filter((r) => r.kind !== "putback or tip"), "kind")} reference={overall} />
          <p class="rb-note">"Putback or tip" (58 misses) is left out: that label is defined by the offense getting the ball, so its 100% is circular, and no model uses it.</p>
        </div>
      </div>
      <p>
        Two things stand out. The offensive rate drifts only a little with range, from {pc(0)(one(E("oreb_by_distance"), (r) => r.shot_range === RANGES[0])?.rate)}
        after shots at the rim to {pc(0)(one(E("oreb_by_distance"), (r) => r.shot_range === RANGES[2])?.rate)} after threes, and
        every interval includes the overall {pc(0)(overall)}: range changes <i>where</i> the ball goes much more than
        <i>who</i> gets it. And what the ball hits first matters little on its own.
      </p>
      <div class="rb-grid two">
        <div>
          <h4>Time from release to first contact</h4>
          <Scatter points={flightPts} lines={[{ points: flightLine, label: `${f(2)(val("flight_time_fit", "value", "intercept"))} s + ${f(3)(val("flight_time_fit", "value", "per_ft"))} s per ft`, color: "var(--ink)" }]}
                   xlabel="Shot distance (ft)" ylabel="Seconds" radius={2.5} opacity={0.45} />
        </div>
        <div>
          <h4>Timing proxies against the recorded rebound frame</h4>
          <Columns categories={touchHist.cats} series={[{ name: "First moment a player could touch it", values: touchHist.vals }, { name: "Ball held (proxy)", values: controlHist.vals }]}
                   xlabel="Seconds relative to the rebound frame (negative = before)" format={(v) => String(Math.round(v))} />
        </div>
      </div>
      <p>
        The flight is regular (it explains {pc(0)(val("flight_time_fit", "value", "r2"))} of the variation in time to the rim), but the
        recorded rebound frame is fuzzy: it falls a median {f(2)(-median(timing, "touch_vs_rebound"))} s after the first moment a player could
        touch the ball and {f(2)(median(timing, "control_vs_rebound"))} s before the ball looks held.
      </p>
      {@render decision("Forecast the ball's path itself rather than a fixed map of rebound spots: where it goes depends on the shot and on how it comes off the rim. Score models on who got the ball, not on when, because the timing label is too loose.")}
    </section>

    <!-- 5 ------------------------------------------------------------------------------------------------- -->
    <section id="rb-flight">
      <h2>5. The ball-flight model</h2>
      <aside class="concept">
        <h4>Concept: a particle filter</h4>
        <p>
          Instead of one guess of where the ball is, keep a few hundred guesses ("particles"), each a position and a
          velocity. Move every particle forward with physics; when the next keyframe arrives, give more weight to particles
          close to it and drop the unlikely ones. What survives is a cloud of plausible states. To forecast, keep simulating
          the cloud with no new data: its spread is the uncertainty, and it can split in two when the ball might go either
          way off the rim.
        </p>
      </aside>
      <ol class="steps">
        <li><h3>Before the flight is seen: a launch prior</h3><p>At release only the release point is known. The time to the basket and the aim point are drawn from the 40 tracked attempts (made or missed) nearest in distance, which fixes each particle's launch velocity.</p></li>
        <li><h3>Through the air: gravity plus noise</h3><p>Particles fly under gravity with a small random acceleration ({f(1)(Math.sqrt(fp.kalman?.q ?? NaN))} ft/s per √s, fitted) and are re-weighted at every keyframe.</p></li>
        <li><h3>At the rim: contact physics</h3><p>The ring is a torus, the backboard a plane, the floor the effective floor from section 3. Bounciness is drawn at each contact and the contact direction is jittered, standing in for spin and the exact point of impact. Those settings were chosen in each fold by how well the cloud predicted the next 0.6 s after contacts in the training games.</p></li>
        <li><h3>Misses only</h3><p>Simulated continuations that drop through the hoop are removed: every forecast is conditional on a miss.</p></li>
      </ol>
      <aside class="concept">
        <h4>Concept: leave one game out, and coverage</h4>
        <p>
          Every number below comes from a game the model never saw: fit on nine games, score on the tenth, ten times. Two
          scores matter for a forecast cloud. <b>Error</b>: how far its centre was from where the ball went. <b>Coverage</b>:
          how often the ball landed inside the region the model called 90% likely. An honest model covers about 90%; an
          overconfident one much less.
        </p>
      </aside>
      <div class="rb-grid two">
        <div>
          <h4>90% coverage after a forecast made just before contact</h4>
          <Scatter lines={[...flightCover, { points: [[0.1, 0.9], [1.05, 0.9]], color: "var(--muted)", dashed: true, label: "honest: 90%" }]} xlabel="Seconds ahead" ylabel="Share inside the 90% region" ydomain={[0, 1]} xdomain={[0.1, 1.05]}
                   yfmt={(v) => `${Math.round(100 * v)}%`} points={flightCover.flatMap((s, j) => s.points.map(([x, y]) => ({ x, y, g: j, tip: `${s.label}: ${Math.round(100 * y)}% at ${x} s` })))}
                   groups={flightCover.map((s) => s.label)} radius={4} opacity={1} />
        </div>
        <div class="rb-explain">
          <h4>What the checks show</h4>
          <p>
            Modelling the contact is what makes this work. A forecast made just before contact misses the ball's position 0.2 s
            later by {f(1)(c02?.err_ft)} ft with contact physics, against {f(1)(nc02?.err_ft)} ft without it, and only the contact model's
            90% region is honest ({pc(0)(c02?.cover90)} against {pc(0)(k02?.cover90)} for a Kalman filter that ignores the rim).
          </p>
          <p>
            Calibration fades with time: from 0.2 s after a contact the 90% region covers {pc(0)(a04?.cover90)} of positions 0.4 s
            ahead but only {pc(0)(a10?.cover90)} a second ahead, when players start touching the ball and the loose ball's
            path is unpredictable.
          </p>
        </div>
      </div>
      <p class="rb-note">
        <b>A correction during the build:</b> the first version fixed the observation noise at the smallest value the
        one-step fit allowed, and its post-contact 90% regions covered as little as 11%. The noise level is now part of the
        settings chosen by multi-step forecasts.
      </p>
      <h4>Untouched landing: not validated</h4>
      <p>
        Only about {int(meanOf(doc.flight.landing, "n"))} held-out misses bounced with nobody within 4 ft before anyone held the ball,
        the only cases where a first landing is actually seen. Forecasts miss them by about {f(0)(meanOf(doc.flight.landing, "err_xy_ft"))} ft
        and land too early. Those bounces may include tips nobody recorded, but either way the violet heatmap on the court is
        an illustration of the model, not a calibrated map.
      </p>
      <details class="rb-more">
        <summary>Every flight score by checkpoint and horizon</summary>
        {@render table([
          { key: "checkpoint", label: "Forecast made", fmt: chk }, { key: "horizon", label: "Ahead (s)", num: true, fmt: f(1) },
          { key: "model", label: "Model", fmt: model }, { key: "n", label: "n", num: true, fmt: int },
          { key: "logscore", label: "Log score", num: true, fmt: f(2) }, { key: "err_ft", label: "Error (ft)", num: true, fmt: f(2) },
          { key: "cover90", label: "90% coverage", num: true, fmt: pc() }, { key: "radius90_ft", label: "90% radius (ft)", num: true, fmt: f(1) },
        ], (doc.flight.summary ?? []).filter((r) => ["particle_contact", "particle_no_contact", "kalman", "empirical_bounce"].includes(String(r.model))), true)}
      </details>
    </section>

    <!-- 6 ------------------------------------------------------------------------------------------------- -->
    <section id="rb-who">
      <h2>6. Who gets the ball</h2>
      <p>
        Knowing where the ball goes, who gets it? The simplest idea, that the player nearest the basket wins, is checked
        first against the idea the model is built on: that the winner is whoever can get to the ball first.
      </p>
      <div class="rb-grid two">
        <div>
          <h4>The rebounder's rank by distance to the hoop</h4>
          <Columns categories={rankCats} series={rankSeries("rank_by_hoop")} format={(v) => `${Math.round(100 * v)}%`} xlabel="1 = nearest of the ten" />
        </div>
        <div>
          <h4>The rebounder's rank by distance to where the ball was secured</h4>
          <Columns categories={rankCats} series={rankSeries("rank_by_spot")} format={(v) => `${Math.round(100 * v)}%`} xlabel="1 = nearest of the ten" />
        </div>
      </div>
      <p>
        Being nearest the hoop helps a little (the nearest player gets {pc(0)(one(E("rank_by_hoop"), (r) => r.checkpoint === "rim" && n(r.rank) === 1)?.share)}
        of rebounds just before the rim). Being nearest to where the ball ends up is decisive: that player gets
        {pc(0)(one(E("rank_by_spot"), (r) => r.checkpoint === "rim" && n(r.rank) === 1)?.share)} of them just before the rim, and the team of that player
        gets the ball {pc(0)(nearestWins("rim"))} of the time ({pc(0)(nearestWins("release"))} measured at release). The catch is that nobody knows
        that spot in advance. Hence the model: forecast the ball's path, then ask who can reach it.
      </p>
      <div class="rb-grid two">
        <div>
          <h4>Offensive ball by offensive players within 12 ft at release</h4>
          <RateDots rows={rates(E("oreb_by_offense_inside"), "off_in", (v) => (n(v) >= 3 ? "3 or more" : String(v)))} reference={overall} />
        </div>
        <div>
          <h4>Offensive ball by net box-outs just before the rim</h4>
          <RateDots rows={rates(E("oreb_by_net_boxouts"), "net", (v) => (n(v) > 0 ? `defense +${v}` : n(v) < 0 ? `offense +${-n(v)}` : "even"))} reference={overall} />
          <p class="rb-note">Players within 15 ft of the hoop whose route to the reachable ball is blocked (strength 0.35+); "defense +1" means one more offensive player blocked than defensive.</p>
        </div>
      </div>
      <p>
        Counting bodies is a weak signal: sending three or more players inside lifts the offensive rate to
        {pc(0)(one(E("oreb_by_offense_inside"), (r) => n(r.off_in) === 3)?.rate)}, and box-out counts barely move it at all. Positions only
        matter through where the ball goes.
      </p>
      {@render decision("Model each player's physical access to the ball along every simulated path (can he be there while it is low enough to grab?) and let obstruction lower an opponent's access, instead of predicting from crowd counts or a fixed rebound map.")}
    </section>

    <!-- 7 ------------------------------------------------------------------------------------------------- -->
    <section id="rb-collect">
      <h2>7. The collection model</h2>
      <ol class="steps">
        <li><h3>Access</h3><p>For every simulated path and every 0.08 s step, each player's chance of being at the ball while it is below a reach of 10.5 ft. He keeps his current velocity for a reaction time, then runs at up to 18.1 ft/s. Until the ball has visibly come off the rim he cannot know which path it takes: in each fold the data chose between keeping on moving and heading for the forecast's centre.</p></li>
        <li><h3>Competing risks</h3><p>At every step, the ten players, a team award to either side and "still loose" compete for that moment. A player's pull rises with his access; a blocked route lowers it; defenders get a small edge. A ball that lands out of bounds ends in an award. Averaging over paths gives every player's chance, and the chances add up to one.</p></li>
        <li><h3>Impossible stays impossible</h3><p>A player with no access at a step cannot collect then, and every outcome keeps a 0.1% floor so a rebound the physics calls impossible does not break the fit. A scenario check confirms a player 400 ft away is left with essentially nothing.</p></li>
      </ol>
      <aside class="concept">
        <h4>Concept: log loss and the model ladder</h4>
        <p>
          Log loss is how surprised a model was by what happened: minus the log of the probability it gave the actual
          outcome, averaged over misses. Lower is better, and a model that says "45%" for the eventual rebounder scores much
          better than one that said "5%". Each model below is compared with the team prior on the same held-out games; the
          gain is the average improvement per game, with a 90% interval across the ten games.
        </p>
      </aside>
      <div class="rb-grid two">
        <div>
          <h4>Gain in log loss over the team prior, at release</h4>
          <RateDots rows={ladder("release")} reference={0} min={-0.15} max={0.4} format={(v, d = 2) => v.toFixed(d)} unit="gain" refLabel="prior" color={SERIES[0]} labelWidth={240} />
        </div>
        <div>
          <h4>Gain in log loss over the team prior, just before the rim</h4>
          <RateDots rows={ladder("rim")} reference={0} min={-0.15} max={0.4} format={(v, d = 2) => v.toFixed(d)} unit="gain" refLabel="prior" color={SERIES[0]} labelWidth={240} />
        </div>
      </div>
      <p>
        At release the access model's log loss is {f(3)(rel?.log_loss)} against {f(3)(pr?.log_loss)} for the team prior, better in
        {rel?.games_better} of 10 held-out games, and a little better than a flexible geometry classifier ({f(3)(geoRel?.log_loss)}) that uses
        distances, ranks and speeds directly. Just before the rim it reaches {f(3)(rim?.log_loss)}, where the geometry classifier is
        slightly ahead ({f(3)(geoRim?.log_loss)}). Obstruction adds a little; player effects add nothing (section 10).
      </p>
      <div class="rb-grid two">
        <div>
          <h4>Does "offense 35%" mean 35%?</h4>
          <Scatter points={[...calPts("release"), ...calPts("rim")]} groups={["At release", "Just before the rim"]}
                   lines={[{ points: [[0.1, 0.1], [0.6, 0.6]], color: "var(--muted)", dashed: true, label: "perfect" }]}
                   xlabel="Predicted chance the offense gets the ball" ylabel="Observed share" xdomain={[0.1, 0.6]} ydomain={[0, 0.7]}
                   xfmt={(v) => `${Math.round(100 * v)}%`} yfmt={(v) => `${Math.round(100 * v)}%`} radius={5} opacity={1} />
        </div>
        <div class="rb-explain">
          <h4>Calibration</h4>
          <p>
            Group held-out misses by the offense's predicted chance and compare with how often the offense actually got the
            ball (groups of 10 or more). Points near the dashed line mean the percentages can be read at face value. Most of
            the forecasts sit between 25% and 40%; the model rarely sees a rebound as a sure thing, which matches how
            contested they are.
          </p>
          <p>Team-level log loss: {f(3)(rel?.team_log_loss)} at release and {f(3)(rim?.team_log_loss)} just before the rim, against {f(3)(pr?.team_log_loss)} for the prior.</p>
        </div>
      </div>
      <details class="rb-more">
        <summary>Every model at both checkpoints</summary>
        {#each ["release", "rim"] as cp (cp)}
          {@render table([
            { key: "model", label: chk(cp), fmt: model }, { key: "n", label: "n", num: true, fmt: int },
            { key: "log_loss", label: "Log loss", num: true, fmt: f(3) }, { key: "gain", label: "Gain vs prior", num: true, fmt: (v, r) => pm(v, r) },
            { key: "games_better", label: "Games better", num: true }, { key: "team_log_loss", label: "Team log loss", num: true, fmt: f(3) },
            { key: "team_auc", label: "Team AUC", num: true, fmt: f(2) },
          ], (doc.collection.summary ?? []).filter((r) => r.checkpoint === cp).sort((a, b) => n(a.log_loss) - n(b.log_loss)), true)}
        {/each}
      </details>
    </section>

    <!-- 8 ------------------------------------------------------------------------------------------------- -->
    <section id="rb-move">
      <h2>8. Movement and anticipation</h2>
      <p>
        Anticipation means moving early to where the ball is likely to go. To grade it, a player's actual first 0.48 s
        after release is compared with moves a player in his spot would typically make, holding the ball forecast at what
        was known at release. That needs a believable model of "typical moves", so movement was checked first.
      </p>
      <div class="rb-grid two">
        <div>
          <h4>Distance moved in 0.48 s against where momentum alone would take him</h4>
          <Scatter points={movePts} groups={["Offense", "Defense"]} xlabel="Current speed × 0.48 s (ft)" ylabel="Actual distance moved (ft)"
                   lines={[{ points: [[0, 0], [8, 8 * damp]], label: `${f(2)(damp)} × momentum`, color: "var(--ink)" }]} radius={2} opacity={0.35} xdomain={[0, 8]} ydomain={[0, 9]} />
        </div>
        <div>
          <h4>Movement toward the hoop by role (ft in 0.48 s)</h4>
          <Columns categories={roleRows.map((r) => String(r.role))} series={[{ name: "Toward the hoop", values: roleRows.map((r) => n(r.toward_hoop_ft)) }]}
                   format={(v) => v.toFixed(1)} />
        </div>
      </div>
      <p>
        Momentum explains most short-term movement: players carry on at about {f(0)(100 * damp)}% of their current pace. A first
        reference model that ignored momentum and used only typical moves for the role predicted worse than plain
        momentum and was replaced.
      </p>
      {@render table([
        { key: "model", label: "Movement model", fmt: model }, { key: "n", label: "n", num: true, fmt: int }, { key: "error_ft", label: "Error (ft)", num: true, fmt: f(2) },
        { key: "log_score", label: "Log score", num: true, fmt: f(2) }, { key: "cover80", label: "80% coverage", num: true, fmt: pc() },
      ], doc.skills.movement)}
      <p>
        The reference used (damped momentum plus a typical residual move for the role) has the lowest error, but it is too
        spread out: {pc(0)(one(doc.skills.movement, (r) => r.model === "damped_role")?.cover80)} of real moves fall inside its 80% region, so the reference
        moves are more varied than real ones. The anticipation score is a player's collection chance at his actual position
        minus its average over 16 reference moves, in points of probability. Where the reference moves barely change his
        chance, he had nothing to show and gets no weight.
      </p>
    </section>

    <!-- 9 ------------------------------------------------------------------------------------------------- -->
    <section id="rb-box">
      <h2>9. Box-outs</h2>
      <p>
        Without video or body orientation, a box-out can only be seen spatially: one player standing in an opponent's
        route to where the ball can be reached, and staying there. Pairs of opponents within 6 ft at release, both within
        22 ft of the hoop, are followed every 0.2 s until the rebound.
      </p>
      <div class="rb-grid two">
        <div>
          <h4>Automated labels of {int((doc.skills.boxout_labels ?? []).reduce((s, r) => s + n(r.pairs), 0))} candidate pairs</h4>
          {@render table([{ key: "label", label: "Label" }, { key: "blocker_def", label: "Blocker on defense", fmt: yes }, { key: "pairs", label: "Pairs", num: true, fmt: int }, { key: "share", label: "Share", num: true, fmt: pc(1) }], doc.skills.boxout_labels)}
        </div>
        <div class="rb-explain">
          <h4>How the labels are made</h4>
          <p>
            Established: the blocker covers at least 0.35 of the opponent's routes. Maintained: still 0.25 for 80% of the
            time through the rim. Escaped: lost, with the opponent ending nearer the ball. Ambiguous: the two closer than their
            tracking error. Defenders hold box-outs more often than offensive players, as expected. These are rules, not
            reviewed video: <code>outputs/rebounding/audit/review_sample.csv</code> lists 60 episodes to check by eye.
          </p>
        </div>
      </div>
      <h4>Can we predict whether an established box-out holds? (held-out games)</h4>
      {@render table([
        { key: "model", label: "Model", fmt: model }, { key: "n", label: "n", num: true, fmt: int }, { key: "log_loss", label: "Log loss", num: true, fmt: f(3) },
        { key: "gain", label: "Gain vs base", num: true, fmt: (v, r) => pm(v, r) }, { key: "games_better", label: "Games better", num: true }, { key: "auc", label: "AUC", num: true, fmt: f(2) },
      ], doc.skills.boxout_validation)}
      <p>Barely: geometry at the moment it is established helps a little, and knowing who the blocker is does not help at all.</p>
    </section>

    <!-- 10 ------------------------------------------------------------------------------------------------ -->
    <section id="rb-players">
      <h2>10. Player effects</h2>
      <aside class="concept">
        <h4>Concept: shrinkage, and why three skills need three kinds of evidence</h4>
        <p>
          A player effect says "this player does better than the model expects". With little data, raw differences are
          mostly luck, so each effect is <b>shrunk</b> toward zero in proportion to how little is known about the player. And if
          only "who got the rebound" were used, anticipation, box-outs and collection would blur into one number. So each is
          estimated from its own evidence (movement, blocked routes, securing a reachable ball) and must pass a test before
          the site uses it.
        </p>
      </aside>
      <div class="rb-grid two">
        <div>
          <h4>Each player's rebound rate against how often he was on court for a miss</h4>
          <Scatter points={funnel} groups={["Mostly on offense", "Mostly on defense"]} xlabel="Misses on court" ylabel="Rebounds per miss on court"
                   lines={[{ points: band(1), color: "var(--muted)", dashed: true, label: "90% band if everyone were average" }, { points: band(-1), color: "var(--muted)", dashed: true }]}
                   xdomain={[0, 92]} ydomain={[0, 0.5]} yfmt={(v) => `${Math.round(100 * v)}%`} xfmt={(v) => String(Math.round(v))} radius={3} opacity={0.7} />
        </div>
        <div class="rb-explain">
          <h4>How much evidence there is</h4>
          <p>
            The typical player was on court for {int(median(players, "scenes"))} misses, and
            {int(players.filter((r) => n(r.games) === 2).length)} of {int(players.length)} were seen in two games. The dashed band is where
            rates would fall from luck alone if every player were exactly average. Points outside it are not evidence of
            skill by themselves: a player who stands near the rim gets more chances, and the physics model already knows
            where everyone stands. The question is whether anything is left over once it has.
          </p>
        </div>
      </div>
      {@render table([
        { key: "component", label: "Skill" }, { key: "evidence", label: "Evidence" }, { key: "player_sd", label: "Spread", num: true, fmt: f(3), title: "Estimated spread of the player effects" },
        { key: "likelihood_ratio", label: "LR", num: true, fmt: f(1), title: "Likelihood ratio for any player differences within games (over 3.84 = detectable)" },
        { key: "cross_game_r", label: "Repeats (r)", num: true, fmt: f(2), title: "Correlation of the same players' effects across their two games (over 0.3 required)" },
        { key: "heldout_gain_repeat", label: "Held-out gain", num: true, fmt: f(4) }, { key: "recovery_r", label: "Recovery (r)", num: true, fmt: f(2), title: "How well known effects were recovered from simulated outcomes (over 0.5 required)" },
        { key: "passes", label: "Passes", fmt: yes },
      ], doc.skills.identification, true)}
      <ul class="facts">
        <li><b>Anticipation</b>: players do differ within a game (likelihood ratio {f(0)(ident("Anticipation")?.likelihood_ratio)}), but by only about {f(1)(100 * n(ident("Anticipation")?.player_sd))} points of probability, and the difference does not repeat across games (r {f(2)(ident("Anticipation")?.cross_game_r)}).</li>
        <li><b>Box-outs</b>: no repetition across games (r {f(2)(ident("Boxing")?.cross_game_r)}) and no held-out gain.</li>
        <li><b>Collection</b>: no held-out gain on rebounds by players seen in training. When known effects were planted in simulated outcomes, the fit recovered them at only r {f(2)(ident("Collection")?.recovery_r)}: with ~700 rebounds even real differences of a plausible size cannot be ranked.</li>
      </ul>
      {@render decision("Use the population model everywhere: the same physics and positioning rules for every player. The per-player estimates are kept below for description only. These thresholds are judgement calls; with more tracked games the same tests can be rerun.")}
      <details class="rb-more">
        <summary>Simulation recovery and prior sensitivity</summary>
        {@render table([
          { key: "sd_true", label: "True spread", num: true, fmt: f(1) }, { key: "rep", label: "Run", num: true }, { key: "cor_all", label: "r, all players", num: true, fmt: f(2) },
          { key: "cor_20plus", label: "r, 20+ misses", num: true, fmt: f(2) }, { key: "shrink_sd", label: "Estimated spread", num: true, fmt: f(3) },
        ], doc.collection.recovery)}
        {@render table([
          { key: "checkpoint", label: "Forecast made", fmt: chk }, { key: "rebounder_seen", label: "Rebounder seen in training", fmt: yes },
          { key: "model", label: "Model", fmt: model }, { key: "n", label: "n", num: true, fmt: int }, { key: "log_loss", label: "Log loss", num: true, fmt: f(4) },
        ], doc.collection.sensitivity, true)}
        {@render table([
          { key: "name", label: "Collection effect (not used)" }, { key: "team_name", label: "Team" }, { key: "effect", label: "Log-odds ± sd", num: true, fmt: (v, r) => `${f(2)(v)} ± ${f(2)(r.effect_se)}` },
          { key: "scenes", label: "Misses on court", num: true, fmt: int }, { key: "rebounds", label: "Rebounds", num: true, fmt: int },
        ], [...doc.collection.players.slice(0, 6), ...doc.collection.players.slice(-4)], true)}
      </details>
    </section>

    <!-- 11 ------------------------------------------------------------------------------------------------ -->
    <section id="rb-checks">
      <h2>11. Checks and limits</h2>
      {#if doc.checks}
        <h4>Scenario checks every forecast has to pass</h4>
        {@render table([{ key: "check", label: "Check" }, { key: "pass", label: "Passes", fmt: yes }, { key: "detail", label: "Detail" }], doc.checks, true)}
      {/if}
      <h4>What this does not support</h4>
      <ul class="facts">
        <li><b>Ten games.</b> Held-out games mostly test new players; only 25 players appear twice.</li>
        <li><b>Associations, not interventions.</b> Movement and box-outs reflect choices and game plans; a model-assessed gain does not prove a different move would have changed the outcome.</li>
        <li><b>The ball is reconstructed</b>, interpolated and biased with height; the hoop calibration uses each game's own made shots.</li>
        <li><b>Contact physics is loosely identified.</b> Several chosen settings sit at the edge of the range searched; they improve forecasts but are not physical measurements.</li>
        <li><b>Shared motion rules</b> for every player: no jumping, body orientation or contact.</li>
        <li><b>Replay only.</b> Dragging players, hypothetical misses of made shots and transition value are not built.</li>
        <li><b>Not shot quality.</b> A rebound forecast is one piece of a shot's value; its link to the competition question is not established.</li>
      </ul>
      <h4>Reproduce</h4>
      <p class="meta">From the repository root, with R 4.4 and Rtools (the simulator is C++ through Rcpp). Each step caches and resumes; <code>--game=&lt;id&gt;</code> runs one fold.</p>
      <pre class="rb-code">Rscript src/rebounding/extract_windows.R
Rscript src/rebounding/run_audit.R
Rscript src/rebounding/run_flight.R
Rscript src/rebounding/run_opportunity.R
Rscript src/rebounding/run_skills.R
Rscript src/rebounding/run_checks.R
Rscript src/rebounding/run_eda.R
Rscript src/rebounding/run_export.R</pre>
      <p class="meta">Framework: "Physics-informed rebounding: research and model framework" (October 27, 2026). Ideas adapted from Achterhold et al. (2023), Okubo and Hubbard (2014), Maheswaran et al. (2012, 2014), Kiriazis, Genest and Leblanc, Spearman-style pitch control and ReboundingPrediction; no code reused. Data: SkillCorner open data, Liga ACB, MIT licence. Built {doc.built}.</p>
    </section>
  </div>
{/if}

<style>
  .rb-doc { max-width: 1120px; }
  .rb-toc { display: flex; flex-wrap: wrap; gap: 6px 16px; margin: 14px 0 6px; padding: 10px 12px; border: 1px solid var(--line); border-radius: 8px; background: var(--panel); }
  .rb-toc .link { font-size: 13px; }
  .rb-grid { display: grid; gap: 20px; margin: 14px 0; align-items: start; }
  .rb-grid.two { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .rb-grid.three { grid-template-columns: repeat(3, minmax(0, 1fr)); }
  .rb-grid h4 { margin-top: 0; }
  .rb-explain p { color: var(--muted); }
  .rb-explain b, .rb-explain i { color: var(--ink); }
  .decision { display: flex; gap: 12px; margin: 14px 0; padding: 10px 14px; border-left: 3px solid var(--off); border-radius: 0 8px 8px 0; background: rgba(76, 154, 255, .08); }
  .decision b { flex: none; color: var(--off); font-size: 12px; letter-spacing: .04em; text-transform: uppercase; line-height: 1.55; }
  .concept { margin: 14px 0; padding: 12px 14px; border: 1px solid var(--line); border-radius: 8px; background: var(--panel); }
  .concept h4 { margin-top: 0; color: var(--ink); }
  .concept p { margin: 0; color: var(--muted); }
  .concept p + p { margin-top: 8px; }
  section > h3 { margin-top: 22px; }
  .concept b { color: var(--ink); }
  .rb-note { color: var(--muted); font-size: 12.5px; }
  .rb-note b { color: var(--ink); }
  .rb-more { margin: 12px 0; }
  .rb-more summary { cursor: pointer; color: var(--off); font-size: 13px; }
  .rb-more .table-wrap { margin-top: 10px; }
  .rb-table.narrow { min-width: 0; width: auto; }
  .rb-table td { font-size: 13px; }
  .rb-code { margin: 8px 0; padding: 10px 12px; overflow-x: auto; border-radius: 8px; background: #0F1522; font-size: 12.5px; line-height: 1.6; }
  code { font-size: 12.5px; }
  @media (max-width: 860px) {
    .rb-grid.two { grid-template-columns: minmax(0, 1fr); }
    .rb-grid.three { gap: 8px; }
  }
</style>
