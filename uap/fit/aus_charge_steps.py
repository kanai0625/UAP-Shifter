"""
AUS charge fit in steps (installed on top of UAP's ChargeSpectrumFitter, UAP code itself unchanged).

install_steps()     4 steps  1 pedestal  2 SPE start (most populated bin above the pedestal),
                             SPE + 2PE fitted in 1 .. 5 pC  3 pedestal + SPE + 2PE  4 + backscatter
install_two_step()  previous 3-step version (1 pedestal  2 pedestal + SPE + 2PE  3 + backscatter)

Used by runners/aus_root2csv.py.
"""

import logging

import numpy as np


def fit_pedestal(data, center, sigma, window_nsigma=2.0, iterations=3):
    """Truncated-Gaussian unbinned ML fit of the pedestal.  Returns dict or None."""
    from math import erf, sqrt
    from iminuit import Minuit

    def cdf(v, mu, sig):
        return 0.5 * (1.0 + erf((v - mu) / (sig * sqrt(2.0))))

    res = None
    for _ in range(iterations):
        lo, hi = center - window_nsigma * sigma, center + window_nsigma * sigma
        x = data[(data >= lo) & (data <= hi)]
        if x.size < 20:
            return res

        def nll(mu, sig, x=x, lo=lo, hi=hi):
            if sig <= 0:
                return 1e300
            acc = cdf(hi, mu, sig) - cdf(lo, mu, sig)
            if not np.isfinite(acc) or acc <= 0:
                return 1e300
            logpdf = -0.5 * ((x - mu) / sig) ** 2 - np.log(sig * np.sqrt(2.0 * np.pi))
            return -np.sum(logpdf) + x.size * np.log(acc)

        nll.errordef = Minuit.LIKELIHOOD
        m = Minuit(nll, center, sigma, name=("mu", "sig"))
        m.limits = [(lo, hi), (1e-4 * max(sigma, 1e-3), 5 * sigma)]
        m.migrad()
        m.hesse()
        mu, sig = float(m.values["mu"]), float(m.values["sig"])
        cov = np.asarray(m.covariance) if m.covariance is not None else np.full((2, 2), np.nan)
        res = dict(mean=mu, sigma=sig, mean_err=float(np.sqrt(cov[0, 0])), sigma_err=float(np.sqrt(cov[1, 1])),
                   n=int(x.size), lo=lo, hi=hi, valid=bool(m.valid))
        center, sigma = mu, sig
    return res


def fit_gauss_range(x, lo, hi, mu0, sig0):
    """Truncated-Gaussian unbinned ML fit of x within [lo, hi].  Returns dict or None."""
    from math import erf, sqrt
    from iminuit import Minuit
    x = x[(x >= lo) & (x <= hi)]
    if x.size < 20:
        return None

    def cdf(v, mu, sig):
        return 0.5 * (1.0 + erf((v - mu) / (sig * sqrt(2.0))))

    def nll(mu, sig):
        if sig <= 0:
            return 1e300
        acc = cdf(hi, mu, sig) - cdf(lo, mu, sig)
        if not np.isfinite(acc) or acc <= 0:
            return 1e300
        return -np.sum(-0.5 * ((x - mu) / sig) ** 2 - np.log(sig * np.sqrt(2.0 * np.pi))) + x.size * np.log(acc)

    nll.errordef = Minuit.LIKELIHOOD
    m = Minuit(nll, mu0, sig0, name=("mu", "sig"))
    m.limits = [(lo, hi), (1e-3, 5.0 * (hi - lo))]
    m.migrad()
    m.hesse()
    cov = np.asarray(m.covariance) if m.covariance is not None else np.full((2, 2), np.nan)
    return dict(mean=float(m.values["mu"]), sigma=float(m.values["sig"]), mean_err=float(np.sqrt(cov[0, 0])),
                sigma_err=float(np.sqrt(cov[1, 1])), n=int(x.size), lo=lo, hi=hi, valid=bool(m.valid))


