# Step 03 of the rebounding manual: leave-one-game-out folds. The episode is the unit: every frame, candidate and
# label of an episode belongs to its game, and its game is its outer test fold. Inner folds (tuning and baseline
# selection) are leave one game out within the nine training games. The split idea (by game, never by row) follows
# ReboundingPrediction's eval/split.py, read for ideas only (no licence); written independently.

#' One row per episode: its game and outer fold (fold k holds out the k-th game by date).
#' @param episodes data.table with episode_id, game_id.
#' @param games data.table with game_id, date (sortable).
fold_assignment <- function(episodes, games) {
  g <- games[order(date, game_id)]
  g[, outer_fold := seq_len(.N)]
  fa <- merge(episodes[, .(episode_id, game_id)], g[, .(game_id, game_date = date, outer_fold)], by = "game_id",
              sort = FALSE)
  if (anyNA(fa$outer_fold)) stop("episodes from a game without a fold")
  setcolorder(fa, c("episode_id", "game_id", "outer_fold", "game_date"))
  fa[order(outer_fold, episode_id)]
}

#' Training and test episode ids of an outer fold, and its inner folds (one per training game).
fold_split <- function(fa, k) {
  test <- fa[outer_fold == k]
  train <- fa[outer_fold != k]
  inner <- lapply(sort(unique(train$game_id)), function(g)
    list(game_id = g, train = train[game_id != g]$episode_id, test = train[game_id == g]$episode_id))
  list(fold = k, test_game = unique(test$game_id), train = train$episode_id, test = test$episode_id, inner = inner)
}

#' Fold checks: every episode in exactly one outer test fold, no test game (hence none of its frames) in training,
#' inner folds inside the training games only. One row per check.
check_folds <- function(fa) {
  k <- sort(unique(fa$outer_fold))
  tested <- unlist(lapply(k, function(i) fold_split(fa, i)$test))
  leaks <- sum(vapply(k, function(i) {
    s <- fold_split(fa, i)
    tr_games <- unique(fa[episode_id %in% s$train]$game_id)
    inner_bad <- any(vapply(s$inner, function(f) any(s$test_game %in% fa[episode_id %in% c(f$train, f$test)]$game_id), NA))
    as.integer(any(s$test_game %in% tr_games) || length(intersect(s$train, s$test)) > 0 || inner_bad)
  }, 0L))
  data.table(check = c("episodes in exactly one outer test fold", "folds whose test game reaches training or an inner fold",
                       "one game per outer fold", "episode ids unique"),
             value = c(sum(table(tested) == 1L), leaks, sum(fa[, uniqueN(game_id), by = outer_fold]$V1 == 1L),
                       anyDuplicated(fa$episode_id)),
             expected = c(nrow(fa), 0L, length(k), 0L))[, pass := value == expected][]
}
