#!/usr/bin/env python3
"""
AUS figure / timing-background changes (installed by runners/aus_root2csv.py, UAP code itself unchanged).

charge  : every fit parameter (pedestal / SPE / 2PE mean, sigma, yield, backscatter yield, gain,
          resolution, P/V) is written in the legend of ..._log.png and ..._step2_spe_log.png.
timing  : the fit itself is UAP's unbinned extended NLL (unchanged).  The figure shows
            data   : one point per possible value (2 ns = 1 sample, the data are quantised in
                     samples, so nothing is merged = unbinned)
            model  : continuous curves (total, signal EMG, background), no histogram steps
            mu     : vertical line at the EMG mu, value in the legend
            FWHM   : of the signal EMG, half-maximum points marked with dotted lines, a shaded band
                     and an arrow, value in the legend
            pull   : (data - model integral of the 2 ns bin) / sqrt(data)
          new CSV columns: FWHM_signal, FWHM_signal_lo, FWHM_signal_hi (UAP's FWHM includes the
          background and is kept as it was).
"""

import logging

import numpy as np

log = logging.getLogger("plot_patch")
SAMPLE_NS = 2.0


def _pm(v, e, fmt="{:.4g}"):
    """value +- error, rounded to 2 significant digits of the error."""
    if not np.isfinite(v):
        return "N/A"
    if e is not None and np.isfinite(e) and e > 0:
        d = max(0, int(1 - np.floor(np.log10(e))))
        return "{:.{d}f} \\pm {:.{d}f}".format(v, e, d=d)
    return fmt.format(v)


def charge_lines(out):
    """All fit parameters as mathtext lines."""
    g = lambda k: float(out.get(k, np.nan)) if out.get(k, None) is not None else np.nan
    lines = []
    for name, pre in (("Ped", "ped"), ("SPE", "spe"), ("2PE", "pe2")):
        mu, s, n = g(pre + "_mean"), g(pre + "_sigma"), g(pre + "_yield")
        if not (np.isfinite(mu) or np.isfinite(n)):
            continue
        mu_e = g(pre + "_mean_err") if pre != "pe2" else np.nan
        s_e = g(pre + "_sigma_err") if pre != "pe2" else np.nan
        lines.append(r"$\mu_{\mathrm{%s}} = %s$ pC" % (name, _pm(mu, mu_e)))
        lines.append(r"$\sigma_{\mathrm{%s}} = %s$ pC" % (name, _pm(s, s_e)))
        lines.append(r"$N_{\mathrm{%s}} = %s$" % (name, _pm(n, g(pre + "_yield_err"), "{:.0f}")))
    bs = g("backscatter_yield")
    if np.isfinite(bs):
        lines.append(r"$N_{\mathrm{BS}} = %s$" % _pm(bs, g("backscatter_yield_err"), "{:.0f}"))
    gp = g("gain_pedestal_subtracted")
    if np.isfinite(gp):
        lines.append(r"Gain $= (%s)\times10^{6}$" % _pm(gp / 1e6, g("gain_pedestal_subtracted_err") / 1e6, "{:.3f}"))
    if np.isfinite(g("resolution")):
        lines.append(r"Resolution $= %.1f$ %%" % g("resolution"))
    if np.isfinite(g("peak_to_valley")):
        lines.append(r"P/V $= %.2f$" % g("peak_to_valley"))
    if np.isfinite(g("poisson_mu")):
        lines.append(r"$\mu_{\mathrm{Poisson}} = %s$" % _pm(g("poisson_mu"), g("poisson_mu_err")))
    return lines


