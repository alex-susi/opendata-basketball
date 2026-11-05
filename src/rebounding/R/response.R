# Step 10 of the rebounding manual: the observable movement response. For each player, the first sustained move
# toward the reference rebound distribution's centre after release, from causal velocities (Step 08): speed toward
# the target at least `toward_ft_s` and at least `rise_ft_s` above his speed toward it at release, for
# `sustain_frames` frames in a row. Players already moving toward it at release are ambiguous and not timed; players
# who never do before the horizon get no onset. An onset is an observed response, not a physiological reaction time:
# anticipation (moving before release) and tactical non-crashing (getting back) both shape it.
# Settings: config/experiment.yaml (step10$response). Requires geometry.R (FPS).

#' Response class and onset (seconds after release) of every player in one episode.
#' @param v causal velocities (frame, pid, x, y, vx, vy) from release to the horizon; `target` c(x, y).
response_onset <- function(v, release, horizon, target, rs) {
  d <- v[frame >= release & frame <= horizon & !is.na(vx)][order(pid, frame)]
  d[, dist := sqrt((target[1] - x)^2 + (target[2] - y)^2)]
  d[, toward := ((target[1] - x) * vx + (target[2] - y) * vy) / pmax(dist, 1e-6)]
  rbindlist(lapply(split(d, by = "pid"), function(p) {
    t0 <- p[frame == release]$toward
    if (!length(t0)) return(data.table(pid = p$pid[1], response = "no velocity at release", onset_s = NA_real_, toward_release = NA_real_))
    if (t0 >= rs$toward_ft_s) return(data.table(pid = p$pid[1], response = "already moving", onset_s = NA_real_, toward_release = t0))
    ok <- p$frame > release & p$toward >= rs$toward_ft_s & p$toward >= t0 + rs$rise_ft_s
    run <- frollsum(as.integer(ok), rs$sustain_frames, align = "left")
    i <- which(ok & run >= rs$sustain_frames)[1]
    if (is.na(i)) data.table(pid = p$pid[1], response = "no response", onset_s = NA_real_, toward_release = t0)
    else data.table(pid = p$pid[1], response = "response", onset_s = (p$frame[i] - release) / FPS, toward_release = t0)
  }))
}
