// main.js — ArduPilot Log Viewer frontend logic
// All features: parameter tree, multi-trace plotting, crosshair, flight path,
// expressions, derived params, d/dt, filtering, segment analysis, saved derivatives manager.

'use strict';

// ======================== STATE ========================
const S = {
    activePlots: [],          // [{expr, color}]
    paramTree: [],            // from server
    derivedList: [],          // from server
    expandedGroups: new Set(),
    selectedFields: new Set(),
    filename: '',
    flightPath: null,         // cached from /api/flight_path
    plotColors: [
        '#3b82f6','#ef4444','#22c55e','#f59e0b','#a855f7',
        '#06b6d4','#ec4899','#84cc16','#f97316','#6366f1',
        '#14b8a6','#e879f9',
    ],
    colorIdx: 0,
};

function nextColor() {
    const c = S.plotColors[S.colorIdx % S.plotColors.length];
    S.colorIdx++;
    return c;
}

// ======================== HELPERS ========================
const $ = (sel) => document.querySelector(sel);
const $$ = (sel) => document.querySelectorAll(sel);

function showLoading() { $('#loadingOverlay').classList.add('active'); }
function hideLoading() { $('#loadingOverlay').classList.remove('active'); }

function toast(msg, ms = 3000) {
    const el = $('#toast');
    el.textContent = msg;
    el.classList.add('show');
    setTimeout(() => el.classList.remove('show'), ms);
}

async function api(url, opts = {}) {
    const res = await fetch(url, opts);
    const text = await res.text();
    let data;
    try {
        data = JSON.parse(text);
    } catch (_) {
        throw new Error(res.ok ? 'Empty server response' : `Server error (HTTP ${res.status}). File may be too large for free hosting.`);
    }
    if (!res.ok || data.error) {
        throw new Error(data.error || `HTTP ${res.status}`);
    }
    return data;
}

async function apiPost(url, body) {
    return api(url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
    });
}

// ======================== INIT ========================
document.addEventListener('DOMContentLoaded', () => {
    initPlots();
    bindEvents();
    loadSavedDerivatives();
});

function bindEvents() {
    $('#btnLoad').addEventListener('click', () => $('#fileInput').click());
    $('#fileInput').addEventListener('change', handleFileUpload);
    $('#btnAddPlot').addEventListener('click', addSelectedToPlot);
    $('#btnInsertExpr').addEventListener('click', insertSelectedIntoExpr);
    $('#btnPlotExpr').addEventListener('click', plotExpression);
    $('#exprInput').addEventListener('keydown', e => { if (e.key === 'Enter') plotExpression(); });
    $('#btnCreateDeriv').addEventListener('click', createDerived);
    $('#btnDdt').addEventListener('click', createDerivative);
    $('#btnFilter').addEventListener('click', filterSignal);
    $('#btnSegment').addEventListener('click', segmentAnalysis);
    $('#btnCalcDist').addEventListener('click', showCalcDistance);
    $('#btnDerivMgr').addEventListener('click', showDerivManager);
    $('#btnClear').addEventListener('click', clearAll);
    $('#btnClearSidebar').addEventListener('click', clearAll);
}

// ======================== FILE UPLOAD ========================
async function handleFileUpload() {
    const file = $('#fileInput').files[0];
    if (!file) return;

    showLoading();
    const form = new FormData();
    form.append('file', file);

    try {
        const data = await api('/api/upload', { method: 'POST', body: form });
        S.filename = data.filename;
        S.paramTree = data.param_tree || [];
        S.derivedList = data.derived_list || [];
        S.expandedGroups.clear();
        S.selectedFields.clear();
        S.activePlots = [];
        S.colorIdx = 0;

        $('#fileLabel').textContent = data.filename;
        document.title = `ArduPilot Log Viewer — ${data.filename}`;

        renderParamTree();
        renderActiveList();
        renderDerivedList();
        await loadFlightPath();
        clearTimePlot();

        toast(`Loaded ${data.filename}`);
    } catch (e) {
        toast(`Error: ${e.message}`, 5000);
    } finally {
        hideLoading();
        $('#fileInput').value = '';
    }
}

// ======================== PARAMETER TREE ========================
function renderParamTree() {
    const container = $('#paramTree');
    container.innerHTML = '';

    for (const group of S.paramTree) {
        const isExp = S.expandedGroups.has(group.name);

        // Group header
        const hdr = document.createElement('div');
        hdr.className = 'tree-group';
        hdr.innerHTML = `<span class="arrow">${isExp ? '▼' : '▶'}</span> ${group.name}`;
        hdr.addEventListener('click', () => {
            if (S.expandedGroups.has(group.name)) S.expandedGroups.delete(group.name);
            else S.expandedGroups.add(group.name);
            renderParamTree();
        });
        container.appendChild(hdr);

        // Fields
        const fieldsDiv = document.createElement('div');
        fieldsDiv.className = 'tree-fields' + (isExp ? ' open' : '');

        for (const f of group.fields) {
            const fEl = document.createElement('div');
            fEl.className = 'tree-field' + (S.selectedFields.has(f.ref) ? ' selected' : '');
            fEl.textContent = f.ref;
            fEl.addEventListener('click', (e) => {
                if (e.ctrlKey || e.metaKey) {
                    if (S.selectedFields.has(f.ref)) S.selectedFields.delete(f.ref);
                    else S.selectedFields.add(f.ref);
                } else {
                    S.selectedFields.clear();
                    S.selectedFields.add(f.ref);
                }
                renderParamTree();
            });
            fEl.addEventListener('dblclick', () => {
                // Double-click inserts into derived expr
                const inp = $('#derivExpr');
                inp.value = inp.value ? inp.value + ' ' + f.ref : f.ref;
            });
            fieldsDiv.appendChild(fEl);
        }
        container.appendChild(fieldsDiv);
    }
}

