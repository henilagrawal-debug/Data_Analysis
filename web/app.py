"""
app.py - Flask backend for ArduPilot Log Viewer (per-session isolation).

Each browser session gets its own state (log data, derived parameters,
saved derivatives).  The master saved_derivatives.json is used as a
template for new sessions.  Per-user data is stored under user_data/<sid>/.

API endpoints:
  POST /api/upload           — Upload .bin file, parse, return parameter tree
  POST /api/plot             — Evaluate expressions, return time+values JSON
  POST /api/create_derived   — Create a named derived parameter
  POST /api/derivative       — Compute d/dt with spectral analysis
  POST /api/filter           — Apply FFT filter (lowpass/highpass/bandpass)
  POST /api/analyze_spectrum — Return spectral analysis for a signal
  POST /api/segment_analysis — Compute stats for a time segment
  POST /api/calc_distance    — Calculate GPS track distance
  GET  /api/flight_path      — Return GPS lat/lng/mode data
  GET  /api/modes            — Return mode transition intervals
  GET  /api/param_tree       — Return collapsible parameter tree
  GET  /api/saved_derivatives          — List saved derivatives
  POST /api/saved_derivatives/save     — Save a derivative to JSON
  POST /api/saved_derivatives/delete   — Delete a saved derivative
  POST /api/saved_derivatives/override — Override a saved derivative expression
"""

import json
import os
import re as _re
import tempfile
import uuid
from pathlib import Path

import numpy as np
from flask import Flask, request, jsonify, send_from_directory, session

from parse_bin_log import parse_bin_log
from expression_eval import eval_expression
from filters import (
    fft_lowpass, fft_highpass, fft_bandpass,
    analyze_spectrum, compute_dominant_freq, compute_max_signal_freq,
)

app = Flask(__name__, static_folder='static', static_url_path='')
app.secret_key = os.environ.get('SECRET_KEY', 'ardupilot-log-viewer-dev-key')

# ======================== Per-Session State ========================
_DEFAULT_DERIV_FILE = str(Path(__file__).parent / 'saved_derivatives.json')
_USER_DATA_DIR = str(Path(__file__).parent / 'user_data')
_default_derivs = {}   # template loaded at startup from saved_derivatives.json
_sessions = {}          # sid -> per-user state dict

# ArduPilot flight mode map
MODE_MAP = {
    0: 'MANUAL', 1: 'CIRCLE', 2: 'STABILIZE', 3: 'TRAINING',
    4: 'ACRO', 5: 'FBWA', 6: 'FBWB', 7: 'CRUISE', 8: 'AUTOTUNE',
    9: 'LAND', 10: 'AUTO', 11: 'RTL', 12: 'LOITER', 13: 'TAKEOFF',
    14: 'AVOID_ADSB', 15: 'GUIDED', 16: 'POSHOLD',
    17: 'QSTABILIZE', 18: 'QHOVER', 19: 'QLOITER', 20: 'QLAND',
    21: 'QRTL', 22: 'QAUTOTUNE', 23: 'QACRO', 24: 'THERMAL',
    25: 'SYSTEMID', 26: 'AUTOROTATE',
}


# ======================== Session helpers ========================

def _get_state():
    """Return the per-session state dict, creating one if needed."""
    sid = session.get('sid')
    if not sid:
        sid = str(uuid.uuid4())
        session['sid'] = sid
    if sid not in _sessions:
        _sessions[sid] = {
            'log_data': None,
            'derived_data': {},
            'filename': '',
            'saved_deriv_file': _user_deriv_path(sid),
            'saved_deriv_names': [],
        }
        _init_session_derivs(_sessions[sid], sid)
    return _sessions[sid]


def _user_deriv_path(sid):
    """Return the saved-derivatives JSON path for a given session."""
    return os.path.join(_USER_DATA_DIR, sid, 'saved_derivatives.json')


