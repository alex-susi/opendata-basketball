// Ball flight, contact and floor physics for the rebounding models, plus a particle filter over the
// delivered ball track. Called from R through Rcpp (src/rebounding/R/flight.R).
//
// Frame: feet, hoop-relative. The calibrated ball-frame hoop centre is (0, 0, rim_z); the offense attacks
// +x, so the backboard face is at x = board_dx > 0 and the endline at x = end_x. A state is
// (x, y, z, vx, vy, vz). Gravity acts on vz. Contacts: the ring as a torus of radius rim_r and tube
// rim_tube, the backboard as a finite plane, the floor at z = z_floor (the effective floor height of the
// reconstructed ball centre). Rim and board contacts are stochastic: restitution is drawn per contact and
// the contact normal is jittered, which represents unknown spin, rim flex and exact impact point.

#include <Rcpp.h>
#include <random>
#include <cmath>
#include <array>
#include <vector>
#include <algorithm>
using namespace Rcpp;

struct Par {
  double g, ball_r, rim_r, rim_tube, rim_z, board_dx, board_hw, board_z0, board_z1;
  double z_floor, e_floor, mu_floor;
  double e_rim_lo, e_rim_hi, rim_jitter, rim_fric;
  double e_board, board_fric;
  double sigma_a, end_x, side_y, h;
  int contacts;   // 0: free flight and floor only (contacts switched off); 1: rim and board too
};

static double num(const List& L, const char* k) { return as<double>(L[k]); }

static Par read_par(const List& L) {
  Par p;
  p.g = num(L, "g"); p.ball_r = num(L, "ball_r"); p.rim_r = num(L, "rim_r"); p.rim_tube = num(L, "rim_tube");
  p.rim_z = num(L, "rim_z"); p.board_dx = num(L, "board_dx"); p.board_hw = num(L, "board_hw");
  p.board_z0 = num(L, "board_z0"); p.board_z1 = num(L, "board_z1");
  p.z_floor = num(L, "z_floor"); p.e_floor = num(L, "e_floor"); p.mu_floor = num(L, "mu_floor");
  p.e_rim_lo = num(L, "e_rim_lo"); p.e_rim_hi = num(L, "e_rim_hi"); p.rim_jitter = num(L, "rim_jitter");
  p.rim_fric = num(L, "rim_fric"); p.e_board = num(L, "e_board"); p.board_fric = num(L, "board_fric");
  p.sigma_a = num(L, "sigma_a"); p.end_x = num(L, "end_x"); p.side_y = num(L, "side_y"); p.h = num(L, "h");
  p.contacts = as<int>(L["contacts"]);
  return p;
}

struct Flags {
  int n_contact = 0;
  bool made = false, floored = false, out = false;
  double t_floor = NA_REAL, x_floor = NA_REAL, y_floor = NA_REAL, t_out = NA_REAL, t_contact = NA_REAL;
};

