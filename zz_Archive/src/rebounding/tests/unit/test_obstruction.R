# Step 11: pairwise obstruction geometry, pairings and the contribution split on synthetic cases.

for (f in c("geometry.R", "pairwise_obstruction.R", "boxout.R")) source(file.path(here, "R", f))
cfg <- yaml::read_yaml(file.path(here, "config", "experiment.yaml"))$step11
p <- cfg$score
pc <- cfg$pairing
tg <- obstruction_targets(cfg$targets)

# five against five: attacker 1 at (30, 0) boxed out by defender 6 standing 2.5 ft nearer the hoop; the rest spread out
scene <- function() data.table(pid = 1:10, off = rep(c(TRUE, FALSE), each = 5),
                               x = c(30, 20, 22, 15, 10, 32.5, 18, 27, 12, 8), y = c(0, 15, -15, 5, -20, 0, 12, -10, 8, -18))
O_of <- function(s, targets = tg) pair_obstruction(s$pid, s$off, s$x, s$y, targets, p)
rotate <- function(x, y, a, c0 = c(RIM_X, 0)) list(x = c0[1] + (x - c0[1]) * cos(a) - (y - c0[2]) * sin(a),
                                                   y = c0[2] + (x - c0[1]) * sin(a) + (y - c0[2]) * cos(a))

test_that("targets are the hoop and the two rings in front of it, none past the baseline", {
  expect_equal(nrow(tg), 1 + 2 * 7)
  expect_true(all(tg$tx <= COURT_HALF_L))
  expect_equal(sort(round(tg$ty, 9)), sort(round(-tg$ty, 9)))      # symmetric left to right
})

test_that("a defender on the attacker's route to the hoop obstructs him; beside, behind or far away he does not", {
  s <- scene()
  O <- O_of(s)
  expect_gt(O["6", "1"], 0.5)
  expect_equal(O["1", "2"], 0)
  expect_equal(O["6", "7"], 0)         # teammates and the diagonal are 0
  expect_equal(unname(diag(O)), rep(0, 10))
  side <- copy(s)[pid == 6, `:=`(x = 30, y = 4)]                      # 4 ft to the side
  behind <- copy(s)[pid == 6, x := 27]                                # between the attacker and centre court
  far <- copy(s)[pid == 6, x := 39]                                   # 9 ft ahead, under the hoop
  expect_lt(O_of(side)["6", "1"], 0.1)
  expect_equal(O_of(behind)["6", "1"], 0)
  expect_lt(O_of(far)["6", "1"], O["6", "1"] / 2)
  expect_true(all(O >= 0 & O <= 1))
})

test_that("distance zero and a runner on the target give finite scores of zero", {
  s <- copy(scene())[pid == 6, `:=`(x = 30, y = 0)]                   # defender on top of the attacker
  O <- O_of(s)
  expect_true(all(is.finite(O)))
  expect_equal(O["6", "1"], 0)
  at <- obstruction_score(31, 0, RIM_X, 0, RIM_X, 0, p)               # runner standing on the target
  expect_equal(at, 0)
})

test_that("rotating every player and target about the hoop, or mirroring the court, changes nothing", {
  s <- scene()
  O <- O_of(s)
  for (a in c(0.3, -1.1, pi / 2)) {
    r <- rotate(s$x, s$y, a)
    rt <- rotate(tg$tx, tg$ty, a)
    O2 <- O_of(copy(s)[, `:=`(x = r$x, y = r$y)], data.table(tx = rt$x, ty = rt$y))
    expect_lt(max(abs(O2 - O)), 1e-12)
  }
  O3 <- O_of(copy(s)[, y := -y])                                      # the target set is symmetric: no change
  expect_lt(max(abs(O3 - O)), 1e-12)
})