def fit_spe_2pe(x, lo, hi, mu0, sig0, ped=None, pe2_ratio=None, mu_lim=None):
    """Extended unbinned ML fit of SPE + 2PE Gaussians (+ the pedestal tail, shape fixed from step 1)
    to the charges in [lo, hi].  Peak positions as in UAP's gaussian_shapes:
      mean_n = ped + n (mu_spe - ped),  sigma_n^2 = sigma_ped^2 + n (sigma_spe^2 - sigma_ped^2).
    pe2_ratio: N_2PE / N_SPE fixed to this value (Poisson: occupancy / 2); None = 2PE yield free.
    mu_lim   : (lo, hi) limits of the SPE mean (default: the fit range).
    Returns dict or None."""
    from iminuit import Minuit
    from scipy.stats import norm
    x = x[(x >= lo) & (x <= hi)]
    if x.size < 30:
        return None
    pm, ps = (ped["mean"], ped["sigma"]) if ped is not None else (0.0, 0.0)
    use_ped = ped is not None and ps > 0 and norm.sf(lo, pm, ps) * ped.get("n", 0) > 1.0

    def shapes(mu, sig):
        s0 = max(ps, 1e-4)
        s1 = sig
        s2 = np.sqrt(max(s0 ** 2 + 2.0 * (sig ** 2 - s0 ** 2), 1e-8)) if ps > 0 else np.sqrt(2.0) * sig
        return [(pm, s0), (mu, s1), (pm + 2.0 * (mu - pm), s2)]

    def nll(mu, sig, n0, n1, n2):
        if sig <= 0:
            return 1e300
        comps = shapes(mu, sig)
        dens = np.zeros_like(x)
        total = 0.0
        if pe2_ratio is not None:
            n2 = n1 * pe2_ratio
        for n, (m, s) in zip((n0 if use_ped else 0.0, n1, n2), comps):
            if n <= 0:
                continue
            dens = dens + n * norm.pdf(x, m, s)
            total += n * (norm.cdf(hi, m, s) - norm.cdf(lo, m, s))
        if total <= 0 or np.any(dens <= 0):
            return 1e300
        return total - np.sum(np.log(dens))

    nll.errordef = Minuit.LIKELIHOOD
    n = float(x.size)
    m = Minuit(nll, mu0, sig0, 0.05 * n if use_ped else 0.0, 0.7 * n, 0.2 * n, name=("mu", "sig", "n0", "n1", "n2"))
    m.limits = [mu_lim or (lo, hi), (0.02, max(hi - lo, 0.1)), (0.0, 5 * n), (0.0, 5 * n), (0.0, 5 * n)]
    if not use_ped:
        m.fixed["n0"] = True
    if pe2_ratio is not None:
        m.fixed["n2"] = True
    m.migrad()
    m.hesse()
    cov = np.asarray(m.covariance) if m.covariance is not None else np.full((5, 5), np.nan)
    v = m.values
    n2 = float(v["n1"]) * pe2_ratio if pe2_ratio is not None else float(v["n2"])
    return dict(mean=float(v["mu"]), sigma=float(v["sig"]), mean_err=float(np.sqrt(abs(cov[0, 0]))),
                sigma_err=float(np.sqrt(abs(cov[1, 1]))), spe_yield=float(v["n1"]), pe2_yield=n2,
                ped_tail_yield=float(v["n0"]), n=int(x.size), lo=lo, hi=hi, valid=bool(m.valid))


