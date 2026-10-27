// Physical opportunity and the competing-risks collection model (framework sections 7 and 10).
//
// Access: for each simulated ball path (particle p) and each step k after the forecast checkpoint, the
// chance that player i can be at the ball's horizontal position while it is low enough to control.
// Players follow one of three information policies until the path's contact becomes visible:
//   0 oracle: from the reaction time on, run straight at the sampled ball (an access bound, not behaviour);
//   1 drift: keep moving as now, then run to the ball once the contact has been seen;
//   2 forecast: run toward the forecast centre (same for every particle), then to the ball.
//
// Competing risks: at each step every live particle ends with player i collecting, a team award to either
// side, or continues. Scores are linear: players b0 + b_def*def + b_obs*obstructed + u_player +
// b_acc*log(access); team awards gO, gD; continuing 0. A ball that lands out of bounds ends the particle
// with a team award (offense with probability plogis(g_side)). Outcome probabilities are averaged over
// particles; the likelihood is the probability of the recorded outcome (not its timing). Players with no access
// at a step are left out of that step, and outcomes get a small uniform floor (A_MIN, TREMBLE below).

#include <Rcpp.h>
#include <cmath>
#include <vector>
#include <algorithm>
#ifdef _OPENMP
#include <omp.h>
#endif
// [[Rcpp::plugins(openmp)]]
using namespace Rcpp;

static inline double plogis_(double x) { return 1.0 / (1.0 + std::exp(-x)); }

//' Access array for one forecast: P x K x 10, stored with players fastest, then steps, then particles.
//' @param bx,by,bz P x K ball positions (player frame) at times dt * (1..K) after the checkpoint.
//' @param pl 10 x 4 players (x, y, vx, vy) at the checkpoint.
//' @param t_info Per particle: seconds after the checkpoint when its contact is visible (0 if already).
//' @param target Forecast centre (x, y) for policy 2.
//' @param par c(react, vmax, sigma, z_reach, z_scale, info_lag).
// [[Rcpp::export]]
NumericVector access_array(NumericMatrix bx, NumericMatrix by, NumericMatrix bz, NumericMatrix pl,
                           NumericVector t_info, NumericVector target, NumericVector par, double dt, int policy) {
  int P = bx.nrow(), K = bx.ncol(), n = pl.nrow();
  double react = par[0], vmax = par[1], sigma = par[2], zr = par[3], zs = par[4], lag = par[5];
  double scale = M_PI / std::sqrt(3.0) / sigma;
  NumericVector A(P * K * n);
  for (int p = 0; p < P; p++) {
    double tsw = std::max(react, t_info[p] + lag);
    for (int i = 0; i < n; i++) {
      double rx = pl(i, 0) + pl(i, 2) * react, ry = pl(i, 1) + pl(i, 3) * react;
      double sx = rx, sy = ry;   // where the player is at the switch time under policies 1 and 2
      if (policy == 1) {
        sx = pl(i, 0) + pl(i, 2) * tsw; sy = pl(i, 1) + pl(i, 3) * tsw;
      } else if (policy == 2) {
        double dx = target[0] - rx, dy = target[1] - ry, d = std::sqrt(dx * dx + dy * dy), go = vmax * (tsw - react);
        if (go >= d) { sx = target[0]; sy = target[1]; } else if (d > 1e-9) { sx = rx + dx / d * go; sy = ry + dy / d * go; }
      }
      for (int k = 0; k < K; k++) {
        double t = dt * (k + 1), qx = bx(p, k), qy = by(p, k);
        double T = react + std::sqrt((qx - rx) * (qx - rx) + (qy - ry) * (qy - ry)) / vmax;
        if (policy != 0) T = std::max(T, tsw + std::sqrt((qx - sx) * (qx - sx) + (qy - sy) * (qy - sy)) / vmax);
        double arrived = plogis_((t - T) * scale);
        double low = plogis_((zr - bz(p, k)) / zs);
        A[(p * K + k) * n + i] = arrived * low;
      }
    }
  }
  return A;
}

struct Model {
  int E, P, K, n, M;
  const double* A;        // E x P x K x n access
  const int* out_step;    // E x P: first step at which the ball is dead out of bounds, or -1
  const double* Z;        // E x n x 2: defense flag, obstruction received
  const int* pidx;        // E x n: index into u, or -1
  const int* y;           // E: outcome, 0..n-1 players, n = offense team award, n+1 = defense team award
};

// theta: b0, b_def, b_obs, b_acc, gO, gD, g_side
static const int NT = 7;
// A player with less access than A_MIN at a step cannot collect then (unreachable stays impossible), and every
// outcome probability is mixed with a uniform floor TREMBLE / 12 so a recorded outcome the physics calls
// impossible keeps a finite likelihood.
static const double A_MIN = 1e-4, TREMBLE = 1e-3;
static inline double tremble(double p) { return (1 - TREMBLE) * p + TREMBLE / 12; }

