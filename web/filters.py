"""
filters.py - FFT-based signal filtering and spectral analysis.

Provides:
  - fft_lowpass, fft_highpass, fft_bandpass (zero-phase, Hann-tapered)
  - analyze_spectrum: recommends filter type and cutoff from FFT
  - compute_dominant_freq: peak-counting oscillation frequency
  - compute_max_signal_freq: highest frequency above noise floor
"""

import numpy as np


# ======================== FFT FILTERS ========================

def fft_lowpass(sig: np.ndarray, fs: float, fc: float) -> np.ndarray:
    """Zero-phase FFT low-pass filter with Hann-tapered transition."""
    sig = np.asarray(sig, dtype=np.float64).ravel()
    n = len(sig)
    mu = np.mean(sig)
    sig = sig - mu

    Y = np.fft.fft(sig)
    freqs = np.fft.fftfreq(n, d=1.0 / fs)
    freqs_abs = np.abs(freqs)

    # Hann taper width = 10% of cutoff
    taper_w = max(fc * 0.1, fs / n)
    mask = np.ones(n)
    # Zero out above cutoff
    mask[freqs_abs > fc + taper_w] = 0.0
    # Taper zone
    taper_zone = (freqs_abs > fc) & (freqs_abs <= fc + taper_w)
    dist = freqs_abs[taper_zone] - fc
    mask[taper_zone] = 0.5 * (1.0 + np.cos(np.pi * dist / taper_w))

    Y *= mask
    return np.real(np.fft.ifft(Y)) + mu


def fft_highpass(sig: np.ndarray, fs: float, fc: float) -> np.ndarray:
    """Zero-phase FFT high-pass filter with Hann-tapered transition."""
    sig = np.asarray(sig, dtype=np.float64).ravel()
    n = len(sig)
    mu = np.mean(sig)
    sig = sig - mu

    Y = np.fft.fft(sig)
    freqs = np.fft.fftfreq(n, d=1.0 / fs)
    freqs_abs = np.abs(freqs)

    taper_w = max(fc * 0.1, fs / n)
    mask = np.ones(n)
    mask[freqs_abs < fc - taper_w] = 0.0
    taper_zone = (freqs_abs >= fc - taper_w) & (freqs_abs < fc)
    dist = fc - freqs_abs[taper_zone]
    mask[taper_zone] = 0.5 * (1.0 + np.cos(np.pi * dist / taper_w))

    # DC always zeroed for highpass
    mask[0] = 0.0

    Y *= mask
    return np.real(np.fft.ifft(Y))  # no DC add-back


def fft_bandpass(sig: np.ndarray, fs: float, f_low: float, f_high: float) -> np.ndarray:
    """Zero-phase FFT band-pass filter with Hann-tapered transitions."""
    sig = np.asarray(sig, dtype=np.float64).ravel()
    n = len(sig)
    mu = np.mean(sig)
    sig = sig - mu

    Y = np.fft.fft(sig)
    freqs = np.fft.fftfreq(n, d=1.0 / fs)
    freqs_abs = np.abs(freqs)

    taper_w = max((f_high - f_low) * 0.1, fs / n)
    mask = np.zeros(n)
    # Pass band
    mask[(freqs_abs >= f_low) & (freqs_abs <= f_high)] = 1.0
    # Taper at low edge
    taper_lo = (freqs_abs >= f_low - taper_w) & (freqs_abs < f_low)
    dist_lo = f_low - freqs_abs[taper_lo]
    mask[taper_lo] = 0.5 * (1.0 + np.cos(np.pi * dist_lo / taper_w))
    # Taper at high edge
    taper_hi = (freqs_abs > f_high) & (freqs_abs <= f_high + taper_w)
    dist_hi = freqs_abs[taper_hi] - f_high
    mask[taper_hi] = 0.5 * (1.0 + np.cos(np.pi * dist_hi / taper_w))

    Y *= mask
    return np.real(np.fft.ifft(Y))


# ======================== SPECTRAL ANALYSIS ========================