def _init_session_derivs(st, sid):
    """Seed a new session with the default saved derivatives."""
    for nm, entry in _default_derivs.items():
        st['derived_data'][nm] = {
            'values': np.array([]), 'time': np.array([]),
            'expr': entry.get('expr', ''),
            'recipe': entry.get('recipe', {'type': 'expr', 'input': entry.get('expr', '')}),
        }
        if nm not in st['saved_deriv_names']:
            st['saved_deriv_names'].append(nm)
    user_dir = os.path.join(_USER_DATA_DIR, sid)
    os.makedirs(user_dir, exist_ok=True)
    _write_saved_derivs(st)


# ======================== Utility ========================

def _arr(a, max_points=50000):
    """Convert numpy array to plain list, downsampling if too large."""
    a = np.asarray(a, dtype=np.float64).ravel()
    a = np.where(np.isfinite(a), a, 0.0)
    if len(a) > max_points:
        idx = np.linspace(0, len(a) - 1, max_points, dtype=int)
        a = a[idx]
    return a.tolist()


def _load_default_derivatives():
    """Load default saved derivative definitions from the master JSON file."""
    global _default_derivs
    if not os.path.isfile(_DEFAULT_DERIV_FILE):
        return
    try:
        with open(_DEFAULT_DERIV_FILE, 'r') as f:
            saved = json.load(f)
        if not isinstance(saved, dict):
            return
        for nm, entry in saved.items():
            if isinstance(entry, dict) and 'recipe' in entry:
                _default_derivs[nm] = {
                    'expr': entry.get('expr', ''),
                    'recipe': entry['recipe'],
                }
            else:
                expr = entry if isinstance(entry, str) else str(entry)
                _default_derivs[nm] = {
                    'expr': expr,
                    'recipe': _parse_legacy_expr(expr),
                }
        print(f"Loaded {len(saved)} default saved derivative(s)")
    except Exception as e:
        print(f"Warning: could not load saved derivatives: {e}")


def _write_saved_derivs(st):
    """Write saved derivatives to JSON with recipes."""
    save_obj = {}
    for nm in st['saved_deriv_names']:
        if nm in st['derived_data']:
            d = st['derived_data'][nm]
            save_obj[nm] = {
                'expr': d.get('expr', ''),
                'recipe': d.get('recipe', {'type': 'expr', 'input': d.get('expr', '')}),
            }
    fpath = st['saved_deriv_file']
    os.makedirs(os.path.dirname(fpath), exist_ok=True)
    with open(fpath, 'w') as f:
        json.dump(save_obj, f, indent=2)


def _parse_legacy_expr(expr_str):
    """Parse legacy expression strings into recipe dicts."""
    m = _re.match(r'^lpf\((.+),\s*([\d.]+)Hz\)$', expr_str)
    if m:
        return {'type': 'filter', 'filtType': 'lowpass',
                'input': m.group(1).strip(), 'cutoffHz': float(m.group(2))}
    m = _re.match(r'^hpf\((.+),\s*([\d.]+)Hz\)$', expr_str)
    if m:
        return {'type': 'filter', 'filtType': 'highpass',
                'input': m.group(1).strip(), 'cutoffHz': float(m.group(2))}
    m = _re.match(r'^bpf\((.+),\s*([\d.]+)-([\d.]+)Hz\)$', expr_str)
    if m:
        return {'type': 'filter', 'filtType': 'bandpass',
                'input': m.group(1).strip(),
                'loHz': float(m.group(2)), 'hiHz': float(m.group(3))}
    m = _re.match(r'^d\((.+)\)/dt\s*\[lpf=([\d.]+)Hz\]$', expr_str)
    if m:
        return {'type': 'derivative', 'input': m.group(1).strip(),
                'cutoffHz': float(m.group(2))}
    return {'type': 'expr', 'input': expr_str}