def install_charge():
    import matplotlib.pyplot as plt
    from matplotlib.lines import Line2D
    from pathlib import Path
    from uap.fit import charge_spectrum_fit as csf

    style = getattr(csf.plot_utils, "FIT_STYLE", {})

    def make_log_plot(self, out_png, centers, counts, yerr, x_model, curves, xr, text_lines):
        with plt.rc_context(style):
            fig, ax = plt.subplots(1, 1, figsize=(13, 7))
            nz = np.asarray(counts) > 0                       # empty bins are not drawn (log scale)
            h_data = ax.errorbar(np.asarray(centers)[nz], np.asarray(counts)[nz], yerr=np.asarray(yerr)[nz],
                                 fmt="ok", ms=4, label="Data")
            handles = [h_data]
            for c in curves:
                h, = ax.plot(x_model, c["y"], linewidth=c.get("linewidth", 2), color=c.get("color"),
                             linestyle=c.get("linestyle", "-"), label=c["label"][:1].upper() + c["label"][1:])
                handles.append(h)
            ax.set_xlim([float(xr[0]), float(xr[1])])
            ax.set_xlabel("Charge (pC)")
            ax.set_ylabel("Events")
            ax.set_yscale("log")
            pos = np.asarray(counts, float)
            pos = pos[pos > 0]
            ymin = float(pos.min()) * 0.5 if pos.size else 0.5
            ymax = float(np.max(counts)) if np.size(counts) else 1.0
            for c in curves:
                yv = np.asarray(c["y"], float)
                if yv.size and np.isfinite(yv).any():
                    ymax = max(ymax, float(np.nanmax(yv)))
            ax.set_ylim(max(ymin, 0.5), max(ymax * 1.5, 2.0))
            blank = Line2D([], [], linestyle="none", marker="none")
            lines = list(text_lines or [])
            labels = [h.get_label() for h in handles] + [""] + lines
            handles = handles + [blank] * (1 + len(lines))
            ax.legend(handles, labels, loc="upper left", bbox_to_anchor=(1.01, 1.0), fontsize=10,
                      frameon=True, borderaxespad=0.0)
            fig.tight_layout()
            target = Path(out_png).resolve()
            target.parent.mkdir(parents=True, exist_ok=True)
            fig.savefig(str(target))
            plt.close(fig)

    csf.ChargeSpectrumFitter._make_log_plot = make_log_plot
    csf.plot_utils.charge_fit_text = charge_lines


# ----------------------------------------------------------------------------- timing
def signal_fwhm(mu, lambd, sigma, xr, npts=20001):
    """FWHM of the EMG alone (fine grid).  Returns (fwhm, x_lo, x_hi, y_peak_x)."""
    from scipy.stats import exponnorm
    lo = min(float(xr[0]), mu - 10 * sigma)
    hi = max(float(xr[1]), mu + 10 * sigma + 10.0 / max(lambd, 1e-6))
    x = np.linspace(lo, hi, npts)
    y = exponnorm.pdf(x, 1.0 / (sigma * lambd), loc=mu, scale=sigma)
    if not np.isfinite(y).any() or np.nanmax(y) <= 0:
        return np.nan, np.nan, np.nan, np.nan
    i = int(np.nanargmax(y))
    half = 0.5 * y[i]
    left = np.nonzero(y[:i] < half)[0]
    right = np.nonzero(y[i:] < half)[0]
    if not left.size or not right.size:
        return np.nan, np.nan, np.nan, x[i]
    j, k = left[-1], i + right[0]
    xl = x[j] + (half - y[j]) * (x[j + 1] - x[j]) / (y[j + 1] - y[j])
    xh = x[k - 1] + (half - y[k - 1]) * (x[k] - x[k - 1]) / (y[k] - y[k - 1])
    return xh - xl, xl, xh, x[i]


