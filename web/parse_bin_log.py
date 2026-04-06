"""
parseBinLog.py - ArduPilot DataFlash binary log parser.

Two-pass parser mirroring the MATLAB implementation:
  Pass 1: Scan for FMT messages, catalog all message positions.
  Pass 2: Preallocate and decode all messages into numpy arrays.
  Messages with an 'I' (instance) field are split: GPS_0, GPS_1, etc.

Usage:
    from parse_bin_log import parse_bin_log
    log_data = parse_bin_log('2026-04-02 09-23-59.bin')
    # log_data['GPS_0']['Spd'] -> numpy array
"""

import gc
import mmap
import struct
import re
import numpy as np
from pathlib import Path

# ---------- DataFlash format character -> (struct_fmt, byte_size, is_numeric) ----------
# Reference: ArduPilot/libraries/AP_Logger/LogStructure.h
_FMT_TABLE = {
    'b': ('b',  1, True),    # int8
    'B': ('B',  1, True),    # uint8
    'M': ('B',  1, True),    # flight mode (uint8)
    'h': ('h',  2, True),    # int16
    'H': ('H',  2, True),    # uint16
    'i': ('i',  4, True),    # int32
    'I': ('I',  4, True),    # uint32
    'f': ('f',  4, True),    # float32
    'd': ('d',  8, True),    # float64
    'n': ('4s', 4, False),   # char[4]
    'N': ('16s', 16, False), # char[16]
    'Z': ('64s', 64, False), # char[64]
    'c': ('h',  2, True),    # int16 * 0.01
    'C': ('H',  2, True),    # uint16 * 0.01
    'e': ('i',  4, True),    # int32 * 0.01
    'E': ('I',  4, True),    # uint32 * 0.01
    'L': ('i',  4, True),    # int32 * 1e-7 (lat/lng)
    'q': ('q',  8, True),    # int64
    'Q': ('Q',  8, True),    # uint64
    'a': ('32h', 64, False), # int16[32] array — treated as non-numeric for simplicity
}

# Scale factors for special format characters
_SCALE = {'c': 0.01, 'C': 0.01, 'e': 0.01, 'E': 0.01, 'L': 1e-7}

HDR1 = 0xA3
HDR2 = 0x95
FMT_TYPE = 128
FMT_LEN = 89

class _FmtDef:
    """Stores a parsed FMT definition for one message type."""
    __slots__ = ('name', 'fmt', 'labels', 'length',
                 'num_mask', 'num_labels', 'num_cols',
                 'struct_fmt', 'struct_size', 'scales',
                 'num_indices', 'num_scales')

    def __init__(self, name: str, fmt: str, labels: list[str], length: int):
        self.name = name
        self.fmt = fmt
        self.labels = labels
        self.length = length

        # Determine which columns are numeric
        self.num_mask = []
        self.num_labels = []
        for i, ch in enumerate(fmt):
            is_num = _FMT_TABLE.get(ch, (None, 1, False))[2]
            self.num_mask.append(is_num)
            if is_num and i < len(labels):
                self.num_labels.append(labels[i].strip())
        self.num_cols = len(self.num_labels)

        # Build a single struct format string for the payload
        parts = []
        scales = []
        for ch in fmt:
            entry = _FMT_TABLE.get(ch)
            if entry is None:
                parts.append('B')
                scales.append(1.0)
            else:
                parts.append(entry[0])
                scales.append(_SCALE.get(ch, 1.0))
        self.struct_fmt = '<' + ''.join(parts)
        self.struct_size = struct.calcsize(self.struct_fmt)
        self.scales = scales

        # Precompute indices and scales for numeric-only extraction
        # This maps from the flat unpacked tuple index to (output_col, scale)
        self.num_indices = []  # [(tuple_idx, scale), ...] for each numeric output col
        self.num_scales = []   # matching scales
        vi = 0
        num_col = 0
        for ci, ch in enumerate(fmt):
            entry = _FMT_TABLE.get(ch)
            if ch == 'a':
                vi += 32
            elif entry is None:
                vi += 1
            elif not entry[2]:
                vi += 1  # string field
            else:
                # numeric field
                if ci < len(self.num_mask) and self.num_mask[ci]:
                    self.num_indices.append(vi)
                    self.num_scales.append(scales[ci])
                    num_col += 1
                vi += 1