def _recompute_derived(nm, st):
    """Recompute a derived parameter using its stored recipe."""
    d = st['derived_data'][nm]
    recipe = d.get('recipe')
    ld = st['log_data']
    dd = st['derived_data']

    if recipe is None:
        vals, tvec = eval_expression(d['expr'], ld, dd)
        st['derived_data'][nm]['values'] = vals
        st['derived_data'][nm]['time'] = tvec
        return

    rtype = recipe.get('type', 'expr')

    if rtype == 'expr':
        vals, tvec = eval_expression(recipe['input'], ld, dd)
        st['derived_data'][nm]['values'] = vals
        st['derived_data'][nm]['time'] = tvec

    elif rtype == 'derivative':
        vals, tvec = eval_expression(recipe['input'], ld, dd)
        dt = np.median(np.diff(tvec))
        if dt <= 0:
            dt = 1e-6
        fs = 1.0 / dt
        cutoff = recipe.get('cutoffHz', fs / 10)
        if cutoff <= 0:
            cutoff = fs / 10
        smoothed = fft_lowpass(vals, fs, cutoff)
        dt_vec = np.gradient(tvec)
        dt_vec[dt_vec == 0] = 1e-6
        dvdt = np.gradient(smoothed) / dt_vec
        st['derived_data'][nm]['values'] = dvdt
        st['derived_data'][nm]['time'] = tvec

    elif rtype == 'filter':
        vals, tvec = eval_expression(recipe['input'], ld, dd)
        dt = np.median(np.diff(tvec))
        if dt <= 0:
            dt = 1e-6
        fs = 1.0 / dt
        ft = recipe.get('filtType', 'lowpass')
        if ft == 'lowpass':
            filtered = fft_lowpass(vals, fs, recipe['cutoffHz'])
        elif ft == 'highpass':
            filtered = fft_highpass(vals, fs, recipe['cutoffHz'])
        elif ft == 'bandpass':
            filtered = fft_bandpass(vals, fs, recipe['loHz'], recipe['hiHz'])
        else:
            raise ValueError(f"Unknown filter type: {ft}")
        st['derived_data'][nm]['values'] = filtered
        st['derived_data'][nm]['time'] = tvec

    else:
        raise ValueError(f"Unknown recipe type: {rtype}")


def _recompute_all_saved(st):
    """Recompute all saved derivatives in dependency order."""
    dd = st['derived_data']
    names = list(dd.keys())

    def dep_order(nm):
        d = dd[nm]
        inp = ''
        if d.get('recipe') and 'input' in d['recipe']:
            inp = d['recipe']['input']
        elif d.get('expr'):
            inp = d['expr']
        return 1 if 'DERIVED' in inp else 0

    names.sort(key=dep_order)
    for nm in names:
        try:
            _recompute_derived(nm, st)
        except Exception as e:
            print(f"Warning: saved deriv '{nm}' failed: {e}")


def _build_param_tree(st):
    """Build hierarchical parameter tree for the frontend."""
    tree = []
    ld = st['log_data']
    if ld is None:
        return tree

    for msg in sorted(ld.keys()):
        fields = sorted(ld[msg].keys())
        tree.append({
            'name': msg,
            'fields': [{'name': f, 'ref': f'{msg}.{f}'} for f in fields],
        })

    dd = st['derived_data']
    if dd:
        d_fields = []
        for nm in sorted(dd.keys()):
            d_fields.append({'name': nm, 'ref': f'DERIVED.{nm}'})
        tree.append({'name': 'DERIVED', 'fields': d_fields})

    return tree


def _build_derived_list(st):
    """Build derived params list with saved status."""
    result = []
    dd = st['derived_data']
    for nm in sorted(dd.keys()):
        d = dd[nm]
        result.append({
            'name': nm,
            'expr': d.get('expr', ''),
            'saved': nm in st['saved_deriv_names'],
            'samples': len(d.get('values', [])),
        })
    return result


# ======================== ROUTES ========================

@app.route('/')
def index():
    return send_from_directory('static', 'index.html')


@app.route('/api/upload', methods=['POST'])
def upload_file():
    if 'file' not in request.files:
        return jsonify(error='No file provided'), 400
    f = request.files['file']
    if not f.filename:
        return jsonify(error='No file selected'), 400

    st = _get_state()

    suffix = Path(f.filename).suffix
    with tempfile.NamedTemporaryFile(delete=False, suffix=suffix) as tmp:
        f.save(tmp.name)
        tmp_path = tmp.name

    try:
        log_data = parse_bin_log(tmp_path)
    except Exception as e:
        os.unlink(tmp_path)
        return jsonify(error=f'Parse error: {e}'), 400
    finally:
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)

    st['log_data'] = log_data
    st['filename'] = f.filename

    if st['derived_data']:
        _recompute_all_saved(st)

    return jsonify(
        filename=f.filename,
        param_tree=_build_param_tree(st),
        derived_list=_build_derived_list(st),
    )