// ======================== ADD TO PLOT ========================
function addSelectedToPlot() {
    if (S.selectedFields.size === 0) return;
    for (const ref of S.selectedFields) {
        if (!S.activePlots.find(p => p.expr === ref)) {
            S.activePlots.push({ expr: ref, color: nextColor() });
        }
    }
    renderActiveList();
    updateTimePlot();
}

function insertSelectedIntoExpr() {
    if (S.selectedFields.size === 0) return;
    const inp = $('#derivExpr');
    for (const ref of S.selectedFields) {
        inp.value = inp.value ? inp.value + ' ' + ref : ref;
    }
}

// ======================== ACTIVE LIST ========================
function renderActiveList() {
    const container = $('#activeList');
    container.innerHTML = '';
    for (let i = 0; i < S.activePlots.length; i++) {
        const p = S.activePlots[i];
        const div = document.createElement('div');
        div.className = 'active-item';
        div.innerHTML = `
            <div class="swatch" style="background:${p.color}"></div>
            <span title="${p.expr}">${p.expr}</span>
            <button class="remove-btn" data-idx="${i}">&times;</button>
        `;
        div.querySelector('.remove-btn').addEventListener('click', () => {
            S.activePlots.splice(i, 1);
            renderActiveList();
            updateTimePlot();
        });
        container.appendChild(div);
    }

    // Show/hide sidebar clear button
    const btn = $('#btnClearSidebar');
    if (btn) btn.style.display = S.activePlots.length > 0 ? 'inline-block' : 'none';
}

// ======================== PLOT EXPRESSION ========================
async function plotExpression() {
    const expr = $('#exprInput').value.trim();
    if (!expr) return;

    try {
        // Validate by requesting data
        await apiPost('/api/plot', { expressions: [expr] });
        if (!S.activePlots.find(p => p.expr === expr)) {
            S.activePlots.push({ expr, color: nextColor() });
        }
        $('#exprInput').value = '';
        renderActiveList();
        updateTimePlot();
    } catch (e) {
        toast(`Error: ${e.message}`, 4000);
    }
}

// ======================== DERIVED PARAMETERS ========================
async function createDerived() {
    const name = $('#derivName').value.trim();
    const expr = $('#derivExpr').value.trim();
    if (!name || !expr) { toast('Enter both name and expression'); return; }

    showLoading();
    try {
        const data = await apiPost('/api/create_derived', { name, expr });
        S.paramTree = data.param_tree || S.paramTree;
        S.derivedList = data.derived_list || S.derivedList;
        renderParamTree();
        renderDerivedList();
        $('#derivName').value = '';
        $('#derivExpr').value = '';
        toast(`Created: DERIVED.${data.name} (${data.samples} samples)`);
    } catch (e) {
        toast(`Error: ${e.message}`, 4000);
    } finally {
        hideLoading();
    }
}

// ======================== TIME DERIVATIVE ========================
async function createDerivative() {
    const defaultExpr = $('#derivExpr').value.trim();
    const defaultName = $('#derivName').value.trim() || (defaultExpr ? 'd_' + defaultExpr.replace(/[^A-Za-z0-9]/g, '_') : '');

    const inputExpr = prompt('Input parameter/expression:', defaultExpr);
    if (!inputExpr) return;
    const outName = prompt('Output name:', defaultName);
    if (!outName) return;

    showLoading();
    try {
        // Step 1: Get recommendation
        const rec = await apiPost('/api/derivative', { input: inputExpr, name: outName });

        if (rec.step === 'recommend') {
            const spec = rec.spectrum;
            const msg = `Spectral Analysis:\n${spec.summary}\n\nRecommended: ${spec.rec_type} at ${spec.rec_cutoff.toFixed(2)} Hz\n\nEnter cutoff frequency (Hz):`;
            const cutoffStr = prompt(msg, spec.rec_cutoff.toFixed(2));
            if (!cutoffStr) { hideLoading(); return; }

            // Step 2: Create with cutoff
            const data = await apiPost('/api/derivative', {
                input: inputExpr, name: outName, cutoffHz: parseFloat(cutoffStr),
            });
            S.paramTree = data.param_tree || S.paramTree;
            S.derivedList = data.derived_list || S.derivedList;
            renderParamTree();
            renderDerivedList();
            toast(`Created: ${data.name} = ${data.expr}`);
        }
    } catch (e) {
        toast(`Error: ${e.message}`, 4000);
    } finally {
        hideLoading();
    }
}

