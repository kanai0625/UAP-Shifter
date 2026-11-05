#!/usr/bin/env python3
"""
Fit KOR-style Pico charge histograms with a Poisson-weighted multi-PE model
and extract mu_e (mean PE), to align with AUS-style relative QE definition.

Usage:
  python fit_mu_e_from_pico.py input.root
  python fit_mu_e_from_pico.py input.root --npe-max 3 --out-csv mu_e_results.csv --plot-dir plots
"""

import argparse
import math
import os
import re
from dataclasses import dataclass
from typing import Dict, List, Optional, Tuple

import numpy as np
import matplotlib.pyplot as plt

try:
    import uproot
except Exception as exc:
    raise SystemExit("Missing package: uproot") from exc

try:
    from scipy.optimize import curve_fit
except Exception as exc:
    raise SystemExit("Missing package: scipy") from exc
from scipy.special import erf



HIST_RE = re.compile(r"^Pico_ch(\d+)(;\d+)?$")


@dataclass
class FitResult:
    channel: int
    mu_e: float
    mu_e_err: float
    chi2_ndf: float
    status: str
    params: Optional[np.ndarray]
    model: str
    hit_boundary: bool
    npe_used: int


def gaus(x: np.ndarray, mu: float, sigma: float) -> np.ndarray:
    sigma = max(sigma, 1e-6)
    inv = 1.0 / (sigma * math.sqrt(2.0 * math.pi))
    z = (x - mu) / sigma
    return inv * np.exp(-0.5 * z * z)


def poisson_prob(n: int, mu: float) -> float:
    if mu < 0:
        return 0.0
    return math.exp(-mu) * (mu ** n) / math.factorial(n)


def model_counts(
    x: np.ndarray,
    bin_width: float,
    npe_max: int,
    mu_e: float,
    mu0: float,
    sig0: float,
    mu1: float,
    sig1: float,
    f_bs: float,
    bs_scale: float,
    norm: float,
) -> np.ndarray:
    # Signal model in expected bin counts (no constant background term).
    total = norm * bin_width * poisson_prob(0, mu_e) * gaus(x, mu0, sig0)

    for n in range(1, npe_max + 1):
        p_n = poisson_prob(n, mu_e)
        mu_n = mu0 + n * mu1
        sig_n = math.sqrt(max(sig0 * sig0 + n * sig1 * sig1, 1e-12))
        total += norm * bin_width * p_n * gaus(x, mu_n, sig_n)

    # KOR-style backscatter shape:
    # A_bs * [erf((x-mu_ped)/sigma_ped) - erf((x-mu_spe)/sigma_spe)]
    # Constrain backscatter to be smaller than 1PE peak by construction:
    # A_bs = f_bs * A_1PE_peak, where 0 <= f_bs < 1.
    mu_spe = mu0 + mu1
    sig_ped = max(sig0, 1e-6)
    sig_bs = max(bs_scale * sig1, 1e-6)
    bs_shape = erf((x - mu0) / sig_ped) - erf((x - mu_spe) / sig_bs)
    p1 = poisson_prob(1, mu_e)
    a_1pe_peak = norm * bin_width * p1 / (max(sig1, 1e-6) * math.sqrt(2.0 * math.pi))
    bs_amp = max(f_bs, 0.0) * a_1pe_peak
    total += bs_amp * bs_shape

    return total