// Probabilities of every outcome for one episode (n players, team O, team D, unresolved), and if wanted the
// gradient of log P(outcome y) with respect to theta and the episode's player effects.
static void episode(const Model& m, int e, const double* th, const double* u, double* prob, bool want_grad,
                    double* g_th, double* g_u) {
  int n = m.n, O = n + 3;   // outcomes: players, team O, team D, continue (index n+2)
  std::vector<double> base(n);
  for (int i = 0; i < n; i++) {
    int pi = m.pidx[e * n + i];
    base[i] = th[0] + th[1] * m.Z[(e * n + i) * 2] + th[2] * m.Z[(e * n + i) * 2 + 1] + (pi >= 0 ? u[pi] : 0.0);
  }
  for (int o = 0; o < n + 3; o++) prob[o] = 0;
  int yy = want_grad ? m.y[e] : -1;
  int NG = NT + n;
  std::vector<double> G(NG), dS(NG), num(NG, 0.0), s(O), h(O);
  double tot_y = 0;
  for (int p = 0; p < m.P; p++) {
    double S = 1.0;
    std::fill(G.begin(), G.end(), 0.0);
    int ko = m.out_step[e * m.P + p];
    for (int k = 0; k < m.K; k++) {
      if (S < 1e-12) break;
      if (ko >= 0 && k >= ko) {
        double po = plogis_(th[6]);
        prob[n] += S * po / m.P; prob[n + 1] += S * (1 - po) / m.P;
        if (want_grad && (yy == n || yy == n + 1)) {
          double w = S * (yy == n ? po : 1 - po);
          tot_y += w;
          for (int j = 0; j < NG; j++) num[j] += w * G[j];
          num[6] += w * (yy == n ? 1 - po : -po);
        }
        S = 0;
        break;
      }
      const double* a = m.A + ((size_t)(e * m.P + p) * m.K + k) * n;
      double mx = 0;
      for (int i = 0; i < n; i++) { s[i] = base[i] + th[3] * std::log(a[i] + 1e-6); mx = std::max(mx, s[i]); }
      s[n] = th[4]; s[n + 1] = th[5]; s[n + 2] = 0;
      mx = std::max(mx, std::max(s[n], s[n + 1]));
      double z = 0;
      for (int o = 0; o < O; o++) { h[o] = (o < n && a[o] < A_MIN) ? 0.0 : std::exp(s[o] - mx); z += h[o]; }
      for (int o = 0; o < O; o++) h[o] /= z;
      for (int o = 0; o < n + 2; o++) prob[o] += S * h[o] / m.P;
      if (want_grad) {
        // expected score gradient sum_o h_o ds_o/dtheta
        std::fill(dS.begin(), dS.end(), 0.0);
        for (int i = 0; i < n; i++) {
          dS[0] += h[i]; dS[1] += h[i] * m.Z[(e * n + i) * 2]; dS[2] += h[i] * m.Z[(e * n + i) * 2 + 1];
          dS[3] += h[i] * std::log(a[i] + 1e-6); dS[NT + i] += h[i];
        }
        dS[4] += h[n]; dS[5] += h[n + 1];
        if (yy >= 0 && yy < n + 2) {
          double w = S * h[yy];
          tot_y += w;
          // d log h_y = ds_y - dS
          for (int j = 0; j < NG; j++) num[j] += w * (G[j] - dS[j]);
          if (yy < n) {
            num[0] += w; num[1] += w * m.Z[(e * n + yy) * 2]; num[2] += w * m.Z[(e * n + yy) * 2 + 1];
            num[3] += w * std::log(a[yy] + 1e-6); num[NT + yy] += w;
          } else num[yy == n ? 4 : 5] += w;
        }
        // continuing: d log h_c = 0 - dS
        for (int j = 0; j < NG; j++) G[j] -= dS[j];
      }
      S *= h[n + 2];
    }
    prob[n + 2] += S / m.P;
  }
  if (want_grad) {
    double py = tot_y / m.P;
    for (int j = 0; j < NT; j++) g_th[j] = (py > 0 ? num[j] / tot_y : 0.0);
    for (int i = 0; i < n; i++) g_u[i] = (py > 0 ? num[NT + i] / tot_y : 0.0);
  }
}

static Model make_model(NumericVector A, IntegerVector out_step, NumericVector Z, IntegerVector pidx, IntegerVector y,
                        IntegerVector dims) {
  Model m;
  m.E = dims[0]; m.P = dims[1]; m.K = dims[2]; m.n = dims[3]; m.M = dims[4];
  m.A = A.begin(); m.out_step = out_step.begin(); m.Z = Z.begin(); m.pidx = pidx.begin(); m.y = y.begin();
  return m;
}