test_that("ties: two mirror-image attackers get equal values and the defender's pairing is ambiguous", {
  s <- data.table(pid = 1:10, off = rep(c(TRUE, FALSE), each = 5),
                  x = c(30, 30, 10, 12, 14, 32, 5, 8, 6, 4), y = c(1.2, -1.2, 20, -20, 22, 0, 18, -18, 22, -22))
  O <- O_of(s)
  expect_equal(O["6", "1"], O["6", "2"], tolerance = 1e-12)
  pg <- pairing_of(O, pc)
  expect_equal(pg[pid == 6]$pairing, "ambiguous")
  expect_equal(pg[pid == 7]$pairing, "none")                          # a far-away defender is not forced into a pair
  expect_equal(pairing_of(O_of(scene()), pc)[pid == 6][, .(runner, pairing)], data.table(runner = 1L, pairing = "pair"))
})

test_that("the score is continuous and a clear box-out survives one-foot moves in any direction", {
  s <- scene()
  O <- O_of(s)
  set.seed(1)
  for (k in 1:50) {
    d <- copy(s)[, `:=`(x = x + rnorm(10, 0, 0.01), y = y + rnorm(10, 0, 0.01))]
    expect_lt(max(abs(O_of(d) - O)), 0.02)
  }
  for (who in c(1L, 6L)) for (a in seq(0, 7) * pi / 4) {
    d <- copy(s)[pid == who, `:=`(x = x + cos(a), y = y + sin(a))]
    pg <- pairing_of(O_of(d), pc)
    expect_equal(pg[pid == 6]$runner, 1L)
    expect_equal(pg[pid == 6]$pairing, "pair")
  }
})

test_that("player features: one strong block counts nearly fully; removing a blocker takes his part away", {
  s <- scene()
  O <- O_of(s)
  f <- obstruction_features(O)
  expect_equal(f[pid == 1]$blocked_by_opp, 1 - prod(1 - O[, "1"]), tolerance = 1e-12)
  expect_gte(f[pid == 1]$blocked_by_opp, O["6", "1"])
  expect_equal(f[pid == 6]$blocking_opp, 1 - prod(1 - O["6", ]), tolerance = 1e-12)
  g <- features_without_blocker(O, 6L)
  expect_equal(g[pid == 6]$blocking_opp, 0)
  expect_lt(g[pid == 1]$blocked_by_opp, f[pid == 1]$blocked_by_opp)
  expect_equal(g[pid %in% 2:5]$blocking_opp, f[pid %in% 2:5]$blocking_opp)   # other players' own blocking unchanged
})

test_that("the contribution split adds up: team = own + teammates", {
  ch <- data.table(episode_id = "e", outcome_id = c(as.character(1:10), "team_off", "team_def"),
                   side = c(rep("off", 5), rep("def", 5), "off", "def"))
  set.seed(2)
  pr <- function(id) {
    v <- runif(12)
    data.table(episode_id = id, outcome_id = ch$outcome_id, probability = v / sum(v))
  }
  pred <- pr("e")
  cf <- rbindlist(lapply(1:10, function(q) pr(paste0("e#", q))))
  cs <- contribution_split(pred, cf, ch)
  expect_equal(nrow(cs), 10L)
  expect_equal(cs$contrib_team, cs$contrib_own + cs$contrib_mates, tolerance = 1e-12)
  expect_equal(cs[pid == 6]$collection, pred[outcome_id == "6"]$probability)
  expect_equal(cs[pid == 6]$team_secures, pred[outcome_id %in% c("6", "7", "8", "9", "10", "team_def"), sum(probability)])
})

test_that("persistence counts the frames a pair holds the block, skipping frames without ten players", {
  s <- scene()
  pl <- rbindlist(lapply(0:12, function(f) cbind(frame = 100L + f, s)))
  pl[frame <= 105 & pid == 6, x := 27]                                # behind the attacker for the first six frames
  pl <- pl[!(frame == 110 & pid == 3)]                                # one frame without player 3 is carried over
  expect_equal(pair_persistence(pl, 112L, 12L, 6L, 1L, tg, p, pc), 7 / 13)
  expect_true(is.na(pair_persistence(pl[pid != 3], 112L, 12L, 6L, 1L, tg, p, pc)))
})