def install_timing():
    import matplotlib.pyplot as plt
    from matplotlib.lines import Line2D
    from uap.fit import emg_timing_offset_fit as tf

    style = getattr(tf.plot_utils, "FIT_STYLE", {})

    def make_plot(self, parameters, data_np, xr, out, plotname):
        p = dict(parameters)
        fw, xl, xh, xpk = signal_fwhm(p["mu"], p["lambd"], p["sigma"], xr)
        out["FWHM_signal"], out["FWHM_signal_lo"], out["FWHM_signal_hi"] = fw, xl, xh
        if self.fig_dir is None:
            return
        x0, x1 = float(xr[0]), float(xr[1])
        # one bin per possible value (2 ns samples), centred on the values
        ref = np.round(np.median(data_np) / SAMPLE_NS) * SAMPLE_NS if data_np.size else 0.0
        e0 = ref + SAMPLE_NS * (np.floor((x0 - ref) / SAMPLE_NS - 0.5) + 0.5)
        edges = np.arange(e0, x1 + SAMPLE_NS, SAMPLE_NS)
        edges = np.unique(np.clip(edges, x0, x1))
        counts, _ = np.histogram(data_np, bins=edges)
        centers = 0.5 * (edges[:-1] + edges[1:])
        width = np.diff(edges)
        expected = tf.timing_bin_expectations(edges, p, (x0, x1))
        pull = (counts - expected) / np.sqrt(np.clip(counts, 1, None))

        xf = np.linspace(x0, x1, 4000)
        sig = p["sig_yield"] * tf.emg_pdf(xf, p["mu"], p["lambd"], p["sigma"], (x0, x1)) * SAMPLE_NS
        tot = tf.timing_density(xf, p, (x0, x1)) * SAMPLE_NS
        has_bkg = "bkg_yield" in p
        bkg = tot - sig

        with plt.rc_context(style):
            fig, (ax, axp) = plt.subplots(2, 1, figsize=(10, 8), sharex=True,
                                          gridspec_kw=dict(height_ratios=(3.2, 1), hspace=0.06))
            ok = counts > 0
            # counts per 2 ns; partial edge bins scaled to 2 ns for display
            scale = SAMPLE_NS / width
            ax.errorbar(centers[ok], (counts * scale)[ok], yerr=(np.sqrt(counts) * scale)[ok], fmt="ok", ms=3.5,
                        elinewidth=1, label="Data")
            ax.plot(xf, tot, color="tab:blue", lw=2.2, label="Total")
            ax.plot(xf, sig, color="#d62783", lw=2.0, ls="--", label="Signal (EMG)")
            if has_bkg:
                ax.plot(xf, bkg, color="#8b4513", lw=2.0, ls="--", label="Background")
            ax.axvline(p["mu"], color="#5b3f9a", lw=2.0, ls="-.",
                       label=r"$\mu = %.2f \pm %.2f$ ns" % (p["mu"], out.get("mu_err", np.nan)))
            if np.isfinite(fw):
                ax.axvspan(xl, xh, color="0.6", alpha=0.18, lw=0)
                for xv in (xl, xh):
                    ax.axvline(xv, color="0.4", lw=1.0, ls=":")
                yhalf = 0.5 * (p["sig_yield"] * tf.emg_pdf(np.array([xpk]), p["mu"], p["lambd"], p["sigma"],
                                                            (x0, x1))[0] * SAMPLE_NS)
                yhalf += (np.interp(xpk, xf, bkg) if has_bkg else 0.0)
                ax.annotate("", xy=(xl, yhalf), xytext=(xh, yhalf),
                            arrowprops=dict(arrowstyle="<->", color="0.3", lw=1.4))
            fw_label = r"FWHM $= %.2f$ ns" % fw if np.isfinite(fw) else "FWHM = N/A"
            ax.plot([], [], " ", label=fw_label)
            ax.plot([], [], " ", label=r"$N_{\mathrm{signal}} = %.0f \pm %.0f$" % (
                p["sig_yield"], out.get("sig_err", np.nan)))
            if has_bkg:
                ax.plot([], [], " ", label=r"$N_{\mathrm{bkg}} = %.0f \pm %.0f$" % (
                    p["bkg_yield"], out.get("bkg_err", np.nan)))
            ax.plot([], [], " ", label=r"$\sigma = %.2f$ ns, $\lambda = %.3f$ /ns" % (p["sigma"], p["lambd"]))
            ax.set_yscale("log")
            pos = counts[counts > 0]
            ymin = max(0.3, 0.5 * float(pos.min())) if pos.size else 0.3
            ax.set_ylim(ymin, max(float(np.nanmax(tot)), float(counts.max()) if counts.size else 1) * 3)
            ax.set_ylabel("Events / 2 ns")
            ax.legend(loc="upper right", fontsize=9, framealpha=0.9)
            ax.set_title((plotname or "timing").strip(), fontsize=10)
            axp.axhline(0, color="k", lw=0.8, ls="--")
            axp.plot(centers, pull, "ok", ms=3)
            lim = max(5.0, float(np.nanmax(np.abs(pull))) * 1.1) if np.isfinite(pull).any() else 5.0
            axp.set_ylim(-lim, lim)
            axp.set_ylabel("Pull")
            axp.set_xlabel(r"$t_{\mathrm{PMT}} - t_{\mathrm{trigger}}$ (ns)")
            axp.set_xlim(x0, x1)
            target = self.fig_dir / "{}.png".format((plotname or "fit").strip())
            fig.savefig(str(target), bbox_inches="tight")
            plt.close(fig)
        log.info("[PLOT] saved %s  (mu %.2f ns, FWHM(signal) %.2f ns)", target, p["mu"], fw)

    tf.TimingEMGFitter._make_plot = make_plot
    have = {k for k, _ in tf.TimingEMGFitter.FIT_FIELD_MAP}
    tf.TimingEMGFitter.FIT_FIELD_MAP = list(tf.TimingEMGFitter.FIT_FIELD_MAP) + [
        (k, k) for k in ("FWHM_signal", "FWHM_signal_lo", "FWHM_signal_hi") if k not in have]