//' Negative penalised log likelihood and its gradient over the episodes in `use`.
//' @param par c(theta (7), u (M)); free Logical of the same length (fixed entries get zero gradient).
//' @param sd_u Prior sd of the player effects (0: effects held at zero); ridge Small penalty on theta.
// [[Rcpp::export]]
List cr_objective(NumericVector par, NumericVector A, IntegerVector out_step, NumericVector Z, IntegerVector pidx,
                  IntegerVector y, IntegerVector dims, IntegerVector use, LogicalVector free, double sd_u, double ridge) {
  Model m = make_model(A, out_step, Z, pidx, y, dims);
  int n = m.n, U = use.size(), NG = NT + m.M;
  const int* up = use.begin();
  const double* pp = par.begin();
  NumericVector grad(NG);
  std::vector<double> gsum(NG, 0.0);
  double ll = 0;
  #pragma omp parallel
  {
    std::vector<double> prob(n + 3), gth(NT), gu(n), gloc(NG, 0.0);
    double lloc = 0;
    #pragma omp for schedule(dynamic, 4)
    for (int k = 0; k < U; k++) {
      int e = up[k];
      episode(m, e, pp, pp + NT, prob.data(), true, gth.data(), gu.data());
      // gradient of log tremble(p) = (1 - TREMBLE) p / tremble(p) times the gradient of log p
      double py = prob[m.y[e]], r = (1 - TREMBLE) * py / tremble(py);
      lloc += std::log(tremble(py));
      for (int j = 0; j < NT; j++) gloc[j] += r * gth[j];
      for (int i = 0; i < n; i++) { int pi = m.pidx[e * n + i]; if (pi >= 0) gloc[NT + pi] += r * gu[i]; }
    }
    #pragma omp critical
    {
      ll += lloc;
      for (int j = 0; j < NG; j++) gsum[j] += gloc[j];
    }
  }
  for (int j = 0; j < NG; j++) grad[j] = gsum[j];
  double pen = 0;
  for (int j = 0; j < NT; j++) { pen += 0.5 * ridge * par[j] * par[j]; grad[j] -= ridge * par[j]; }
  for (int j = 0; j < m.M; j++) {
    if (sd_u > 0) { pen += 0.5 * par[NT + j] * par[NT + j] / (sd_u * sd_u); grad[NT + j] -= par[NT + j] / (sd_u * sd_u); }
  }
  for (int j = 0; j < NT + m.M; j++) if (!free[j]) grad[j] = 0;
  return List::create(_["value"] = -(ll - pen), _["gradient"] = -grad, _["loglik"] = ll);
}

//' Outcome probabilities (n players, team O, team D, unresolved) for every episode.
// [[Rcpp::export]]
NumericMatrix cr_predict(NumericVector par, NumericVector A, IntegerVector out_step, NumericVector Z, IntegerVector pidx,
                         IntegerVector y, IntegerVector dims) {
  Model m = make_model(A, out_step, Z, pidx, y, dims);
  std::vector<double> res((size_t)m.E * (m.n + 3));
  const double* pp = par.begin();
  #pragma omp parallel
  {
    std::vector<double> prob(m.n + 3);
    #pragma omp for schedule(dynamic, 4)
    for (int e = 0; e < m.E; e++) {
      episode(m, e, pp, pp + NT, prob.data(), false, nullptr, nullptr);
      for (int o = 0; o < m.n + 2; o++) res[(size_t)e * (m.n + 3) + o] = tremble(prob[o]);
      res[(size_t)e * (m.n + 3) + m.n + 2] = (1 - TREMBLE) * prob[m.n + 2];
    }
  }
  NumericMatrix out(m.E, m.n + 3);
  for (int e = 0; e < m.E; e++) for (int o = 0; o < m.n + 3; o++) out(e, o) = res[(size_t)e * (m.n + 3) + o];
  return out;
}

//' Obstruction of each player's routes to the target points by each opponent (see obstruction_matrix() in
//' R/opportunity.R, which this mirrors): O(b, o) is how much b stands in o's way, 0 to 1.
// [[Rcpp::export]]
NumericMatrix obstruction_cpp(NumericVector px, NumericVector py, LogicalVector off, NumericVector tx, NumericVector ty,
                              double corridor, double close) {
  int n = px.size(), T = tx.size();
  NumericMatrix O(n, n);
  for (int o = 0; o < n; o++) for (int b = 0; b < n; b++) {
    if (off[o] == off[b]) continue;
    double gx = px[b] - px[o], gy = py[b] - py[o], gap = std::sqrt(gx * gx + gy * gy);
    if (gap > 8) continue;
    double s = 0;
    for (int t = 0; t < T; t++) {
      double ux = tx[t] - px[o], uy = ty[t] - py[o], L = std::sqrt(ux * ux + uy * uy);
      if (L <= 1) continue;
      ux /= L; uy /= L;
      double lam = gx * ux + gy * uy, perp = std::fabs(-gx * uy + gy * ux);
      if (lam > 0 && lam < L) s += std::exp(-perp * perp / (2 * corridor * corridor));
    }
    O(b, o) = s / T * std::exp(-std::max(0.0, gap - close) / 1.5);
  }
  return O;
}