// ======================== FILTER SIGNAL ========================
async function filterSignal() {
    const inputExpr = prompt('Parameter/expression to filter:');
    if (!inputExpr) return;
    const outName = prompt('Output name:');
    if (!outName) return;

    showLoading();
    try {
        // Get recommendation
        const rec = await apiPost('/api/filter', { input: inputExpr, name: outName });

        if (rec.step === 'recommend') {
            const spec = rec.spectrum;
            const msg = `Spectral Analysis:\n${spec.summary}\n\nRecommended: ${spec.rec_type} at ${spec.rec_cutoff.toFixed(2)} Hz`;
            const filtType = prompt(`${msg}\n\nFilter type (lowpass / highpass / bandpass):`, spec.rec_type);
            if (!filtType) { hideLoading(); return; }

            let body = { input: inputExpr, name: outName, filtType };
            if (filtType === 'bandpass') {
                const bpStr = prompt('Cutoff frequencies Hz (low,high):', `${(spec.rec_cutoff * 0.5).toFixed(2)},${spec.rec_cutoff.toFixed(2)}`);
                if (!bpStr) { hideLoading(); return; }
                const parts = bpStr.split(',').map(Number);
                body.loHz = parts[0];
                body.hiHz = parts[1];
            } else {
                const cutoffStr = prompt('Cutoff frequency (Hz):', spec.rec_cutoff.toFixed(2));
                if (!cutoffStr) { hideLoading(); return; }
                body.cutoffHz = parseFloat(cutoffStr);
            }

            const data = await apiPost('/api/filter', body);
            S.paramTree = data.param_tree || S.paramTree;
            S.derivedList = data.derived_list || S.derivedList;
            renderParamTree();
            renderDerivedList();
            toast(`Created: ${data.name} = ${data.expr}`);
        }
    } catch (e) {
        toast(`Error: ${e.message}`, 4000);
    } finally {
        hideLoading();
    }
}

// ======================== DERIVED LIST ========================
function renderDerivedList() {
    const container = $('#derivedList');
    container.innerHTML = '';
    for (const d of S.derivedList) {
        const div = document.createElement('div');
        div.className = 'deriv-item';
        const tag = d.saved ? '<span class="saved-tag">[SAVED]</span> ' : '';
        div.innerHTML = `${tag}DERIVED.${d.name} [= ${d.expr}]`;
        div.title = `${d.name} = ${d.expr} (${d.samples} samples)`;
        container.appendChild(div);
    }
}

async function loadSavedDerivatives() {
    try {
        const data = await api('/api/saved_derivatives');
        S.derivedList = data.derived_list || [];
        renderDerivedList();
    } catch (_) { /* ignore on first load */ }
}

// ======================== SEGMENT ANALYSIS ========================
async function segmentAnalysis() {
    if (S.activePlots.length === 0) {
        toast('No parameters plotted. Add traces first.');
        return;
    }

    // Get current X range from Plotly
    const layout = document.getElementById('timePlot')._fullLayout || {};
    const xRange = (layout.xaxis && layout.xaxis.range) || [0, 100];
    const t0Str = prompt('Start time (s):', xRange[0].toFixed(2));
    if (!t0Str) return;
    const t1Str = prompt('End time (s):', xRange[1].toFixed(2));
    if (!t1Str) return;

    showLoading();
    try {
        const data = await apiPost('/api/segment_analysis', {
            t0: parseFloat(t0Str),
            t1: parseFloat(t1Str),
            expressions: S.activePlots.map(p => p.expr),
        });
        hideLoading();
        showSegmentResults(data);
    } catch (e) {
        hideLoading();
        toast(`Error: ${e.message}`, 4000);
    }
}

function showSegmentResults(data) {
    const overlay = document.createElement('div');
    overlay.className = 'modal-overlay';
    overlay.addEventListener('click', e => { if (e.target === overlay) overlay.remove(); });

    const cols = ['Parameter','Min','Max','Mean','Usual Low','Usual High',
                  'Peak Above','Peak Below','Main Osc Freq','Max Signal Freq'];

    let rowsHtml = '';
    for (const r of data.results) {
        rowsHtml += `<tr>
            <td>${r.param}</td>
            <td>${r.min.toFixed(4)}</td><td>${r.max.toFixed(4)}</td><td>${r.mean.toFixed(4)}</td>
            <td>${r.usual_low.toFixed(4)}</td><td>${r.usual_high.toFixed(4)}</td>
            <td>+${r.peak_above.toFixed(4)}</td><td>${r.peak_below.toFixed(4)}</td>
            <td>${r.main_osc_freq > 0 ? r.main_osc_freq.toFixed(2) + ' Hz' : '—'}</td>
            <td>${r.max_signal_freq > 0 ? r.max_signal_freq.toFixed(2) + ' Hz' : '—'}</td>
        </tr>`;
    }

    overlay.innerHTML = `<div class="modal" style="min-width:900px">
        <button class="modal-close" onclick="this.closest('.modal-overlay').remove()">&times;</button>
        <h2>Segment Analysis [${data.t0.toFixed(1)}s – ${data.t1.toFixed(1)}s]</h2>
        <p style="color:#fbbf24;margin-bottom:8px">Modes: ${data.modes}</p>
        <table class="modal-table">
            <tr>${cols.map(c => `<th>${c}</th>`).join('')}</tr>
            ${rowsHtml}
        </table>
        <div style="margin-top:12px;text-align:center">
            <button class="modal-btn export" id="btnExportCSV">Export CSV</button>
        </div>
    </div>`;

    document.body.appendChild(overlay);

    // CSV export
    overlay.querySelector('#btnExportCSV').addEventListener('click', () => {
        let csv = cols.join(',') + '\n';
        for (const r of data.results) {
            csv += [r.param, r.min, r.max, r.mean, r.usual_low, r.usual_high,
                    r.peak_above, r.peak_below,
                    r.main_osc_freq > 0 ? r.main_osc_freq.toFixed(2) : '',
                    r.max_signal_freq > 0 ? r.max_signal_freq.toFixed(2) : ''].join(',') + '\n';
        }
        downloadCSV(`segment_${data.t0.toFixed(0)}s-${data.t1.toFixed(0)}s.csv`, csv);
    });
}

