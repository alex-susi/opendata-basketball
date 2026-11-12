## ═════════════════════════════════════════════════════════════════════════════
# Step 6: film study. Plays where one or both models were confident and wrong, one card per play.
#   Rscript kickout_transformer/01_scripts/06_film_study.R [--drop-other] [--model=freeze] [--n_per=...]
#
# "Confident and wrong": the model's most likely outcome did not happen and it gave that outcome at least CONFIDENT
# (60%). Every prediction here is from the game the model never saw. Plays are picked by category so the set covers the
# different kinds of miss, most confident first, preferring games not already used:
#   both_pass_was_drive   both models expected a pass, the receiver drove      (the most common miss)
#   both_pass_was_shot    both models expected a pass, the receiver shot
#   both_shot_was_other   both models expected a shot, the receiver passed or drove
#   transformer_only      only the transformer was confidently wrong; the logistic model's top pick was right
#   logistic_only         only the logistic model was confidently wrong; the transformer's top pick was right
#   kickout               the most confident miss (either model) among strict kickouts
#
# Writes figures/film_study/<nn>_<category>.png and film_study_plays.csv (links, clock, probabilities) under the
# output folder, plus a count of every confident miss by kind (film_study_miss_counts.csv).
## ═════════════════════════════════════════════════════════════════════════════

source(file.path(dirname(sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))), "R", "common.R"))
root <- kt_root()
paths <- kt_paths(root)
source(file.path(root, "kickout_transformer", "01_scripts", "R", "draw_play.R"))
arg <- function(name, default) {
  hit <- grep(paste0("^--", name, "="), commandArgs(TRUE), value = TRUE)
  if (length(hit)) sub(paste0("^--", name, "="), "", hit[1]) else default
}
MODEL <- arg("model", "freeze")
# A confident miss puts at least CONFIDENT on an outcome that did not happen; N_PER plays are drawn per category.
CONFIDENT <- 0.6
N_PER <- c(both_pass_was_drive = 2, both_pass_was_shot = 2, both_shot_was_other = 1, transformer_only = 1,
           logistic_only = 1, kickout = 1)

# Held-out transformer and logistic predictions, and the transformer's attention stacked over its folds.
d <- kt_load_catches(paths)
m <- d$meta
tf <- lapply(list.files(paths$cache, sprintf("^tf_%s_[0-9]+\\.rds$", MODEL), full.names = TRUE), readRDS)
tf_pred <- rbindlist(lapply(tf, `[[`, "pred"))
att_rows <- unlist(lapply(tf, function(o) o$pred$row))
att <- do.call(abind_first <- function(...) {
  parts <- list(...)
  n <- vapply(parts, function(a) dim(a)[1], 0L)
  out <- array(NA_real_, c(sum(n), dim(parts[[1]])[-1]))
  at <- 0L
  for (a in parts) {
    out[at + seq_len(dim(a)[1]), , , ] <- a
    at <- at + dim(a)[1]
  }
  out
}, lapply(tf, `[[`, "attention"))                                       # [catch, layer, head, token]
# Receiver's last-layer attention for one catch, heads averaged.
last_layer_w <- function(r) colMeans(matrix(att[match(r, att_rows), dim(att)[2], , ], nrow = dim(att)[3]))
lg_pred <- readRDS(file.path(paths$cache, "pred_baselines.rds"))[model == "logistic"]

# Each model's top class and its probability; then classify every catch by which model missed confidently.
top_of <- function(p) {
  P <- as.matrix(p[, ..PROB_COLS])
  data.table(row = p$row, top = CLASSES[max.col(P, ties.method = "first")], ptop = apply(P, 1, max))
}
x <- merge(top_of(tf_pred), top_of(lg_pred), by = "row", suffixes = c("_tf", "_lg"))
x[m, on = "row", `:=`(label = i.label, kickout = i.kickout, game_id = i.game_id)]
x[, `:=`(conf_wrong_tf = top_tf != label & ptop_tf >= CONFIDENT, conf_wrong_lg = top_lg != label & ptop_lg >= CONFIDENT)]
x[, kind := fcase(conf_wrong_tf & conf_wrong_lg, sprintf("both expected %s, was %s", top_tf, label),
                  conf_wrong_tf & top_lg == label, "transformer only",
                  conf_wrong_lg & top_tf == label, "logistic only",
                  conf_wrong_tf | conf_wrong_lg, "one confident, other also wrong (under 60%)",
                  default = NA_character_)]
counts <- x[!is.na(kind), .N, by = kind][order(-N)]
fwrite(counts, file.path(paths$out, "film_study_miss_counts.csv"))
cat(sprintf("Confident misses (>= %.0f%% on an outcome that did not happen), out of %d catches:\n", 100 * CONFIDENT, nrow(x)))
print(counts)





## ═════════════════════════════════════════════════════════════════════════════
## 01 - PICK THE PLAYS ---------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# A "perimeter catch" more than 40 ft from the hoop means the positions (or the court direction) are broken for that
# play. Those are data problems, not model mistakes: list them separately and keep them out of the film-study set.
x[m, on = "row", recv_hoop_dist := i.recv_hoop_dist]
issues <- x[recv_hoop_dist > 40 & (conf_wrong_tf | conf_wrong_lg)]
issues[m, on = "row", `:=`(dashboard = paste0("#/play/", i.poss_id), pass_id = i.pass_id, catch_frame = i.catch)]
fwrite(issues[, .(dashboard, pass_id, catch_frame, recv_hoop_dist, label, top_tf, ptop_tf, top_lg, ptop_lg)],
       file.path(paths$out, "film_study_data_issues.csv"))