def _make_fmt_def():
    """Create the FMT definition for the FMT message itself."""
    return _FmtDef('FMT', 'BBnNZ',
                    ['Type', 'Length', 'Name', 'Format', 'Labels'],
                    FMT_LEN)


def _decode_payload(data: bytes, fmt_def: _FmtDef):
    """Decode a single message payload into a list of values.
    Returns (numeric_values_list, all_values_list) or (None, None) on failure.
    """
    if len(data) < fmt_def.struct_size:
        return None, None
    try:
        raw_vals = struct.unpack_from(fmt_def.struct_fmt, data)
    except struct.error:
        return None, None

    all_vals = []
    vi = 0
    for ci, ch in enumerate(fmt_def.fmt):
        entry = _FMT_TABLE.get(ch)
        if entry is None:
            all_vals.append(raw_vals[vi])
            vi += 1
            continue

        if ch == 'a':
            # int16[32] array — skip as one item
            arr = raw_vals[vi:vi+32]
            all_vals.append(arr)
            vi += 32
        elif not entry[2]:
            # String field
            val = raw_vals[vi]
            if isinstance(val, bytes):
                val = val.rstrip(b'\x00').decode('ascii', errors='replace').strip()
            all_vals.append(val)
            vi += 1
        else:
            val = float(raw_vals[vi]) * fmt_def.scales[ci]
            all_vals.append(val)
            vi += 1

    # Extract numeric-only columns
    num_vals = []
    for i, ch in enumerate(fmt_def.fmt):
        if i < len(fmt_def.num_mask) and fmt_def.num_mask[i]:
            if i < len(all_vals) and isinstance(all_vals[i], (int, float)):
                num_vals.append(all_vals[i])
            else:
                num_vals.append(0.0)

    return num_vals, all_vals