// Advance one particle by dt seconds (several substeps of at most p.h), recording events.
static void advance(double* s, double t0, double dt, const Par& p, std::mt19937& rng, Flags& f) {
  std::normal_distribution<double> N01(0.0, 1.0);
  std::uniform_real_distribution<double> U01(0.0, 1.0);
  int n = std::max(1, (int)std::ceil(dt / p.h - 1e-9));
  double h = dt / n;
  double sq = p.sigma_a * std::sqrt(h);
  for (int k = 0; k < n; k++) {
    double t = t0 + (k + 1) * h;
    if (sq > 0) { s[3] += sq * N01(rng); s[4] += sq * N01(rng); s[5] += sq * N01(rng); }
    double zprev = s[2];
    s[5] -= p.g * h;
    s[0] += s[3] * h; s[1] += s[4] * h; s[2] += s[5] * h;
    double r = std::sqrt(s[0] * s[0] + s[1] * s[1]);
    // through the hoop from above: a make
    if (zprev >= p.rim_z && s[2] < p.rim_z && r < p.rim_r - 0.5 * p.ball_r) f.made = true;
    if (p.contacts) {
      // ring: nearest point on the torus centre line
      double cx = r > 1e-9 ? p.rim_r * s[0] / r : p.rim_r, cy = r > 1e-9 ? p.rim_r * s[1] / r : 0.0;
      double dx = s[0] - cx, dy = s[1] - cy, dz = s[2] - p.rim_z;
      double d = std::sqrt(dx * dx + dy * dy + dz * dz), lim = p.ball_r + p.rim_tube;
      if (d < lim && d > 1e-9) {
        double nx = dx / d, ny = dy / d, nz = dz / d;
        double vn = s[3] * nx + s[4] * ny + s[5] * nz;
        if (vn < 0) {
          if (p.rim_jitter > 0) {
            nx += p.rim_jitter * N01(rng); ny += p.rim_jitter * N01(rng); nz += p.rim_jitter * N01(rng);
            double m = std::sqrt(nx * nx + ny * ny + nz * nz); nx /= m; ny /= m; nz /= m;
            vn = s[3] * nx + s[4] * ny + s[5] * nz;
            if (vn > 0) vn = -vn;
          }
          double e = p.e_rim_lo + (p.e_rim_hi - p.e_rim_lo) * U01(rng);
          double tx = s[3] - vn * nx, ty = s[4] - vn * ny, tz = s[5] - vn * nz;
          s[3] = p.rim_fric * tx - e * vn * nx; s[4] = p.rim_fric * ty - e * vn * ny; s[5] = p.rim_fric * tz - e * vn * nz;
          s[0] = cx + (dx / d) * lim; s[1] = cy + (dy / d) * lim; s[2] = p.rim_z + (dz / d) * lim;
          if (f.n_contact == 0) f.t_contact = t;
          f.n_contact++;
        }
      }
      // backboard face
      if (s[3] > 0 && s[0] + p.ball_r > p.board_dx && s[0] < p.board_dx + 0.3 && std::fabs(s[1]) < p.board_hw &&
          s[2] > p.board_z0 && s[2] < p.board_z1) {
        s[3] = -p.e_board * s[3]; s[4] *= p.board_fric; s[5] *= p.board_fric;
        s[0] = p.board_dx - p.ball_r;
        if (f.n_contact == 0) f.t_contact = t;
        f.n_contact++;
      }
    }
    // floor
    if (s[2] < p.z_floor && s[5] < 0) {
      if (!f.floored) { f.floored = true; f.t_floor = t; f.x_floor = s[0]; f.y_floor = s[1]; }
      if (!f.out && (s[0] > p.end_x || std::fabs(s[1]) > p.side_y)) { f.out = true; f.t_out = t; }
      s[5] = -p.e_floor * s[5]; s[3] *= p.mu_floor; s[4] *= p.mu_floor;
      s[2] = p.z_floor;
    }
  }
}

//' Simulate particles forward with no player touches.
//' @param S N x 6 states at time 0 (hoop-relative ball frame).
//' @param t_out Output times (seconds, increasing, > 0).
//' @return list(pos = N x T x 3 array as N x (3T) matrix [x1..xT, y1..yT, z1..zT], floor = N x 3 (t, x, y),
//'   made, contacts, t_contact, t_out (first floor contact outside the lines)).
// [[Rcpp::export]]
List sim_paths(NumericMatrix S, NumericVector t_out, List par, int seed) {
  Par p = read_par(par);
  int N = S.nrow(), T = t_out.size();
  NumericMatrix pos(N, 3 * T), fl(N, 3);
  LogicalVector made(N);
  IntegerVector nc(N);
  NumericVector tc(N), to(N);
  std::mt19937 rng(seed);
  for (int i = 0; i < N; i++) {
    double s[6];
    for (int j = 0; j < 6; j++) s[j] = S(i, j);
    Flags f;
    double t = 0;
    for (int k = 0; k < T; k++) {
      advance(s, t, t_out[k] - t, p, rng, f);
      t = t_out[k];
      pos(i, k) = s[0]; pos(i, T + k) = s[1]; pos(i, 2 * T + k) = s[2];
    }
    fl(i, 0) = f.t_floor; fl(i, 1) = f.x_floor; fl(i, 2) = f.y_floor;
    made[i] = f.made; nc[i] = f.n_contact; tc[i] = f.t_contact; to[i] = f.t_out;
  }
  return List::create(_["pos"] = pos, _["floor"] = fl, _["made"] = made, _["contacts"] = nc,
                      _["t_contact"] = tc, _["t_out"] = to);
}