if (nrow(issues)) cat("\nLeft out as data problems (receiver drawn > 40 ft from the hoop):",
                      paste0("#/play/", m[row %in% issues$row, poss_id]), "\n")
x <- x[recv_hoop_dist <= 40]

# Candidate pools per category, most confident first.
both <- x[conf_wrong_tf & conf_wrong_lg][, conf := pmin(ptop_tf, ptop_lg)]
pools <- list(both_pass_was_drive = both[top_tf == "pass" & top_lg == "pass" & label == "drive"][order(-conf)],
              both_pass_was_shot = both[top_tf == "pass" & top_lg == "pass" & label == "shot"][order(-conf)],
              both_shot_was_other = both[top_tf == "shot" & top_lg == "shot"][order(-conf)],
              transformer_only = x[conf_wrong_tf & top_lg == label][order(-ptop_tf)],
              logistic_only = x[conf_wrong_lg & top_tf == label][order(-ptop_lg)],
              kickout = x[kickout == TRUE & (conf_wrong_tf | conf_wrong_lg)][order(-pmax(ptop_tf * conf_wrong_tf, ptop_lg * conf_wrong_lg))])
# Draw plays category by category, preferring games not used yet and never repeating a catch.
picked <- list()
used_games <- integer()
used_rows <- integer()
for (cat_name in names(N_PER)) {
  pool <- pools[[cat_name]][!row %in% used_rows]
  for (k in seq_len(N_PER[[cat_name]])) {
    if (!nrow(pool)) break
    fresh <- pool[!game_id %in% used_games]
    pick <- if (nrow(fresh)) fresh[1] else pool[1]
    picked[[length(picked) + 1]] <- pick[, category := cat_name]
    used_games <- c(used_games, pick$game_id)
    used_rows <- c(used_rows, pick$row)
    pool <- pool[row != pick$row]
  }
}
picked <- rbindlist(picked, fill = TRUE)





## ═════════════════════════════════════════════════════════════════════════════
## 02 - DRAW -------------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

roster <- load_rosters(root, unique(picked$game_id))
# Card headline: what happened and what each model expected.
pct <- function(p) sprintf("%.0f%%", 100 * p)
headline_of <- function(s) {
  actual <- sprintf("Actually a %s.", toupper(s$label))
  if (s$conf_wrong_tf && s$conf_wrong_lg && s$top_tf == s$top_lg)
    sprintf("%s Both models expected a %s (transformer %s, logistic %s).", actual, s$top_tf, pct(s$ptop_tf), pct(s$ptop_lg))
  else if (s$conf_wrong_tf && s$conf_wrong_lg)
    sprintf("%s Transformer expected a %s (%s), logistic a %s (%s).", actual, s$top_tf, pct(s$ptop_tf), s$top_lg, pct(s$ptop_lg))
  else if (s$conf_wrong_tf)
    sprintf("%s The transformer expected a %s (%s); the logistic model's top pick was right.", actual, s$top_tf, pct(s$ptop_tf))
  else
    sprintf("%s The logistic model expected a %s (%s); the transformer's top pick was right.", actual, s$top_lg, pct(s$ptop_lg))
}
tf_label <- if (MODEL == "hist") "Transformer (+ last 1 s)" else "Transformer (freeze frame)"

fig_dir <- file.path(paths$out, "figures", "film_study")
dir.create(fig_dir, recursive = TRUE, showWarnings = FALSE)
unlink(list.files(fig_dir, "\\.png$", full.names = TRUE))
# One card per picked play, plus a table row with its dashboard link and both models' probabilities.
rows_out <- list()
for (i in seq_len(nrow(picked))) {
  s <- picked[i]
  r <- s$row
  meta <- m[row == r]
  probs <- setNames(list(setNames(unlist(tf_pred[row == r, ..PROB_COLS]), CLASSES),
                         setNames(unlist(lg_pred[row == r, ..PROB_COLS]), CLASSES)),
                    c(tf_label, "Logistic (10 hand features)"))
  card <- play_card(root, meta, d$freeze[r, , ], d$token_pid[r, ], roster, last_layer_w(r), probs, headline_of(s)) +
    plot_annotation(caption = CARD_CAPTION,
                    theme = theme(plot.caption = element_text(hjust = 0, size = 8.5, colour = "grey35")))
  f <- sprintf("%02d_%s.png", i, s$category)
  ggsave(file.path(fig_dir, f), card, width = 11, height = 7.2, dpi = 150, bg = "white")
  rows_out[[i]] <- data.table(file = f, category = s$category, dashboard = paste0("#/play/", meta$poss_id),
                              pass_id = meta$pass_id, game_id = meta$game_id, period = meta$period,
                              clock = catch_clock(root, meta$game_id, meta$pass_id), catch_frame = meta$catch,
                              actual = meta$label, kickout = meta$kickout,
                              transformer = paste(sprintf("%s %s", CLASSES, pct(probs[[1]])), collapse = ", "),
                              logistic = paste(sprintf("%s %s", CLASSES, pct(probs[[2]])), collapse = ", "))
}
plays <- rbindlist(rows_out)
fwrite(plays, file.path(paths$out, "film_study_plays.csv"))
cat("\nFilm-study plays (figures in", fig_dir, "):\n")
print(plays[, .(file, dashboard, period, clock, actual, transformer, logistic)])
