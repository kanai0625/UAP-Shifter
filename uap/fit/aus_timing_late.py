#!/usr/bin/env python3
"""
PMT timing fit with a late-pulse component, replacing UAP's EMG + linear background
fit for the PMT (the SiPM fit is unchanged).  Uses UAP's extended unbinned NLL and iminuit wrapper.

Model in the timing window [x0, x1] (yields = events in the window):
  N_prompt * EMG(mu, sigma, lambda)                       first (prompt) pulse
  N_late   * EMG(mu + dmu_late, sigma_late, lambda_late)  late pulse   (dmu_late >= 0)
  N_bkg    * (1 + coeff * x') / (x1 - x0)                 linear background (UAP's 1st-order Chebyshev,
                                                           x' = -1 .. 1 across the window)
Fit order (each step starts from the previous one):
  1. prompt   : prompt EMG alone, data in [peak + PROMPT_LO, peak + PROMPT_HI]   (default -10 .. +6 ns)
  2. late     : late EMG, data in [peak + PROMPT_HI, x1], prompt fixed (its tail is included)
  3. bkg      : linear background, whole window, both EMGs fixed
  4. final    : everything free together, whole window
CSV: the prompt EMG keeps UAP's columns (mu, sigma, lambda, sig_yield, FWHM_signal ...);
     late_mu / late_dmu / late_sigma / late_lambda / late_yield (+ _err), late_fraction,
     step1_* / step2_* / step3_* (results of the steps).
"""

import logging

import numpy as np
from scipy.stats import exponnorm

log = logging.getLogger("timing_emg2")
SAMPLE_NS = 2.0
PARAMS = ("mu", "sigma", "lambd", "sig_yield", "dmu_late", "sigma_late", "lambd_late", "late_yield",
          "bkg_yield", "coeff")


def _cdf(x, mu, sig, lam):
    return exponnorm.cdf(x, 1.0 / (sig * lam), loc=mu, scale=sig)


def _sf(x, mu, sig, lam):
    return exponnorm.sf(x, 1.0 / (sig * lam), loc=mu, scale=sig)


def _prob(a, b, mu, sig, lam):
    """P(a < X < b), numerically safe in both tails."""
    ca = _cdf(a, mu, sig, lam)
    return np.where(ca > 0.5, _sf(a, mu, sig, lam) - _sf(b, mu, sig, lam), _cdf(b, mu, sig, lam) - ca)


class Model:
    def __init__(self, xr):
        self.x0, self.x1 = float(xr[0]), float(xr[1])
        self.w = self.x1 - self.x0

    def _emg(self, x, mu, sig, lam):
        acc = float(_prob(self.x0, self.x1, mu, sig, lam))
        if not np.isfinite(acc) or acc <= 0:
            return np.full(np.shape(x), np.nan)
        return np.exp(exponnorm.logpdf(x, 1.0 / (sig * lam), loc=mu, scale=sig)) / acc

    def components(self, x, p):
        x = np.asarray(x, float)
        prompt = p["sig_yield"] * self._emg(x, p["mu"], p["sigma"], p["lambd"])
        late = p["late_yield"] * self._emg(x, p["mu"] + p["dmu_late"], p["sigma_late"], p["lambd_late"])
        xs = 2.0 * (x - self.x0) / self.w - 1.0
        bkg = p["bkg_yield"] * (1.0 + p["coeff"] * xs) / self.w
        return prompt, late, bkg

    def density(self, x, p):
        a, b, c = self.components(x, p)
        return a + b + c

    def expected(self, lo, hi, p):
        """expected events in [lo, hi] (arrays allowed) per component and total."""
        lo, hi = np.asarray(lo, float), np.asarray(hi, float)
        out = []
        for n, mu, sig, lam in ((p["sig_yield"], p["mu"], p["sigma"], p["lambd"]),
                                (p["late_yield"], p["mu"] + p["dmu_late"], p["sigma_late"], p["lambd_late"])):
            acc = float(_prob(self.x0, self.x1, mu, sig, lam))
            out.append(n * _prob(lo, hi, mu, sig, lam) / acc if acc > 0 else np.full(lo.shape, np.nan))
        ua, ub = 2.0 * (lo - self.x0) / self.w - 1.0, 2.0 * (hi - self.x0) / self.w - 1.0
        out.append(p["bkg_yield"] / 2.0 * ((ub - ua) + p["coeff"] * (ub ** 2 - ua ** 2) / 2.0))
        return out[0], out[1], out[2], out[0] + out[1] + out[2]