def analyze_spectrum(vals: np.ndarray, fs: float) -> dict:
    """Analyze FFT power spectrum and recommend filter settings.

    Returns dict with keys:
        rec_cutoff, rec_type, summary, fs, nyquist, peak_freq, peak_snr, f90, f99
    """
    vals = np.asarray(vals, dtype=np.float64).ravel()
    n = len(vals)
    sig = vals - np.mean(vals)

    Y = np.fft.fft(sig)
    P2 = np.abs(Y / n)
    P1 = P2[:n // 2 + 1].copy()
    P1[1:-1] *= 2.0
    freqs = np.arange(n // 2 + 1) * fs / n

    # Skip DC
    P1 = P1[1:]
    freqs = freqs[1:]

    f_nyq = fs / 2.0

    if len(P1) == 0 or np.all(P1 == 0):
        return {
            'rec_cutoff': fs / 10, 'rec_type': 'lowpass',
            'summary': 'Flat spectrum — defaulting to Fs/10.',
            'fs': fs, 'nyquist': f_nyq, 'peak_freq': 0, 'peak_snr': 0,
            'f90': 0, 'f99': 0,
        }

    power_sq = P1 ** 2
    cum_pow = np.cumsum(power_sq)
    total_pow = cum_pow[-1]
    if total_pow == 0:
        return {
            'rec_cutoff': fs / 10, 'rec_type': 'lowpass',
            'summary': 'Zero signal power — defaulting to Fs/10.',
            'fs': fs, 'nyquist': f_nyq, 'peak_freq': 0, 'peak_snr': 0,
            'f90': 0, 'f99': 0,
        }

    cum_frac = cum_pow / total_pow
    idx90 = np.searchsorted(cum_frac, 0.90)
    idx99 = np.searchsorted(cum_frac, 0.99)
    idx90 = min(idx90, len(freqs) - 1)
    idx99 = min(idx99, len(freqs) - 1)
    f90 = freqs[idx90]
    f99 = freqs[idx99]

    i_peak = np.argmax(P1)
    f_peak = freqs[i_peak]

    upper_q = P1[int(0.75 * len(P1)):]
    noise_floor = np.median(upper_q) if len(upper_q) > 0 else 1e-30
    if noise_floor == 0:
        noise_floor = 1e-30
    peak_snr = P1[i_peak] / noise_floor

    # Decide recommendation
    low_idx = np.searchsorted(freqs, f_nyq * 0.1)
    low_idx = min(low_idx, len(cum_frac) - 1)
    low_energy_frac = cum_frac[low_idx]

    if f_peak > f_nyq * 0.3 and low_energy_frac < 0.2:
        rec_type = 'highpass'
        rec_cutoff = round(f_peak * 0.8, 2)
    elif f_peak < f_nyq * 0.1 and peak_snr > 5:
        rec_type = 'lowpass'
        rec_cutoff = round(f90 * 1.2, 2)
    else:
        rec_type = 'lowpass'
        rec_cutoff = round(f90 * 1.2, 2)

    rec_cutoff = max(rec_cutoff, freqs[0])
    rec_cutoff = min(rec_cutoff, f_nyq * 0.95)

    summary = (
        f"Fs = {fs:.1f} Hz  |  Nyquist = {f_nyq:.1f} Hz\n"
        f"Peak frequency: {f_peak:.2f} Hz (SNR: {peak_snr:.1f}x over noise floor)\n"
        f"90% energy below: {f90:.2f} Hz\n"
        f"99% energy below: {f99:.2f} Hz"
    )

    return {
        'rec_cutoff': rec_cutoff, 'rec_type': rec_type, 'summary': summary,
        'fs': fs, 'nyquist': f_nyq, 'peak_freq': f_peak, 'peak_snr': peak_snr,
        'f90': f90, 'f99': f99,
    }


# ======================== FREQUENCY ESTIMATION ========================

def compute_dominant_freq(t_vec: np.ndarray, vals: np.ndarray) -> float:
    """Dominant oscillation frequency via smoothed peak counting. Returns Hz or 0."""
    t_vec = np.asarray(t_vec).ravel()
    vals = np.asarray(vals).ravel()
    n = len(vals)
    if n < 10:
        return 0.0

    duration = t_vec[-1] - t_vec[0]
    if duration <= 0:
        return 0.0

    dt = np.median(np.diff(t_vec))
    if dt <= 0:
        return 0.0

    # Smooth: moving-average ~5% of length
    win = max(3, min(51, 2 * int(n * 0.025) + 1))
    kernel = np.ones(win) / win
    smoothed = np.convolve(vals, kernel, mode='same')

    # Detrend
    smoothed = smoothed - np.polyval(np.polyfit(np.arange(n), smoothed, 1), np.arange(n))

    # Find peaks
    is_peak = np.zeros(n, dtype=bool)
    for k in range(1, n - 1):
        if smoothed[k] > smoothed[k - 1] and smoothed[k] > smoothed[k + 1]:
            is_peak[k] = True

    n_peaks = np.sum(is_peak)
    if n_peaks < 2:
        return 0.0

    peak_idx = np.where(is_peak)[0]
    peak_duration = t_vec[peak_idx[-1]] - t_vec[peak_idx[0]]
    if peak_duration > 0:
        return (n_peaks - 1) / peak_duration
    return 0.0


def compute_max_signal_freq(t_vec: np.ndarray, vals: np.ndarray) -> float:
    """Highest frequency with power above 3x noise floor. Returns Hz or 0."""
    t_vec = np.asarray(t_vec).ravel()
    vals = np.asarray(vals).ravel()
    n = len(vals)
    if n < 16:
        return 0.0

    dt = np.median(np.diff(t_vec))
    if dt <= 0:
        return 0.0
    fs = 1.0 / dt

    sig = vals - np.mean(vals)
    Y = np.fft.fft(sig)
    P = np.abs(Y / n)
    P1 = P[:n // 2 + 1].copy()
    P1[1:-1] *= 2.0
    freqs = np.arange(n // 2 + 1) * fs / n

    # Skip DC
    P1 = P1[1:]
    freqs = freqs[1:]
    if len(P1) == 0:
        return 0.0

    upper_q = P1[int(0.75 * len(P1)):]
    noise_floor = np.median(upper_q) if len(upper_q) > 0 else 0.0
    if noise_floor == 0:
        noise_floor = 1e-30

    threshold = 3.0 * noise_floor
    above_noise = np.where(P1 > threshold)[0]
    if len(above_noise) == 0:
        return 0.0

    return float(freqs[above_noise[-1]])