//' Run forward until the first floor contact (or t_max) for each particle: the untouched landing.
// [[Rcpp::export]]
NumericMatrix first_landing(NumericMatrix S, double t_max, List par, int seed) {
  Par p = read_par(par);
  int N = S.nrow();
  NumericMatrix out(N, 4);
  std::mt19937 rng(seed);
  double step = 0.02;
  for (int i = 0; i < N; i++) {
    double s[6];
    for (int j = 0; j < 6; j++) s[j] = S(i, j);
    Flags f;
    double t = 0;
    while (t < t_max && !f.floored) { advance(s, t, step, p, rng, f); t += step; }
    out(i, 0) = f.t_floor; out(i, 1) = f.x_floor; out(i, 2) = f.y_floor; out(i, 3) = f.made ? 1.0 : 0.0;
  }
  return out;
}

static double student_logpdf(double r, double scale, double nu) {
  double z = r / scale;
  return std::lgamma((nu + 1) / 2) - std::lgamma(nu / 2) - 0.5 * std::log(nu * M_PI) - std::log(scale) -
         (nu + 1) / 2 * std::log1p(z * z / nu);
}

//' Particle filter over observed ball positions.
//' @param S N x 6 particles at time 0.
//' @param obs_t Observation times (> 0, increasing). obs M x 3 positions (hoop-relative ball frame).
//' @param sig c(horizontal, vertical) observation scale; nu Student-t degrees of freedom.
//' @param t_end Time to return the particles at (>= last observation used).
//' @return list(S = N x 6 particles at t_end (equal weights after a final resample), loglik = per-observation
//'   log predictive density, ess = effective sample size before each resample, made, contacts).
// [[Rcpp::export]]
List pf_run(NumericMatrix S0, NumericVector obs_t, NumericMatrix obs, NumericVector sig, double nu, double t_end,
            List par, int seed) {
  Par p = read_par(par);
  int N = S0.nrow(), M = obs_t.size();
  std::mt19937 rng(seed);
  std::uniform_real_distribution<double> U01(0.0, 1.0);
  std::normal_distribution<double> N01(0.0, 1.0);
  std::vector<std::array<double, 6>> S(N), S2(N);
  std::vector<Flags> F(N), F2(N);
  for (int i = 0; i < N; i++) for (int j = 0; j < 6; j++) S[i][j] = S0(i, j);
  std::vector<double> lw(N, 0.0), w(N);
  NumericVector ll(M), ess(M);
  double t = 0;
  for (int m = 0; m < M; m++) {
    if (obs_t[m] > t_end + 1e-9) { ll[m] = NA_REAL; ess[m] = NA_REAL; continue; }
    double dt = obs_t[m] - t;
    for (int i = 0; i < N; i++) if (dt > 0) advance(S[i].data(), t, dt, p, rng, F[i]);
    t = obs_t[m];
    double mx = -1e300;
    std::vector<double> inc(N);
    for (int i = 0; i < N; i++) {
      inc[i] = student_logpdf(S[i][0] - obs(m, 0), sig[0], nu) + student_logpdf(S[i][1] - obs(m, 1), sig[0], nu) +
               student_logpdf(S[i][2] - obs(m, 2), sig[1], nu);
      mx = std::max(mx, lw[i] + inc[i]);
    }
    // predictive density of this observation: weighted mean of its likelihood under the current weights
    double sw = 0, swl = 0, mw = -1e300;
    for (int i = 0; i < N; i++) mw = std::max(mw, lw[i]);
    for (int i = 0; i < N; i++) { double a = std::exp(lw[i] - mw); sw += a; swl += a * std::exp(inc[i] + lw[i] - mx); }
    ll[m] = std::log(swl / sw) + mx - mw;
    double tot = 0;
    for (int i = 0; i < N; i++) { lw[i] += inc[i]; w[i] = std::exp(lw[i] - mx); tot += w[i]; }
    double s2 = 0;
    for (int i = 0; i < N; i++) { w[i] /= tot; s2 += w[i] * w[i]; }
    ess[m] = 1.0 / s2;
    if (ess[m] < N / 2.0 || m == M - 1) {
      // systematic resampling, then a small jitter so duplicated particles separate
      double u = U01(rng) / N, c = w[0];
      int j = 0;
      for (int i = 0; i < N; i++) {
        double target = u + (double)i / N;
        while (target > c && j < N - 1) { j++; c += w[j]; }
        S2[i] = S[j]; F2[i] = F[j];
      }
      S.swap(S2); F.swap(F2);
      for (int i = 0; i < N; i++) {
        lw[i] = 0;
        for (int k = 0; k < 3; k++) S[i][k] += 0.05 * N01(rng);
        for (int k = 3; k < 6; k++) S[i][k] += 0.3 * N01(rng);
      }
    } else {
      for (int i = 0; i < N; i++) lw[i] = std::log(std::max(w[i], 1e-300));
    }
  }
  // carry to t_end and return equally weighted particles
  NumericMatrix out(N, 6);
  LogicalVector made(N);
  IntegerVector nc(N);
  double mx = -1e300, tot = 0;
  for (int i = 0; i < N; i++) mx = std::max(mx, lw[i]);
  for (int i = 0; i < N; i++) { w[i] = std::exp(lw[i] - mx); tot += w[i]; }
  double u = U01(rng) / N, c = w[0] / tot;
  int j = 0;
  for (int i = 0; i < N; i++) {
    double target = u + (double)i / N;
    while (target > c && j < N - 1) { j++; c += w[j] / tot; }
    std::array<double, 6> s = S[j];
    Flags f = F[j];
    if (t_end > t) advance(s.data(), t, t_end - t, p, rng, f);
    for (int k = 0; k < 6; k++) out(i, k) = s[k];
    made[i] = f.made; nc[i] = f.n_contact;
  }
  return List::create(_["S"] = out, _["loglik"] = ll, _["ess"] = ess, _["made"] = made, _["contacts"] = nc);
}