def fit_emg2(self, request, prompt_lo=-10.0, prompt_hi=6.0, plot=None):
    """Replacement of TimingEMGFitter._fit_emg for the PMT."""
    from uap.fit import common_math

    data = np.asarray(request.data, float).reshape(-1)
    data = data[np.isfinite(data)]
    xr = request.xr if request.xr is not None else (float(data.min()), float(data.max()))
    x0, x1 = float(xr[0]), float(xr[1])
    data = data[(data >= x0) & (data <= x1)]
    if data.size < 20:
        raise RuntimeError("too few timing entries in the window: {}".format(data.size))
    n = float(data.size)
    model = Model((x0, x1))
    stat = {"name": "unbinned_nll"}
    opt = dict(self.fit_config.get("optimizer", {}))
    opt["name"] = "iminuit"

    vals, cnts = np.unique(data, return_counts=True)
    peak = float(vals[np.argmax(cnts)])
    r1 = (max(x0, peak + prompt_lo), min(x1, peak + prompt_hi))
    r2 = (r1[1], x1)

    p = dict(mu=peak, sigma=1.5, lambd=0.5, sig_yield=0.0, dmu_late=max(prompt_hi + 6.0, 5.0), sigma_late=3.0,
             lambd_late=0.1, late_yield=0.0, bkg_yield=0.0, coeff=0.0)
    lim = dict(mu=(peak + prompt_lo, peak + prompt_hi), sigma=(0.2, 20.0), lambd=(0.005, 5.0),
               sig_yield=(0.0, 2.0 * n), dmu_late=(0.0, x1 - x0), sigma_late=(0.2, 40.0),
               lambd_late=(0.001, 5.0), late_yield=(0.0, 2.0 * n), bkg_yield=(0.0, 2.0 * n), coeff=(-1.0, 1.0))
    steps = {}

    def run(rng, free, start):
        d = data[(data >= rng[0]) & (data <= rng[1])]
        names = tuple(PARAMS)

        def dens(x, q):
            return model.density(x, q)

        def integ(q):
            return float(model.expected(rng[0], rng[1], q)[3])

        cost = common_math.build_objective(d, rng, names, dens, integ, stat)
        init = {k: float(np.clip(start[k], *lim[k])) for k in names}
        fixed = {k: init[k] for k in names if k not in free}
        res = common_math.minimize(cost, init, lim, opt, fixed)
        q = res.values.to_dict()
        return q, res, cost, d.size

    # ---- step 1: prompt EMG only
    n1 = float(np.sum((data >= r1[0]) & (data <= r1[1])))
    p.update(sig_yield=n1 * float(_prob(x0, x1, peak, 1.5, 0.5)) / max(float(_prob(r1[0], r1[1], peak, 1.5, 0.5)), 1e-3))
    p, res1, _, _ = run(r1, ("mu", "sigma", "lambd", "sig_yield"), p)
    steps["step1"] = dict(p)
    log.info("[STEP1 prompt] %s  data %.1f..%.1f ns: mu=%.3f sigma=%.3f lambda=%.4f N=%.0f  valid=%s",
             request.plotname, r1[0], r1[1], p["mu"], p["sigma"], p["lambd"], p["sig_yield"], res1.valid)

    # ---- step 2: late EMG after the prompt region (prompt fixed)
    n2 = float(np.sum((data > r2[0]) & (data <= r2[1])))
    pred2 = float(model.expected(r2[0], r2[1], dict(p, late_yield=0.0, bkg_yield=0.0))[0])
    if n2 - pred2 > 5 and r2[1] - r2[0] > 4:
        resid_vals = data[(data > r2[0])]
        p.update(late_yield=max(n2 - pred2, 1.0) * 1.2,
                 dmu_late=max(float(np.median(resid_vals)) - p["mu"] - 5.0, prompt_hi),
                 sigma_late=3.0, lambd_late=0.1)
        lim["dmu_late"] = (0.0, x1 - p["mu"])
        p, res2, _, _ = run(r2, ("dmu_late", "sigma_late", "lambd_late", "late_yield"), p)
        log.info("[STEP2 late  ] %s  data %.1f..%.1f ns: mu_late=%.3f sigma=%.3f lambda=%.4f N=%.0f  valid=%s",
                 request.plotname, r2[0], r2[1], p["mu"] + p["dmu_late"], p["sigma_late"], p["lambd_late"],
                 p["late_yield"], res2.valid)
    else:
        log.warning("[STEP2 late  ] %s  no excess after the prompt (%.0f events, prompt tail %.0f) -> no late pulse",
                    request.plotname, n2, pred2)
    steps["step2"] = dict(p)

    # ---- step 3: linear background, both EMGs fixed
    rest = n - float(model.expected(x0, x1, dict(p, bkg_yield=0.0))[3])
    p.update(bkg_yield=max(rest, 0.05 * n), coeff=0.0)
    p, res3, _, _ = run((x0, x1), ("bkg_yield", "coeff"), p)
    steps["step3"] = dict(p)
    log.info("[STEP3 bkg   ] %s  N_bkg=%.0f coeff=%.3f  valid=%s", request.plotname, p["bkg_yield"], p["coeff"],
             res3.valid)

    # ---- step 4: everything free
    free = list(PARAMS) if p["late_yield"] > 0 else [k for k in PARAMS if k not in
                                                   ("dmu_late", "sigma_late", "lambd_late", "late_yield")]
    lim["mu"] = (x0, x1)
    p, res, cost, _ = run((x0, x1), tuple(free), p)
    err = common_math.parameter_errors(res)
    log.info("[STEP4 final ] %s  mu=%.3f+-%.3f sigma=%.3f lambda=%.4f N=%.0f | late mu=%.3f sigma=%.3f "
             "lambda=%.4f N=%.0f | bkg N=%.0f coeff=%.3f  valid=%s", request.plotname, p["mu"], err["mu"],
             p["sigma"], p["lambd"], p["sig_yield"], p["mu"] + p["dmu_late"], p["sigma_late"], p["lambd_late"],
             p["late_yield"], p["bkg_yield"], p["coeff"], res.valid)

    cov = np.asarray(res.covariance) if res.covariance is not None else None
    names = list(res.parameters)
    late_mu_err = np.nan
    if cov is not None and "dmu_late" in names:
        i, j = names.index("mu"), names.index("dmu_late")
        v = cov[i, i] + cov[j, j] + 2 * cov[i, j]
        late_mu_err = float(np.sqrt(v)) if v >= 0 else np.nan
    out = {"mean": p["mu"], "lambda": p["lambd"], "sigma": p["sigma"],
           "mu_err": err["mu"], "std_err": err["sigma"], "lambd_err": err["lambd"],
           "sig_yield": p["sig_yield"], "sig_err": err["sig_yield"],
           "bkg_yield": p["bkg_yield"], "bkg_err": err["bkg_yield"], "coeff": p["coeff"],
           "late_mu": p["mu"] + p["dmu_late"], "late_mu_err": late_mu_err,
           "late_dmu": p["dmu_late"], "late_dmu_err": err["dmu_late"],
           "late_sigma": p["sigma_late"], "late_sigma_err": err["sigma_late"],
           "late_lambda": p["lambd_late"], "late_lambda_err": err["lambd_late"],
           "late_yield": p["late_yield"], "late_yield_err": err["late_yield"],
           "late_fraction": p["late_yield"] / (p["late_yield"] + p["sig_yield"])
           if p["late_yield"] + p["sig_yield"] > 0 else np.nan,
           **common_math.fit_quality(res)}
    for s, q in steps.items():
        for k in ("mu", "sigma", "lambd", "sig_yield", "late_yield", "bkg_yield"):
            out["{}_{}".format(s, k)] = q[k]
        out[s + "_late_mu"] = q["mu"] + q["dmu_late"]
    out.update(fit_model="emg+late_emg+linear", fit_statistic="unbinned_nll", fit_optimizer="iminuit",
               objective_value=res.fval, prior_penalty=0.0, chi2=np.nan, ndf=np.nan, bkg_model="linear")
    # diagnostics in 2 ns bins (as UAP: deviance, ndf)
    edges = _edges(data, x0, x1)
    counts, _ = np.histogram(data, bins=edges)
    expct = model.expected(edges[:-1], edges[1:], p)[3]
    from scipy.special import xlogy
    with np.errstate(divide="ignore", invalid="ignore"):
        out["poisson_deviance"] = float(2.0 * np.nansum(expct - counts + xlogy(counts, counts) - xlogy(counts, expct)))
    out["diagnostic_ndf"] = len(counts) - int(res.nfit)
    # FWHM: full model (as UAP's FWHM column) and prompt EMG only
    xf = np.linspace(x0, x1, 4000)
    out["FWHM"] = _fwhm(xf, model.density(xf, p))
    from uap.fit.aus_plot_style import signal_fwhm
    fw, xl, xh, xpk = signal_fwhm(p["mu"], p["lambd"], p["sigma"], (x0, x1))
    out["FWHM_signal"], out["FWHM_signal_lo"], out["FWHM_signal_hi"] = fw, xl, xh
    out["late_FWHM"] = signal_fwhm(p["mu"] + p["dmu_late"], p["lambd_late"], p["sigma_late"], (x0, x1))[0] \
        if p["late_yield"] > 0 else np.nan
    if self.fig_dir is not None:
        draw(self.fig_dir, request.plotname, data, model, p, out, edges, counts, expct, (fw, xl, xh, xpk))
    return out


