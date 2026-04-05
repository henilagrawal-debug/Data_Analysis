"""
expression_eval.py - Safe expression evaluator for ArduPilot log parameters.

Evaluates mathematical expressions referencing MSG.Field or DERIVED.Name,
with automatic interpolation to a common time base (nearest-neighbour on
the slowest signal's timestamps).

All MATLAB element-wise operators (.*, ./, .^) are handled automatically.
Supports standard math: sin, cos, tan, asin, acos, atan, atan2, atand, cosd, sind,
abs, sqrt, log, log10, exp, pi.
"""

import re
import math
import numpy as np

# Safe math functions available in expressions
_SAFE_MATH = {
    'sin': np.sin, 'cos': np.cos, 'tan': np.tan,
    'asin': np.arcsin, 'acos': np.arccos, 'atan': np.arctan,
    'atan2': np.arctan2,
    'sind': lambda x: np.sin(np.radians(x)),
    'cosd': lambda x: np.cos(np.radians(x)),
    'tand': lambda x: np.tan(np.radians(x)),
    'atand': lambda x: np.degrees(np.arctan(x)),
    'abs': np.abs, 'sqrt': np.sqrt,
    'log': np.log, 'log10': np.log10, 'log2': np.log2,
    'exp': np.exp,
    'pi': np.pi,
    'min': np.minimum, 'max': np.maximum,
    'mean': np.mean,
}

# Regex to match MSG.Field references
_REF_PATTERN = re.compile(r'([A-Za-z_]\w*)\.(\w+)')
# Regex to match bracket notation: GPS[0].Spd -> GPS_0.Spd
_BRACKET_PATTERN = re.compile(r'(\w+)\[(\d+)\]')


