/* Play viewer front end: play list, canvas animation, timeline, rosters and the EPV overlay.
   Shiny sends two messages: "plays" (the filtered list) and "play" (one possession's tracking, plus
   EPV prices when src/epv/build_epv.R has been run).
   Coordinates arrive in feet with the origin at centre court and the offense attacking +x. */
(function () {
  'use strict';

  // ---- court geometry: FIBA markings are specified in metres, tracking is in feet ----
  const M = 3.28084;
  const HALF_L = 14 * M, HALF_W = 7.5 * M;
  const HOOP_X = HALF_L - 1.575 * M;
  const KEY_X = HALF_L - 5.8 * M, KEY_HALF_W = 2.45 * M;
  const THREE_R = 6.75 * M, THREE_Y = 6.6 * M;
  const CIRCLE_R = 1.8 * M, NO_CHARGE_R = 1.25 * M;
  const BOARD_X = HALF_L - 1.2 * M, BOARD_HALF_W = 0.9 * M, RIM_R = 0.225 * M;
  const LANE_MARKS = [1.75 * M, 3.85 * M, 4.7 * M], LANE_BLOCK = [2.6 * M, 3.0 * M];

  const FPS = 25;
  const MARGIN = 4;                          // feet of floor shown outside the lines
  const PAD = { top: 112, bottom: 34, side: 12 };
  const LEAD_IN = 50, TAIL = 25;             // stopped-clock frames kept before a restart / after a whistle
  const CAPTION_FRAMES = 62;                 // how long an event label stays up
  const END_HOLD = 1.2;                      // seconds to rest on the last frame before looping
  const EPV_STALE = 9;                       // frames after the last price before the overlay is hidden
  const VALUE_SPAN = 0.35;                   // points above/below current EPV at which pass colours saturate
  // The court keeps its light hardwood look; everything around it follows the dark dashboard theme.
  const COLORS = { paper: '#1B2334', floor: '#F6CFA3', line: '#2B2622', ink: '#E8EDF6', muted: '#93A0B8',
                   off: '#1F6FE5', def: '#F26A36', offText: '#4C9AFF', defText: '#FF8552', ball: '#F59A23',
                   ballEdge: '#7A3E00', white: '#FFFFFF', panel: '#0F1522', dark: '#0B0E14', best: '#18A56B',
                   risk: '#F5B02E' };
  const FONT = 'system-ui, -apple-system, "Segoe UI", Roboto, sans-serif';
  const TICK_FONT = `600 10.5px ${FONT}`;    // must match .tick-label in style.css
  const OPTIONS = { 'opt-def-hull': 'showDef', 'opt-off-hull': 'showOff', 'opt-extrap': 'markExtrap', 'opt-loop': 'loop',
                    'opt-epv': 'showEpv', 'opt-pass-values': 'showPassValues', 'opt-pass-tov': 'showPassTov',
                    'opt-ball-tov': 'showBallTov', 'opt-shot-pass': 'showShotPass', 'opt-best-pass': 'showBestPass',
                    'opt-readout': 'showReadout' };

  const $ = (id) => document.getElementById(id);
  const canvas = $('court'), ctx = canvas.getContext('2d'), stage = $('stage');
  const measure = document.createElement('canvas').getContext('2d');   // text widths for timeline captions

  const state = { plays: [], playId: null, play: null, seq: [], pos: 0, playing: false, hold: 0, speed: 1,
                  view: 'full', showDef: true, showOff: false, skipDead: true, loop: true, markExtrap: false,
                  showEpv: true, showPassValues: true, showPassTov: true, showBallTov: true, showShotPass: true,
                  showBestPass: true, showReadout: true,
                  hoverPid: null, dirty: true, lastTs: 0, recorder: null, rosterKey: '', areaTick: 0 };

  // ---- small helpers ----
  const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v));
  const clock = (s) => `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, '0')}`;
  const quarter = (p) => (p <= 4 ? `Q${p}` : `OT${p - 4}`);
  const pct = (v, digits) => `${(100 * v).toFixed(digits)}%`;
  const el = (tag, cls, text) => {
    const node = document.createElement(tag);
    if (cls) node.className = cls;
    if (text != null) node.textContent = text;
    return node;
  };

  // Red below the current EPV, neutral at it, green above it.
  function valueColor(delta, ends) {
    const t = clamp(delta / VALUE_SPAN, -1, 1), end = t < 0 ? ends[0] : ends[2];
    return `rgb(${ends[1].map((m, i) => Math.round(m + (end[i] - m) * Math.abs(t))).join(',')})`;
  }
  const TEXT_ENDS = [[255, 138, 128], [241, 243, 248], [125, 240, 180]];

  function convexHull(points) {
    if (points.length < 3) return points.slice();
    const p = points.slice().sort((a, b) => a[0] - b[0] || a[1] - b[1]);
    const cross = (o, a, b) => (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0]);
    const chain = (pts) => {
      const out = [];
      for (const q of pts) {
        while (out.length >= 2 && cross(out[out.length - 2], out[out.length - 1], q) <= 0) out.pop();
        out.push(q);
      }
      out.pop();
      return out;
    };
    return chain(p).concat(chain(p.slice().reverse()));
  }

  function polygonArea(poly) {
    let twice = 0;
    for (let i = 0; i < poly.length; i++) {
      const a = poly[i], b = poly[(i + 1) % poly.length];
      twice += a[0] * b[1] - b[0] * a[1];
    }
    return Math.abs(twice) / 2;
  }

  // ---- layout: map feet to canvas pixels ----
  function viewRect() {
    return { x0: state.view === 'half' ? -MARGIN : -(HALF_L + MARGIN), x1: HALF_L + MARGIN,
             y0: -(HALF_W + MARGIN), y1: HALF_W + MARGIN };
  }

  function layout() {
    const W = stage.clientWidth, H = stage.clientHeight, v = viewRect();
    const s = Math.max(1, Math.min((W - 2 * PAD.side) / (v.x1 - v.x0), (H - PAD.top - PAD.bottom) / (v.y1 - v.y0)));
    const cw = (v.x1 - v.x0) * s, ch = (v.y1 - v.y0) * s;
    const left = (W - cw) / 2, top = PAD.top + (H - PAD.top - PAD.bottom - ch) / 2;
    return { W, H, s, left, top, cw, ch, ox: left - v.x0 * s, oy: top + v.y1 * s };
  }

  function resize() {
    const dpr = window.devicePixelRatio || 1;
    canvas.width = Math.round(stage.clientWidth * dpr);
    canvas.height = Math.round(stage.clientHeight * dpr);
    state.dirty = true;
  }

  // ---- court ----
  function halfCourtLines() {
    const a = Math.atan2(THREE_Y, -Math.sqrt(THREE_R * THREE_R - THREE_Y * THREE_Y));
    ctx.beginPath();
    ctx.rect(KEY_X, -KEY_HALF_W, HALF_L - KEY_X, 2 * KEY_HALF_W);
    ctx.moveTo(HALF_L, THREE_Y);
    ctx.lineTo(HOOP_X + THREE_R * Math.cos(a), THREE_Y);
    ctx.arc(HOOP_X, 0, THREE_R, a, 2 * Math.PI - a);
    ctx.lineTo(HALF_L, -THREE_Y);
    ctx.moveTo(KEY_X, CIRCLE_R);
    ctx.arc(KEY_X, 0, CIRCLE_R, Math.PI / 2, 1.5 * Math.PI);
    ctx.moveTo(BOARD_X, NO_CHARGE_R);
    ctx.lineTo(HOOP_X, NO_CHARGE_R);
    ctx.arc(HOOP_X, 0, NO_CHARGE_R, Math.PI / 2, 1.5 * Math.PI);
    ctx.lineTo(BOARD_X, -NO_CHARGE_R);
    ctx.moveTo(BOARD_X, -BOARD_HALF_W);
    ctx.lineTo(BOARD_X, BOARD_HALF_W);
    ctx.moveTo(HOOP_X + RIM_R, 0);
    ctx.arc(HOOP_X, 0, RIM_R, 0, 2 * Math.PI);
    for (const side of [1, -1]) {
      for (const d of LANE_MARKS) {
        ctx.moveTo(HALF_L - d, side * KEY_HALF_W);
        ctx.lineTo(HALF_L - d, side * (KEY_HALF_W + 0.5));
      }
    }
    ctx.stroke();
    for (const side of [1, -1]) {
      ctx.fillRect(HALF_L - LANE_BLOCK[1], side > 0 ? KEY_HALF_W : -KEY_HALF_W - 0.5, LANE_BLOCK[1] - LANE_BLOCK[0], 0.5);
    }
    ctx.save();
    ctx.setLineDash([1.1, 1.1]);
    ctx.beginPath();
    ctx.arc(KEY_X, 0, CIRCLE_R, -Math.PI / 2, Math.PI / 2);
    ctx.stroke();
    ctx.restore();
  }

  function drawCourt(L, dpr) {
    ctx.save();
    ctx.beginPath();
    ctx.rect(L.left, L.top, L.cw, L.ch);
    ctx.clip();
    ctx.setTransform(dpr * L.s, 0, 0, -dpr * L.s, dpr * L.ox, dpr * L.oy);
    ctx.fillStyle = COLORS.floor;
    ctx.fillRect(-HALF_L, -HALF_W, 2 * HALF_L, 2 * HALF_W);
    ctx.strokeStyle = COLORS.line;
    ctx.fillStyle = COLORS.line;
    ctx.lineWidth = Math.max(1.25, 0.14 * L.s) / L.s;
    ctx.lineJoin = 'round';
    ctx.beginPath();
    ctx.rect(-HALF_L, -HALF_W, 2 * HALF_L, 2 * HALF_W);
    ctx.moveTo(0, -HALF_W);
    ctx.lineTo(0, HALF_W);
    ctx.moveTo(CIRCLE_R, 0);
    ctx.arc(0, 0, CIRCLE_R, 0, 2 * Math.PI);
    ctx.stroke();
    halfCourtLines();
    ctx.scale(-1, 1);
    halfCourtLines();
    ctx.restore();
  }

  // ---- playback sequence ----
  // The payload holds every live tracking frame of the possession. `seq` lists the frames to show:
  // all of them, or (skip dead-ball time) the running-clock frames plus a short run-up to each restart.
  function buildSeq() {
    const p = state.play, n = p.frames.length, keep = new Uint8Array(n);
    const joined = (i) => p.frames[i + 1] - p.frames[i] === 1;
    if (state.skipDead) {
      for (let i = 0; i < n; i++) {
        if (p.stopped[i]) continue;
        keep[i] = 1;
        for (let j = i - 1; j >= 0 && i - j <= LEAD_IN && p.stopped[j] && joined(j); j--) keep[j] = 1;
        for (let j = i + 1; j < n && j - i <= TAIL && p.stopped[j] && joined(j - 1); j++) keep[j] = 1;
      }
    }
    if (!state.skipDead || !keep.includes(1)) keep.fill(1);
    state.seq = [];
    for (let i = 0; i < n; i++) if (keep[i]) state.seq.push(i);
  }

  function seqIndexOfFrame(frame) {
    const f = state.play.frames, seq = state.seq;
    let lo = 0, hi = seq.length - 1;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      if (f[seq[mid]] < frame) lo = mid + 1; else hi = mid;
    }
    return lo;
  }

  // Frame pair and blend weight at the current position; no blending across a cut.
  function cursor() {
    const seq = state.seq, k = clamp(Math.floor(state.pos), 0, seq.length - 1);
    const i0 = seq[k], i1 = seq[Math.min(k + 1, seq.length - 1)];
    const t = state.play.frames[i1] - state.play.frames[i0] === 1 ? state.pos - k : 0;
    return { i0, i1, t };
  }

  const blend = (arr, c) => {
    const a = arr[c.i0], b = arr[c.i1];
    if (a == null) return null;
    return b == null ? a : a + (b - a) * c.t;
  };

  function ballHandler(frame) {
    let pid = null;
    for (const t of state.play.touches) if (t.f0 <= frame && frame <= t.f1) pid = t.pid;
    return pid;
  }

  // ---- EPV prices ----
  // Prices sit on a coarser grid than the tracking. Returns a reader that blends between grid points,
  // or null where nothing is priced (dead ball, nobody holding the ball, prices not built).
  function epvAt(frame) {
    const e = state.play.epv;
    if (!state.showEpv || !e || !e.f.length || frame < e.f[0]) return null;
    let lo = 0, hi = e.f.length - 1;
    while (lo < hi) {
      const mid = (lo + hi + 1) >> 1;
      if (e.f[mid] <= frame) lo = mid; else hi = mid - 1;
    }
    if (frame - e.f[lo] > EPV_STALE) return null;
    const joined = lo + 1 < e.f.length && e.f[lo + 1] - e.f[lo] <= EPV_STALE && e.holder[lo + 1] === e.holder[lo];
    const next = joined ? lo + 1 : lo, t = joined ? clamp((frame - e.f[lo]) / (e.f[next] - e.f[lo]), 0, 1) : 0;
    const read = (arr) => (arr[lo] == null ? null : arr[next] == null ? arr[lo] : arr[lo] + (arr[next] - arr[lo]) * t);
    const option = (pid, key) => (e.players[pid] ? read(e.players[pid][key]) : null);
    return { holder: e.holder[lo], target: e.to[lo], value: read(e.v), haz: read(e.haz), rop: read(e.rop),
             cum: read(e.cum), shot: read(e.shot), pass: read(e.pass), option };
  }

  // ---- drawing ----
  function drawHull(L, pts, color) {
    const poly = convexHull(pts);
    if (poly.length < 3) return 0;
    ctx.beginPath();
    poly.forEach((q, i) => ctx[i ? 'lineTo' : 'moveTo'](L.ox + q[0] * L.s, L.oy - q[1] * L.s));
    ctx.closePath();
    ctx.globalAlpha = 0.5;
    ctx.fillStyle = color;
    ctx.fill();
    ctx.globalAlpha = 1;
    ctx.lineWidth = 2;
    ctx.lineJoin = 'round';
    ctx.strokeStyle = color;
    ctx.stroke();
    return polygonArea(poly);
  }

  function drawPlayer(L, d, r, hasBall) {
    const x = L.ox + d.x * L.s, y = L.oy - d.y * L.s, color = COLORS[d.p.role];
    const faded = state.markExtrap && !d.det;
    if (state.hoverPid === d.p.id || hasBall) {
      ctx.beginPath();
      ctx.arc(x, y, r + 5.5, 0, 2 * Math.PI);
      ctx.lineWidth = 2.5;
      ctx.strokeStyle = state.hoverPid === d.p.id ? COLORS.dark : color;
      ctx.stroke();
    }
    ctx.beginPath();
    ctx.arc(x, y, r, 0, 2 * Math.PI);
    ctx.fillStyle = COLORS.white;
    ctx.fill();
    ctx.globalAlpha = faded ? 0.45 : 1;
    ctx.beginPath();
    ctx.arc(x, y, r - 2.2, 0, 2 * Math.PI);
    ctx.fillStyle = color;
    ctx.fill();
    ctx.globalAlpha = 1;
    ctx.fillStyle = faded ? color : COLORS.white;
    ctx.font = `700 ${Math.round(r * (d.p.jersey.length > 1 ? 0.95 : 1.1))}px ${FONT}`;
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillText(d.p.jersey, x, y + 0.5);
  }

  // A small dark label. `anchor` is 'center' (x is its middle) or 'left' (x is its left edge).
  function drawTag(x, cy, text, color, size, anchor) {
    ctx.font = `700 ${size}px ${FONT}`;
    const w = ctx.measureText(text).width + 10, h = size + 7, left = anchor === 'left' ? x : x - w / 2;
    ctx.fillStyle = COLORS.panel;
    ctx.globalAlpha = 0.92;
    ctx.beginPath();
    ctx.roundRect(left, cy - h / 2, w, h, 4);
    ctx.fill();
    ctx.globalAlpha = 1;
    ctx.fillStyle = color;
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillText(text, left + w / 2, cy + 0.5);
  }

  // EPV labels around the offense. Player dots themselves are never restyled by the overlay.
  function drawOptions(L, dots, r, ep) {
    const at = (d) => [L.ox + d.x * L.s, L.oy - d.y * L.s];
    const holder = dots.find((d) => d.p.id === ep.holder);
    for (const d of dots) {
      if (d === holder) continue;
      const [x, y] = at(d), pv = ep.option(d.p.id, 'pv'), tov = ep.option(d.p.id, 'tov');
      if (state.showPassValues && pv != null) {
        drawTag(x, y - r - 12, pv.toFixed(2), valueColor(pv - (ep.value == null ? pv : ep.value), TEXT_ENDS), 12, 'center');
      }
      if (state.showPassTov && tov != null) drawTag(x + r + 5, y, `${pct(tov, 1)} TOV`, COLORS.ink, 10.5, 'left');
    }
    if (!holder) return;
    const [x, y] = at(holder);
    if (state.showShotPass && ep.shot != null) {
      const w = 96, h = 34, top = y - r - 9 - h;
      ctx.fillStyle = COLORS.panel;
      ctx.globalAlpha = 0.92;
      ctx.beginPath();
      ctx.roundRect(x - w / 2, top, w, h, 5);
      ctx.fill();
      ctx.globalAlpha = 1;
      ctx.textAlign = 'center';
      ctx.textBaseline = 'middle';
      for (const [label, value, cx] of [['SHOT', ep.shot, x - w / 4], ['PASS', ep.pass, x + w / 4]]) {
        ctx.font = `700 8.5px ${FONT}`;
        ctx.fillStyle = COLORS.muted;
        ctx.fillText(label, cx, top + 10);
        ctx.font = `700 12.5px ${FONT}`;
        ctx.fillStyle = COLORS.ink;
        ctx.fillText(value == null ? '–' : value.toFixed(2), cx, top + 23);
      }
    }
    if (state.showPassValues && ep.value != null) drawTag(x, y + r + 12, ep.value.toFixed(2), COLORS.ink, 12, 'center');
    if (state.showBallTov && ep.haz != null) {
      const bx = x + r * 0.95, by = y - r * 0.95;
      ctx.beginPath();
      ctx.arc(bx, by, 13.5, 0, 2 * Math.PI);
      ctx.fillStyle = COLORS.risk;
      ctx.fill();
      ctx.fillStyle = COLORS.dark;
      ctx.font = `700 10px ${FONT}`;
      ctx.textAlign = 'center';
      ctx.textBaseline = 'middle';
      ctx.fillText(pct(ep.haz, ep.haz < 0.0995 ? 1 : 0), bx, by + 0.5);
    }
  }

  // Header, centred over the court and stacked: teams, then quarter / shot clock / game clock, then
  // the EPV readout when prices are showing.
  function drawHud(L, c, labels, ep) {
    const p = state.play, cx = L.left + L.cw / 2, shotClock = p.sc[c.i0];
    const cells = ep && state.showReadout
      ? [['EPV', ep.value == null ? '–' : ep.value.toFixed(2)], ['TOV% (ROP)', ep.rop == null ? '–' : pct(ep.rop, 1)],
         ['CUM. TOV', ep.cum == null ? '–' : pct(ep.cum, 1)]]
      : [];
    const teamsY = L.top - (cells.length ? 96 : 44), clockY = teamsY + 24;
    ctx.textBaseline = 'middle';

    const teams = [[p.off, COLORS.offText, 700], ['  vs  ', COLORS.muted, 400], [p.def, COLORS.defText, 700]];
    const span = (size) => teams.reduce((sum, [text, , weight]) => {
      ctx.font = `${weight} ${size}px ${FONT}`;
      return sum + ctx.measureText(text).width;
    }, 0);
    const size = Math.max(10, Math.min(15, Math.floor(15 * (L.W - 24) / span(15))));
    let x = cx - span(size) / 2;
    ctx.textAlign = 'left';
    for (const [text, color, weight] of teams) {
      ctx.font = `${weight} ${size}px ${FONT}`;
      ctx.fillStyle = color;
      ctx.fillText(text, x, teamsY);
      x += ctx.measureText(text).width;
    }

    const period = quarter(p.period), game = clock(p.gc[c.i0]), pill = 34, gap = 10;
    ctx.font = `700 15px ${FONT}`;
    const periodW = ctx.measureText(period).width, gameW = ctx.measureText(game).width;
    x = cx - (periodW + pill + gameW + 2 * gap) / 2;
    ctx.fillStyle = COLORS.ink;
    ctx.fillText(period, x, clockY);
    ctx.fillText(game, x + periodW + pill + 2 * gap, clockY);
    ctx.fillStyle = COLORS.panel;
    ctx.beginPath();
    ctx.roundRect(x + periodW + gap, clockY - 11, pill, 22, 6);
    ctx.fill();
    ctx.fillStyle = COLORS.risk;
    ctx.textAlign = 'center';
    ctx.fillText(shotClock == null ? '–' : String(Math.ceil(shotClock)), x + periodW + gap + pill / 2, clockY + 0.5);

    if (cells.length) {
      const cellW = clamp(L.cw * 0.16, 86, 112), panelW = cells.length * cellW, panelTop = L.top - 58;
      ctx.fillStyle = COLORS.panel;
      ctx.beginPath();
      ctx.roundRect(cx - panelW / 2, panelTop, panelW, 48, 8);
      ctx.fill();
      cells.forEach(([label, value], i) => {
        const cellX = cx - panelW / 2 + (i + 0.5) * cellW;
        ctx.font = `700 9.5px ${FONT}`;
        ctx.fillStyle = COLORS.muted;
        ctx.fillText(label, cellX, panelTop + 13);
        ctx.font = `700 19px ${FONT}`;
        ctx.fillStyle = COLORS.ink;
        ctx.fillText(value, cellX, panelTop + 32);
      });
    }

    // event caption: both recent labels if they fit beside the credit, otherwise the latest one
    const room = L.cw - 200;
    ctx.font = `500 13px ${FONT}`;
    ctx.fillStyle = COLORS.ink;
    ctx.textAlign = 'left';
    const both = labels.join('   ·   ');
    ctx.fillText(ctx.measureText(both).width <= room ? both : labels[labels.length - 1] || '', L.left, L.top + L.ch + 17, room);
    ctx.textAlign = 'right';
    ctx.font = `400 11px ${FONT}`;
    ctx.fillStyle = COLORS.muted;
    ctx.fillText('Data: SkillCorner open data, Liga ACB', L.left + L.cw, L.top + L.ch + 17);
  }

  function draw() {
    const dpr = window.devicePixelRatio || 1, L = layout();
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.fillStyle = COLORS.paper;
    ctx.fillRect(0, 0, L.W, L.H);
    drawCourt(L, dpr);
    const p = state.play;
    if (!p || !state.seq.length) return;

    const c = cursor(), frame = p.frames[c.i0], dots = { off: [], def: [] };
    for (const pl of p.players) {
      const x = blend(pl.x, c), y = blend(pl.y, c);
      if (x != null && y != null) dots[pl.role].push({ p: pl, x, y, det: pl.d[c.i0] });
    }
    const ep = epvAt(frame + c.t), r = clamp(1.2 * L.s, 9, 22), handler = ballHandler(frame);
    ctx.save();
    ctx.beginPath();
    ctx.rect(L.left, L.top, L.cw, L.ch);
    ctx.clip();
    const areaDef = state.showDef ? drawHull(L, dots.def.map((d) => [d.x, d.y]), COLORS.def) : null;
    const areaOff = state.showOff ? drawHull(L, dots.off.map((d) => [d.x, d.y]), COLORS.off) : null;
    if (ep && state.showBestPass && ep.target != null) {
      const from = dots.off.find((d) => d.p.id === ep.holder), to = dots.off.find((d) => d.p.id === ep.target);
      if (from && to) {
        ctx.beginPath();
        ctx.moveTo(L.ox + from.x * L.s, L.oy - from.y * L.s);
        ctx.lineTo(L.ox + to.x * L.s, L.oy - to.y * L.s);
        ctx.lineWidth = 3;
        ctx.lineCap = 'round';
        ctx.strokeStyle = COLORS.best;
        ctx.stroke();
      }
    }
    for (const d of dots.def.concat(dots.off)) drawPlayer(L, d, r, d.p.id === handler);
    if (ep) drawOptions(L, dots.off, r, ep);
    const bx = blend(p.ball.x, c), by = blend(p.ball.y, c), bz = blend(p.ball.z, c) || 0;
    if (bx != null && by != null) {
      ctx.beginPath();
      ctx.arc(L.ox + bx * L.s, L.oy - by * L.s, clamp(0.55 * L.s, 4.5, 10) * (1 + 0.5 * clamp(bz, 0, 14) / 14), 0, 2 * Math.PI);
      ctx.fillStyle = COLORS.ball;
      ctx.fill();
      ctx.lineWidth = 1.2;
      ctx.strokeStyle = COLORS.ballEdge;
      ctx.stroke();
    }
    ctx.restore();

    const labels = p.events.filter((e) => frame >= e.f && frame - e.f <= CAPTION_FRAMES).slice(-2).map((e) => e.label);
    drawHud(L, c, labels, ep);
    updateTimeline();
    updateRosters(dots, handler, areaOff, areaDef);
  }

  // ---- timeline ----
  function updateTimeline() {
    const end = Math.max(1, state.seq.length - 1), frac = clamp(state.pos / end, 0, 1);
    $('track-fill').style.width = `${frac * 100}%`;
    $('track-thumb').style.left = `${frac * 100}%`;
    $('time-label').textContent = `${clock(state.pos / FPS)} / ${clock(end / FPS)}`;
  }

  // Ticks for the possession's events, each captioned with the action above it and the player below.
  // Captions that would overlap drop to a second row; if that is taken too, the tooltip still names them.
  function renderTicks() {
    const p = state.play, end = Math.max(1, state.seq.length - 1), ticks = $('track-ticks'), captions = $('track-labels');
    const width = $('track').clientWidth, rowEnds = [-Infinity, -Infinity], marks = new Set();
    ticks.replaceChildren();
    captions.replaceChildren();
    for (let k = 1; k < state.seq.length; k++) {
      if (p.frames[state.seq[k]] - p.frames[state.seq[k - 1]] > 1) {
        const cut = el('i', 'tick cut');
        cut.style.left = `${(k / end) * 100}%`;
        cut.title = 'Footage skips here';
        ticks.append(cut);
      }
    }
    measure.font = TICK_FONT;
    for (const e of p.events) {
      const k = seqIndexOfFrame(e.f);
      if (Math.abs(p.frames[state.seq[k]] - e.f) > LEAD_IN) continue;
      marks.add(k);
      const tick = el('i', `tick ${e.kind}`);
      tick.style.left = `${(k / end) * 100}%`;
      tick.title = e.label;
      ticks.append(tick);
      const w = Math.max(measure.measureText(e.short || '').width, measure.measureText(e.who || '').width) + 8;
      const left = clamp((k / end) * width - w / 2, 0, Math.max(0, width - w));
      const row = rowEnds.findIndex((edge) => left >= edge);
      if (row < 0) continue;
      rowEnds[row] = left + w;
      for (const [text, side] of [[e.short, 'above'], [e.who, 'below']]) {
        const caption = el('span', `tick-label ${side} row${row} ${e.kind}`, text || '');
        caption.style.left = `${left}px`;
        caption.style.width = `${w}px`;
        captions.append(caption);
      }
    }
    state.marks = [...marks].sort((a, b) => a - b);
  }

  // Jump to the next action, or back to the previous one (the current one counts as passed after half a second).
  function stepAction(direction) {
    if (!state.play) return;
    const marks = state.marks || [], last = state.seq.length - 1;
    const target = direction > 0 ? marks.find((k) => k > state.pos + 1) : marks.slice().reverse().find((k) => k < state.pos - 12);
    state.pos = target == null ? (direction > 0 ? last : 0) : target;
    state.hold = 0;
    state.dirty = true;
  }

  function seekFromPointer(ev) {
    if (!state.play) return;
    const rail = $('track').getBoundingClientRect();
    state.pos = clamp((ev.clientX - rail.left) / rail.width, 0, 1) * (state.seq.length - 1);
    state.hold = 0;
    state.dirty = true;
  }

  // ---- rosters ----
  function renderRosters() {
    const p = state.play;
    $('team-off').textContent = p.off;
    $('team-def').textContent = p.def;
    for (const role of ['off', 'def']) {
      const list = $(`roster-${role}`);
      list.replaceChildren();
      for (const pl of p.players.filter((q) => q.role === role)) {
        const row = el('li');
        row.dataset.pid = pl.id;
        row.append(el('span', 'num', pl.jersey), el('span', 'name', pl.name), el('span', 'ball-mark'));
        row.addEventListener('mouseenter', () => { state.hoverPid = pl.id; state.dirty = true; });
        row.addEventListener('mouseleave', () => { state.hoverPid = null; state.dirty = true; });
        list.append(row);
      }
    }
    state.rosterKey = '';
  }

  function updateRosters(dots, handler, areaOff, areaDef) {
    const onCourt = new Set(dots.off.concat(dots.def).map((d) => d.p.id));
    const key = `${[...onCourt].join(',')}|${handler}`;
    if (key !== state.rosterKey) {
      state.rosterKey = key;
      document.querySelectorAll('.roster li').forEach((row) => {
        const pid = Number(row.dataset.pid);
        row.classList.toggle('bench', !onCourt.has(pid));
        row.classList.toggle('has-ball', pid === handler);
      });
    }
    if (state.areaTick++ % 4 === 0 || !state.playing) {
      $('area-off').textContent = areaOff == null ? '' : `Hull area ${Math.round(areaOff)} sq ft`;
      $('area-def').textContent = areaDef == null ? '' : `Hull area ${Math.round(areaDef)} sq ft`;
    }
  }

  // ---- play list ----
  function renderPlays(rows) {
    state.plays = rows;
    $('play-count').textContent = rows.length.toLocaleString();
    const frag = document.createDocumentFragment();
    let lastGame = null;
    for (const row of rows) {
      if (row.game !== lastGame) frag.append(el('div', 'game-head', lastGame = row.game));
      const item = el('button', 'play-item');
      item.type = 'button';
      item.dataset.id = row.id;
      const top = el('span', 'pi-top');
      top.append(el('b', null, `${quarter(row.q)} ${row.clock}`), el('span', 'pi-team', row.off), el('span', 'pi-secs', `${row.secs}s`));
      const tags = el('span', 'pi-tags');
      for (const t of row.types ? row.types.split('|') : []) tags.append(el('i', null, t));
      const made = row.result.startsWith('Made') ? 'made' : row.result.startsWith('Missed') ? 'missed' : '';
      item.append(top, el('span', `pi-result ${made}`, row.who ? `${row.result} · ${row.who}` : row.result), tags);
      frag.append(item);
    }
    $('play-list').replaceChildren(frag);
    if (!rows.length) return clearPlay('No possessions match these filters.');
    if (rows.some((r) => r.id === state.playId)) markActive(false); else selectPlay(rows[0].id);
  }

  function markActive(scroll) {
    document.querySelectorAll('.play-item.active').forEach((n) => n.classList.remove('active'));
    const item = document.querySelector(`.play-item[data-id="${state.playId}"]`);
    if (!item) return;
    item.classList.add('active');
    if (scroll) item.scrollIntoView({ block: 'nearest' });
  }

  function selectPlay(id) {
    state.playId = id;
    markActive(true);
    Shiny.setInputValue('play_id', id, { priority: 'event' });
  }

  function clearPlay(note) {
    state.play = null;
    state.playId = null;
    state.playing = false;
    $('play-title').textContent = 'No play selected';
    $('play-sub').textContent = '';
    $('scorebug').replaceChildren();
    $('stage-note').textContent = note;
    $('stage-note').hidden = false;
    document.querySelectorAll('.roster ul').forEach((n) => n.replaceChildren());
    for (const id of ['team-off', 'team-def', 'area-off', 'area-def']) $(id).textContent = '';
    $('track-ticks').replaceChildren();
    $('track-labels').replaceChildren();
    state.marks = [];
    syncPlayButton();
    state.dirty = true;
  }

  function loadPlay(p) {
    if (!p || p.id !== state.playId) return;
    stopRecording(false);
    state.play = p;
    state.pos = 0;
    state.hold = 0;
    state.playing = true;
    buildSeq();
    $('stage-note').hidden = true;
    $('epv-missing').hidden = Boolean(p.epv);
    $('play-title').textContent = `${quarter(p.period)} ${clock(p.gc[0])} · ${p.off} possession`;
    $('play-sub').textContent = [p.who ? `${p.result} (${p.who})` : p.result].concat(p.types).join(' · ');
    const bug = $('scorebug');
    bug.replaceChildren(el('span', p.off === p.home ? 'off' : 'def', p.home), el('b', null, `${p.homeScore} – ${p.awayScore}`),
                        el('span', p.off === p.away ? 'off' : 'def', p.away));
    bug.title = p.game;
    renderRosters();
    renderTicks();
    syncPlayButton();
    state.dirty = true;
  }

  // ---- transport ----
  function syncPlayButton() {
    $('play-glyph').setAttribute('d', state.playing ? 'M6 4h4v16H6zM14 4h4v16h-4z' : 'M7 4v16l13-8z');
  }

  function togglePlay() {
    if (!state.play) return;
    if (!state.playing && state.pos >= state.seq.length - 1) state.pos = 0;
    state.playing = !state.playing;
    state.hold = 0;
    syncPlayButton();
  }

  function nudge(seconds) {
    if (!state.play) return;
    state.pos = clamp(state.pos + seconds * FPS, 0, state.seq.length - 1);
    state.hold = 0;
    state.dirty = true;
  }

  function tick(ts) {
    requestAnimationFrame(tick);
    const dt = Math.min(0.1, (ts - state.lastTs) / 1000);
    state.lastTs = ts;
    if (state.play && state.playing) {
      const end = state.seq.length - 1;
      if (state.pos >= end) {
        state.hold += dt;
        const recording = Boolean(state.recorder);
        if (recording) stopRecording(true);
        if (recording || !state.loop) { state.playing = false; syncPlayButton(); }
        else if (state.hold >= END_HOLD) { state.pos = 0; state.hold = 0; }
      } else {
        state.pos = Math.min(end, state.pos + dt * FPS * state.speed);
      }
      state.dirty = true;
    }
    if (state.dirty) {
      state.dirty = false;
      draw();
    }
  }

  // ---- video export: record the canvas while the play runs once from the start ----
  function startRecording() {
    if (!state.play || state.recorder) return;
    const mime = ['video/mp4;codecs=avc1', 'video/webm;codecs=vp9', 'video/webm'].find((m) => window.MediaRecorder && MediaRecorder.isTypeSupported(m));
    if (!mime) return window.alert('This browser cannot record the canvas. Try a current Chrome, Edge or Firefox.');
    const chunks = [], name = `${state.play.id}.${mime.startsWith('video/mp4') ? 'mp4' : 'webm'}`;
    const recorder = new MediaRecorder(canvas.captureStream(30), { mimeType: mime, videoBitsPerSecond: 8e6 });
    recorder.ondataavailable = (ev) => { if (ev.data.size) chunks.push(ev.data); };
    recorder.onstop = () => {
      if (!recorder.keep) return;
      const link = el('a');
      link.href = URL.createObjectURL(new Blob(chunks, { type: mime.split(';')[0] }));
      link.download = name;
      link.click();
      setTimeout(() => URL.revokeObjectURL(link.href), 10000);
    };
    state.recorder = recorder;
    state.pos = 0;
    state.hold = 0;
    state.playing = true;
    $('btn-export').textContent = 'Recording… click to cancel';
    $('btn-export').classList.add('recording');
    syncPlayButton();
    recorder.start();
  }

  function stopRecording(keep) {
    const recorder = state.recorder;
    if (!recorder) return;
    recorder.keep = keep;
    state.recorder = null;
    $('btn-export').textContent = 'Save animation as video';
    $('btn-export').classList.remove('recording');
    setTimeout(() => recorder.stop(), keep ? 250 : 0);
  }

  // ---- wiring ----
  for (const [id, key] of Object.entries(OPTIONS)) {
    $(id).addEventListener('change', (e) => {
      state[key] = e.target.checked;
      if (id === 'opt-epv') $('epv-options').classList.toggle('off', !e.target.checked);
      state.dirty = true;
    });
  }
  $('opt-skip').addEventListener('change', (e) => {
    state.skipDead = e.target.checked;
    if (!state.play) return;
    const frame = state.play.frames[cursor().i0];
    buildSeq();
    state.pos = seqIndexOfFrame(frame);
    renderTicks();
    state.dirty = true;
  });
  document.querySelectorAll('.segmented button').forEach((btn) => btn.addEventListener('click', () => {
    document.querySelectorAll('.segmented button').forEach((b) => b.classList.toggle('on', b === btn));
    state.view = btn.dataset.view;
    state.dirty = true;
  }));
  $('speed').addEventListener('change', (e) => { state.speed = Number(e.target.value); });
  $('btn-play').addEventListener('click', togglePlay);
  $('btn-prev').addEventListener('click', () => stepAction(-1));
  $('btn-next').addEventListener('click', () => stepAction(1));
  $('btn-export').addEventListener('click', () => (state.recorder ? stopRecording(false) : startRecording()));
  $('play-list').addEventListener('click', (e) => {
    const item = e.target.closest('.play-item');
    if (item) selectPlay(item.dataset.id);
  });
  const track = $('track');
  track.addEventListener('pointerdown', (e) => { track.setPointerCapture(e.pointerId); seekFromPointer(e); });
  track.addEventListener('pointermove', (e) => { if (track.hasPointerCapture(e.pointerId)) seekFromPointer(e); });
  document.addEventListener('keydown', (e) => {
    if (e.target.closest('input, select, textarea, .selectize-control')) return;
    if (e.code === 'Space') { e.preventDefault(); togglePlay(); }
    if (e.code === 'ArrowLeft') { e.preventDefault(); nudge(-1); }
    if (e.code === 'ArrowRight') { e.preventDefault(); nudge(1); }
  });
  new ResizeObserver(resize).observe(stage);
  new ResizeObserver(() => { if (state.play) renderTicks(); }).observe(track);

  const parsed = (msg) => (typeof msg === 'string' ? JSON.parse(msg) : msg);
  Shiny.addCustomMessageHandler('plays', (msg) => renderPlays(parsed(msg) || []));
  Shiny.addCustomMessageHandler('play', (msg) => loadPlay(parsed(msg)));

  resize();
  requestAnimationFrame(tick);
})();