@app.route('/api/param_tree')
def get_param_tree():
    st = _get_state()
    return jsonify(param_tree=_build_param_tree(st))


@app.route('/api/plot', methods=['POST'])
def plot_data():
    body = request.get_json(force=True)
    expressions = body.get('expressions', [])
    if not expressions:
        return jsonify(error='No expressions'), 400
    st = _get_state()
    if st['log_data'] is None:
        return jsonify(error='No log loaded'), 400

    traces = []
    for expr in expressions:
        try:
            vals, tvec = eval_expression(expr, st['log_data'], st['derived_data'])
            vals = np.asarray(vals, dtype=np.float64).ravel()
            tvec = np.asarray(tvec, dtype=np.float64).ravel()
            mn, mx, avg = float(np.nanmin(vals)), float(np.nanmax(vals)), float(np.nanmean(vals))
            traces.append({
                'expr': expr,
                'time': _arr(tvec),
                'values': _arr(vals),
                'stats': {'min': mn, 'max': mx, 'mean': avg},
            })
        except Exception as e:
            traces.append({'expr': expr, 'error': str(e)})

    return jsonify(traces=traces)


@app.route('/api/create_derived', methods=['POST'])
def create_derived():
    body = request.get_json(force=True)
    name = body.get('name', '').strip()
    expr = body.get('expr', '').strip()
    if not name or not expr:
        return jsonify(error='Name and expression required'), 400
    st = _get_state()
    if st['log_data'] is None:
        return jsonify(error='No log loaded'), 400

    name = _re.sub(r'[^A-Za-z0-9_]', '_', name)

    try:
        vals, tvec = eval_expression(expr, st['log_data'], st['derived_data'])
    except Exception as e:
        return jsonify(error=f'Expression error: {e}'), 400

    recipe = {'type': 'expr', 'input': expr}
    st['derived_data'][name] = {
        'values': vals, 'time': tvec, 'expr': expr, 'recipe': recipe,
    }

    return jsonify(
        name=name, expr=expr, samples=len(vals),
        param_tree=_build_param_tree(st),
        derived_list=_build_derived_list(st),
    )


@app.route('/api/derivative', methods=['POST'])
def create_derivative():
    body = request.get_json(force=True)
    input_expr = body.get('input', '').strip()
    output_name = body.get('name', '').strip()
    cutoff_hz = body.get('cutoffHz')

    if not input_expr or not output_name:
        return jsonify(error='Input expression and output name required'), 400
    st = _get_state()
    if st['log_data'] is None:
        return jsonify(error='No log loaded'), 400

    output_name = _re.sub(r'[^A-Za-z0-9_]', '_', output_name)

    try:
        vals, tvec = eval_expression(input_expr, st['log_data'], st['derived_data'])
    except Exception as e:
        return jsonify(error=f'Expression error: {e}'), 400

    if len(vals) < 8:
        return jsonify(error='Not enough data points'), 400

    dt = float(np.median(np.diff(tvec)))
    if dt <= 0:
        dt = 1e-6
    fs = 1.0 / dt

    if cutoff_hz is None:
        spec = analyze_spectrum(vals, fs)
        return jsonify(
            step='recommend', spectrum=spec,
            input=input_expr, name=output_name, fs=fs,
        )

    cutoff_hz = float(cutoff_hz)
    if cutoff_hz <= 0:
        return jsonify(error='Cutoff must be positive'), 400

    smoothed = fft_lowpass(vals, fs, cutoff_hz)
    dt_vec = np.gradient(tvec)
    dt_vec[dt_vec == 0] = 1e-6
    dvdt = np.gradient(smoothed) / dt_vec

    deriv_expr = f'd({input_expr})/dt [lpf={cutoff_hz:.1f}Hz]'
    recipe = {'type': 'derivative', 'input': input_expr, 'cutoffHz': cutoff_hz}
    st['derived_data'][output_name] = {
        'values': dvdt, 'time': tvec, 'expr': deriv_expr, 'recipe': recipe,
    }

    return jsonify(
        name=output_name, expr=deriv_expr, samples=len(dvdt),
        param_tree=_build_param_tree(st),
        derived_list=_build_derived_list(st),
    )