def eval_expression(expr_str: str, log_data: dict, derived_data: dict | None = None):
    """Evaluate an expression against log data and derived parameters.

    Args:
        expr_str: Expression string, e.g. "GPS_0.Spd * 3.6"
        log_data: Dict from parse_bin_log (msg -> field -> numpy array)
        derived_data: Dict of derived params (name -> {'values': array, 'time': array, ...})

    Returns:
        (values: np.ndarray, time_vec: np.ndarray)

    Raises:
        ValueError: If expression is invalid or references unknown parameters.
    """
    if derived_data is None:
        derived_data = {}

    # Sanitize: keep printable ASCII
    expr_str = ''.join(c for c in expr_str if 32 <= ord(c) <= 126).strip()
    if not expr_str:
        raise ValueError("Empty expression")

    # Normalize bracket notation
    expr_str = _BRACKET_PATTERN.sub(r'\1_\2', expr_str)

    # Find all MSG.Field references
    all_tokens = _REF_PATTERN.findall(expr_str)
    if not all_tokens:
        raise ValueError(f"No parameter references found in: {expr_str}")

    # Unique references, sorted longest-first to avoid partial replacement
    seen = set()
    unique_refs = []
    unique_tokens = []
    for msg, fld in all_tokens:
        ref = f"{msg}.{fld}"
        if ref not in seen:
            seen.add(ref)
            unique_refs.append(ref)
            unique_tokens.append((msg, fld))

    unique_refs, unique_tokens = zip(*sorted(
        zip(unique_refs, unique_tokens),
        key=lambda x: -len(x[0])
    ))

    # Resolve data and time vectors
    var_data = []
    var_time = []
    eval_str = expr_str

    for i, (msg, fld) in enumerate(unique_tokens):
        ref = f"{msg}.{fld}"
        vn = f"_V{i}"

        if msg == 'DERIVED':
            if fld not in derived_data:
                raise ValueError(f"Unknown derived parameter: {fld}")
            d = derived_data[fld]
            var_data.append(np.asarray(d['values'], dtype=np.float64).ravel())
            var_time.append(np.asarray(d['time'], dtype=np.float64).ravel() if d.get('time') is not None else None)
        elif msg in log_data and fld in log_data[msg]:
            var_data.append(np.asarray(log_data[msg][fld], dtype=np.float64).ravel())
            if 'TimeUS' in log_data[msg]:
                var_time.append(np.asarray(log_data[msg]['TimeUS'], dtype=np.float64).ravel() / 1e6)
            elif 'TimeMS' in log_data[msg]:
                var_time.append(np.asarray(log_data[msg]['TimeMS'], dtype=np.float64).ravel() / 1e3)
            else:
                var_time.append(None)
        else:
            raise ValueError(f"Unknown parameter: {msg}.{fld}")

        eval_str = eval_str.replace(ref, vn)

    # Auto element-wise: ^ -> **, and ensure ** not duplicated
    eval_str = re.sub(r'(?<!\*)\^', '**', eval_str)

    # ---- Interpolation to common time vector ----
    has_time = [t is not None for t in var_time]

    if not any(has_time):
        min_len = min(len(d) for d in var_data)
        time_vec = np.arange(min_len, dtype=np.float64)
        aligned = {f"_V{i}": var_data[i][:min_len] for i in range(len(var_data))}
    elif sum(has_time) == 1 or len(var_data) == 1:
        min_len = min(len(d) for d in var_data)
        idx = next(i for i, h in enumerate(has_time) if h)
        time_vec = var_time[idx][:min_len]
        aligned = {f"_V{i}": var_data[i][:min_len] for i in range(len(var_data))}
    else:
        # Multiple references with time: use slowest signal's timestamps
        t_lens = [len(t) if t is not None else float('inf') for t in var_time]
        slow_idx = int(np.argmin(t_lens))
        time_vec = var_time[slow_idx]

        # Remove duplicate timestamps
        _, u_idx = np.unique(time_vec, return_index=True)
        u_idx = np.sort(u_idx)
        time_vec = time_vec[u_idx]

        # Clamp to overlapping range
        t_min, t_max = -np.inf, np.inf
        for i, t in enumerate(var_time):
            if t is not None and len(t) > 0:
                t_min = max(t_min, t[0])
                t_max = min(t_max, t[-1])
        if t_min > t_max:
            raise ValueError("Time ranges of parameters do not overlap.")

        mask = (time_vec >= t_min) & (time_vec <= t_max)
        time_vec = time_vec[mask]

        aligned = {}
        for i in range(len(var_data)):
            vn = f"_V{i}"
            if has_time[i] and i != slow_idx:
                t_other = var_time[i]
                _, u_other = np.unique(t_other, return_index=True)
                u_other = np.sort(u_other)
                t_uniq = t_other[u_other]
                d_uniq = var_data[i][u_other]
                near_idx = np.searchsorted(t_uniq, time_vec, side='left')
                near_idx = np.clip(near_idx, 0, len(t_uniq) - 1)
                # Check if previous index is closer
                prev_idx = np.clip(near_idx - 1, 0, len(t_uniq) - 1)
                use_prev = np.abs(t_uniq[prev_idx] - time_vec) < np.abs(t_uniq[near_idx] - time_vec)
                near_idx[use_prev] = prev_idx[use_prev]
                aligned[vn] = d_uniq[near_idx]
            else:
                d = var_data[slow_idx] if i == slow_idx else var_data[i]
                aligned[vn] = d[mask] if i == slow_idx else d[:len(time_vec)]

    # Build safe evaluation namespace
    ns = dict(_SAFE_MATH)
    ns.update(aligned)

    # Validate: no dangerous builtins access
    _validate_expr(eval_str)

    try:
        result = eval(eval_str, {"__builtins__": {}}, ns)  # noqa: S307
    except Exception as e:
        raise ValueError(f"Expression evaluation failed: {e}") from e

    result = np.asarray(result, dtype=np.float64).ravel()

    # Ensure result matches time_vec length
    if len(result) == 1:
        result = np.full_like(time_vec, result[0])
    elif len(result) != len(time_vec):
        min_len = min(len(result), len(time_vec))
        result = result[:min_len]
        time_vec = time_vec[:min_len]

    return result, time_vec


def _validate_expr(expr_str: str):
    """Basic safety check — reject obviously dangerous expressions."""
    forbidden = ['import', '__', 'exec', 'eval', 'open', 'compile',
                 'getattr', 'setattr', 'delattr', 'globals', 'locals',
                 'vars', 'dir', 'type', 'class', 'lambda']
    lower = expr_str.lower()
    for word in forbidden:
        if re.search(r'\b' + word + r'\b', lower):
            raise ValueError(f"Forbidden keyword in expression: {word}")