def _edges(data, x0, x1):
    ref = np.round(np.median(data) / SAMPLE_NS) * SAMPLE_NS if data.size else 0.0
    e0 = ref + SAMPLE_NS * (np.floor((x0 - ref) / SAMPLE_NS - 0.5) + 0.5)
    return np.unique(np.clip(np.arange(e0, x1 + SAMPLE_NS, SAMPLE_NS), x0, x1))


def _fwhm(x, y):
    if not np.isfinite(y).any() or np.nanmax(y) <= 0:
        return np.nan
    i = int(np.nanargmax(y))
    half = 0.5 * y[i]
    left = np.nonzero(y[:i] < half)[0]
    right = np.nonzero(y[i:] < half)[0]
    if not left.size or not right.size:
        return np.nan
    j, k = left[-1], i + right[0]
    xl = x[j] + (half - y[j]) * (x[j + 1] - x[j]) / (y[j + 1] - y[j])
    xh = x[k - 1] + (half - y[k - 1]) * (x[k] - x[k - 1]) / (y[k] - y[k - 1])
    return xh - xl


def draw(fig_dir, plotname, data, model, p, out, edges, counts, expct, fw):
    import matplotlib.pyplot as plt
    from uap.fit import plot_utils
    fwhm, xl, xh, xpk = fw
    x0, x1 = model.x0, model.x1
    centers = 0.5 * (edges[:-1] + edges[1:])
    width = np.diff(edges)
    pull = (counts - expct) / np.sqrt(np.clip(counts, 1, None))
    xf = np.linspace(x0, x1, 4000)
    a, b, c = (comp * SAMPLE_NS for comp in model.components(xf, p))
    tot = a + b + c
    with plt.rc_context(getattr(plot_utils, "FIT_STYLE", {})):
        fig, (ax, axp) = plt.subplots(2, 1, figsize=(13, 8), sharex=True,
                                      gridspec_kw=dict(height_ratios=(3.2, 1), hspace=0.06))
        ok = counts > 0
        scale = SAMPLE_NS / width
        ax.errorbar(centers[ok], (counts * scale)[ok], yerr=(np.sqrt(counts) * scale)[ok], fmt="ok", ms=3.5,
                    elinewidth=1, label="Data")
        ax.plot(xf, tot, color="tab:blue", lw=2.2, label="Total")
        ax.plot(xf, a, color="#d62783", lw=2.0, ls="--", label="Prompt (EMG)")
        if p["late_yield"] > 0:
            ax.plot(xf, b, color="tab:green", lw=2.0, ls="--", label="Late pulse (EMG)")
        ax.plot(xf, c, color="#8b4513", lw=2.0, ls="--", label="Background (linear)")
        ax.axvline(p["mu"], color="#5b3f9a", lw=2.0, ls="-.",
                   label=r"$\mu = %.2f \pm %.2f$ ns" % (p["mu"], out.get("mu_err", np.nan)))
        if np.isfinite(fwhm):
            ax.axvspan(xl, xh, color="0.6", alpha=0.18, lw=0)
            for xv in (xl, xh):
                ax.axvline(xv, color="0.4", lw=1.0, ls=":")
            yh = 0.5 * float(np.interp(xpk, xf, a)) + float(np.interp(xpk, xf, b + c))
            ax.annotate("", xy=(xl, yh), xytext=(xh, yh), arrowprops=dict(arrowstyle="<->", color="0.3", lw=1.4))
        extra = [r"FWHM $= %.2f$ ns" % fwhm if np.isfinite(fwhm) else "FWHM = N/A",
                 r"$N_{\mathrm{prompt}} = %.0f \pm %.0f$" % (p["sig_yield"], out.get("sig_err", np.nan)),
                 r"$\sigma = %.2f$ ns, $\lambda = %.3f$ /ns" % (p["sigma"], p["lambd"])]
        if p["late_yield"] > 0:
            extra += [r"$\mu_{\mathrm{late}} = %.2f$ ns ($+%.1f$ ns)" % (p["mu"] + p["dmu_late"], p["dmu_late"]),
                      r"$\sigma_{\mathrm{late}} = %.2f$ ns, $\lambda_{\mathrm{late}} = %.3f$ /ns" % (
                          p["sigma_late"], p["lambd_late"]),
                      r"$N_{\mathrm{late}} = %.0f \pm %.0f$ (%.1f %%)" % (
                          p["late_yield"], out.get("late_yield_err", np.nan), 100 * out.get("late_fraction", np.nan))]
        extra += [r"$N_{\mathrm{bkg}} = %.0f \pm %.0f$, slope $= %.2f$" % (
            p["bkg_yield"], out.get("bkg_err", np.nan), p["coeff"])]
        for t in extra:
            ax.plot([], [], " ", label=t)
        ax.set_yscale("log")
        pos = counts[counts > 0]
        ax.set_ylim(max(0.3, 0.5 * float(pos.min())) if pos.size else 0.3,
                    max(float(np.nanmax(tot)), float(counts.max()) if counts.size else 1.0) * 3)
        ax.set_ylabel("Events / 2 ns")
        ax.legend(loc="upper left", bbox_to_anchor=(1.01, 1.0), fontsize=9, framealpha=0.9, borderaxespad=0.0)
        ax.set_title((plotname or "timing").strip() + "   (prompt -> late pulse -> background, then all free)",
                     fontsize=10)
        axp.axhline(0, color="k", lw=0.8, ls="--")
        axp.plot(centers, pull, "ok", ms=3)
        lim = max(5.0, float(np.nanmax(np.abs(pull))) * 1.1) if np.isfinite(pull).any() else 5.0
        axp.set_ylim(-lim, lim)
        axp.set_ylabel("Pull")
        axp.set_xlabel(r"$t_{\mathrm{PMT}} - t_{\mathrm{trigger}}$ (ns)")
        axp.set_xlim(x0, x1)
        target = fig_dir / "{}.png".format((plotname or "fit").strip())
        fig.savefig(str(target), bbox_inches="tight")
        plt.close(fig)
    log.info("[PLOT] saved %s", target)