# ----------------------------------------------------------------------------- timing background
BKG_MODELS = ("linear", "const", "none")


def install_timing_bkg(pmt="const", sipm="linear"):
    """Background shape of the timing fit (UAP fit itself, only its configuration is changed):
         linear : UAP default, 1st-order Chebyshev  bkg_yield * (1 + coeff * x') / width
         const  : flat background (coeff fixed to 0)
         none   : no background term (signal EMG only)
       pmt for the PMT fit, sipm for the SiPM fit (plotname sipm_*)."""
    import copy
    from uap.fit import emg_timing_offset_fit as tf

    for m in (pmt, sipm):
        if m not in BKG_MODELS:
            raise ValueError("timing background must be one of {}".format(BKG_MODELS))
    original = tf.TimingEMGFitter._fit_emg

    def fit_emg(self, request):
        model = sipm if (request.plotname or "").startswith("sipm") else pmt
        if model == "linear":
            out = original(self, request)
            out["bkg_model"] = model
            return out
        saved_cfg, saved_expl = self.fit_config, self._explicit_config
        cfg = copy.deepcopy(saved_cfg)
        fixed = cfg["constraints"].setdefault("fixed", {})
        fixed.pop("coeff", None)
        if model == "const":
            cfg["model"]["background"] = True
            fixed["coeff"] = 0.0
        else:                                         # none
            cfg["model"]["background"] = False
            for sec in ("bounds", "priors"):
                for k in ("bkg_yield", "coeff"):
                    cfg["constraints"].get(sec, {}).pop(k, None)
        self.fit_config, self._explicit_config = cfg, True
        try:
            out = original(self, request)
        finally:
            self.fit_config, self._explicit_config = saved_cfg, saved_expl
        out["bkg_model"] = model
        return out

    tf.TimingEMGFitter._fit_emg = fit_emg
    have = {k for k, _ in tf.TimingEMGFitter.FIT_FIELD_MAP}
    if "bkg_model" not in have:
        tf.TimingEMGFitter.FIT_FIELD_MAP = list(tf.TimingEMGFitter.FIT_FIELD_MAP) + [("bkg_model", "bkg_model")]
    log.info("[TIMING BKG] PMT: %s   SiPM: %s", pmt, sipm)