//' Kalman filter for ballistic flight with white-noise acceleration, one axis at a time (axes are
//' independent under this model). Returns the filtered state at t_end and the predictive log density of
//' each observation.
//' @param y Observations on one axis; t their times; g acceleration on this axis (-g for z, 0 otherwise).
//' @param m0,P0 Prior mean (position, velocity) and its 2 x 2 covariance at time 0.
// [[Rcpp::export]]
List kf_axis(NumericVector t, NumericVector y, double g, NumericVector m0, NumericMatrix P0, double q, double r,
             double t_end) {
  int M = t.size();
  double m[2] = {m0[0], m0[1]}, P[2][2] = {{P0(0, 0), P0(0, 1)}, {P0(1, 0), P0(1, 1)}};
  NumericVector ll(M);
  double tc = 0;
  auto predict = [&](double dt) {
    m[0] += m[1] * dt + 0.5 * g * dt * dt; m[1] += g * dt;
    double a = P[0][0] + dt * (P[1][0] + P[0][1]) + dt * dt * P[1][1], b = P[0][1] + dt * P[1][1], d = P[1][1];
    a += q * dt * dt * dt / 3; b += q * dt * dt / 2; d += q * dt;
    P[0][0] = a; P[0][1] = b; P[1][0] = b; P[1][1] = d;
  };
  for (int k = 0; k < M; k++) {
    if (t[k] > t_end + 1e-9) { ll[k] = NA_REAL; continue; }
    predict(t[k] - tc); tc = t[k];
    double Sv = P[0][0] + r, res = y[k] - m[0];
    ll[k] = -0.5 * (std::log(2 * M_PI * Sv) + res * res / Sv);
    double K0 = P[0][0] / Sv, K1 = P[1][0] / Sv;
    m[0] += K0 * res; m[1] += K1 * res;
    double a = (1 - K0) * P[0][0], b = (1 - K0) * P[0][1], c = P[1][0] - K1 * P[0][0], d = P[1][1] - K1 * P[0][1];
    P[0][0] = a; P[0][1] = b; P[1][0] = c; P[1][1] = d;
  }
  if (t_end > tc) predict(t_end - tc);
  NumericMatrix Pout(2, 2);
  Pout(0, 0) = P[0][0]; Pout(0, 1) = P[0][1]; Pout(1, 0) = P[1][0]; Pout(1, 1) = P[1][1];
  return List::create(_["m"] = NumericVector::create(m[0], m[1]), _["P"] = Pout, _["loglik"] = ll);
}