@app.route('/api/filter', methods=['POST'])
def filter_signal():
    body = request.get_json(force=True)
    input_expr = body.get('input', '').strip()
    output_name = body.get('name', '').strip()
    filt_type = body.get('filtType', 'lowpass').strip().lower()
    cutoff_hz = body.get('cutoffHz')
    lo_hz = body.get('loHz')
    hi_hz = body.get('hiHz')

    if not input_expr or not output_name:
        return jsonify(error='Input and output name required'), 400
    st = _get_state()
    if st['log_data'] is None:
        return jsonify(error='No log loaded'), 400

    output_name = _re.sub(r'[^A-Za-z0-9_]', '_', output_name)

    try:
        vals, tvec = eval_expression(input_expr, st['log_data'], st['derived_data'])
    except Exception as e:
        return jsonify(error=f'Expression error: {e}'), 400

    if len(vals) < 8:
        return jsonify(error='Not enough data points'), 400

    dt = float(np.median(np.diff(tvec)))
    if dt <= 0:
        dt = 1e-6
    fs = 1.0 / dt

    if cutoff_hz is None and filt_type != 'bandpass':
        spec = analyze_spectrum(vals, fs)
        return jsonify(step='recommend', spectrum=spec, input=input_expr,
                       name=output_name, filtType=filt_type, fs=fs)

    if filt_type == 'lowpass':
        cutoff_hz = float(cutoff_hz)
        filtered = fft_lowpass(vals, fs, cutoff_hz)
        filt_desc = f'lpf({input_expr}, {cutoff_hz:.1f}Hz)'
        recipe = {'type': 'filter', 'filtType': 'lowpass', 'input': input_expr,
                  'cutoffHz': cutoff_hz}
    elif filt_type == 'highpass':
        cutoff_hz = float(cutoff_hz)
        filtered = fft_highpass(vals, fs, cutoff_hz)
        filt_desc = f'hpf({input_expr}, {cutoff_hz:.1f}Hz)'
        recipe = {'type': 'filter', 'filtType': 'highpass', 'input': input_expr,
                  'cutoffHz': cutoff_hz}
    elif filt_type == 'bandpass':
        if lo_hz is None or hi_hz is None:
            spec = analyze_spectrum(vals, fs)
            return jsonify(step='recommend', spectrum=spec, input=input_expr,
                           name=output_name, filtType=filt_type, fs=fs)
        lo_hz, hi_hz = float(lo_hz), float(hi_hz)
        filtered = fft_bandpass(vals, fs, lo_hz, hi_hz)
        filt_desc = f'bpf({input_expr}, {lo_hz:.1f}-{hi_hz:.1f}Hz)'
        recipe = {'type': 'filter', 'filtType': 'bandpass', 'input': input_expr,
                  'loHz': lo_hz, 'hiHz': hi_hz}
    else:
        return jsonify(error=f'Unknown filter type: {filt_type}'), 400

    st['derived_data'][output_name] = {
        'values': filtered, 'time': tvec, 'expr': filt_desc, 'recipe': recipe,
    }

    return jsonify(
        name=output_name, expr=filt_desc, samples=len(filtered),
        param_tree=_build_param_tree(st),
        derived_list=_build_derived_list(st),
    )


