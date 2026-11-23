<script lang="ts">
  // The Rebounding tab: a descriptive look at the ten tracked games' missed shots. What the data hold, how far the
  // ball's track can be trusted, and where misses go and who gets them. No model is fitted here beyond a straight
  // line and smoothing; every number comes from rebounding_eda.json, frozen from the archived rebounding pipeline
  // (zz_Archive/src/rebounding/run_audit.R, run_eda.R, run_export.R), so the text cannot drift from the tables.
  import { loadReboundEda } from "../lib/data";
  import { fitWide } from "../lib/fitwide";
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
    episodes: number;
    eda: Record<string, Row[]>;
    audit: Record<"counts" | "population" | "quality" | "hoops" | "gaps", Row[]>;
  }
  interface Col { key: string; label: string; fmt?: (v: Cell, row: Row) => string; num?: boolean; title?: string }

  let doc = $state.raw<Doc | null>(null);
  let problem = $state("");
  loadReboundEda<Doc>().then((d) => { doc = d; }).catch((err: Error) => { problem = err.message; });

  // ---- formatting ----
  const n = (v: Cell) => (typeof v === "number" ? v : Number(v));
  const f = (d: number) => (v: Cell) => (v == null || Number.isNaN(n(v)) ? "–" : n(v).toFixed(d));
  const int = (v: Cell) => (v == null || Number.isNaN(n(v)) ? "–" : Math.round(n(v)).toLocaleString("en-US"));
  const pc = (d = 0) => (v: Cell) => (v == null || Number.isNaN(n(v)) ? "–" : `${(100 * n(v)).toFixed(d)}%`);
  const one = (rows: Row[] | undefined, pred: (r: Row) => boolean) => (rows ?? []).find(pred) ?? null;
  const E = (name: string): Row[] => doc?.eda?.[name] ?? [];
  const val = (name: string, key: string, term: string) => n(one(E(name), (r) => r.term === term)?.[key]);
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
  const RANGE_TITLE: Record<string, string> = { "rim (<5 ft)": "Rim (Under 5 ft)", "midrange (other 2s)": "Midrange (Other 2s)", three: "Three" };
  // One colour scale for the three maps (their densest cell), so the same shade means the same share in each.
  const mapMax = $derived(Math.max(...RANGES.map((rg) => peak(kde(byRange(rg), gridOf(-30, 5.6, -24.6, 24.6), 1.5)))));
  const finderSpots = $derived(spots.map((r) => ({ sx: n(r.sx), sy: n(r.sy), rx: n(r.rx), ry: n(r.ry), off: r.off === true || r.off === "TRUE" })));
  const spotScatter = $derived(spots.map((r) => ({ x: n(r.shot_dist), y: n(r.r), g: r.off === true || r.off === "TRUE" ? 0 : 1,
                                                   tip: `Shot from ${f(0)(r.shot_dist)} ft\nRebound ${f(1)(r.r)} ft from the hoop` })));
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
                                                               tip: `Game ${r.game_id}\n${r.end}\n${f(2)(r.dx)} ft along\n${f(2)(r.dy)} ft across` })));
  const meanOf = (rows: Row[] | undefined, key: string) => { const v = (rows ?? []).map((r) => n(r[key])).filter((x) => !Number.isNaN(x)); return v.length ? v.reduce((a, b) => a + b, 0) / v.length : NaN; };
  const rangeOf = (rows: Row[] | undefined, key: string) => { const v = (rows ?? []).map((r) => n(r[key])); return [Math.min(...v), Math.max(...v)]; };
  const median = (rows: Row[], key: string) => { const v = rows.map((r) => n(r[key])).filter((x) => !Number.isNaN(x)).sort((a, b) => a - b); return v.length ? v[Math.floor(v.length / 2)] : NaN; };

  const SECTIONS = [
    ["rb-question", "1. The Question"], ["rb-data", "2. The Data"], ["rb-ball", "3. Can We Trust the Ball?"],
    ["rb-where", "4. Where Misses Go"], ["rb-limits", "5. What to Keep in Mind"],
  ];
  // Plain scrolling: the page's address names the tab (#/rebounding), so section links must not change it.
  const go = (id: string) => document.getElementById(id)?.scrollIntoView({ behavior: "smooth", block: "start" });