def spe_start(data, search_min=1.0, bin_w=0.05, xmax=None):
    """charge >= search_min with the most events (histogram, bin_w).  If that is the first bin
    (pedestal tail still falling), the highest bin after the first local minimum is used."""
    hi = float(np.max(data)) if xmax is None else float(xmax)
    if hi <= search_min + 2 * bin_w:
        return None, "no charges above {} pC".format(search_min)
    counts, edges = np.histogram(data, bins=np.arange(search_min, hi + bin_w, bin_w))
    if counts.sum() == 0:
        return None, "no charges above {} pC".format(search_min)
    k = int(np.argmax(counts))
    note = "max bin"
    if k == 0:
        sm = np.convolve(counts, np.ones(5) / 5.0, mode="same")
        d = np.diff(sm)
        rise = np.nonzero((d[:-1] < 0) & (d[1:] >= 0))[0]          # first local minimum
        if rise.size:
            j = rise[0] + 1
            k = j + int(np.argmax(counts[j:]))
            note = "first bin was the max (pedestal tail) -> max after the minimum at {:.2f} pC".format(
                0.5 * (edges[j] + edges[j + 1]))
    return 0.5 * (edges[k] + edges[k + 1]), note


def install_steps(ped_window, ped_bound, spe_bound=None, spe_search_min=None, spe_halfwidth=1.0,
                  spe_bin=0.05, keep_spe_prior=False, spe_ped_gap=3.0, spe_range=(1.0, 5.0), pe2_free=False,
                  min_err_frac=1e-3):
    """Four-step charge fit:
       1 pedestal
       2 SPE start = most populated bin above the pedestal (ped mean + SPE_PED_GAP sigma, or SPE_SEARCH_MIN),
         SPE + 2PE (+ pedestal tail, shape fixed) fitted to the charges in SPE_RANGE (default 1 .. 5 pC)
       3 pedestal + SPE + 2PE over the whole range (SPE mean kept in step-2 mean +- SPE_HALFWIDTH)
       4 + backscatter."""
    import copy
    from uap.fit import charge_spectrum_fit as csf

    original = csf.ChargeSpectrumFitter._fit_gaussian_peaks
    log = logging.getLogger("four_step")
    spe_n = 10.0 if spe_bound is None else spe_bound      # step 4 SPE: step 3 +- 10 x fit error (default)

    def window(value, err, ref, n=None):
        n = ped_bound if n is None else n
        e = err if np.isfinite(err) and err > 0 else 0.05 * abs(ref)
        e = max(e, min_err_frac * abs(ref)) * n
        return (value - e, value + e)

    def run(self, request, bounds, backscatter, suffix, spe_init=None):
        saved_c, saved_bs = self.constraints, self.inc_backscatter
        b = dict(saved_c.get("bounds", {}))
        b.update(bounds)
        pri = dict(saved_c.get("priors", {}))
        if spe_init is not None and not keep_spe_prior:
            pri.pop("mu_spe", None)
            pri.pop("sigma_spe", None)
        self.constraints = dict(saved_c, bounds=b, priors=pri)
        self.inc_backscatter = backscatter
        if spe_init is not None:                     # start values of the SPE from step 2
            orig_guess = self._initial_guesses

            def guesses(*args, **kw):
                g = dict(orig_guess(*args, **kw))
                g.update(mu_spe=spe_init["mean"], sigma_spe=spe_init["sigma"], spe_window=spe_init["window"])
                return g
            self._initial_guesses = guesses
        req = copy.copy(request)
        if suffix:
            req.plotname = request.plotname + suffix
        try:
            return original(self, req)
        finally:
            self.constraints, self.inc_backscatter = saved_c, saved_bs
            self.__dict__.pop("_initial_guesses", None)

    def four_step(self, request):
        data = self._finite_1d(request.data)
        xmin, xmax = float(request.xr[0]), float(request.xr[1])
        data = self._clip_to_range(data, xmin, xmax)
        counts, edges = np.histogram(data, bins=200, range=(xmin, xmax))
        center = 0.5 * (edges[np.argmax(counts)] + edges[np.argmax(counts) + 1])
        near = data[np.abs(data - center) < 0.25 * (xmax - xmin)]
        sigma = 1.4826 * float(np.median(np.abs(near - center))) if near.size else 0.1

        # ---- step 1: pedestal only
        ped = fit_pedestal(data, center, max(sigma, 1e-3), ped_window)
        bounds = {}
        if ped is not None and np.isfinite(ped["mean"]) and np.isfinite(ped["sigma"]):
            lo_s, hi_s = window(ped["sigma"], ped["sigma_err"], ped["sigma"])
            bounds = {"mu_ped": window(ped["mean"], ped["mean_err"], ped["sigma"]),
                      "sigma_ped": (max(1e-6, lo_s), hi_s)}
            log.info("[STEP1 ped ] %s  mu=%.4f+-%.4f  sigma=%.4f+-%.4f  (n=%d, window %.3f..%.3f)",
                     request.plotname, ped["mean"], ped["mean_err"], ped["sigma"], ped["sigma_err"],
                     ped["n"], ped["lo"], ped["hi"])
        else:
            log.warning("[STEP1 ped ] %s failed -> pedestal not bounded", request.plotname)

        # ---- step 2: SPE start = most populated bin above the pedestal; SPE + 2PE fit in spe_range
        if spe_search_min is not None:
            smin = float(spe_search_min)
        elif ped is not None and np.isfinite(ped["mean"]):
            smin = ped["mean"] + spe_ped_gap * ped["sigma"]
        else:
            smin = 1.0
        seed, note = spe_start(data, smin, spe_bin, xmax)
        spe = None
        spe_init = None
        rlo, rhi = max(float(spe_range[0]), xmin), min(float(spe_range[1]), xmax)
        if seed is not None:
            if not (rlo < seed < rhi):
                log.warning("[STEP2 seed] %s  start %.3f pC is outside the SPE range %.2f..%.2f pC",
                            request.plotname, seed, rlo, rhi)
            # Poisson: N_2PE / N_SPE = occupancy / 2, occupancy = -ln(N_pedestal / N) from the step-1 fit
            ratio, occ = None, np.nan
            if not pe2_free and ped is not None and ped["n"] > 0:
                from math import erf, sqrt
                lo1, hi1 = ped["lo"], ped["hi"]
                acc = 0.5 * (erf((hi1 - ped["mean"]) / (ped["sigma"] * sqrt(2))) -
                             erf((lo1 - ped["mean"]) / (ped["sigma"] * sqrt(2))))
                n_ped = ped["n"] / max(acc, 1e-3)
                if 0 < n_ped < data.size:
                    occ = -np.log(n_ped / data.size)
                    ratio = occ / 2.0
            mlim = (max(rlo, seed - spe_halfwidth), min(rhi, seed + spe_halfwidth))
            spe = fit_spe_2pe(data, rlo, rhi, float(np.clip(seed, *mlim)), max(0.3 * (seed - smin), 0.1), ped,
                              ratio, mlim)
            if spe is not None and np.isfinite(spe["mean"]) and rlo < spe["mean"] < rhi:
                mu, sg = spe["mean"], spe["sigma"]
                lo = mu - spe_halfwidth
                if ped is not None and spe_ped_gap > 0:
                    lo = max(lo, min(ped["mean"] + spe_ped_gap * ped["sigma"], mu - 0.05))
                spe_init = dict(mean=mu, sigma=sg, window=(lo, mu + spe_halfwidth))
                bounds["mu_spe"] = (lo, mu + spe_halfwidth)
                bounds["sigma_spe"] = (max(1e-3, 0.25 * sg), 2.0 * sg)
                log.info("[STEP2 seed] %s  start %.3f pC (max bin above %.3f pC, %s)  SPE+2PE fit in %.2f..%.2f pC "
                         "(SPE mean %.2f..%.2f, %s): mu=%.4f+-%.4f  sigma=%.4f+-%.4f  N_SPE=%.0f N_2PE=%.0f "
                         "N_ped-tail=%.0f  (n=%d, valid=%s)", request.plotname, seed, smin, note, rlo, rhi,
                         mlim[0], mlim[1], "2PE free" if ratio is None else
                         "N_2PE/N_SPE = occupancy/2 = %.4f" % ratio, mu, spe["mean_err"], sg, spe["sigma_err"],
                         spe["spe_yield"], spe["pe2_yield"], spe["ped_tail_yield"], spe["n"], spe["valid"])
            else:                                      # no fit: the start value itself is used
                sig0 = max(0.3 * (seed - smin), 0.1)
                lo = max(seed - spe_halfwidth, smin)
                spe_init = dict(mean=seed, sigma=sig0, window=(lo, seed + spe_halfwidth))
                bounds["mu_spe"] = (lo, seed + spe_halfwidth)
                bounds["sigma_spe"] = (max(1e-3, 0.25 * sig0), 2.0 * sig0)
                log.warning("[STEP2 seed] %s  start %.3f pC (%s): SPE+2PE fit in %.2f..%.2f failed -> "
                            "start value used, SPE kept in %.3f..%.3f", request.plotname, seed, note, rlo, rhi,
                            lo, seed + spe_halfwidth)
        else:
            log.warning("[STEP2 seed] %s  %s -> UAP start values", request.plotname, note)

        # ---- step 3: pedestal + SPE + 2PE (no backscatter)
        step2 = None
        if not self.inc_backscatter:
            out = run(self, request, bounds, False, "", spe_init)
        else:
            step2 = run(self, request, bounds, False, "_step2_spe", spe_init)
            log.info("[STEP3 spe ] %s  spe=%.4f+-%.4f  sigma_spe=%.4f+-%.4f  ped=%.4f  status=%s",
                     request.plotname, step2.get("spe_mean", np.nan), step2.get("spe_mean_err", np.nan),
                     step2.get("spe_sigma", np.nan), step2.get("spe_sigma_err", np.nan),
                     step2.get("ped_mean", np.nan), step2.get("fit_status", ""))
            # ---- step 4: + backscatter, pedestal and SPE shapes bounded to step 3
            bounds4 = dict(bounds)
            ok = all(np.isfinite(step2.get(k, np.nan)) for k in ("ped_mean", "ped_sigma", "spe_mean", "spe_sigma"))
            init4 = spe_init
            if ok:
                ps, ss = step2["ped_sigma"], step2["spe_sigma"]
                bounds4["mu_ped"] = window(step2["ped_mean"], step2.get("ped_mean_err", np.nan), ps)
                lo, hi = window(ps, step2.get("ped_sigma_err", np.nan), ps)
                bounds4["sigma_ped"] = (max(1e-6, lo), hi)
                if spe_n > 0:
                    bounds4["mu_spe"] = window(step2["spe_mean"], step2.get("spe_mean_err", np.nan), ss, spe_n)
                    lo, hi = window(ss, step2.get("spe_sigma_err", np.nan), ss, spe_n)
                    bounds4["sigma_spe"] = (max(1e-6, lo), hi)
                init4 = dict(mean=step2["spe_mean"], sigma=step2["spe_sigma"],
                             window=bounds4.get("mu_spe", (spe_init or {}).get("window", (xmin, xmax))))
            else:
                log.warning("[STEP3 spe ] %s: no usable result -> step 4 with step-1/2 bounds", request.plotname)
            out = run(self, request, bounds4, True, "", init4)
            log.info("[STEP4 bs  ] %s  backscatter yield=%.1f  spe=%.4f  status=%s", request.plotname,
                     out.get("backscatter_yield", np.nan), out.get("spe_mean", np.nan), out.get("fit_status", ""))

        if ped is not None:
            for k in ("mean", "mean_err", "sigma", "sigma_err", "n", "lo", "hi", "valid"):
                out["ped_prefit_" + k] = ped[k]
        out["ped_prefit_bound_nerr"] = ped_bound
        out["spe_seed_start"] = np.nan if seed is None else seed
        out["spe_seed_search_min"] = smin
        out["spe_seed_occupancy"] = occ if seed is not None else np.nan
        for k in ("mean", "mean_err", "sigma", "sigma_err", "spe_yield", "pe2_yield", "n", "lo", "hi"):
            out["spe_seed_" + k] = np.nan if spe is None else spe[k]
        if step2 is not None:
            for k in STEP2_KEYS:
                out["step2_" + k] = step2.get(k, np.nan)
        return out

    csf.ChargeSpectrumFitter._fit_gaussian_peaks = four_step
    extra = [("ped_prefit_" + k, "ped_prefit_" + k)
             for k in ("mean", "mean_err", "sigma", "sigma_err", "n", "lo", "hi", "valid", "bound_nerr")]
    extra += [("spe_seed_" + k, "spe_seed_" + k)
              for k in ("start", "search_min", "occupancy", "mean", "mean_err", "sigma", "sigma_err", "spe_yield", "pe2_yield",
                        "n", "lo", "hi")]
    extra += [("step2_" + k, "step2_" + k) for k in STEP2_KEYS]
    have = {k for k, _ in csf.ChargeSpectrumFitter.FIT_FIELD_MAP}
    csf.ChargeSpectrumFitter.FIT_FIELD_MAP = list(csf.ChargeSpectrumFitter.FIT_FIELD_MAP) + [
        e for e in extra if e[0] not in have]