def model_components(
    x: np.ndarray,
    bin_width: float,
    npe_max: int,
    mu_e: float,
    mu0: float,
    sig0: float,
    mu1: float,
    sig1: float,
    f_bs: float,
    bs_scale: float,
    norm: float,
) -> Dict[str, np.ndarray]:
    comps: Dict[str, np.ndarray] = {}
    ped = norm * bin_width * poisson_prob(0, mu_e) * gaus(x, mu0, sig0)
    comps["pedestal"] = ped

    for n in range(1, npe_max + 1):
        p_n = poisson_prob(n, mu_e)
        mu_n = mu0 + n * mu1
        sig_n = math.sqrt(max(sig0 * sig0 + n * sig1 * sig1, 1e-12))
        comps[f"pe{n}"] = norm * bin_width * p_n * gaus(x, mu_n, sig_n)

    # Same backscatter component used in the total model.
    mu_spe = mu0 + mu1
    sig_ped = max(sig0, 1e-6)
    sig_bs = max(bs_scale * sig1, 1e-6)
    bs_shape = erf((x - mu0) / sig_ped) - erf((x - mu_spe) / sig_bs)
    p1 = poisson_prob(1, mu_e)
    a_1pe_peak = norm * bin_width * p1 / (max(sig1, 1e-6) * math.sqrt(2.0 * math.pi))
    bs_amp = max(f_bs, 0.0) * a_1pe_peak
    comps["backscatter"] = bs_amp * bs_shape
    return comps


def initial_guess(x: np.ndarray, y: np.ndarray) -> Tuple[float, ...]:
    # Very simple robust guesses
    positive = y > 0
    if np.sum(positive) == 0:
        return (0.08, 0.0, 0.2, 1.8, 0.4, 0.2, 2.0, max(np.sum(y), 1.0))

    # pedestal near 0 charge
    ped_mask = (x > -1.5) & (x < 0.8) & positive
    if np.any(ped_mask):
        mu0 = float(np.average(x[ped_mask], weights=y[ped_mask]))
        var0 = float(np.average((x[ped_mask] - mu0) ** 2, weights=y[ped_mask]))
        sig0 = max(math.sqrt(max(var0, 1e-6)), 0.08)
    else:
        mu0, sig0 = 0.0, 0.2

    # crude SPE peak estimate
    spe_mask = (x > 1.0) & (x < 5.0)
    if np.any(spe_mask) and np.max(y[spe_mask]) > 0:
        mu1 = float(x[spe_mask][np.argmax(y[spe_mask])])
    else:
        mu1 = 1.5

    sig1 = 0.35
    mu_e = 0.12
    f_bs = 0.2
    bs_scale = 2.0
    norm = max(float(np.sum(y)), 1.0)

    return (mu_e, mu0, sig0, mu1, sig1, f_bs, bs_scale, norm)


def prefit_seeds(
    x: np.ndarray,
    y: np.ndarray,
    p0: np.ndarray,
    mu1_min: float,
    mu1_max: float,
    fbs_min: float,
    fbs_max: float,
) -> np.ndarray:
    """Derive better seeds from pedestal, SPE peak, and valley region."""
    out = p0.copy()
    positive = y > 0
    if not np.any(positive):
        return out

    # Pedestal from left side.
    ped_mask = (x > -1.5) & (x < 0.8) & positive
    if np.any(ped_mask):
        mu0 = float(np.average(x[ped_mask], weights=y[ped_mask]))
        var0 = float(np.average((x[ped_mask] - mu0) ** 2, weights=y[ped_mask]))
        out[1] = mu0
        out[2] = max(math.sqrt(max(var0, 1e-8)), 0.05)

    # SPE from right shoulder/peak.
    spe_mask = (x > mu1_min) & (x < mu1_max)
    if np.any(spe_mask) and np.max(y[spe_mask]) > 0:
        out[3] = float(x[spe_mask][np.argmax(y[spe_mask])])
        # width from local second moment near peak
        local = (x > out[3] - 0.6) & (x < out[3] + 0.6) & positive
        if np.any(local):
            var1 = float(np.average((x[local] - out[3]) ** 2, weights=y[local]))
            out[4] = max(math.sqrt(max(var1, 1e-6)), 0.12)

    # Valley-driven f_bs seed.
    lo = min(out[1], out[3])
    hi = max(out[1], out[3])
    valley_mask = (x > lo + 0.15) & (x < hi - 0.15) & positive
    if np.any(valley_mask):
        y_valley = float(np.min(y[valley_mask]))
        y_spe_peak = float(np.max(y[spe_mask])) if np.any(spe_mask) else 1.0
        ratio = y_valley / max(y_spe_peak, 1.0)
        out[5] = min(max(ratio * 0.8, fbs_min), fbs_max)

    out[3] = min(max(out[3], mu1_min), mu1_max)
    out[5] = min(max(out[5], fbs_min), fbs_max)
    out[6] = min(max(out[6], 1.2), 3.0)
    return out