@app.route('/api/analyze_spectrum', methods=['POST'])
def api_analyze_spectrum():
    body = request.get_json(force=True)
    expr = body.get('expr', '').strip()
    if not expr:
        return jsonify(error='Expression required'), 400
    st = _get_state()
    if st['log_data'] is None:
        return jsonify(error='No log loaded'), 400

    try:
        vals, tvec = eval_expression(expr, st['log_data'], st['derived_data'])
    except Exception as e:
        return jsonify(error=str(e)), 400

    dt = float(np.median(np.diff(tvec)))
    if dt <= 0:
        dt = 1e-6
    fs = 1.0 / dt

    spec = analyze_spectrum(vals, fs)
    return jsonify(spectrum=spec)


@app.route('/api/segment_analysis', methods=['POST'])
def segment_analysis():
    body = request.get_json(force=True)
    t0 = float(body.get('t0', 0))
    t1 = float(body.get('t1', 0))
    expressions = body.get('expressions', [])

    if t1 <= t0:
        return jsonify(error='Invalid time range'), 400
    st = _get_state()
    if st['log_data'] is None:
        return jsonify(error='No log loaded'), 400

    mode_str = 'N/A'
    ld = st['log_data']
    if 'MODE' in ld and 'Mode' in ld['MODE'] and 'TimeUS' in ld['MODE']:
        mode_time = ld['MODE']['TimeUS'] / 1e6
        mode_codes = ld['MODE']['Mode']
        idx_before = np.where(mode_time <= t0)[0]
        idx_in_range = np.where((mode_time >= t0) & (mode_time <= t1))[0]
        relevant = np.unique(np.concatenate([
            idx_before[-1:] if len(idx_before) > 0 else [],
            idx_in_range
        ]).astype(int))
        if len(relevant) > 0:
            unique_codes = np.unique(mode_codes[relevant])
            names = [MODE_MAP.get(int(c), f'Mode{int(c)}') for c in unique_codes]
            mode_str = ', '.join(names)

    results = []
    for expr in expressions:
        try:
            vals, tvec = eval_expression(expr, ld, st['derived_data'])
            mask = (tvec >= t0) & (tvec <= t1)
            v_seg = vals[mask]
            t_seg = tvec[mask]

            if len(v_seg) < 2:
                continue

            sorted_seg = np.sort(v_seg)
            p10 = sorted_seg[max(0, int(round(0.10 * len(sorted_seg))) - 1)]
            p90 = sorted_seg[min(len(sorted_seg) - 1, int(round(0.90 * len(sorted_seg))) - 1)]
            dev = v_seg - np.mean(v_seg)

            results.append({
                'param': expr,
                'min': float(np.min(v_seg)),
                'max': float(np.max(v_seg)),
                'mean': float(np.mean(v_seg)),
                'usual_low': float(p10),
                'usual_high': float(p90),
                'peak_above': float(np.max(dev)),
                'peak_below': float(np.min(dev)),
                'main_osc_freq': float(compute_dominant_freq(t_seg, v_seg)),
                'max_signal_freq': float(compute_max_signal_freq(t_seg, v_seg)),
            })
        except Exception:
            continue

    return jsonify(t0=t0, t1=t1, modes=mode_str, results=results)