EXTRA_FIELDS = (["late_mu", "late_mu_err", "late_dmu", "late_dmu_err", "late_sigma", "late_sigma_err",
                 "late_lambda", "late_lambda_err", "late_yield", "late_yield_err", "late_fraction", "late_FWHM"]
                + ["{}_{}".format(s, k) for s in ("step1", "step2", "step3")
                   for k in ("mu", "sigma", "lambd", "sig_yield", "late_yield", "bkg_yield", "late_mu")])


def install(prompt_lo=-10.0, prompt_hi=6.0):
    """PMT timing fit -> prompt EMG + late EMG + linear background (SiPM: unchanged)."""
    from uap.fit import emg_timing_offset_fit as tf
    original = tf.TimingEMGFitter._fit_emg

    def fit(self, request):
        if (request.plotname or "").startswith("sipm"):
            return original(self, request)
        return fit_emg2(self, request, prompt_lo, prompt_hi)

    tf.TimingEMGFitter._fit_emg = fit
    have = {k for k, _ in tf.TimingEMGFitter.FIT_FIELD_MAP}
    tf.TimingEMGFitter.FIT_FIELD_MAP = list(tf.TimingEMGFitter.FIT_FIELD_MAP) + [
        (k, k) for k in EXTRA_FIELDS + ["bkg_model", "FWHM_signal", "FWHM_signal_lo", "FWHM_signal_hi"]
        if k not in have]
    log.info("[TIMING] PMT: prompt EMG (%.0f..%+.0f ns around the peak) -> late EMG -> linear bkg -> all free",
             prompt_lo, prompt_hi)