</script>

{#snippet table(cols: Col[], rows: Row[], wide = false)}
  <div class="table-wrap" use:fitWide>
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

{#snippet takeaway(text: string)}
  <div class="decision"><b>Takeaway</b><span>{text}</span></div>
{/snippet}

{#if !doc}
  <div class="doc-inner"><p class="lead">{problem || "Loading…"}</p></div>
{:else}
  {@const shortR = one(E("rebound_distance_by_range"), (r) => r.range === RANGES[0])}
  {@const midR = one(E("rebound_distance_by_range"), (r) => r.range === RANGES[1])}
  {@const longR = one(E("rebound_distance_by_range"), (r) => r.range === RANGES[2])}
  <div class="doc-inner rb-doc">
    <h1>Rebounding</h1>
    <p class="lead">
      When a shot misses, which team gets the ball, and where? I counted, averaged and smoothed every live miss in the ten
      tracked ACB games. The only fitted model on the page is one straight line, labelled where it appears.
    </p>
    <nav class="rb-toc" aria-label="On this page">
      {#each SECTIONS as [id, label] (id)}<button type="button" class="link" onclick={() => go(id)}>{label}</button>{/each}
    </nav>

    <!-- 1 ------------------------------------------------------------------------------------------------- -->
    <section id="rb-question">
      <h2>1. The Question</h2>
      <ul class="facts">
        <li>This page describes what happened on missed shots in these ten games</li>
        <li>It makes no forecast and passes no judgment on shot selection</li>
        <li>Three things are worth knowing before any rebounding analysis, and each section answers one</li>
      </ul>
      {@render table([{ key: "q", label: "Question" }, { key: "s", label: "Section" }], [
        { q: "How many misses are there, and how does each one end?", s: "2. The Data" },
        { q: "Can the ball's position and height be taken at face value?", s: "3. Can We Trust the Ball?" },
        { q: "Where do misses go, how long do they take, and which team gets them?", s: "4. Where Misses Go" },
      ])}
    </section>

    <!-- 2 ------------------------------------------------------------------------------------------------- -->
    <section id="rb-data">
      <h2>2. The Data</h2>
      <ul class="facts">
        <li>The ten games have {int(one(doc.audit.counts, (r) => r.quantity === "Shot records, including fouled misses")?.count)} shot records</li>
        <li>Fouled misses go to the free-throw line and made shots have no rebound, which leaves {int(one(doc.audit.counts, (r) => r.quantity === "Non-fouled misses")?.count)} live misses</li>
        <li>{int(doc.episodes)} of those have a recorded rebound and a usable ball track. Every chart below uses them</li>
      </ul>
      <div class="rb-grid two">
        <div>
          <h4>How the {int(doc.episodes)} Misses Ended</h4>
          <Columns categories={E("outcomes").map((r) => OUT[String(r.outcome)] ?? String(r.outcome))}
                   series={[{ name: "Share", values: E("outcomes").map((r) => n(r.share)) }]} format={(v) => `${Math.round(100 * v)}%`} labels />
        </div>
        <div class="rb-explain">
          <h4>Collected or awarded</h4>
          <ul class="facts">
            <li><b>Collected</b> = a player secures the ball, and the rebound is credited to him</li>
            <li><b>Awarded</b> = nobody secures it and the referees give the ball to a team, usually after it goes out of bounds and sometimes after a held ball or a foul. The box score calls that a team rebound</li>
            <li>Awards are {pc(0)(E("outcomes").filter((r) => String(r.outcome).includes("award")).reduce((s, r) => s + n(r.share), 0))} of misses and go to the offense more often than not</li>
            <li>Overall the offense keeps the ball after {pc(0)(overall)} of misses. That base rate is the reference line in the rate charts below, so a group above it rebounds its own misses more often than average</li>
          </ul>
        </div>
      </div>
      {@render takeaway("A miss ends one of four ways. Either team's player collects it, or either team is awarded it. I left out the 29 misses with no rebound row and report them in the audit below. They are not counted as defensive rebounds.")}
      <details class="rb-more">
        <summary>The event audit: where the shot counts come from</summary>
        {@render table([{ key: "quantity", label: "Quantity" }, { key: "count", label: "This Build", num: true, fmt: int }, { key: "framework", label: "Expected", num: true, fmt: int }], doc.audit.counts)}
        {@render table([{ key: "status", label: "Status" }, { key: "outcome", label: "Outcome", fmt: (v) => (v == null ? "–" : String(v)) }, { key: "N", label: "Shots", num: true, fmt: int }], doc.audit.population)}
      </details>
    </section>

    <!-- 3 ------------------------------------------------------------------------------------------------- -->
    <section id="rb-ball">
      <h2>3. Can We Trust the Ball?</h2>
      <ul class="facts">
        <li>Every chart on this page leans on the ball's track, and so does the ball height in the trace panel under the court</li>
        <li>Before trusting either, I checked how the track is made and where it goes wrong. Four findings follow</li>
      </ul>
      <div class="rb-grid two">
        <div>
          <h4>One Miss, Ball Height over Time</h4>
          <Scatter points={example.map((r) => ({ x: n(r.t), y: n(r.z), g: r.key === true || r.key === "TRUE" ? 0 : 1,
                                                  tip: `${f(2)(r.t)} s\n${f(2)(r.z)} ft high${r.key === true || r.key === "TRUE" ? "" : "\ninterpolated"}` }))}
                   lines={[{ points: example.map((r): [number, number] => [n(r.t), n(r.z)]), color: "var(--muted)" }]}
                   groups={["Keyframe", "Midpoint of its neighbours"]} events={exEvents} xlabel="Seconds After Release" ylabel="Ball Height (ft)"
                   radius={3.5} opacity={0.9} />
        </div>
        <div class="rb-explain">
          <h4>The ball is reconstructed</h4>
          <ul class="facts">
            <li>The ball's <code>isDetected</code> flag is 0 on every frame of every game</li>
            <li>{pc(0)(meanOf(doc.audit.quality, "midpoint_share"))} of its positions sit exactly halfway between their neighbours. The vendor reports the ball about 12.5 times a second and fills the frames between with straight lines</li>
            <li>The orange points on the chart add no information</li>
            <li>The fill uses the <i>next</i> keyframe, so the track already knows a little of the future</li>
          </ul>
        </div>
      </div>
      {@render takeaway("About half the ball positions are filled in by straight lines. Treat the ball height between keyframes as a guess, and remember that a filled-in point already knows where the ball goes next.")}
      <div class="rb-grid two">
        <div>
          <h4>Lowest Point of the Ball at Each Bounce</h4>
          <Columns categories={minima.map((r) => f(1)(r.z))} series={[{ name: "Bounces", values: minima.map((r) => n(r.n)) }]}
                   xlabel="Height of the Ball's Centre at the Bottom of a Bounce (ft)" format={(v) => String(Math.round(v))}
                   marks={minima.findIndex((r) => Math.abs(n(r.z) - 0.4) < 1e-6) >= 0 ? [{ at: minima.findIndex((r) => Math.abs(n(r.z) - 0.4) < 1e-6), label: "ball radius 0.40 ft" }] : []} />
        </div>
        <div class="rb-explain">
          <h4>It never reaches the floor</h4>
          <ul class="facts">
            <li>A ball's centre touches down at its radius, 0.40 ft</li>
            <li>In the data, bounce minima pile up between 1.0 and 1.6 ft. The keyframes likely skip the instant of contact</li>
            <li>{pc(0)(belowZero / allMinima)} of minima are below zero from calibration noise, and I left them off the chart</li>
          </ul>
        </div>
      </div>
      {@render takeaway("A bounce shows up about a foot above the floor. Low ball heights are approximate, so a bounce's height can't be read to the inch.")}
      <div class="rb-grid two">
        <div>
          <h4>Where Made Shots Pass Rim Height, Relative to the Nominal Hoop</h4>
          <Scatter points={crossings} groups={["Camera's right basket", "Camera's left basket"]} xlabel="Along the Court (ft, + = Toward the Baseline)"
                   ylabel="Across (ft)" xdomain={[-3, 3]} ydomain={[-2.5, 2.5]}
                   lines={[{ points: [[0, -2.5], [0, 2.5]], color: "var(--muted)", dashed: true }]} radius={3.5} />
        </div>
        <div class="rb-explain">
          <h4>The ball and the players disagree at height</h4>
          <ul class="facts">
            <li>A made shot must pass within a few inches of the hoop's centre</li>
            <li>In the data it crosses rim height about {f(1)(-meanOf(doc.audit.hoops.filter((h) => n(h.dx) < 0), "dx"))} ft short of the nominal hoop at one end and {f(1)(meanOf(doc.audit.hoops.filter((h) => n(h.dx) > 0), "dx"))} ft past it at the other, in every game</li>
            <li>A ball being held sits about a foot from its holder, as expected</li>
            <li>So the error grows with height, and the 3D reconstruction is biased up in the air</li>
          </ul>
        </div>
      </div>
      {@render takeaway("High in the air the ball's position is off by a foot or more along the court, in a consistent direction at each end. Compare the ball with players near the floor and leave the top of its arc alone.")}
      <p class="rb-note">
        <b>Also found.</b> The tracking files skip frame numbers (up to {int(rangeOf(doc.audit.gaps, "missing_indices")[1])} in one game). My first
        reader assumed the line number equals the frame number and silently put 255 shots on the wrong frames. It now matches lines
        on their frame number. A join can fail without an error.
      </p>
    </section>

    <!-- 4 ------------------------------------------------------------------------------------------------- -->
    <section id="rb-where">
      <h2>4. Where Misses Go</h2>
      <ul class="facts">
        <li>Each map shows where rebounds were secured (the rebounder's position at the recorded rebound frame), by the range of the shot</li>
        <li>Ranges are at the rim (under 5 ft), midrange (every other two) and three. The hoop is at the right</li>
        <li>Every rebound spreads as a soft 1.5 ft blob, and all three maps share one colour scale, so the same shade means the same share of that range's rebounds per square foot</li>
        <li>Hover a map to read the share within 3 ft of the pointer</li>
      </ul>
      <div class="rb-grid three">
        {#each RANGES as rg (rg)}<CourtMap points={byRange(rg)} title={RANGE_TITLE[rg]} vmax={mapMax} />{/each}
      </div>
      <div class="rb-grid two">
        <div>
          <h4>Rebound Distance from the Hoop against Shot Distance</h4>
          <Scatter points={spotScatter} groups={["Offensive rebound", "Defensive rebound"]} xlabel="Shot Distance (ft)" ylabel="Rebound Distance (ft)"
                   lines={medianLines} radius={2.5} opacity={0.45} />
        </div>
        <div>
          <h4>Angle from the Shooter's Side (0° = Same Side as the Shot)</h4>
          <Columns categories={angleCats} series={angleSeries} format={(v) => `${Math.round(100 * v)}%`} />
        </div>
      </div>
      <ul class="facts">
        <li><b>Longer shots, longer rebounds.</b> The median rebound is {f(1)(shortR?.median_r)} ft from the hoop after a shot at the rim, {f(1)(midR?.median_r)} ft after a midrange shot and {f(1)(longR?.median_r)} ft after a three. {pc(0)(longR?.long_share)} of three-point rebounds come down more than 12 ft out, against {pc(0)(shortR?.long_share)} at the rim</li>
        <li><b>Rebounds stay on the shooter's side.</b> The most common direction is within 30° of the shot's own line for every range. The old rule that misses bounce long to the weak side does not show up here</li>
        <li><b>Most rebounds are close.</b> Even after threes, three quarters are secured within about {f(0)(longR?.q75)} ft of the hoop, so the fight for the ball happens in a small area</li>
      </ul>

      <h3>Try It: Where Do Misses from a Given Spot Go?</h3>
      <ul class="facts">
        <li>The maps above pool every shot in a range</li>
        <li>Here you pick the shot. Click a spot (or a preset) and the map shows where misses from shots like it were rebounded in these ten games</li>
      </ul>
      <ReboundFinder spots={finderSpots} />
      <aside class="concept">
        <h4>How the map is built, and how much data backs it</h4>
        <ul class="facts">
          <li>Every real miss votes for the spot where its rebound was secured. A vote counts more the closer its shot was to the one you clicked, with the weight falling off as a bell curve whose width is the slider</li>
          <li>The weighted votes are smoothed into a map exactly like the maps above. Nothing is fitted</li>
          <li>The width is a trade-off. A narrow width uses only near-identical shots, which is faithful to the spot but noisy. A wide width borrows from less similar shots, which is steadier but blurred toward the overall pattern</li>
          <li><b>"Worth N misses"</b> is the effective sample size, (sum of weights)² / sum of squared weights. It says how many equally weighted misses the weights add up to. Below about 15, treat the map as a rough sketch</li>
          <li><b>Mirroring</b> assumes a miss from the left behaves like the same miss from the right, reflected. It doubles the data. Untick it to see what the ten games say on each side alone</li>
        </ul>
      </aside>

      <div class="rb-grid two">
        <div>
          <h4>Offensive Rebounds by Shot Range</h4>
          <RateDots rows={rates(E("oreb_by_distance"), "shot_range", (v) => RANGE_TITLE[String(v)] ?? String(v))} reference={overall} />
        </div>
        <div>
          <h4>Offensive Rebounds by What the Ball Hit First</h4>
          <RateDots rows={rates(E("oreb_by_kind").filter((r) => r.kind !== "putback or tip"), "kind")} reference={overall} />
          <p class="rb-note">I left out "putback or tip" (58 misses). The label requires the offense to get the ball, so its 100% is circular.</p>
        </div>
      </div>
      <ul class="facts">
        <li><b>Range moves where the ball goes far more than who gets it.</b> The offensive rate drifts only from {pc(0)(one(E("oreb_by_distance"), (r) => r.shot_range === RANGES[0])?.rate)} after shots at the rim to {pc(0)(one(E("oreb_by_distance"), (r) => r.shot_range === RANGES[2])?.rate)} after threes, and every interval includes the overall {pc(0)(overall)}</li>
        <li><b>What the ball hits first matters little on its own</b></li>
      </ul>
      <div class="rb-grid two">
        <div>
          <h4>Time from Release to First Contact</h4>
          <Scatter points={flightPts} lines={[{ points: flightLine, label: `${f(2)(val("flight_time_fit", "value", "intercept"))} s + ${f(3)(val("flight_time_fit", "value", "per_ft"))} s per ft`, color: "var(--ink)" }]}
                   xlabel="Shot Distance (ft)" ylabel="Seconds" radius={2.5} opacity={0.45} />
        </div>
        <div>
          <h4>Timing Stand-Ins against the Recorded Rebound Frame</h4>
          <Columns categories={touchHist.cats} series={[{ name: "First moment a player could touch it", values: touchHist.vals }, { name: "Ball held (stand-in)", values: controlHist.vals }]}
                   xlabel="Seconds Relative to the Rebound Frame (Negative = Before)" format={(v) => String(Math.round(v))} />
        </div>
      </div>
      <ul class="facts">
        <li><b>The flight is regular.</b> Shot distance explains {pc(0)(val("flight_time_fit", "value", "r2"))} of the variation in time to the rim</li>
        <li><b>The recorded rebound frame is fuzzy.</b> It falls a median {f(2)(-median(timing, "touch_vs_rebound"))} s after the first moment a player could touch the ball and {f(2)(median(timing, "control_vs_rebound"))} s before the ball looks held</li>
      </ul>
      {@render takeaway("Where a miss goes depends on the shot's range and side, while who gets it barely moves with range. The recorded rebound moment is loose by a few tenths of a second, so exact rebound timing is unreliable.")}
    </section>

    <!-- 5 ------------------------------------------------------------------------------------------------- -->
    <section id="rb-limits">
      <h2>5. What to Keep in Mind</h2>
      <ul class="facts">
        <li><b>Ten games, {int(doc.episodes)} misses.</b> Rates come with 90% intervals. Where two intervals overlap, the data can't tell the groups apart</li>
        <li><b>Players choose where to go.</b> A group that rebounds more may differ in many ways besides the one charted, such as who is crashing and how many</li>
        <li><b>The ball is reconstructed.</b> It is partly interpolated and biased with height (section 3), and the trace panel's ball heights share those limits</li>
        <li><b>The rebound moment is loose</b> by a few tenths of a second (section 4), so "where the rebound was secured" means where the rebounder stood at that recorded frame</li>
      </ul>
      <p class="meta">
        The tables come from the rebounding pipeline, now archived with its models in <code>zz_Archive/src/rebounding/</code>
        (<code>run_audit.R</code>, <code>run_eda.R</code>, <code>run_export.R</code>) and frozen here as <code>rebounding_eda.json</code>.
        Data from SkillCorner open data, Liga ACB, MIT licence. Built {doc.built}.
      </p>
    </section>
  </div>
{/if}

<style>
  .rb-doc { max-width: 1120px; }
  .rb-toc { display: flex; flex-direction: column; align-items: flex-start; gap: 6px; margin: 14px 0 6px; padding: 10px 12px; border: 1px solid var(--line); border-radius: 8px; background: var(--panel); }
  .rb-toc .link { font-size: 15px; text-align: left; }
  .rb-grid { display: grid; gap: 28px; margin: 22px 0; align-items: start; }
  .rb-grid.two { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .rb-grid.three { grid-template-columns: repeat(3, minmax(0, 1fr)); }
  .rb-grid h4 { margin-top: 0; }
  .rb-grid > div:not(.rb-explain) > h4 { text-align: center; }
  .rb-explain .facts { margin-top: 0; }
  .rb-explain b, .rb-explain i { color: var(--ink); }
  .decision { display: flex; gap: 14px; margin: 22px 0; padding: 12px 16px; border-left: 3px solid var(--off); border-radius: 0 8px 8px 0; background: rgba(76, 154, 255, .08); }
  .decision b { flex: none; color: var(--off); font-size: 13.5px; letter-spacing: .01em; text-transform: capitalize; line-height: 1.55; }
  .concept { margin: 14px 0; padding: 12px 14px; border: 1px solid var(--line); border-radius: 8px; background: var(--panel); }
  .concept h4 { margin-top: 0; color: var(--ink); }
  .concept .facts { margin-top: 0; }
  section > h3 { margin-top: 22px; }
  .concept b { color: var(--ink); }
  .rb-note { color: var(--muted); font-size: 14.5px; }
  .rb-note b { color: var(--ink); }
  .rb-more { margin: 12px 0; }
  .rb-more summary { cursor: pointer; color: var(--off); font-size: 15px; }
  .rb-more .table-wrap { margin-top: 10px; }
  .rb-table.narrow { min-width: 0; width: auto; }
  .rb-table td { font-size: 15px; white-space: nowrap; }
  code { font-size: 14px; }
  @media (max-width: 860px) {
    .rb-grid.two { grid-template-columns: minmax(0, 1fr); }
    .rb-grid.three { gap: 8px; }
  }
</style>