def parse_bin_log(filename: str) -> dict:
    """Parse an ArduPilot .bin log file.

    Returns:
        dict: Nested dict where log_data['MSG_NAME']['FieldName'] is a numpy float64 array.
              Instance-split messages become MSG_0, MSG_1, etc.
    """
    path = Path(filename)
    n_bytes = path.stat().st_size
    print(f"Loaded {filename} ({n_bytes / 1e6:.1f} MB)")

    # Memory-map the file to avoid loading it entirely into Python heap
    _fh = open(filename, 'rb')
    raw = mmap.mmap(_fh.fileno(), 0, access=mmap.ACCESS_READ)

    # Format table indexed by type (0-255)
    fmts: dict[int, _FmtDef] = {}
    fmts[FMT_TYPE] = _make_fmt_def()

    _HDR = b'\xa3\x95'

    # ===== Pass 1: Scan for FMT definitions and catalog messages =====
    msg_positions = []  # list of (position, type)
    pos = 0

    while True:
        idx = raw.find(_HDR, pos)
        if idx < 0 or idx + 2 >= n_bytes:
            break

        t = raw[idx + 2]

        if t not in fmts:
            pos = idx + 1
            continue

        fmt_def = fmts[t]
        if idx + fmt_def.length > n_bytes:
            break

        msg_positions.append((idx, t))

        # If FMT, parse it to learn about new message types
        if t == FMT_TYPE:
            payload = raw[idx + 3: idx + fmt_def.length]
            _, all_vals = _decode_payload(payload, fmt_def)
            if all_vals is not None and len(all_vals) >= 5:
                n_type = int(all_vals[0])
                n_len = int(all_vals[1])
                n_name = str(all_vals[2]).strip()
                n_fmt = str(all_vals[3]).strip()
                n_lbl = str(all_vals[4]).strip()
                if 0 <= n_type <= 255 and n_len > 2 and n_name:
                    labels = [l.strip() for l in n_lbl.split(',')]
                    fmts[n_type] = _FmtDef(n_name, n_fmt, labels, n_len)

        pos = idx + fmt_def.length

    print(f"Pass 1 complete: {len(msg_positions)} messages cataloged")

    # ===== Count messages per type =====
    type_counts: dict[int, int] = {}
    for _, t in msg_positions:
        type_counts[t] = type_counts.get(t, 0) + 1

    # ===== Pass 2: Preallocate and parse =====
    data_mats: dict[int, np.ndarray] = {}
    data_counts: dict[int, int] = {}

    for t, count in type_counts.items():
        if t == FMT_TYPE or t not in fmts:
            continue
        fmt_def = fmts[t]
        if fmt_def.num_cols > 0:
            data_mats[t] = np.zeros((count, fmt_def.num_cols), dtype=np.float32)
            data_counts[t] = 0

    for k, (p, t) in enumerate(msg_positions):
        if t == FMT_TYPE or t not in fmts:
            continue
        fmt_def = fmts[t]
        if fmt_def.num_cols == 0 or t not in data_mats:
            continue

        # Fast numeric-only extraction using precomputed indices
        payload = raw[p + 3: p + fmt_def.length]
        if len(payload) < fmt_def.struct_size:
            continue
        try:
            raw_vals = struct.unpack_from(fmt_def.struct_fmt, payload)
        except struct.error:
            continue

        row = data_counts[t]
        ni = fmt_def.num_indices
        ns = fmt_def.num_scales
        mat = data_mats[t]
        for c in range(len(ni)):
            mat[row, c] = raw_vals[ni[c]] * ns[c]
        data_counts[t] = row + 1

        if (k + 1) % 200000 == 0:
            print(f"  Parsed {k + 1} / {len(msg_positions)} messages...")

    print("Pass 2 complete: all messages parsed")

    # Free file mapping and intermediate data
    raw.close()
    _fh.close()
    del msg_positions
    gc.collect()

    # ===== Build output dict with named fields, split by instance =====
    log_data: dict[str, dict[str, np.ndarray]] = {}

    for t, fmt_def in fmts.items():
        if t == FMT_TYPE or t not in data_mats:
            continue
        count = data_counts.get(t, 0)
        if count == 0:
            continue

        mat = data_mats[t][:count]
        name = re.sub(r'[^A-Za-z0-9_]', '_', fmt_def.name)
        num_labels = fmt_def.num_labels

        # Check for instance field 'I'
        i_col = None
        for ci, lbl in enumerate(num_labels):
            if lbl == 'I':
                i_col = ci
                break

        is_instance = False
        if i_col is not None and mat.shape[0] > 0:
            i_vals = mat[:, i_col]
            instances = np.unique(i_vals)
            if (np.all(instances >= 0) and
                np.all(instances == np.round(instances)) and
                np.max(instances) < 16):
                is_instance = True

        if is_instance and len(instances) > 1:
            for inst in instances:
                mask = mat[:, i_col] == inst
                inst_name = f"{name}_{int(inst)}"
                log_data[inst_name] = {}
                for ci, lbl in enumerate(num_labels):
                    safe_lbl = re.sub(r'[^A-Za-z0-9_]', '_', lbl)
                    log_data[inst_name][safe_lbl] = mat[mask, ci].astype(np.float32)
        else:
            log_data[name] = {}
            for ci, lbl in enumerate(num_labels):
                safe_lbl = re.sub(r'[^A-Za-z0-9_]', '_', lbl)
                log_data[name][safe_lbl] = mat[:, ci].astype(np.float32)

    # Free preallocated arrays
    del data_mats
    gc.collect()

    print(f"Done. {len(log_data)} message types: {', '.join(sorted(log_data.keys()))}")
    return log_data


if __name__ == '__main__':
    import sys
    if len(sys.argv) > 1:
        data = parse_bin_log(sys.argv[1])
        for msg, fields in sorted(data.items()):
            n = len(next(iter(fields.values()))) if fields else 0
            print(f"  {msg}: {list(fields.keys())} ({n} rows)")
