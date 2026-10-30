# Unit checks for R/hmm_em.R: (1) the forward pass reproduces depmixS4's log-likelihood for the fit-1 parameters;
# (2) EM recovers a simulated two-state model with a fixed self-transition and keeps it fixed; (3) Viterbi decodes it.
#   Rscript src/rebounding/tests/unit/test_hmm_em.R
suppressMessages({ library(data.table); library(depmixS4) })
here <- "src/rebounding"
source(file.path(here, "R", "hmm_em.R"))
source(file.path(here, "R", "hmm_features.R"))
ok <- function(cond, msg) { cat(if (cond) "PASS" else "FAIL", msg, "\n"); if (!cond) quit(status = 1) }

# (1) against depmixS4, fit 1 (7 states, trained on episodes outside the v2 held-aside subset)
f1 <- readRDS("outputs/rebounding/step02_v2/fit1/hmm_fit.rds")
feats <- readRDS("outputs/cache/rebounding/hmm_features.rds"); setorder(feats, shot_id, frame)
ho <- fread("outputs/rebounding/step02_v2/review/sample.csv")$shot_id
tr <- feats[!shot_id %in% ho]
X <- as.matrix(tr[, ..HMM_FEATURES]); X[!complete.cases(X), ] <- NA
K <- length(f1$states); P <- length(HMM_FEATURES)
p <- getpars(f1$fit)
init <- p[1:K]; A <- matrix(p[K + 1:(K * K)], K, K, byrow = TRUE)
rp <- matrix(p[(K + K * K + 1):length(p)], K, byrow = TRUE)
mu <- rp[, seq(1, 2 * P, 2)]; sd <- rp[, seq(2, 2 * P, 2)]
ll <- hmm_fb(hmm_log_emis(X, mu, sd), A, init, hmm_index(tr$shot_id))$loglik
cat(sprintf("own %.2f, depmixS4 %.2f\n", ll, as.numeric(logLik(f1$fit))))
ok(abs(ll - as.numeric(logLik(f1$fit))) < 0.5, "log-likelihood matches depmixS4 within 0.5")

# (2) simulated: state 2 is a short 'impact' with stay fixed at 0.3
set.seed(1)
At <- matrix(c(0.95, 0.05, 0.7, 0.3), 2, byrow = TRUE)
sim <- rbindlist(lapply(1:300, function(e) {
  s <- integer(60); s[1] <- 1L
  for (t in 2:60) s[t] <- sample(2, 1, prob = At[s[t - 1], ])
  data.table(ep = e, s = s, x = rnorm(60, c(0, 4)[s], c(1, 0.5)[s]))
}))
sim[sample(.N, 0.3 * .N), x := NA]
fit <- hmm_em(matrix(sim$x), sim$ep, matrix(0.5, 2, 2), matrix(c(-1, 2)), matrix(c(2, 2)), c(1, 0), c(NA, 0.3))
ok(abs(fit$A[2, 2] - 0.3) < 1e-12, "fixed stay kept at 0.3")
ok(abs(fit$A[1, 2] - 0.05) < 0.015, sprintf("free transition recovered (%.3f vs 0.05)", fit$A[1, 2]))
ok(all(abs(fit$mu - c(0, 4)) < 0.15), "means recovered")
ok(all(diff(fit$trace) > -1e-6), "log-likelihood never decreases")
path <- hmm_viterbi(hmm_log_emis(matrix(sim$x), fit$mu, fit$sd), fit$A, fit$init, hmm_index(sim$ep))
ok(mean(path[!is.na(sim$x)] == sim$s[!is.na(sim$x)]) > 0.97, "Viterbi recovers observed-frame states")