def compute_chi2_ndf(
    x: np.ndarray,
    y: np.ndarray,
    y_hat: np.ndarray,
    npar: int,
) -> Tuple[float, float]:
    sigma = np.sqrt(np.maximum(y, 1.0))
    chi2 = float(np.sum(((y - y_hat) / sigma) ** 2))
    ndf = max(len(y) - npar, 1)
    return chi2, chi2 / ndf


def hit_bounds(params: np.ndarray, lower: np.ndarray, upper: np.ndarray, frac: float = 0.01) -> bool:
    width = np.maximum(upper - lower, 1e-12)
    d_low = np.abs(params - lower) / width
    d_up = np.abs(upper - params) / width
    return bool(np.any(d_low < frac) or np.any(d_up < frac))


def make_start_points(
    base: np.ndarray,
    lower: np.ndarray,
    upper: np.ndarray,
    n_trials: int,
    rng: np.random.Generator,
) -> List[np.ndarray]:
    starts = [np.clip(base, lower, upper)]
    if n_trials <= 1:
        return starts

    # Physically motivated alternates
    bs0 = min(max(base[5], 0.05), 0.9)
    k0 = min(max(base[6], 1.2), 3.0)
    alternates = [
        np.array([0.02, base[1], base[2], max(base[3], 1.0), base[4], min(0.3 * bs0, 0.9), min(max(1.2, 0.8 * k0), 3.0), base[7]]),
        np.array([0.08, base[1], base[2], max(base[3], 1.0), max(base[4], 0.25), min(1.0 * bs0, 0.9), min(max(2.0, 1.0 * k0), 3.0), base[7]]),
        np.array([0.15, base[1], base[2], max(base[3], 1.0), max(base[4], 0.35), min(1.5 * bs0, 0.9), min(3.0, 1.4 * k0), base[7]]),
    ]
    for a in alternates:
        starts.append(np.clip(a, lower, upper))

    n_rand = max(n_trials - len(starts), 0)
    width = upper - lower
    for _ in range(n_rand):
        # jitter around base + occasional global draw
        if rng.uniform() < 0.7:
            draw = base + rng.normal(0.0, 0.18, size=base.shape) * width
        else:
            draw = lower + rng.uniform(size=base.shape) * width
        starts.append(np.clip(draw, lower, upper))
    return starts


def run_best_fit(
    x_fit: np.ndarray,
    y_fit: np.ndarray,
    bw: float,
    npe_max: int,
    p0: np.ndarray,
    lower: np.ndarray,
    upper: np.ndarray,
    multistart: int,
    rng: np.random.Generator,
) -> Tuple[Optional[np.ndarray], Optional[np.ndarray], float]:
    starts = make_start_points(p0, lower, upper, multistart, rng)
    best = None
    best_cov = None
    best_chi2 = float("inf")

    sigma = np.sqrt(np.maximum(y_fit, 1.0))

    for s in starts:
        try:
            popt, pcov = curve_fit(
                lambda xx, mu_e, mu0, sig0, mu1, sig1, f_bs, bs_scale, norm: model_counts(
                    xx, bw, npe_max, mu_e, mu0, sig0, mu1, sig1, f_bs, bs_scale, norm
                ),
                x_fit,
                y_fit,
                p0=s,
                bounds=(lower, upper),
                sigma=sigma,
                absolute_sigma=True,
                maxfev=80000,
            )
            y_hat = model_counts(x_fit, bw, npe_max, *popt)
            chi2, _ = compute_chi2_ndf(x_fit, y_fit, y_hat, len(popt))
            if chi2 < best_chi2:
                best_chi2 = chi2
                best = popt
                best_cov = pcov
        except Exception:
            continue

    return best, best_cov, best_chi2