function downloadCSV(filename, csv) {
    const blob = new Blob([csv], { type: 'text/csv' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url; a.download = filename;
    document.body.appendChild(a); a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
}

// ======================== SAVED DERIVATIVES MANAGER ========================
function showDerivManager() {
    if (S.derivedList.length === 0) {
        toast('No derived parameters defined yet.');
        return;
    }

    const overlay = document.createElement('div');
    overlay.className = 'modal-overlay';
    overlay.addEventListener('click', e => { if (e.target === overlay) overlay.remove(); });

    let rowsHtml = '';
    for (const d of S.derivedList) {
        const statusTag = d.saved
            ? '<span style="color:#22c55e;font-weight:600">SAVED</span>'
            : '<span style="color:#f59e0b">unsaved</span>';
        const btns = d.saved
            ? `<button class="modal-btn del" data-name="${d.name}" data-action="delete">Delete</button>
               <button class="modal-btn override" data-name="${d.name}" data-action="override">Override</button>`
            : `<button class="modal-btn save" data-name="${d.name}" data-action="save">Save</button>`;
        rowsHtml += `<tr>
            <td style="color:#fbbf24;font-weight:600">${d.name}</td>
            <td>${d.expr}</td>
            <td>${statusTag}</td>
            <td>${btns}</td>
        </tr>`;
    }

    overlay.innerHTML = `<div class="modal" style="min-width:650px">
        <button class="modal-close" onclick="this.closest('.modal-overlay').remove()">&times;</button>
        <h2>Saved Derivatives Manager</h2>
        <table class="modal-table">
            <tr><th>Name</th><th>Expression</th><th>Status</th><th>Actions</th></tr>
            ${rowsHtml}
        </table>
    </div>`;

    document.body.appendChild(overlay);

    // Bind action buttons
    overlay.querySelectorAll('.modal-btn[data-action]').forEach(btn => {
        btn.addEventListener('click', async () => {
            const name = btn.dataset.name;
            const action = btn.dataset.action;
            try {
                if (action === 'save') {
                    const data = await apiPost('/api/saved_derivatives/save', { name });
                    S.derivedList = data.derived_list;
                } else if (action === 'delete') {
                    const data = await apiPost('/api/saved_derivatives/delete', { name });
                    S.derivedList = data.derived_list;
                } else if (action === 'override') {
                    const newExpr = prompt(`New expression for "${name}":`,
                        S.derivedList.find(d => d.name === name)?.expr || '');
                    if (!newExpr) return;
                    const data = await apiPost('/api/saved_derivatives/override', { name, expr: newExpr });
                    S.derivedList = data.derived_list;
                    if (data.param_tree) S.paramTree = data.param_tree;
                    renderParamTree();
                }
                renderDerivedList();
                // Re-render modal
                overlay.remove();
                showDerivManager();
            } catch (e) {
                toast(`Error: ${e.message}`, 4000);
            }
        });
    });
}

// ======================== CLEAR ALL ========================
function clearAll() {
    S.activePlots = [];
    S.colorIdx = 0;
    renderActiveList();
    clearTimePlot();
}

// ======================== CALC DISTANCE ========================
function showCalcDistance() {
    if (!S.filename) {
        toast('Load a .bin file first.'); return;
    }

    // Get current time plot X-axis range as defaults
    let defT1 = '0', defT2 = '1000';
    const timePlotEl = document.getElementById('timePlot');
    if (timePlotEl && timePlotEl.layout && timePlotEl.layout.xaxis && timePlotEl.layout.xaxis.range) {
        defT1 = parseFloat(timePlotEl.layout.xaxis.range[0]).toFixed(2);
        defT2 = parseFloat(timePlotEl.layout.xaxis.range[1]).toFixed(2);
    }

    const overlay = document.createElement('div');
    overlay.className = 'modal-overlay';
    overlay.addEventListener('click', e => { if (e.target === overlay) overlay.remove(); });

    overlay.innerHTML = `<div class="modal" style="min-width:400px; max-width:480px">
        <button class="modal-close" onclick="this.closest('.modal-overlay').remove()">&times;</button>
        <h2 style="color:#0ea5e9">Calculate Horizontal Distance</h2>
        <div style="display:grid; grid-template-columns:auto 1fr; gap:8px 12px; align-items:center; font-size:13px; margin-bottom:16px;">
            <label style="color:#aaa">Latitude param:</label>
            <input id="cdLat" class="side-input" value="GPS_0.Lat" style="width:100%">
            <label style="color:#aaa">Longitude param:</label>
            <input id="cdLng" class="side-input" value="GPS_0.Lng" style="width:100%">
            <label style="color:#aaa">Start time (s):</label>
            <input id="cdT1" class="side-input" type="number" step="0.01" value="${defT1}" style="width:100%">
            <label style="color:#aaa">End time (s):</label>
            <input id="cdT2" class="side-input" type="number" step="0.01" value="${defT2}" style="width:100%">
        </div>
        <button class="modal-btn" id="cdCompute" style="background:#0ea5e9; padding:6px 20px; font-size:13px; width:100%">Compute</button>
        <div id="cdResult" style="margin-top:14px; display:none; background:#1e1e2a; border-radius:6px; padding:12px; font-family:monospace; font-size:13px; color:#ddd; line-height:1.8;"></div>
    </div>`;

    document.body.appendChild(overlay);

    overlay.querySelector('#cdCompute').addEventListener('click', async () => {
        const latParam = overlay.querySelector('#cdLat').value.trim();
        const lngParam = overlay.querySelector('#cdLng').value.trim();
        const t1 = parseFloat(overlay.querySelector('#cdT1').value);
        const t2 = parseFloat(overlay.querySelector('#cdT2').value);

        if (!latParam || !lngParam) { toast('Enter lat/lng parameters'); return; }
        if (isNaN(t1) || isNaN(t2) || t2 <= t1) { toast('Invalid time range'); return; }

        try {
            const result = await apiPost('/api/calc_distance', {
                lat_param: latParam, lng_param: lngParam, t1, t2,
            });
            const div = overlay.querySelector('#cdResult');
            div.style.display = 'block';
            div.innerHTML = `
                <div style="color:#0ea5e9; font-weight:bold; margin-bottom:6px;">Horizontal Distance</div>
                <div>Distance: &nbsp; <span style="color:#22c55e; font-weight:bold">${result.distance}</span></div>
                <div>Duration: &nbsp; <span style="color:#fbbf24">${result.duration.toFixed(1)} s</span></div>
                <div>Avg Speed: <span style="color:#f97316">${result.avg_speed}</span></div>
                <div>Points: &nbsp;&nbsp; ${result.points}</div>
                <div>Time Range: ${result.t_start.toFixed(2)} – ${result.t_end.toFixed(2)} s</div>
            `;
        } catch (e) {
            toast(`Error: ${e.message}`, 4000);
        }
    });
}

// ======================== PLOTLY PLOTS ========================
const plotlyDarkLayout = {
    paper_bgcolor: '#1a1a22',
    plot_bgcolor: '#0e0e14',
    font: { color: '#d8d8d8', size: 11 },
    margin: { l: 55, r: 20, t: 35, b: 40 },
    xaxis: {
        gridcolor: '#2a2a35', zerolinecolor: '#333',
        title: { text: 'Time (s)', font: { size: 12 } },
    },
    yaxis: {
        gridcolor: '#2a2a35', zerolinecolor: '#333',
    },
    legend: {
        bgcolor: 'rgba(30,30,40,0.85)', bordercolor: '#444', borderwidth: 1,
        font: { size: 10 },
        orientation: 'h',
        yanchor: 'bottom', y: 1.02,
        xanchor: 'left', x: 0,
    },
    hovermode: 'x unified',
    showlegend: true,
};

const plotlyConfig = {
    responsive: true,
    displaylogo: false,
    modeBarButtonsToRemove: ['sendDataToCloud'],
};

function initPlots() {
    Plotly.newPlot('timePlot', [], {
        ...plotlyDarkLayout,
        title: { text: 'Time Series Plot', font: { size: 14, color: '#ddd' } },
    }, plotlyConfig);

    Plotly.newPlot('mapPlot', [], {
        ...plotlyDarkLayout,
        title: { text: 'Flight Path', font: { size: 14, color: '#ddd' } },
        xaxis: { ...plotlyDarkLayout.xaxis, title: { text: 'Longitude' } },
        yaxis: { ...plotlyDarkLayout.yaxis, title: { text: 'Latitude' } },
        legend: { ...plotlyDarkLayout.legend, orientation: 'h', y: 1.02, yanchor: 'bottom', x: 1, xanchor: 'right' },
        margin: { l: 60, r: 20, t: 35, b: 40 },
    }, plotlyConfig);

    // Link zoom on time plot to flight path update
    document.getElementById('timePlot').on('plotly_relayout', onTimePlotRelayout);
}

function clearTimePlot() {
    Plotly.react('timePlot', [], {
        ...plotlyDarkLayout,
        title: { text: 'Time Series Plot', font: { size: 14, color: '#ddd' } },
    });
}

async function updateTimePlot() {
    if (S.activePlots.length === 0) { clearTimePlot(); return; }

    showLoading();
    try {
        // Fetch plot data and mode intervals in parallel
        const [data, modesResp] = await Promise.all([
            apiPost('/api/plot', { expressions: S.activePlots.map(p => p.expr) }),
            api('/api/modes').catch(() => ({ modes: [] })),
        ]);
        hideLoading();

        const traces = [];
        const yAxes = {};

        for (let i = 0; i < data.traces.length; i++) {
            const t = data.traces[i];
            if (t.error) {
                toast(`Plot error for "${t.expr}": ${t.error}`, 4000);
                continue;
            }

            const color = S.activePlots[i]?.color || S.plotColors[i % S.plotColors.length];
            const yAxisName = i === 0 ? 'y' : `y${i + 1}`;
            const yAxisKey = i === 0 ? 'yaxis' : `yaxis${i + 1}`;

            traces.push({
                x: t.time,
                y: t.values,
                type: 'scattergl',
                mode: 'lines',
                name: `${t.expr} | ${t.stats.min.toFixed(1)}..${t.stats.max.toFixed(1)} μ${t.stats.mean.toFixed(1)}`,
                line: { color, width: 1.5 },
                yaxis: yAxisName,
                hovertemplate: `${t.expr}: %{y:.3f}<extra></extra>`,
            });

            // Setup Y axis
            const side = i % 2 === 0 ? 'left' : 'right';
            const overlap = Math.floor(i / 2) * 0.06;
            yAxes[yAxisKey] = {
                title: { text: t.expr, font: { color, size: 10 } },
                titlefont: { color },
                tickfont: { color, size: 9 },
                gridcolor: i === 0 ? '#2a2a35' : 'transparent',
                zerolinecolor: '#333',
                side,
                overlaying: i === 0 ? undefined : 'y',
                position: side === 'left' ? overlap : 1.0 - overlap,
                showgrid: i === 0,
            };
        }

        const layout = {
            ...plotlyDarkLayout,
            title: { text: S.filename || 'Time Series', font: { size: 14, color: '#ddd' } },
            ...yAxes,
        };

        // Adjust margins for multiple y-axes and legend rows
        const nRight = Math.ceil(traces.length / 2) - (traces.length > 1 ? 0 : 1);
        const nLeft = Math.floor((traces.length + 1) / 2);
        // Estimate legend rows: ~2 items per row for long trace names
        const legendRows = Math.ceil(traces.length / 2);
        const legendHeight = Math.max(0, legendRows - 1) * 22;
        layout.margin = { l: 55 + Math.max(0, nLeft - 1) * 50, r: 20 + nRight * 50, t: 50 + legendHeight, b: 40 };

        // Mode phase shading — bright vivid palette per user preference
        const modeShadePalette = [
            [255,0,144],   // hot pink       #FF0090
            [255,37,59],   // vivid red      #FF253B
            [247,255,24],  // electric yellow #F7FF18
            [255,140,30],  // warm orange
            [157,255,252], // bright cyan    #9DFFFC (the blue shade)
            [200,120,50],  // warm brown
            [247,255,24],  // electric yellow again
            [255,37,59],   // vivid red again
            [255,180,40],  // golden amber
            [157,255,252], // bright cyan
            [185,231,0],   // neon lime
            [185,231,0],   // neon lime      #B9E700 (replaces green)
        ];
        const modes = modesResp.modes || [];
        if (modes.length > 0) {
            layout.shapes = modes.map(m => {
                const c = modeShadePalette[m.code % modeShadePalette.length];
                return {
                    type: 'rect', xref: 'x', yref: 'paper',
                    x0: m.t0, x1: m.t1, y0: 0, y1: 1,
                    fillcolor: `rgba(${c[0]},${c[1]},${c[2]},0.35)`,
                    line: { width: 0 },
                    layer: 'below',
                };
            });
            // Mode labels at top
            layout.annotations = modes.map(m => {
                const c = modeShadePalette[m.code % modeShadePalette.length];
                return {
                    x: (m.t0 + m.t1) / 2, y: 1,
                    xref: 'x', yref: 'paper',
                    text: m.name,
                    font: { size: 9, color: `rgb(${c[0]},${c[1]},${c[2]})` },
                    showarrow: false,
                    yanchor: 'bottom',
                };
            });
        }

        Plotly.react('timePlot', traces, layout, plotlyConfig);
    } catch (e) {
        hideLoading();
        toast(`Plot error: ${e.message}`, 4000);
    }
}

// ======================== FLIGHT PATH ========================
async function loadFlightPath() {
    try {
        const data = await api('/api/flight_path');
        S.flightPath = data;
        renderFlightPath(data);
    } catch (e) {
        console.warn('Flight path:', e.message);
    }
}

function renderFlightPath(data, tMin = null, tMax = null) {
    if (!data || !data.lat || data.lat.length === 0) {
        Plotly.react('mapPlot', [], {
            ...plotlyDarkLayout,
            title: { text: 'No GPS data', font: { size: 14, color: '#e55' } },
        });
        return;
    }

    let lat = data.lat.slice(), lng = data.lng.slice(), codes = data.mode_codes.slice();
    let alt = data.alt ? data.alt.slice() : null;

    // Filter by time range if specified
    if (tMin != null && tMax != null && data.time && data.time.length === lat.length) {
        const filtLat = [], filtLng = [], filtCodes = [], filtAlt = [];
        for (let i = 0; i < data.time.length; i++) {
            if (data.time[i] >= tMin && data.time[i] <= tMax) {
                filtLat.push(lat[i]);
                filtLng.push(lng[i]);
                filtCodes.push(codes[i]);
                if (alt) filtAlt.push(alt[i]);
            }
        }
        lat = filtLat; lng = filtLng; codes = filtCodes;
        if (alt) alt = filtAlt;
    }

    if (lat.length === 0) {
        Plotly.react('mapPlot', [], {
            ...plotlyDarkLayout,
            title: { text: 'No GPS data in view', font: { size: 14, color: '#e55' } },
        });
        return;
    }

    const modeMap = data.mode_map || {};
    const modeColors = [
        '#fbbf24','#ef4444','#f97316','#3b82f6','#22c55e','#a855f7',
        '#06b6d4','#ec4899','#84cc16','#fb923c','#6366f1','#cbd5e1',
    ];

    // Group by mode
    const uniqueCodes = [...new Set(codes)];
    const traces = [];

    for (let mi = 0; mi < uniqueCodes.length; mi++) {
        const m = uniqueCodes[mi];
        const idx = [];
        for (let i = 0; i < codes.length; i++) {
            if (codes[i] === m) idx.push(i);
        }
        const col = modeColors[mi % modeColors.length];
        const modeName = modeMap[String(Math.round(m))] || `Mode ${Math.round(m)}`;

        traces.push({
            x: idx.map(i => lng[i]),
            y: idx.map(i => lat[i]),
            type: 'scattergl',
            mode: 'markers',
            name: modeName,
            marker: { color: col, size: 3 },
            hovertemplate: `${modeName}<br>Lng: %{x:.6f}<br>Lat: %{y:.6f}<extra></extra>`,
        });
    }

    // Start/end markers
    traces.push({
        x: [lng[0]], y: [lat[0]],
        type: 'scatter', mode: 'markers',
        name: 'Start',
        marker: { color: '#22c55e', size: 12, symbol: 'circle' },
        showlegend: false,
    });
    traces.push({
        x: [lng[lng.length - 1]], y: [lat[lat.length - 1]],
        type: 'scatter', mode: 'markers',
        name: 'End',
        marker: { color: '#ef4444', size: 12, symbol: 'square' },
        showlegend: false,
    });

    // Range circles
    const cLat = lat.reduce((a, b) => a + b, 0) / lat.length;
    const cLng = lng.reduce((a, b) => a + b, 0) / lng.length;
    const mPerDegLat = 111320;
    const mPerDegLng = 111320 * Math.cos(cLat * Math.PI / 180);

    let maxR = 0;
    for (let i = 0; i < lat.length; i++) {
        const dLat = (lat[i] - cLat) * mPerDegLat;
        const dLng = (lng[i] - cLng) * mPerDegLng;
        const d = Math.sqrt(dLat * dLat + dLng * dLng);
        if (d > maxR) maxR = d;
    }

    const shapes = [];
    const annotations = [];
    if (maxR > 0.5) {
        // Draw range circles as traces for proper scaling
        const nPts = 120;
        for (let ci = 1; ci <= 4; ci++) {
            const r = maxR * ci / 4;
            const cLats = [], cLngs = [];
            for (let k = 0; k <= nPts; k++) {
                const theta = 2 * Math.PI * k / nPts;
                cLats.push(cLat + (r * Math.sin(theta)) / mPerDegLat);
                cLngs.push(cLng + (r * Math.cos(theta)) / mPerDegLng);
            }
            const isOuter = ci === 4;
            traces.push({
                x: cLngs, y: cLats,
                type: 'scatter', mode: 'lines',
                line: {
                    color: isOuter ? 'rgba(255,70,70,0.5)' : 'rgba(140,140,140,0.35)',
                    dash: isOuter ? 'dash' : 'dot',
                    width: isOuter ? 1.5 : 1,
                },
                showlegend: false, hoverinfo: 'skip',
            });
            const label = r >= 1000 ? `${(r / 1000).toFixed(1)} km` : `${Math.round(r)} m`;
            annotations.push({
                x: cLng + r / mPerDegLng,
                y: cLat,
                text: label,
                font: { color: '#ccc', size: 9 },
                showarrow: false,
                xanchor: 'left',
            });
        }

        // Max altitude
        if (data.max_alt != null) {
            const maxAlt = (tMin != null && alt && alt.length > 0) ? Math.max(...alt) : data.max_alt;
            const altText = maxAlt >= 1000
                ? `Max Alt: ${(maxAlt / 1000).toFixed(1)} km`
                : `Max Alt: ${Math.round(maxAlt)} m`;
            annotations.push({
                x: cLng - maxR / mPerDegLng * 0.7,
                y: cLat - maxR / mPerDegLat,
                text: altText,
                font: { color: '#4dd8f0', size: 11 },
                showarrow: false,
                xanchor: 'left', yanchor: 'top',
            });
        }

        // Total flight distance
        let totalDist = 0;
        for (let i = 1; i < lat.length; i++) {
            const dLa = (lat[i] - lat[i-1]) * mPerDegLat;
            const dLo = (lng[i] - lng[i-1]) * mPerDegLng;
            totalDist += Math.sqrt(dLa * dLa + dLo * dLo);
        }
        const distText = totalDist >= 1000
            ? `Total: ${(totalDist / 1000).toFixed(2)} km`
            : `Total: ${Math.round(totalDist)} m`;
        const maxRangeText = maxR >= 1000
            ? `Max Range: ${(maxR / 1000).toFixed(2)} km`
            : `Max Range: ${Math.round(maxR)} m`;
        annotations.push({
            xref: 'paper', yref: 'paper',
            x: 0.01, y: 0.01,
            text: `${distText}  |  ${maxRangeText}`,
            font: { color: '#7dd3fc', size: 11 },
            showarrow: false,
            xanchor: 'left', yanchor: 'bottom',
        });
    }

    // Compute axis ranges that preserve aspect ratio
    const latMin = Math.min(...lat), latMax = Math.max(...lat);
    const lngMin = Math.min(...lng), lngMax = Math.max(...lng);
    const latSpan = (latMax - latMin) || 0.001;
    const lngSpan = (lngMax - lngMin) || 0.001;
    // Account for range circles extending beyond data points
    const padLat = maxR > 0 ? maxR / mPerDegLat * 1.15 : latSpan * 0.1;
    const padLng = maxR > 0 ? maxR / mPerDegLng * 1.15 : lngSpan * 0.1;
    const ctrLat = (latMin + latMax) / 2, ctrLng = (lngMin + lngMax) / 2;
    const halfLat = Math.max(padLat, latSpan / 2 * 1.05);
    const halfLng = Math.max(padLng, lngSpan / 2 * 1.05);

    Plotly.react('mapPlot', traces, {
        ...plotlyDarkLayout,
        title: { text: 'Flight Path', font: { size: 14, color: '#ddd' } },
        xaxis: {
            ...plotlyDarkLayout.xaxis,
            title: { text: 'Longitude' },
            range: [ctrLng - halfLng, ctrLng + halfLng],
        },
        yaxis: {
            ...plotlyDarkLayout.yaxis,
            title: { text: 'Latitude' },
            range: [ctrLat - halfLat, ctrLat + halfLat],
            scaleanchor: 'x',
            scaleratio: mPerDegLat / mPerDegLng,
        },
        legend: { ...plotlyDarkLayout.legend, orientation: 'h', y: 1.02, yanchor: 'bottom', x: 1, xanchor: 'right' },
        margin: { l: 60, r: 20, t: 35, b: 40 },
        annotations,
    }, plotlyConfig);
}

// ======================== ZOOM-LINKED FLIGHT PATH ========================
let _fpDebounce = null;
function onTimePlotRelayout(eventData) {
    let tMin = null, tMax = null;

    // Only respond to X-axis changes
    if (eventData['xaxis.range[0]'] != null && eventData['xaxis.range[1]'] != null) {
        tMin = parseFloat(eventData['xaxis.range[0]']);
        tMax = parseFloat(eventData['xaxis.range[1]']);
    } else if (eventData['xaxis.range'] && Array.isArray(eventData['xaxis.range'])) {
        tMin = parseFloat(eventData['xaxis.range'][0]);
        tMax = parseFloat(eventData['xaxis.range'][1]);
    } else if (eventData['xaxis.autorange']) {
        // Reset to full view — auto-range all Y axes too
        const plotEl = document.getElementById('timePlot');
        const yUpdate = {};
        if (plotEl.data) {
            for (let i = 0; i < plotEl.data.length; i++) {
                const axKey = i === 0 ? 'yaxis' : `yaxis${i + 1}`;
                yUpdate[axKey + '.autorange'] = true;
            }
        }
        Plotly.relayout('timePlot', yUpdate);

        if (S.flightPath && S.flightPath.time) {
            if (_fpDebounce) clearTimeout(_fpDebounce);
            _fpDebounce = setTimeout(() => renderFlightPath(S.flightPath), 100);
        }
        return;
    } else {
        // Ignore Y-axis or other relayout events
        return;
    }

    if (isNaN(tMin) || isNaN(tMax) || tMin >= tMax) return;

    // Auto-scale each Y axis to fit visible data in [tMin, tMax]
    const plotEl = document.getElementById('timePlot');
    if (plotEl.data) {
        const yUpdate = {};
        for (let i = 0; i < plotEl.data.length; i++) {
            const trace = plotEl.data[i];
            if (!trace.x || !trace.y) continue;
            let lo = Infinity, hi = -Infinity;
            for (let j = 0; j < trace.x.length; j++) {
                const tx = trace.x[j];
                if (tx >= tMin && tx <= tMax) {
                    const v = trace.y[j];
                    if (v < lo) lo = v;
                    if (v > hi) hi = v;
                }
            }
            if (lo < hi) {
                const pad = (hi - lo) * 0.05 || 0.1;
                const axKey = i === 0 ? 'yaxis' : `yaxis${i + 1}`;
                yUpdate[axKey + '.range'] = [lo - pad, hi + pad];
                yUpdate[axKey + '.autorange'] = false;
            }
        }
        if (Object.keys(yUpdate).length > 0) {
            Plotly.relayout('timePlot', yUpdate);
        }
    }

    // Debounce flight path update
    if (S.flightPath && S.flightPath.time) {
        if (_fpDebounce) clearTimeout(_fpDebounce);
        _fpDebounce = setTimeout(() => renderFlightPath(S.flightPath, tMin, tMax), 80);
    }
}