@app.route('/api/calc_distance', methods=['POST'])
def calc_distance():
    """Calculate horizontal distance along a GPS track between two times."""
    body = request.get_json(force=True)
    lat_param = body.get('lat_param', '').strip()
    lng_param = body.get('lng_param', '').strip()
    t1 = body.get('t1')
    t2 = body.get('t2')

    if not lat_param or not lng_param:
        return jsonify(error='Lat/Lng parameters required'), 400
    if t1 is None or t2 is None or float(t2) <= float(t1):
        return jsonify(error='Invalid time range'), 400
    st = _get_state()
    if st['log_data'] is None:
        return jsonify(error='No log loaded'), 400

    t1, t2 = float(t1), float(t2)

    try:
        lat_vals, lat_time = eval_expression(lat_param, st['log_data'], st['derived_data'])
        lng_vals, lng_time = eval_expression(lng_param, st['log_data'], st['derived_data'])
    except Exception as e:
        return jsonify(error=f'Could not evaluate parameters: {e}'), 400

    lat_vals = np.asarray(lat_vals, dtype=np.float64).ravel()
    lat_time = np.asarray(lat_time, dtype=np.float64).ravel()
    lng_vals = np.asarray(lng_vals, dtype=np.float64).ravel()
    lng_time = np.asarray(lng_time, dtype=np.float64).ravel()

    lng_resampled = np.zeros_like(lat_time)
    for i in range(len(lat_time)):
        idx = np.argmin(np.abs(lng_time - lat_time[i]))
        lng_resampled[i] = lng_vals[idx]

    mask = (lat_time >= t1) & (lat_time <= t2)
    lat_seg = lat_vals[mask]
    lng_seg = lng_resampled[mask]
    t_seg = lat_time[mask]

    if len(lat_seg) < 2:
        return jsonify(error='Not enough data points in the selected time range'), 400

    valid = (lat_seg != 0) & (lng_seg != 0)
    lat_seg = lat_seg[valid]
    lng_seg = lng_seg[valid]
    t_seg = t_seg[valid]

    if len(lat_seg) < 2:
        return jsonify(error='Not enough valid GPS points in range'), 400

    R = 6371000.0
    total_dist = 0.0
    for i in range(1, len(lat_seg)):
        d_lat = np.radians(lat_seg[i] - lat_seg[i - 1])
        d_lng = np.radians(lng_seg[i] - lng_seg[i - 1])
        a = (np.sin(d_lat / 2) ** 2 +
             np.cos(np.radians(lat_seg[i - 1])) * np.cos(np.radians(lat_seg[i])) *
             np.sin(d_lng / 2) ** 2)
        total_dist += R * 2 * np.arctan2(np.sqrt(a), np.sqrt(1 - a))

    duration = float(t_seg[-1] - t_seg[0])
    avg_speed = total_dist / max(duration, 1e-9)

    dist_str = f'{total_dist / 1000:.2f} km' if total_dist >= 1000 else f'{total_dist:.1f} m'
    spd_str = f'{avg_speed * 3.6:.1f} km/h' if avg_speed >= 1000 / 3600 else f'{avg_speed:.2f} m/s'

    return jsonify(
        distance=dist_str, distance_m=total_dist,
        duration=duration, avg_speed=spd_str, avg_speed_ms=avg_speed,
        points=int(len(lat_seg)),
        t_start=float(t_seg[0]), t_end=float(t_seg[-1]),
    )


@app.route('/api/modes')
def get_modes():
    """Return mode transition intervals: [{t0, t1, code, name}]."""
    st = _get_state()
    ld = st['log_data']
    if ld is None:
        return jsonify(error='No log loaded'), 400
    if 'MODE' not in ld or 'Mode' not in ld['MODE'] or 'TimeUS' not in ld['MODE']:
        return jsonify(modes=[])

    mode_time = np.asarray(ld['MODE']['TimeUS'], dtype=np.float64) / 1e6
    mode_vals = np.asarray(ld['MODE']['Mode'], dtype=np.float64)

    t_max = 0.0
    for msg in ld:
        if 'TimeUS' in ld[msg]:
            tus = ld[msg]['TimeUS']
            if len(tus) > 0:
                t_max = max(t_max, float(np.max(tus)) / 1e6)

    intervals = []
    for i in range(len(mode_time)):
        t0 = float(mode_time[i])
        t1 = float(mode_time[i + 1]) if i + 1 < len(mode_time) else t_max
        code = int(mode_vals[i])
        name = MODE_MAP.get(code, f'Mode{code}')
        intervals.append({'t0': t0, 't1': t1, 'code': code, 'name': name})

    return jsonify(modes=intervals, mode_map={str(k): v for k, v in MODE_MAP.items()})