def run_staged_fit(
    x_fit: np.ndarray,
    y_fit: np.ndarray,
    bw: float,
    npe_max: int,
    p0: np.ndarray,
    fbs_min: float,
    fbs_max: float,
    mu1_min: float,
    mu1_max: float,
) -> Tuple[Optional[np.ndarray], Optional[np.ndarray]]:
    """
    Staged fit:
      1) Pedestal moments -> mu0,sig0 (already in p0)
      2) SPE peak moments  -> mu1,sig1 (already in p0)
      3) Valley fit only f_bs with others fixed
      4) Global micro-fit for (mu_e, norm, f_bs) only
    """
    mu_e0, mu0, sig0, mu1, sig1, fbs0, bs_scale0, norm0 = [float(v) for v in p0]
    mu1 = min(max(mu1, mu1_min), mu1_max)
    fbs0 = min(max(fbs0, fbs_min), fbs_max)

    # Stage-3: valley fit for f_bs only
    valley_mask = (x_fit > mu0 + 0.15) & (x_fit < mu1 - 0.10)
    if np.any(valley_mask):
        xv = x_fit[valley_mask]
        yv = y_fit[valley_mask]
        sv = np.sqrt(np.maximum(yv, 1.0))
        try:
            p_f, _ = curve_fit(
                lambda xx, f_bs: model_counts(xx, bw, npe_max, mu_e0, mu0, sig0, mu1, sig1, f_bs, bs_scale0, norm0),
                xv,
                yv,
                p0=[fbs0],
                bounds=([fbs_min], [fbs_max]),
                sigma=sv,
                absolute_sigma=True,
                maxfev=20000,
            )
            fbs0 = float(p_f[0])
        except Exception:
            pass

    # Stage-4: global micro-fit with locked shape parameters
    s = np.sqrt(np.maximum(y_fit, 1.0))
    try:
        popt3, pcov3 = curve_fit(
            lambda xx, mu_e, norm, f_bs: model_counts(
                xx, bw, npe_max, mu_e, mu0, sig0, mu1, sig1, f_bs, bs_scale0, norm
            ),
            x_fit,
            y_fit,
            p0=[mu_e0, norm0, fbs0],
            bounds=([0.0, 1.0, fbs_min], [0.8, 1e12, fbs_max]),
            sigma=s,
            absolute_sigma=True,
            maxfev=40000,
        )
        mu_e, norm, f_bs = [float(v) for v in popt3]
        full = np.array([mu_e, mu0, sig0, mu1, sig1, f_bs, bs_scale0, norm], dtype=float)
        # Lift 3x3 covariance into full-parameter covariance
        full_cov = np.zeros((8, 8), dtype=float)
        # parameter map: mu_e->0, norm->7, f_bs->5
        full_cov[0, 0] = pcov3[0, 0]
        full_cov[7, 7] = pcov3[1, 1]
        full_cov[5, 5] = pcov3[2, 2]
        full_cov[0, 7] = full_cov[7, 0] = pcov3[0, 1]
        full_cov[0, 5] = full_cov[5, 0] = pcov3[0, 2]
        full_cov[7, 5] = full_cov[5, 7] = pcov3[1, 2]
        return full, full_cov
    except Exception:
        return None, None