def install_two_step(ped_window, ped_bound, spe_bound=None, min_err_frac=1e-3):
    """Three-step charge fit (name kept for compatibility):
       1. pedestal only  2. pedestal(bounded) + SPE + 2PE  3. + backscatter (shapes bounded)."""
    import copy
    from uap.fit import charge_spectrum_fit as csf

    original = csf.ChargeSpectrumFitter._fit_gaussian_peaks
    log = logging.getLogger("three_step")

    spe_n = ped_bound if spe_bound is None else spe_bound

    def window(value, err, ref, n=None):
        """value +- n * err  (err floored at min_err_frac * ref so MIGRAD can move)."""
        n = ped_bound if n is None else n
        e = err if np.isfinite(err) and err > 0 else 0.05 * abs(ref)
        e = max(e, min_err_frac * abs(ref)) * n
        return (value - e, value + e)

    def run(self, request, bounds, backscatter, suffix):
        saved_c, saved_bs = self.constraints, self.inc_backscatter
        b = dict(saved_c.get("bounds", {}))
        b.update(bounds)
        self.constraints = dict(saved_c, bounds=b)
        self.inc_backscatter = backscatter
        req = copy.copy(request)
        if suffix:
            req.plotname = request.plotname + suffix
        try:
            return original(self, req)
        finally:
            self.constraints, self.inc_backscatter = saved_c, saved_bs

    def three_step(self, request):
        data = self._finite_1d(request.data)
        xmin, xmax = float(request.xr[0]), float(request.xr[1])
        data = self._clip_to_range(data, xmin, xmax)
        counts, edges = np.histogram(data, bins=200, range=(xmin, xmax))
        center = 0.5 * (edges[np.argmax(counts)] + edges[np.argmax(counts) + 1])
        near = data[np.abs(data - center) < 0.25 * (xmax - xmin)]
        sigma = 1.4826 * float(np.median(np.abs(near - center))) if near.size else 0.1

        # ---- step 1: pedestal only
        ped = fit_pedestal(data, center, max(sigma, 1e-3), ped_window)
        bounds2 = {}
        if ped is not None and np.isfinite(ped["mean"]) and np.isfinite(ped["sigma"]):
            lo_s, hi_s = window(ped["sigma"], ped["sigma_err"], ped["sigma"])
            bounds2 = {"mu_ped": window(ped["mean"], ped["mean_err"], ped["sigma"]),
                       "sigma_ped": (max(1e-6, lo_s), hi_s)}
            log.info("[STEP1 ped] %s  mu=%.4f+-%.4f  sigma=%.4f+-%.4f  (n=%d, window %.3f..%.3f)",
                     request.plotname, ped["mean"], ped["mean_err"], ped["sigma"], ped["sigma_err"],
                     ped["n"], ped["lo"], ped["hi"])
        else:
            log.warning("[STEP1 ped] %s failed -> pedestal not bounded", request.plotname)

        # ---- step 2: SPE + 2PE (no backscatter), pedestal bounded
        if not self.inc_backscatter:
            out = run(self, request, bounds2, False, "")
            step2 = None
        else:
            step2 = run(self, request, bounds2, False, "_step2_spe")
            log.info("[STEP2 spe] %s  spe=%.4f+-%.4f  sigma_spe=%.4f+-%.4f  ped=%.4f  status=%s",
                     request.plotname, step2.get("spe_mean", np.nan), step2.get("spe_mean_err", np.nan),
                     step2.get("spe_sigma", np.nan), step2.get("spe_sigma_err", np.nan),
                     step2.get("ped_mean", np.nan), step2.get("fit_status", ""))
            # ---- step 3: + backscatter, pedestal and SPE shapes bounded to step 2
            bounds3 = dict(bounds2)
            ok = all(np.isfinite(step2.get(k, np.nan)) for k in ("ped_mean", "ped_sigma", "spe_mean", "spe_sigma"))
            if ok:
                ps, ss = step2["ped_sigma"], step2["spe_sigma"]
                bounds3["mu_ped"] = window(step2["ped_mean"], step2.get("ped_mean_err", np.nan), ps)
                lo, hi = window(ps, step2.get("ped_sigma_err", np.nan), ps)
                bounds3["sigma_ped"] = (max(1e-6, lo), hi)
                if spe_n > 0:   # spe_bound 0 -> SPE free in step 3 (step 2 only seeds it)
                    bounds3["mu_spe"] = window(step2["spe_mean"], step2.get("spe_mean_err", np.nan), ss, spe_n)
                    lo, hi = window(ss, step2.get("spe_sigma_err", np.nan), ss, spe_n)
                    bounds3["sigma_spe"] = (max(1e-6, lo), hi)
            else:
                log.warning("[STEP2 spe] %s: no usable result -> step 3 with pedestal bounds only", request.plotname)
            out = run(self, request, bounds3, True, "")
            log.info("[STEP3 bs ] %s  backscatter yield=%.1f  spe=%.4f  status=%s", request.plotname,
                     out.get("backscatter_yield", np.nan), out.get("spe_mean", np.nan), out.get("fit_status", ""))

        if ped is not None:
            for k in ("mean", "mean_err", "sigma", "sigma_err", "n", "lo", "hi", "valid"):
                out["ped_prefit_" + k] = ped[k]
        out["ped_prefit_bound_nerr"] = ped_bound
        if step2 is not None:
            for k in STEP2_KEYS:
                out["step2_" + k] = step2.get(k, np.nan)
        return out

    csf.ChargeSpectrumFitter._fit_gaussian_peaks = three_step
    extra = [("ped_prefit_" + k, "ped_prefit_" + k)
             for k in ("mean", "mean_err", "sigma", "sigma_err", "n", "lo", "hi", "valid", "bound_nerr")]
    extra += [("step2_" + k, "step2_" + k) for k in STEP2_KEYS]
    have = {k for k, _ in csf.ChargeSpectrumFitter.FIT_FIELD_MAP}
    csf.ChargeSpectrumFitter.FIT_FIELD_MAP = list(csf.ChargeSpectrumFitter.FIT_FIELD_MAP) + [
        e for e in extra if e[0] not in have]


STEP2_KEYS = ("ped_mean", "ped_sigma", "spe_mean", "spe_mean_err", "spe_sigma", "spe_sigma_err",
              "ped_yield", "spe_yield", "pe2_yield", "gain_pedestal_subtracted", "fit_status")


# ----------------------------------------------------------------------------- main