@app.route('/api/flight_path')
def flight_path():
    st = _get_state()
    ld = st['log_data']
    if ld is None:
        return jsonify(error='No log loaded'), 400

    gps_name = None
    for nm in ld:
        if 'Lat' in ld[nm] and 'Lng' in ld[nm]:
            gps_name = nm
            break

    if gps_name is None:
        return jsonify(error='No GPS data found'), 404

    lat = ld[gps_name]['Lat']
    lng = ld[gps_name]['Lng']
    valid = (lat != 0) & (lng != 0)
    lat, lng = lat[valid], lng[valid]

    alt = None
    if 'Alt' in ld[gps_name]:
        alt = ld[gps_name]['Alt'][valid]
    elif 'RAlt' in ld[gps_name]:
        alt = ld[gps_name]['RAlt'][valid]

    mode_codes = np.zeros(len(lat))
    if 'MODE' in ld and 'Mode' in ld['MODE'] and 'TimeUS' in ld['MODE']:
        if 'TimeUS' in ld[gps_name]:
            gps_time = ld[gps_name]['TimeUS'][valid]
            mode_time = ld['MODE']['TimeUS']
            mode_vals = ld['MODE']['Mode']
            for gi in range(len(gps_time)):
                idx = np.where(mode_time <= gps_time[gi])[0]
                if len(idx) > 0:
                    mode_codes[gi] = mode_vals[idx[-1]]

    gps_time_sec = None
    if 'TimeUS' in ld[gps_name]:
        gps_time_sec = ld[gps_name]['TimeUS'][valid] / 1e6

    result = {
        'lat': _arr(lat, 100000),
        'lng': _arr(lng, 100000),
        'mode_codes': _arr(mode_codes, 100000),
    }
    if alt is not None:
        result['alt'] = _arr(alt, 100000)
        result['max_alt'] = float(np.max(alt))
    if gps_time_sec is not None:
        result['time'] = _arr(gps_time_sec, 100000)

    result['mode_map'] = {str(k): v for k, v in MODE_MAP.items()}

    return jsonify(result)


# ======================== SAVED DERIVATIVES ========================

@app.route('/api/saved_derivatives')
def get_saved_derivatives():
    st = _get_state()
    return jsonify(derived_list=_build_derived_list(st))


@app.route('/api/saved_derivatives/save', methods=['POST'])
def save_derivative():
    body = request.get_json(force=True)
    name = body.get('name', '').strip()
    st = _get_state()
    if not name or name not in st['derived_data']:
        return jsonify(error='Unknown derived parameter'), 400

    if name not in st['saved_deriv_names']:
        st['saved_deriv_names'].append(name)
    _write_saved_derivs(st)
    return jsonify(derived_list=_build_derived_list(st))


@app.route('/api/saved_derivatives/delete', methods=['POST'])
def delete_saved_derivative():
    body = request.get_json(force=True)
    name = body.get('name', '').strip()
    st = _get_state()
    st['saved_deriv_names'] = [n for n in st['saved_deriv_names'] if n != name]
    _write_saved_derivs(st)
    return jsonify(derived_list=_build_derived_list(st))


@app.route('/api/saved_derivatives/override', methods=['POST'])
def override_saved_derivative():
    body = request.get_json(force=True)
    name = body.get('name', '').strip()
    new_expr = body.get('expr', '').strip()
    if not name or not new_expr:
        return jsonify(error='Name and expression required'), 400

    st = _get_state()

    if name not in st['derived_data']:
        st['derived_data'][name] = {
            'values': np.array([]), 'time': np.array([]),
            'expr': new_expr, 'recipe': {'type': 'expr', 'input': new_expr},
        }
    else:
        st['derived_data'][name]['expr'] = new_expr
        st['derived_data'][name]['recipe'] = {'type': 'expr', 'input': new_expr}
        st['derived_data'][name]['values'] = np.array([])
        st['derived_data'][name]['time'] = np.array([])

    if st['log_data'] is not None:
        try:
            _recompute_derived(name, st)
        except Exception as e:
            print(f"Warning: could not evaluate '{new_expr}': {e}")

    if name not in st['saved_deriv_names']:
        st['saved_deriv_names'].append(name)
    _write_saved_derivs(st)

    return jsonify(
        derived_list=_build_derived_list(st),
        param_tree=_build_param_tree(st),
    )


# ======================== STARTUP ========================

_load_default_derivatives()

if __name__ == '__main__':
    print("Starting ArduPilot Log Viewer on http://localhost:5000")
    app.run(host='0.0.0.0', port=5000, debug=False)