def fit_one_hist(
    channel: int,
    values: np.ndarray,
    edges: np.ndarray,
    npe_max: int,
    fit_xmin: float,
    fit_xmax: float,
    multistart: int,
    rng: np.random.Generator,
    mu1_min: float,
    mu1_max: float,
    fbs_min: float,
    fbs_max: float,
    bs_scale_min: float,
    bs_scale_max: float,
    fix_bs_scale: float,
    force_full: bool,
    use_prefit: bool,
) -> FitResult:
    x = 0.5 * (edges[:-1] + edges[1:])
    bw = float(edges[1] - edges[0])
    y = values.astype(float)

    fit_mask = (x > fit_xmin) & (x < fit_xmax)
    x_fit = x[fit_mask]
    y_fit = y[fit_mask]
    if len(x_fit) < 20 or np.sum(y_fit) <= 0:
        return FitResult(channel, float("nan"), float("nan"), float("nan"), "fit_fail: empty_range", None, "none", False, 0)

    p0 = np.array(initial_guess(x_fit, y_fit), dtype=float)

    # Stage-0 pedestal stabilization from pedestal-dominant region
    ped_mask = (x_fit > -1.5) & (x_fit < 0.8) & (y_fit > 0)
    if np.any(ped_mask):
        mu0 = float(np.average(x_fit[ped_mask], weights=y_fit[ped_mask]))
        var0 = float(np.average((x_fit[ped_mask] - mu0) ** 2, weights=y_fit[ped_mask]))
        p0[1] = mu0
        p0[2] = max(math.sqrt(max(var0, 1e-6)), 0.06)

    # Force SPE peak seed/range away from pedestal shoulder if requested.
    p0[3] = min(max(p0[3], mu1_min), mu1_max)

    if use_prefit:
        p0 = prefit_seeds(x_fit, y_fit, p0, mu1_min, mu1_max, fbs_min, fbs_max)

    # Model-A: full model (multi-PE + backscatter with independent right-tail width scale)
    p0[5] = min(max(p0[5], fbs_min), fbs_max)
    if fix_bs_scale > 0:
        p0[6] = fix_bs_scale
        lower_a = np.array([0.0, -1.0, 0.02, mu1_min, 0.05, 0.0, fix_bs_scale, 1.0], dtype=float)
        upper_a = np.array([0.5, 1.5, 1.0, mu1_max, 2.0, 0.95, fix_bs_scale, 1e12], dtype=float)
    else:
        p0[6] = min(max(p0[6], bs_scale_min), bs_scale_max)
        lower_a = np.array([0.0, -1.0, 0.02, mu1_min, 0.05, 0.0, bs_scale_min, 1.0], dtype=float)
        upper_a = np.array([0.5, 1.5, 1.0, mu1_max, 2.0, 0.95, bs_scale_max, 1e12], dtype=float)
    lower_a[5] = fbs_min
    upper_a[5] = fbs_max

    # Stage-1: prefit with tighter pedestal bounds.
    p_start = p0.copy()
    if use_prefit:
        lower_s1 = lower_a.copy()
        upper_s1 = upper_a.copy()
        lower_s1[1] = max(lower_s1[1], p0[1] - 0.10)
        upper_s1[1] = min(upper_s1[1], p0[1] + 0.10)
        lower_s1[2] = max(lower_s1[2], 0.7 * p0[2])
        upper_s1[2] = min(upper_s1[2], 1.3 * p0[2])
        popt_s1, _, _ = run_best_fit(
            x_fit, y_fit, bw, npe_max, p0, lower_s1, upper_s1, max(6, multistart // 3), rng
        )
        if popt_s1 is not None:
            p_start = popt_s1

    if use_prefit:
        popt_a, pcov_a = run_staged_fit(
            x_fit, y_fit, bw, npe_max, p_start, fbs_min, fbs_max, mu1_min, mu1_max
        )
        if popt_a is None or pcov_a is None:
            popt_a, pcov_a, _ = run_best_fit(
                x_fit, y_fit, bw, npe_max, p_start, lower_a, upper_a, multistart, rng
            )
    else:
        popt_a, pcov_a, _ = run_best_fit(
            x_fit, y_fit, bw, npe_max, p_start, lower_a, upper_a, multistart, rng
        )

    candidates: List[Tuple[str, np.ndarray, np.ndarray, float, bool, int]] = []
    if popt_a is not None and pcov_a is not None:
        y_hat_a = model_counts(x_fit, bw, npe_max, *popt_a)
        _, chi2_ndf_a = compute_chi2_ndf(x_fit, y_fit, y_hat_a, len(popt_a))
        candidates.append(("full", popt_a, pcov_a, chi2_ndf_a, hit_bounds(popt_a, lower_a, upper_a), npe_max))

    if not force_full:
        # Model-B fallback: no backscatter (force f_bs ~ 0)
        lower_b = lower_a.copy()
        upper_b = upper_a.copy()
        lower_b[5] = 0.0
        upper_b[5] = 1e-6
        p0_b = p_start.copy()
        p0_b[5] = 0.0
        if fix_bs_scale > 0:
            p0_b[6] = fix_bs_scale
            lower_b[6] = fix_bs_scale
            upper_b[6] = fix_bs_scale
        else:
            p0_b[6] = min(max(2.0, bs_scale_min), bs_scale_max)
        popt_b, pcov_b, _ = run_best_fit(
            x_fit, y_fit, bw, npe_max, p0_b, lower_b, upper_b, max(multistart // 2, 8), rng
        )
        if popt_b is not None and pcov_b is not None:
            y_hat_b = model_counts(x_fit, bw, npe_max, *popt_b)
            _, chi2_ndf_b = compute_chi2_ndf(x_fit, y_fit, y_hat_b, len(popt_b))
            candidates.append(("no_bs", popt_b, pcov_b, chi2_ndf_b, hit_bounds(popt_b, lower_b, upper_b), npe_max))

        # Model-C fallback: 1PE only + no backscatter
        lower_c = lower_b.copy()
        upper_c = upper_b.copy()
        p0_c = p0_b.copy()
        popt_c, pcov_c, _ = run_best_fit(
            x_fit, y_fit, bw, 1, p0_c, lower_c, upper_c, max(multistart // 2, 8), rng
        )
        if popt_c is not None and pcov_c is not None:
            y_hat_c = model_counts(x_fit, bw, 1, *popt_c)
            _, chi2_ndf_c = compute_chi2_ndf(x_fit, y_fit, y_hat_c, len(popt_c))
            candidates.append(("1pe_no_bs", popt_c, pcov_c, chi2_ndf_c, hit_bounds(popt_c, lower_c, upper_c), 1))

    if not candidates:
        return FitResult(channel, float("nan"), float("nan"), float("nan"), "fit_fail: all_models_failed", None, "none", False, 0)

    # Prefer lower chi2/ndf; penalize boundary solutions lightly
    best_model, best_popt, best_pcov, best_chi2_ndf, best_hit, best_npe = min(
        candidates,
        key=lambda t: (t[3] + (30.0 if t[4] else 0.0)),
    )
    mu_e = float(best_popt[0])
    mu_e_err = float(math.sqrt(max(best_pcov[0, 0], 0.0)))
    status = "ok"
    if best_hit:
        status = "ok_boundary"
    return FitResult(channel, mu_e, mu_e_err, best_chi2_ndf, status, best_popt, best_model, best_hit, best_npe)


def load_pico_hists(path: str) -> Dict[int, Tuple[np.ndarray, np.ndarray]]:
    out: Dict[int, Tuple[np.ndarray, np.ndarray]] = {}
    with uproot.open(path) as f:
        for key in f.keys():
            base = key.split(";")[0]
            m = HIST_RE.match(base)
            if not m:
                continue
            ch = int(m.group(1))
            h = f[base]
            values, edges = h.to_numpy()
            out[ch] = (values, edges)
    return out


def main() -> None:
    ap = argparse.ArgumentParser(description="Fit mu_e from Pico_ch* histograms")
    ap.add_argument("root_file", help="Input ROOT file containing Pico_chX histograms")
    ap.add_argument("--npe-max", type=int, default=3, help="Max PE terms in Poisson sum (default: 3)")
    ap.add_argument("--fit-xmin", type=float, default=-2.0, help="Fit range lower bound in pC")
    ap.add_argument("--fit-xmax", type=float, default=8.0, help="Fit range upper bound in pC")
    ap.add_argument("--multistart", type=int, default=24, help="Number of multi-start trials per model")
    ap.add_argument("--seed", type=int, default=12345, help="Random seed for multi-start")
    ap.add_argument("--mu1-min", type=float, default=1.0, help="Lower bound for 1PE peak position (pC)")
    ap.add_argument("--mu1-max", type=float, default=8.0, help="Upper bound for 1PE peak position (pC)")
    ap.add_argument("--fbs-min", type=float, default=0.0, help="Lower bound for backscatter fraction f_bs")
    ap.add_argument("--fbs-max", type=float, default=0.95, help="Upper bound for backscatter fraction f_bs")
    ap.add_argument("--bs-scale-min", type=float, default=1.2, help="Lower bound for backscatter tail scale")
    ap.add_argument("--bs-scale-max", type=float, default=3.0, help="Upper bound for backscatter tail scale")
    ap.add_argument("--fix-bs-scale", type=float, default=0.0, help="Fix backscatter tail scale (>0 to fix)")
    ap.add_argument("--force-full", action="store_true", help="Force full model with backscatter (disable fallback models)")
    ap.add_argument("--no-prefit", action="store_true", help="Disable staged prefit seeding/tight-bounds pass")
    ap.add_argument("--scan-bs-scale", nargs=3, type=float, metavar=("START", "STOP", "STEP"),
                    help="Scan fixed bs_scale over [START, STOP] with STEP and write summary")
    ap.add_argument("--plot-ymin", type=float, default=1e-2, help="Lower y-limit for log plot")
    ap.add_argument("--linear-y", action="store_true", help="Use linear y-axis instead of log scale")
    ap.add_argument("--plot-ymax", type=float, default=1e6, help="Upper y-limit for plot")
    ap.add_argument("--out-csv", default="mu_e_results.csv", help="Output CSV path")
    ap.add_argument("--plot-out", default="mu_e_fit_ch0_ch1.png", help="Output PNG for ch0/ch1 fit overlay")
    args = ap.parse_args()

    hists = load_pico_hists(args.root_file)
    if not hists:
        raise SystemExit("No Pico_ch* histograms found in ROOT file")

    def run_once(fix_bs_scale: float, out_csv: str, out_plot: str) -> List[FitResult]:
        results_local: List[FitResult] = []
        rng_local = np.random.default_rng(args.seed)
        for ch in sorted(hists):
            vals, edges = hists[ch]
            res = fit_one_hist(
                ch,
                vals,
                edges,
                args.npe_max,
                args.fit_xmin,
                args.fit_xmax,
                args.multistart,
                rng_local,
                args.mu1_min,
                args.mu1_max,
                args.fbs_min,
                args.fbs_max,
                args.bs_scale_min,
                args.bs_scale_max,
                fix_bs_scale,
                args.force_full,
                (not args.no_prefit),
            )
            results_local.append(res)
        return results_local

    results = run_once(args.fix_bs_scale, args.out_csv, args.plot_out)

    valid = [r for r in results if r.status.startswith("ok") and np.isfinite(r.mu_e)]
    if valid:
        # relative-to-center (if ch0 exists), otherwise relative-to-min-channel
        ref = None
        for r in valid:
            if r.channel == 0:
                ref = r.mu_e
                break
        if ref is None:
            ref = valid[0].mu_e
    else:
        ref = float("nan")

    with open(args.out_csv, "w", encoding="utf-8") as fo:
        fo.write("channel,mu_e,mu_e_err,rel_qe_mu_e,chi2_ndf,status,model,npe_used,hit_boundary,f_bs,bs_scale\n")
        for r in results:
            rel = (r.mu_e / ref) if (r.status.startswith("ok") and np.isfinite(ref) and ref > 0) else float("nan")
            f_bs = r.params[5] if (r.params is not None and len(r.params) > 5) else float("nan")
            bs_scale = r.params[6] if (r.params is not None and len(r.params) > 6) else float("nan")
            fo.write(
                f"{r.channel},{r.mu_e},{r.mu_e_err},{rel},{r.chi2_ndf},{r.status},"
                f"{r.model},{r.npe_used},{int(r.hit_boundary)},{f_bs},{bs_scale}\n"
            )

    if args.scan_bs_scale:
        start, stop, step = args.scan_bs_scale
        if step <= 0:
            raise SystemExit("--scan-bs-scale STEP must be > 0")
        scan_path = os.path.splitext(args.out_csv)[0] + "_scan_bs_scale.csv"
        with open(scan_path, "w", encoding="utf-8") as fs:
            fs.write("bs_scale,channel,mu_e,mu_e_err,chi2_ndf,status,f_bs\n")
            v = start
            while v <= stop + 1e-12:
                scan_results = run_once(v, args.out_csv, args.plot_out)
                for r in scan_results:
                    f_bs = r.params[5] if (r.params is not None and len(r.params) > 5) else float("nan")
                    fs.write(f"{v},{r.channel},{r.mu_e},{r.mu_e_err},{r.chi2_ndf},{r.status},{f_bs}\n")
                v += step
        print(f"Saved: {scan_path}")

    # Plot ch0 and ch1 with fit curves in one figure
    plot_channels = [0, 1]
    fig, axes = plt.subplots(1, 2, figsize=(12, 4), constrained_layout=True)
    for i, ch in enumerate(plot_channels):
        ax = axes[i]
        if ch not in hists:
            ax.text(0.5, 0.5, f"ch{ch} missing", ha="center", va="center", transform=ax.transAxes)
            ax.set_title(f"ch{ch}")
            continue
        vals, edges = hists[ch]
        x = 0.5 * (edges[:-1] + edges[1:])
        bw = float(edges[1] - edges[0])
        ax.step(x, vals, where="mid", label="Data", color="black")
        r = next((rr for rr in results if rr.channel == ch), None)
        if r is not None and r.status.startswith("ok") and r.params is not None:
            yhat = model_counts(x, bw, r.npe_used, *r.params)
            ax.plot(x, yhat, color="red", lw=1.8, label=f"Fit {r.model} (mu_e={r.mu_e:.3g})")
            comps = model_components(x, bw, r.npe_used, *r.params)
            if "pedestal" in comps:
                ax.plot(x, comps["pedestal"], color="tab:orange", ls="--", lw=1.2, label="Pedestal")
            if "backscatter" in comps:
                ax.plot(x, comps["backscatter"], color="tab:green", ls=":", lw=1.5, label="Backscatter")
            for n in range(1, r.npe_used + 1):
                key = f"pe{n}"
                if key in comps:
                    ax.plot(x, comps[key], lw=1.1, label=f"{n}PE")
        if args.linear_y:
            ax.set_yscale("linear")
            ax.set_ylim(bottom=0.0, top=args.plot_ymax)
        else:
            ax.set_yscale("log")
            ax.set_ylim(bottom=args.plot_ymin, top=args.plot_ymax)
        ax.set_xlim(-2, 8)
        ax.set_xlabel("Charge [pC]")
        ax.set_ylabel("Counts")
        ax.set_title(f"ch{ch}")
        ax.legend(fontsize=8)

    plt.savefig(args.plot_out, dpi=150)
    print(f"Saved: {args.plot_out}")

    print(f"Saved: {args.out_csv}")
    for r in results:
        rel = (r.mu_e / ref) if (r.status.startswith("ok") and np.isfinite(ref) and ref > 0) else float("nan")
        print(
            f"ch{r.channel}: mu_e={r.mu_e:.5g} +/- {r.mu_e_err:.3g}, "
            f"rel(mu_e)={rel:.5g}, chi2/ndf={r.chi2_ndf:.3g}, model={r.model}, "
            f"npe={r.npe_used}, f_bs={(r.params[5] if (r.params is not None and len(r.params)>5) else float('nan')):.4g}, "
            f"bs_scale={(r.params[6] if (r.params is not None and len(r.params)>6) else float('nan')):.4g}, "
            f"boundary={r.hit_boundary}, {r.status}"
        )


if __name__ == "__main__":
    main()
