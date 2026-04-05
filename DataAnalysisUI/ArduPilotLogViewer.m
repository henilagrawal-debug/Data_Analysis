function ArduPilotLogViewer(binFile)
%ARDUPILOTLOGVIEWER MATLAB ArduPilot log viewer with derived parameters
%
%   ArduPilotLogViewer()          — Opens file browser
%   ArduPilotLogViewer('file.bin') — Loads specified file
%
%   Features:
%     - Parse and browse all ArduPilot .bin log parameters
%     - Plot any parameter vs time (multi-trace with legend stats)
%     - Create derived parameters from expressions (e.g. GPS_0.Spd * 3.6)
%     - Add arbitrary expressions directly to the plot
%     - Flight path visualization colored by flight mode
%     - Supports instance splitting (GPS[0], GPS[1], etc.)

    %% Create main figure
    scrSz = get(0, 'ScreenSize');
    figW = min(1500, scrSz(3) - 100);
    figH = min(900, scrSz(4) - 100);
    fig = figure('Name', 'ArduPilot Log Viewer', ...
        'NumberTitle', 'off', ...
        'Position', [50, 50, figW, figH], ...
        'MenuBar', 'none', ...
        'ToolBar', 'figure', ...
        'Color', [0.15 0.15 0.18], ...
        'Resize', 'on', ...
        'Visible', 'off');

    %% State
    handles = struct();
    handles.logData      = [];
    handles.derivedData  = struct();   % name -> struct(values, time, expr)
    handles.activePlots  = {};         % cell of expression strings
    handles.filename     = '';
    handles.plotColors    = lines(12);
    handles.expandedGroups = {};       % cell of expanded message group names
    handles.extraAxes      = [];       % array of overlay axes for multi-Y
    handles.crosshairLine  = [];       % vertical crosshair line handle
    handles.crosshairTexts = {};       % text handles for cursor value readout
    handles.plotDataCache  = {};       % cached {vals, tVec, expr, color} per trace
    handles.xlimListener   = [];       % listener for syncing zoom across axes
    handles.gpsCache       = [];       % struct with lat, lng, timeSec, modeCodes for flight path filtering
    handles.savedDerivFile = fullfile(fileparts(mfilename('fullpath')), 'saved_derivatives.json');
    handles.savedDerivNames = {};       % cell of names that are persisted in JSON

    %% ===== TOP TOOLBAR PANEL (above plots) =====
    handles.pToolbar = uipanel(fig, 'Units', 'pixels', ...
        'BackgroundColor', [0.20 0.20 0.25], ...
        'BorderType', 'line', ...
        'HighlightColor', [0.35 0.35 0.40]);

    handles.btnSegAnalysis = uicontrol(handles.pToolbar, 'Style', 'pushbutton', ...
        'String', 'Segment Analysis', ...
        'FontSize', 9, 'FontWeight', 'bold', ...
        'BackgroundColor', [0.30 0.55 0.75], ...
        'ForegroundColor', [1 1 1], ...
        'Callback', @segmentAnalysisCb);

    handles.btnDerivMgr = uicontrol(handles.pToolbar, 'Style', 'pushbutton', ...
        'String', 'Saved Derivatives', ...
        'FontSize', 9, 'FontWeight', 'bold', ...
        'BackgroundColor', [0.60 0.45 0.20], ...
        'ForegroundColor', [1 1 1], ...
        'Tag', 'btnDerivMgr', ...
        'Callback', @derivManagerCb);

    handles.btnFilter = uicontrol(handles.pToolbar, 'Style', 'pushbutton', ...
        'String', 'Filter Signal', ...
        'FontSize', 9, 'FontWeight', 'bold', ...
        'BackgroundColor', [0.35 0.55 0.45], ...
        'ForegroundColor', [1 1 1], ...
        'Callback', @filterSignalCb);

    handles.btnCalcDist = uicontrol(handles.pToolbar, 'Style', 'pushbutton', ...
        'String', 'Calc Distance', ...
        'FontSize', 9, 'FontWeight', 'bold', ...
        'BackgroundColor', [0.55 0.35 0.60], ...
        'ForegroundColor', [1 1 1], ...
        'Callback', @calcDistanceCb);

    %% ===== LEFT PANEL =====
    pLeft = uipanel(fig, 'Units', 'pixels', ...
        'BackgroundColor', [0.18 0.18 0.22], ...
        'ForegroundColor', [0.9 0.9 0.9], ...
        'BorderType', 'line', ...
        'HighlightColor', [0.3 0.3 0.35], ...
        'Title', '');

    yOff = 0; % will be set by resize

    % --- Load File ---
    handles.btnLoad = uicontrol(pLeft, 'Style', 'pushbutton', ...
        'String', 'Load .bin File', ...
        'FontSize', 11, 'FontWeight', 'bold', ...
        'BackgroundColor', [0.25 0.52 0.96], ...
        'ForegroundColor', [1 1 1], ...
        'Callback', @loadFileCb);

    handles.lblFile = uicontrol(pLeft, 'Style', 'text', ...
        'String', 'No file loaded', ...
        'FontSize', 8, ...
        'BackgroundColor', [0.18 0.18 0.22], ...
        'ForegroundColor', [0.7 0.7 0.7], ...
        'HorizontalAlignment', 'left');

    % --- Available Parameters ---
    uicontrol(pLeft, 'Style', 'text', ...
        'String', 'Available Parameters:', ...
        'FontSize', 10, 'FontWeight', 'bold', ...
        'BackgroundColor', [0.18 0.18 0.22], ...
        'ForegroundColor', [0.9 0.6 0.2], ...
        'HorizontalAlignment', 'left', ...
        'Tag', 'lblParams');

    handles.lbParams = uicontrol(pLeft, 'Style', 'listbox', ...
        'String', {}, ...
        'FontSize', 9, ...
        'Max', 10, 'Min', 0, ...
        'BackgroundColor', [0.12 0.12 0.15], ...
        'ForegroundColor', [0.85 0.85 0.85], ...
        'Callback', @paramsListClickCb, ...
        'Tag', 'lbParams');

    handles.btnAdd = uicontrol(pLeft, 'Style', 'pushbutton', ...
        'String', 'Add to Plot  >>', ...
        'FontSize', 10, ...
        'BackgroundColor', [0.2 0.6 0.3], ...
        'ForegroundColor', [1 1 1], ...
        'Callback', @addToPlotCb);

    handles.btnInsertExpr = uicontrol(pLeft, 'Style', 'pushbutton', ...
        'String', 'Insert into Expr  v', ...
        'FontSize', 9, ...
        'BackgroundColor', [0.45 0.35 0.65], ...
        'ForegroundColor', [1 1 1], ...
        'TooltipString', 'Insert selected param into Derived Expression (or double-click)', ...
        'Callback', @insertIntoExprCb);

    % --- Active Plots ---
    uicontrol(pLeft, 'Style', 'text', ...
        'String', 'Active Plots:', ...
        'FontSize', 10, 'FontWeight', 'bold', ...
        'BackgroundColor', [0.18 0.18 0.22], ...
        'ForegroundColor', [0.2 0.8 0.9], ...
        'HorizontalAlignment', 'left', ...
        'Tag', 'lblActive');

    handles.lbActive = uicontrol(pLeft, 'Style', 'listbox', ...
        'String', {}, ...
        'FontSize', 9, ...
        'Max', 10, 'Min', 0, ...
        'BackgroundColor', [0.12 0.12 0.15], ...
        'ForegroundColor', [0.85 0.85 0.85], ...
        'Tag', 'lbActive');

    handles.btnRemove = uicontrol(pLeft, 'Style', 'pushbutton', ...
        'String', '<< Remove', ...
        'FontSize', 10, ...
        'BackgroundColor', [0.8 0.25 0.2], ...
        'ForegroundColor', [1 1 1], ...
        'Callback', @removeFromPlotCb);

    % --- Expression Input ---
    uicontrol(pLeft, 'Style', 'text', ...
        'String', 'Add Expression:', ...
        'FontSize', 10, 'FontWeight', 'bold', ...
        'BackgroundColor', [0.18 0.18 0.22], ...
        'ForegroundColor', [0.9 0.6 0.9], ...
        'HorizontalAlignment', 'left', ...
        'Tag', 'lblExpr');

    handles.edExpr = uicontrol(pLeft, 'Style', 'edit', ...
        'String', '', ...
        'FontSize', 9, ...
        'BackgroundColor', [0.12 0.12 0.15], ...
        'ForegroundColor', [0.9 0.9 0.9], ...
        'HorizontalAlignment', 'left', ...
        'TooltipString', 'e.g. GPS_0.Spd * 3.6  or  CTUN.As * CTUN.ThO');

    handles.btnAddExpr = uicontrol(pLeft, 'Style', 'pushbutton', ...
        'String', 'Plot Expression', ...
        'FontSize', 10, ...
        'BackgroundColor', [0.6 0.3 0.7], ...
        'ForegroundColor', [1 1 1], ...
        'Callback', @addExprCb);

    % --- Derived Parameters ---
    uicontrol(pLeft, 'Style', 'text', ...
        'String', '--- Derived Parameters ---', ...
        'FontSize', 10, 'FontWeight', 'bold', ...
        'BackgroundColor', [0.18 0.18 0.22], ...
        'ForegroundColor', [1 0.85 0.3], ...
        'HorizontalAlignment', 'center', ...
        'Tag', 'lblDerived');

    uicontrol(pLeft, 'Style', 'text', ...
        'String', 'Name:', ...
        'FontSize', 9, ...
        'BackgroundColor', [0.18 0.18 0.22], ...
        'ForegroundColor', [0.8 0.8 0.8], ...
        'HorizontalAlignment', 'left', ...
        'Tag', 'lblDName');

    handles.edDName = uicontrol(pLeft, 'Style', 'edit', ...
        'String', '', ...
        'FontSize', 9, ...
        'BackgroundColor', [0.12 0.12 0.15], ...
        'ForegroundColor', [0.9 0.9 0.9], ...
        'TooltipString', 'e.g. SpeedKmh');

    uicontrol(pLeft, 'Style', 'text', ...
        'String', 'Expression:', ...
        'FontSize', 9, ...
        'BackgroundColor', [0.18 0.18 0.22], ...
        'ForegroundColor', [0.8 0.8 0.8], ...
        'HorizontalAlignment', 'left', ...
        'Tag', 'lblDExpr');

    handles.edDExpr = uicontrol(pLeft, 'Style', 'edit', ...
        'String', '', ...
        'FontSize', 9, ...
        'BackgroundColor', [0.12 0.12 0.15], ...
        'ForegroundColor', [0.9 0.9 0.9], ...
        'TooltipString', 'e.g. GPS_0.Spd * 3.6');

    handles.btnCreate = uicontrol(pLeft, 'Style', 'pushbutton', ...
        'String', 'Create Derived Param', ...
        'FontSize', 10, ...
        'BackgroundColor', [0.85 0.6 0.1], ...
        'ForegroundColor', [1 1 1], ...
        'Callback', @createDerivedCb);

    handles.btnDdt = uicontrol(pLeft, 'Style', 'pushbutton', ...
        'String', [char(8706) '/' char(8706) 't'], ...
        'FontSize', 10, 'FontWeight', 'bold', ...
        'BackgroundColor', [0.45 0.30 0.65], ...
        'ForegroundColor', [1 1 1], ...
        'TooltipString', 'Create time-derivative of a parameter (smoothed first)', ...
        'Callback', @derivativeCb);

    handles.lbDerived = uicontrol(pLeft, 'Style', 'listbox', ...
        'String', {}, ...
        'FontSize', 9, ...
        'BackgroundColor', [0.12 0.12 0.15], ...
        'ForegroundColor', [0.85 0.85 0.85], ...
        'Tag', 'lbDerived');

    % --- Clear All ---
    handles.btnClear = uicontrol(pLeft, 'Style', 'pushbutton', ...
        'String', 'Clear All Plots', ...
        'FontSize', 10, ...
        'BackgroundColor', [0.5 0.2 0.2], ...
        'ForegroundColor', [1 1 1], ...
        'Callback', @clearAllCb);

    %% ===== RIGHT PANEL: AXES =====
    % Time series axes (top)
    handles.axTime = axes(fig, 'Units', 'pixels', ...
        'Color', [0.08 0.08 0.10], ...
        'XColor', [0.7 0.7 0.7], ...
        'YColor', [0.7 0.7 0.7], ...
        'GridColor', [0.3 0.3 0.3], ...
        'FontSize', 9, ...
        'Box', 'off');
    grid(handles.axTime, 'on');
    xlabel(handles.axTime, 'Time (s)', 'Color', [0.8 0.8 0.8]);
    title(handles.axTime, 'Time Series Plot', 'Color', [0.9 0.9 0.9], ...
        'FontSize', 12);

    % Flight path axes (bottom)
    handles.axMap = axes(fig, 'Units', 'pixels', ...
        'Color', [0.08 0.08 0.10], ...
        'XColor', [0.7 0.7 0.7], ...
        'YColor', [0.7 0.7 0.7], ...
        'GridColor', [0.3 0.3 0.3], ...
        'FontSize', 9, ...
        'Box', 'on', ...
        'DataAspectRatioMode', 'auto');
    grid(handles.axMap, 'on');
    xlabel(handles.axMap, 'Longitude', 'Color', [0.8 0.8 0.8]);
    ylabel(handles.axMap, 'Latitude', 'Color', [0.8 0.8 0.8]);
    title(handles.axMap, 'Flight Path', 'Color', [0.9 0.9 0.9], ...
        'FontSize', 12);

    handles.pLeft = pLeft;

    %% Store handles
    guidata(fig, handles);

    %% Initial layout — set ResizeFcn now that handles exist, then show
    set(fig, 'ResizeFcn', @resizeCb);
    resizeCb(fig, []);
    set(fig, 'Visible', 'on');

    %% Auto-load saved derivatives from JSON
    loadSavedDerivatives(fig);

    %% Auto-load if file provided
    if nargin > 0 && ~isempty(binFile)
        loadFileImpl(fig, binFile);
    end

    %% ================== CALLBACKS ==================

    function resizeCb(src, ~)
        figObj = ancestor(src, 'figure');
        fp = get(figObj, 'Position');
        W = fp(3); H = fp(4);

        panelW = min(310, round(W * 0.22));
        axLeft = panelW + 15;
        axW    = W - axLeft - 15;
        axH    = round((H - 80) / 2);

        % Left panel
        set(handles.pLeft, 'Position', [0, 0, panelW, H]);

        % Layout left panel controls from top
        m  = 8;   % margin
        cw = panelW - 2*m;
        y  = H - 10;

        y = y - 35;
        set(handles.btnLoad, 'Position', [m, y, cw, 30]);
        y = y - 18;
        set(handles.lblFile, 'Position', [m, y, cw, 16]);

        y = y - 22;
        ch = findobj(pLeft, 'Tag', 'lblParams');
        set(ch, 'Position', [m, y, cw, 18]);

        paramH = max(100, H - 430);
        y = y - paramH;
        set(handles.lbParams, 'Position', [m, y, cw, paramH]);

        halfW = floor((cw - 4) / 2);
        y = y - 26;
        set(handles.btnAdd, 'Position', [m, y, halfW, 23]);
        set(handles.btnInsertExpr, 'Position', [m + halfW + 4, y, halfW, 23]);

        y = y - 18;
        ch = findobj(pLeft, 'Tag', 'lblActive');
        set(ch, 'Position', [m, y, cw, 16]);

        activeH = max(35, min(55, round(H * 0.06)));
        y = y - activeH;
        set(handles.lbActive, 'Position', [m, y, cw, activeH]);

        y = y - 24;
        set(handles.btnRemove, 'Position', [m, y, halfW, 22]);

        % Expression row (inline)
        ch = findobj(pLeft, 'Tag', 'lblExpr');
        set(ch, 'Position', [m + halfW + 4, y, halfW, 22]);
        y = y - 22;
        set(handles.edExpr, 'Position', [m, y, cw - 60, 20]);
        set(handles.btnAddExpr, 'Position', [m + cw - 58, y, 58, 20]);

        y = y - 18;
        ch = findobj(pLeft, 'Tag', 'lblDerived');
        set(ch, 'Position', [m, y, cw, 16]);

        y = y - 18;
        ch = findobj(pLeft, 'Tag', 'lblDName');
        set(ch, 'Position', [m, y, 40, 16]);
        set(handles.edDName, 'Position', [m+42, y, cw-42, 18]);

        y = y - 20;
        ch = findobj(pLeft, 'Tag', 'lblDExpr');
        set(ch, 'Position', [m, y, 40, 16]);
        set(handles.edDExpr, 'Position', [m+42, y, cw-42, 18]);

        y = y - 24;
        createW = cw - 42;
        set(handles.btnCreate, 'Position', [m, y, createW, 22]);
        set(handles.btnDdt, 'Position', [m + createW + 2, y, 38, 22]);

        derivedH = max(25, y - m - 28);
        y = y - derivedH;
        set(handles.lbDerived, 'Position', [m, max(m+26, y), cw, max(25, derivedH)]);

        set(handles.btnClear, 'Position', [m, m, cw, 23]);

        % Right axes — leave generous left margin for multi Y-axes
        yAxMargin = 80;  % extra left space for stacked Y-axis labels
        axPlotLeft = axLeft + yAxMargin;
        axPlotW    = axW - yAxMargin;

        % Top toolbar
        toolbarH = 32;
        set(handles.pToolbar, 'Position', [axLeft, H - toolbarH - 2, axW, toolbarH]);
        set(handles.btnSegAnalysis, 'Position', [6, 3, 130, 26]);
        set(handles.btnDerivMgr, 'Position', [142, 3, 140, 26]);
        set(handles.btnFilter, 'Position', [288, 3, 110, 26]);
        set(handles.btnCalcDist, 'Position', [404, 3, 120, 26]);

        % Axes below toolbar
        topMargin = toolbarH + 40;   % space above time plot (toolbar + title room)
        botMargin = 55;              % space below flight path for x-axis label
        gap = 45;                    % gap between time plot and flight path
        availH = H - topMargin - botMargin - gap;
        topAxH = round(availH * 0.50);
        botAxH = availH - topAxH;

        timeAxBot = H - topMargin - topAxH;
        set(handles.axTime, 'Position', [axPlotLeft, timeAxBot, axPlotW, topAxH]);
        set(handles.axMap, 'Position', [axLeft, botMargin, axW, botAxH]);

        % Reposition any extra Y-axes
        repositionExtraAxes(handles, axLeft, yAxMargin, axPlotLeft, axPlotW, timeAxBot, topAxH);
    end

    function loadFileCb(src, ~)
        [f, p] = uigetfile({'*.bin','ArduPilot Log (*.bin)'; '*.*','All Files'}, ...
            'Select ArduPilot .bin Log');
        if isequal(f, 0), return; end
        loadFileImpl(ancestor(src, 'figure'), fullfile(p, f));
    end

    function loadFileImpl(figObj, filename)
        h = guidata(figObj);
        set(figObj, 'Pointer', 'watch'); drawnow;
        try
            h.logData  = parseBinLog(filename);
            h.filename = filename;
            [~, fn, ext] = fileparts(filename);
            set(h.lblFile, 'String', [fn ext]);

            % Populate parameter list (tree view — all collapsed)
            h.expandedGroups = {};
            refreshParamTree(h);
            set(h.lbParams, 'Value', []);

            % Plot flight path
            h = plotFlightPath(h);

            % Recompute saved derivatives with new log data
            if isstruct(h.derivedData) && ~isempty(fieldnames(h.derivedData))
                dNames = fieldnames(h.derivedData);
                % Sort by dependency: entries referencing DERIVED go later
                depOrder = zeros(numel(dNames), 1);
                for di = 1:numel(dNames)
                    d = h.derivedData.(dNames{di});
                    inStr = '';
                    if isfield(d, 'recipe') && isfield(d.recipe, 'input')
                        inStr = d.recipe.input;
                    elseif isfield(d, 'expr')
                        inStr = d.expr;
                    end
                    if contains(inStr, 'DERIVED')
                        depOrder(di) = 1;
                    end
                end
                [~, sortIdx] = sort(depOrder);
                dNames = dNames(sortIdx);

                for di = 1:numel(dNames)
                    nm = dNames{di};
                    try
                        h = recomputeFromRecipe(h, nm);
                    catch ME
                        fprintf('Warning: saved deriv "%s" failed: %s\n', nm, ME.message);
                    end
                end
                updateDerivedListbox(h);
                refreshParamTree(h);
            end

            guidata(figObj, h);
            set(figObj, 'Name', ['ArduPilot Log Viewer — ' fn ext]);
        catch ME
            set(figObj, 'Pointer', 'arrow');
            errordlg(ME.message, 'Load Error');
            return;
        end
        set(figObj, 'Pointer', 'arrow');
    end

    function paramsListClickCb(src, ~)
    % Single-click on group header toggles expand/collapse
    % Double-click on a field inserts into derived expression
        figObj = ancestor(src, 'figure');
        h = guidata(figObj);
        sel = get(h.lbParams, 'Value');
        items = get(h.lbParams, 'String');
        if isempty(sel) || isempty(items), return; end

        clickedItem = items{sel(1)};
        isDouble = strcmp(get(figObj, 'SelectionType'), 'open');

        if startsWith(clickedItem, char(9654)) || startsWith(clickedItem, char(9660))
            % Group header clicked — toggle expand/collapse
            groupName = strtrim(extractAfter(clickedItem, 1));
            if any(strcmp(h.expandedGroups, groupName))
                h.expandedGroups(strcmp(h.expandedGroups, groupName)) = [];
            else
                h.expandedGroups{end+1} = groupName;
            end
            guidata(figObj, h);
            refreshParamTree(h);
        elseif isDouble && startsWith(clickedItem, '    ')
            % Double-click on a field — insert into expression
            param = strtrim(clickedItem);
            existing = get(h.edDExpr, 'String');
            if isempty(existing)
                set(h.edDExpr, 'String', param);
            else
                set(h.edDExpr, 'String', [existing ' ' param]);
            end
        end
    end

    function refreshParamTree(h)
    %REFRESHPARAMTREE Rebuild the listbox with collapsible tree items
        if isempty(h.logData)
            set(h.lbParams, 'String', {}, 'Value', []);
            return;
        end
        items = {};
        msgNames = sort(fieldnames(h.logData));
        for mi = 1:numel(msgNames)
            msg = msgNames{mi};
            isExp = any(strcmp(h.expandedGroups, msg));
            if isExp
                items{end+1} = [char(9660) ' ' msg]; %#ok<AGROW>  % down arrow
                fields = sort(fieldnames(h.logData.(msg)));
                for fi = 1:numel(fields)
                    items{end+1} = ['    ' msg '.' fields{fi}]; %#ok<AGROW>
                end
            else
                items{end+1} = [char(9654) ' ' msg]; %#ok<AGROW>  % right arrow
            end
        end
        % Also add derived params
        if isstruct(h.derivedData) && ~isempty(fieldnames(h.derivedData))
            dNames = fieldnames(h.derivedData);
            isExp = any(strcmp(h.expandedGroups, 'DERIVED'));
            if isExp
                items{end+1} = [char(9660) ' DERIVED'];
                for di = 1:numel(dNames)
                    items{end+1} = ['    DERIVED.' dNames{di}]; %#ok<AGROW>
                end
            else
                items{end+1} = [char(9654) ' DERIVED'];
            end
        end
        set(h.lbParams, 'String', items, 'Value', []);
    end

    function insertIntoExprCb(src, ~)
    % Insert selected available param(s) into the derived expression field
        figObj = ancestor(src, 'figure');
        h = guidata(figObj);
        sel = get(h.lbParams, 'Value');
        items = get(h.lbParams, 'String');
        if isempty(sel) || isempty(items), return; end
        existing = strtrim(get(h.edDExpr, 'String'));
        for si = 1:numel(sel)
            item = items{sel(si)};
            if ~startsWith(item, '    '), continue; end  % skip group headers
            param = strtrim(item);
            if isempty(existing)
                existing = param;
            else
                existing = [existing ' ' param]; %#ok<AGROW>
            end
        end
        set(h.edDExpr, 'String', existing);
    end

    function addToPlotCb(src, ~)
        figObj = ancestor(src, 'figure');
        h = guidata(figObj);
        if isempty(h.logData), return; end

        sel = get(h.lbParams, 'Value');
        items = get(h.lbParams, 'String');
        if isempty(sel), return; end

        for si = 1:numel(sel)
            item = items{sel(si)};
            if ~startsWith(item, '    '), continue; end  % skip group headers
            expr = strtrim(item);
            if ~any(strcmp(h.activePlots, expr))
                h.activePlots{end+1} = expr;
            end
        end

        set(h.lbActive, 'String', h.activePlots, 'Value', []);
        guidata(figObj, h);
        updateTimePlot(h);
    end

    function removeFromPlotCb(src, ~)
        figObj = ancestor(src, 'figure');
        h = guidata(figObj);

        sel = get(h.lbActive, 'Value');
        if isempty(sel), return; end

        h.activePlots(sel) = [];
        set(h.lbActive, 'String', h.activePlots, 'Value', []);
        guidata(figObj, h);
        updateTimePlot(h);
    end

    function addExprCb(src, ~)
        figObj = ancestor(src, 'figure');
        h = guidata(figObj);
        if isempty(h.logData), return; end

        expr = strtrim(get(h.edExpr, 'String'));
        if isempty(expr), return; end

        % Validate expression
        try
            [~, ~] = evalExpression(expr, h.logData, h.derivedData);
        catch ME
            errordlg(['Expression error: ' ME.message], 'Error');
            return;
        end

        if ~any(strcmp(h.activePlots, expr))
            h.activePlots{end+1} = expr;
        end

        set(h.lbActive, 'String', h.activePlots, 'Value', []);
        set(h.edExpr, 'String', '');
        guidata(figObj, h);
        updateTimePlot(h);
    end

    function createDerivedCb(src, ~)
        figObj = ancestor(src, 'figure');
        h = guidata(figObj);
        if isempty(h.logData), return; end

        dName = strtrim(get(h.edDName, 'String'));
        dExpr = strtrim(get(h.edDExpr, 'String'));

        if isempty(dName) || isempty(dExpr)
            errordlg('Enter both Name and Expression.', 'Error');
            return;
        end

        dName = matlab.lang.makeValidName(dName);

        try
            [vals, tVec] = evalExpression(dExpr, h.logData, h.derivedData);
        catch ME
            errordlg(['Expression error: ' ME.message], 'Error');
            return;
        end

        recipe = struct('type', 'expr', 'input', dExpr);
        h.derivedData.(dName) = struct('values', vals, 'time', tVec, 'expr', dExpr, 'recipe', recipe);

        % Update derived list
        updateDerivedListbox(h);

        % Add to available parameters (refresh tree)
        refreshParamTree(h);

        set(h.edDName, 'String', '');
        set(h.edDExpr, 'String', '');
        guidata(figObj, h);
        fprintf('Created derived parameter: %s = %s (%d samples)\n', ...
            dName, dExpr, numel(vals));
    end

    function derivativeCb(src, ~)
    % Compute d/dt: analyze spectrum, recommend cutoff, filter, then differentiate
        figObj = ancestor(src, 'figure');
        h = guidata(figObj);
        if isempty(h.logData)
            msgbox('Load a .bin file first.', 'Derivative');
            return;
        end

        % Pre-fill from the derived expression box if non-empty
        defaultExpr = strtrim(get(h.edDExpr, 'String'));
        defaultName = strtrim(get(h.edDName, 'String'));
        if isempty(defaultName) && ~isempty(defaultExpr)
            defaultName = ['d_' matlab.lang.makeValidName(defaultExpr)];
        end

        % Step 1: Ask for input expression only
        ans1 = inputdlg({ ...
            'Input parameter/expression (e.g. GPS_0.Spd):', ...
            'Output name:'}, ...
            'Time Derivative (d/dt) — Step 1: Select Signal', [1 50], ...
            {defaultExpr, defaultName});
        if isempty(ans1), return; end

        inExpr  = strtrim(ans1{1});
        outName = matlab.lang.makeValidName(strtrim(ans1{2}));
        if isempty(inExpr) || isempty(outName)
            errordlg('Both input expression and output name are required.', 'Derivative');
            return;
        end

        try
            [vals, tVec] = evalExpression(inExpr, h.logData, h.derivedData);
        catch ME
            errordlg(['Expression error: ' ME.message], 'Derivative');
            return;
        end

        if numel(vals) < 8
            errordlg('Not enough data points.', 'Derivative');
            return;
        end

        % Step 2: Analyze spectrum and recommend
        dt = median(diff(tVec));
        if dt <= 0, dt = eps; end
        Fs = 1 / dt;
        [recCutoff, recType, summary] = analyzeSpectrum(vals(:), Fs);

        % Step 3: Show recommendation, let user accept or override
        prompt = sprintf([ ...
            '--- Spectral Analysis ---\n%s\n\n' ...
            'Recommended: %s at %.2f Hz\n\n' ...
            'Enter low-pass cutoff frequency (Hz):'], ...
            summary, recType, recCutoff);

        ans2 = inputdlg({prompt}, ...
            sprintf('d/dt — Step 2: Filter (Fs=%.1f Hz)', Fs), [5 60], ...
            {sprintf('%.2f', recCutoff)});
        if isempty(ans2), return; end

        cutoffHz = str2double(strtrim(ans2{1}));
        if isnan(cutoffHz) || cutoffHz <= 0
            errordlg('Enter a valid positive cutoff frequency.', 'Derivative');
            return;
        end

        % Step 4: Filter + differentiate
        smoothed = fftLowPass(vals(:), Fs, cutoffHz);
        dtVec = gradient(tVec(:));
        dtVec(dtVec == 0) = eps;
        dVdt = gradient(smoothed) ./ dtVec;

        derivExpr = sprintf('d(%s)/dt [lpf=%.1fHz]', inExpr, cutoffHz);
        recipe = struct('type', 'derivative', 'input', inExpr, 'cutoffHz', cutoffHz);
        h.derivedData.(outName) = struct('values', dVdt(:)', 'time', tVec(:)', 'expr', derivExpr, 'recipe', recipe);
        updateDerivedListbox(h);
        refreshParamTree(h);
        guidata(figObj, h);

        fprintf('Created derivative: %s = d(%s)/dt (%d samples, cutoff=%.1f Hz, Fs=%.1f Hz)\n', ...
            outName, inExpr, numel(dVdt), cutoffHz, Fs);
    end

    function filterSignalCb(src, ~)
    % FFT-based filter: analyze spectrum first, recommend, then filter
        figObj = ancestor(src, 'figure');
        h = guidata(figObj);
        if isempty(h.logData)
            msgbox('Load a .bin file first.', 'Filter Signal');
            return;
        end

        % Step 1: Ask for input expression only
        ans1 = inputdlg({ ...
            'Parameter/expression to filter:', ...
            'Output name:'}, ...
            'FFT Filter — Step 1: Select Signal', [1 55], ...
            {'', ''});
        if isempty(ans1), return; end

        inExpr  = strtrim(ans1{1});
        outName = matlab.lang.makeValidName(strtrim(ans1{2}));
        if isempty(inExpr) || isempty(outName)
            errordlg('Input expression and output name are required.', 'Filter');
            return;
        end

        try
            [vals, tVec] = evalExpression(inExpr, h.logData, h.derivedData);
        catch ME
            errordlg(['Expression error: ' ME.message], 'Filter');
            return;
        end

        N = numel(vals);
        if N < 8
            errordlg('Not enough data points for filtering.', 'Filter');
            return;
        end

        dt = median(diff(tVec));
        if dt <= 0, dt = eps; end
        Fs = 1 / dt;

        % Step 2: Analyze spectrum and recommend
        [recCutoff, recType, summary] = analyzeSpectrum(vals(:), Fs);

        prompt = sprintf([ ...
            '--- Spectral Analysis ---\n%s\n\n' ...
            'Recommended: %s at %.2f Hz\n\n' ...
            'Filter type (lowpass / highpass / bandpass):'], ...
            summary, recType, recCutoff);

        ans2 = inputdlg({ ...
            prompt, ...
            'Cutoff frequency Hz (for bandpass: low,high):'}, ...
            sprintf('FFT Filter — Step 2 (Fs=%.1f Hz)', Fs), [5 60; 1 60], ...
            {recType, sprintf('%.2f', recCutoff)});
        if isempty(ans2), return; end

        filtType  = lower(strtrim(ans2{1}));
        cutoffStr = strtrim(ans2{2});

        switch filtType
            case 'lowpass'
                fc = str2double(cutoffStr);
                if isnan(fc) || fc <= 0
                    errordlg('Enter a positive cutoff frequency.', 'Filter');
                    return;
                end
                filtered = fftLowPass(vals(:), Fs, fc);
                filtDesc = sprintf('lpf(%s, %.1fHz)', inExpr, fc);

            case 'highpass'
                fc = str2double(cutoffStr);
                if isnan(fc) || fc <= 0
                    errordlg('Enter a positive cutoff frequency.', 'Filter');
                    return;
                end
                filtered = fftHighPass(vals(:), Fs, fc);
                filtDesc = sprintf('hpf(%s, %.1fHz)', inExpr, fc);

            case 'bandpass'
                parts = str2double(strsplit(cutoffStr, ','));
                if numel(parts) ~= 2 || any(isnan(parts)) || parts(1) >= parts(2)
                    errordlg('For bandpass enter two frequencies: low,high (e.g. 1,10)', 'Filter');
                    return;
                end
                filtered = fftBandPass(vals(:), Fs, parts(1), parts(2));
                filtDesc = sprintf('bpf(%s, %.1f-%.1fHz)', inExpr, parts(1), parts(2));

            otherwise
                errordlg('Unknown filter type. Use: lowpass, highpass, or bandpass', 'Filter');
                return;
        end

        switch filtType
            case 'lowpass',  recipe = struct('type','filter','filtType','lowpass','input',inExpr,'cutoffHz',fc);
            case 'highpass', recipe = struct('type','filter','filtType','highpass','input',inExpr,'cutoffHz',fc);
            case 'bandpass', recipe = struct('type','filter','filtType','bandpass','input',inExpr,'loHz',parts(1),'hiHz',parts(2));
        end
        h.derivedData.(outName) = struct('values', filtered(:)', 'time', tVec(:)', 'expr', filtDesc, 'recipe', recipe);
        updateDerivedListbox(h);
        refreshParamTree(h);
        guidata(figObj, h);

        fprintf('Created filtered param: %s = %s (%d samples, Fs=%.1f Hz)\n', ...
            outName, filtDesc, numel(filtered), Fs);
    end

    function calcDistanceCb(src, ~)
    % Calculate total horizontal distance between two time points along a GPS track.
        figObj = ancestor(src, 'figure');
        h = guidata(figObj);
        if isempty(h.logData)
            msgbox('Load a .bin file first.', 'Calc Distance');
            return;
        end

        % Default lat/lon param names from gpsCache if available
        defLat = 'GPS.Lat';
        defLon = 'GPS.Lng';
        ld = h.logData;
        msgNames = fieldnames(ld);
        for mi = 1:numel(msgNames)
            nm = msgNames{mi};
            if isfield(ld.(nm), 'Lat') && isfield(ld.(nm), 'Lng')
                defLat = [nm '.Lat'];
                defLon = [nm '.Lng'];
                break;
            end
        end

        % Get current X-axis limits as default time range
        xl = get(h.axTime, 'XLim');
        defT1 = sprintf('%.2f', xl(1));
        defT2 = sprintf('%.2f', xl(2));

        prompt = { ...
            'Latitude parameter (MSG.Field):', ...
            'Longitude parameter (MSG.Field):', ...
            'Start time (s):', ...
            'End time (s):'};
        dlgTitle = 'Calculate Horizontal Distance';
        dims = [1 55; 1 55; 1 55; 1 55];
        defaults = {defLat, defLon, defT1, defT2};
        answer = inputdlg(prompt, dlgTitle, dims, defaults);
        if isempty(answer), return; end

        latParam = strtrim(answer{1});
        lonParam = strtrim(answer{2});
        t1 = str2double(answer{3});
        t2 = str2double(answer{4});
        if isnan(t1) || isnan(t2) || t2 <= t1
            errordlg('Invalid time range. End must be greater than Start.', 'Calc Distance');
            return;
        end

        % Evaluate lat and lon expressions
        try
            [latVals, latTime] = evalExpression(latParam, ld, h.derivedData);
            [lonVals, lonTime] = evalExpression(lonParam, ld, h.derivedData);
        catch me
            errordlg(['Could not evaluate parameters: ' me.message], 'Calc Distance');
            return;
        end

        % Align lat/lon onto common time vector (use lat's time as base)
        tBase = latTime(:);
        latV  = latVals(:);
        % Resample lon onto lat's time grid (nearest neighbour)
        lonV  = zeros(size(tBase));
        for ki = 1:numel(tBase)
            [~, idx] = min(abs(lonTime - tBase(ki)));
            lonV(ki) = lonVals(idx);
        end

        % Filter to requested time range
        mask = tBase >= t1 & tBase <= t2;
        latSeg = latV(mask);
        lonSeg = lonV(mask);
        tSeg   = tBase(mask);

        if numel(latSeg) < 2
            errordlg('Not enough data points in the selected time range.', 'Calc Distance');
            return;
        end

        % Filter out zero lat/lon points
        valid = latSeg ~= 0 & lonSeg ~= 0;
        latSeg = latSeg(valid);
        lonSeg = lonSeg(valid);
        tSeg   = tSeg(valid);

        if numel(latSeg) < 2
            errordlg('Not enough valid (non-zero) GPS points in range.', 'Calc Distance');
            return;
        end

        % Compute cumulative haversine distance (metres)
        totalDist = 0;
        R = 6371000; % Earth radius in metres
        for ki = 2:numel(latSeg)
            dLat = deg2rad(latSeg(ki) - latSeg(ki-1));
            dLon = deg2rad(lonSeg(ki) - lonSeg(ki-1));
            a = sin(dLat/2)^2 + cosd(latSeg(ki-1)) * cosd(latSeg(ki)) * sin(dLon/2)^2;
            totalDist = totalDist + R * 2 * atan2(sqrt(a), sqrt(1 - a));
        end

        % Duration
        duration = tSeg(end) - tSeg(1);

        % Format result
        if totalDist >= 1000
            distStr = sprintf('%.2f km', totalDist / 1000);
        else
            distStr = sprintf('%.1f m', totalDist);
        end
        avgSpeed = totalDist / max(duration, eps);
        if avgSpeed >= 1000/3600
            spdStr = sprintf('%.1f km/h', avgSpeed * 3.6);
        else
            spdStr = sprintf('%.2f m/s', avgSpeed);
        end

        msg = sprintf([ ...
            'Horizontal Distance\n' ...
            '─────────────────────\n' ...
            'Distance:   %s\n' ...
            'Duration:   %.1f s\n' ...
            'Avg Speed:  %s\n' ...
            'Points:     %d\n' ...
            'Time Range: %.2f – %.2f s'], ...
            distStr, duration, spdStr, numel(latSeg), tSeg(1), tSeg(end));
        msgbox(msg, 'Distance Result', 'help');
    end

    function clearAllCb(src, ~)
        figObj = ancestor(src, 'figure');
        h = guidata(figObj);
        h.activePlots = {};
        set(h.lbActive, 'String', {}, 'Value', []);
        % Delete extra axes and listener
        for ea = 1:numel(h.extraAxes)
            if isvalid(h.extraAxes(ea)), delete(h.extraAxes(ea)); end
        end
        h.extraAxes = [];
        h.plotDataCache = {};
        if ~isempty(h.xlimListener)
            delete(h.xlimListener);
            h.xlimListener = [];
        end
        guidata(figObj, h);
        cla(h.axTime);
        title(h.axTime, 'Time Series Plot', 'Color', [0.9 0.9 0.9]);
        legend(h.axTime, 'off');
    end

    %% ================== SAVED DERIVATIVES MANAGER ==================

    function loadSavedDerivatives(figObj)
    % Load saved derivative definitions from JSON file on startup
        h = guidata(figObj);
        if ~isfile(h.savedDerivFile), return; end
        try
            txt = fileread(h.savedDerivFile);
            saved = jsondecode(txt);
            if ~isstruct(saved), return; end
            names = fieldnames(saved);
            for k = 1:numel(names)
                nm = names{k};
                entry = saved.(nm);
                % New format: struct with expr + recipe
                if isstruct(entry) && isfield(entry, 'recipe')
                    h.derivedData.(nm) = struct('values', [], 'time', [], ...
                        'expr', entry.expr, 'recipe', entry.recipe);
                else
                    % Legacy format: bare expression string — parse into recipe
                    recipe = parseLegacyExpr(entry);
                    h.derivedData.(nm) = struct('values', [], 'time', [], ...
                        'expr', entry, 'recipe', recipe);
                end
                h.savedDerivNames{end+1} = nm;
            end
            updateDerivedListbox(h);
            refreshParamTree(h);
            guidata(figObj, h);
            fprintf('Loaded %d saved derivative(s) from %s\n', numel(names), h.savedDerivFile);
        catch ME
            fprintf('Warning: could not load saved derivatives: %s\n', ME.message);
        end
    end

    function writeSavedDerivFile(h)
    % Write the current set of saved derivatives to JSON (with recipe)
        saveStruct = struct();
        for k = 1:numel(h.savedDerivNames)
            nm = h.savedDerivNames{k};
            if isfield(h.derivedData, nm)
                d = h.derivedData.(nm);
                if isfield(d, 'recipe')
                    saveStruct.(nm) = struct('expr', d.expr, 'recipe', d.recipe);
                else
                    saveStruct.(nm) = struct('expr', d.expr, ...
                        'recipe', struct('type', 'expr', 'input', d.expr));
                end
            end
        end
        txt = jsonencode(saveStruct);
        fid = fopen(h.savedDerivFile, 'w');
        fprintf(fid, '%s', txt);
        fclose(fid);
    end

    function h = recomputeFromRecipe(h, nm)
    % Recompute a derived parameter using its stored recipe
        d = h.derivedData.(nm);
        if ~isfield(d, 'recipe')
            % Fallback: try as plain expression
            [vals, tVec] = evalExpression(d.expr, h.logData, h.derivedData);
            h.derivedData.(nm).values = vals;
            h.derivedData.(nm).time   = tVec;
            return;
        end

        r = d.recipe;
        switch r.type
            case 'expr'
                [vals, tVec] = evalExpression(r.input, h.logData, h.derivedData);
                h.derivedData.(nm).values = vals;
                h.derivedData.(nm).time   = tVec;

            case 'derivative'
                [vals, tVec] = evalExpression(r.input, h.logData, h.derivedData);
                dt = median(diff(tVec));
                if dt <= 0, dt = eps; end
                Fs = 1 / dt;
                cutoff = r.cutoffHz;
                if cutoff <= 0, cutoff = Fs / 10; end
                smoothed = fftLowPass(vals(:), Fs, cutoff);
                dtVec = gradient(tVec(:));
                dtVec(dtVec == 0) = eps;
                dVdt = gradient(smoothed) ./ dtVec;
                h.derivedData.(nm).values = dVdt(:)';
                h.derivedData.(nm).time   = tVec(:)';

            case 'filter'
                [vals, tVec] = evalExpression(r.input, h.logData, h.derivedData);
                dt = median(diff(tVec));
                if dt <= 0, dt = eps; end
                Fs = 1 / dt;
                switch r.filtType
                    case 'lowpass'
                        filtered = fftLowPass(vals(:), Fs, r.cutoffHz);
                    case 'highpass'
                        filtered = fftHighPass(vals(:), Fs, r.cutoffHz);
                    case 'bandpass'
                        filtered = fftBandPass(vals(:), Fs, r.loHz, r.hiHz);
                    otherwise
                        error('Unknown filter type: %s', r.filtType);
                end
                h.derivedData.(nm).values = filtered(:)';
                h.derivedData.(nm).time   = tVec(:)';

            otherwise
                error('Unknown recipe type: %s', r.type);
        end
        fprintf('Recomputed: %s = %s\n', nm, d.expr);
    end

    function recipe = parseLegacyExpr(exprStr)
    %PARSELEGACYEXPR  Convert old display strings into a machine-readable recipe.
    %   Handles: lpf(..., XHz), hpf(..., XHz), bpf(..., X-YHz),
    %            d(...)/dt [lpf=XHz], and plain expressions.

        % Try lpf(input, XHz)
        tok = regexp(exprStr, '^lpf\((.+),\s*([\d.]+)Hz\)$', 'tokens');
        if ~isempty(tok)
            recipe = struct('type','filter','filtType','lowpass', ...
                'input', strtrim(tok{1}{1}), 'cutoffHz', str2double(tok{1}{2}));
            return;
        end

        % Try hpf(input, XHz)
        tok = regexp(exprStr, '^hpf\((.+),\s*([\d.]+)Hz\)$', 'tokens');
        if ~isempty(tok)
            recipe = struct('type','filter','filtType','highpass', ...
                'input', strtrim(tok{1}{1}), 'cutoffHz', str2double(tok{1}{2}));
            return;
        end

        % Try bpf(input, X-YHz)
        tok = regexp(exprStr, '^bpf\((.+),\s*([\d.]+)-([\d.]+)Hz\)$', 'tokens');
        if ~isempty(tok)
            recipe = struct('type','filter','filtType','bandpass', ...
                'input', strtrim(tok{1}{1}), ...
                'loHz', str2double(tok{1}{2}), 'hiHz', str2double(tok{1}{3}));
            return;
        end

        % Try d(...)/dt [lpf=XHz]
        tok = regexp(exprStr, '^d\((.+)\)/dt\s*\[lpf=([\d.]+)Hz\]$', 'tokens');
        if ~isempty(tok)
            recipe = struct('type','derivative', ...
                'input', strtrim(tok{1}{1}), 'cutoffHz', str2double(tok{1}{2}));
            return;
        end

        % Plain expression
        recipe = struct('type', 'expr', 'input', exprStr);
    end

    function updateDerivedListbox(h)
    % Refresh the derived params listbox, marking saved ones with [SAVED]
        if ~isstruct(h.derivedData) || isempty(fieldnames(h.derivedData))
            set(h.lbDerived, 'String', {});
            return;
        end
        dNames = fieldnames(h.derivedData);
        dStrings = {};
        for di = 1:numel(dNames)
            nm = dNames{di};
            expr = h.derivedData.(nm).expr;
            if ismember(nm, h.savedDerivNames)
                tag = '[SAVED] ';
            else
                tag = '';
            end
            dStrings{di} = sprintf('%sDERIVED.%s  [= %s]', tag, nm, expr);
        end
        set(h.lbDerived, 'String', dStrings);
    end

    function derivManagerCb(src, ~)
        figObj = ancestor(src, 'figure');
        h = guidata(figObj);

        % Collect all derived params (saved + unsaved)
        if ~isstruct(h.derivedData) || isempty(fieldnames(h.derivedData))
            msgbox('No derived parameters defined yet.', 'Saved Derivatives');
            return;
        end

        dNames = fieldnames(h.derivedData);
        nD = numel(dNames);

        % Build dialog
        dlgH = 50 + nD * 32 + 10;
        dlgW = 650;
        dlgFig = figure('Name', 'Saved Derivatives Manager', ...
            'NumberTitle', 'off', ...
            'Color', [0.15 0.15 0.18], ...
            'Position', [250, 250, dlgW, dlgH], ...
            'MenuBar', 'none', 'ToolBar', 'none', ...
            'Resize', 'off');

        % Header
        uicontrol(dlgFig, 'Style', 'text', ...
            'String', '  Name                    Expression                                                        Action', ...
            'Units', 'pixels', 'Position', [5, dlgH - 28, dlgW - 10, 22], ...
            'FontSize', 9, 'FontWeight', 'bold', ...
            'ForegroundColor', [0.8 0.8 0.8], ...
            'BackgroundColor', [0.22 0.22 0.27], ...
            'HorizontalAlignment', 'left');

        for di = 1:nD
            nm = dNames{di};
            expr = h.derivedData.(nm).expr;
            isSaved = ismember(nm, h.savedDerivNames);
            yRow = dlgH - 28 - di * 32;

            % Name label
            uicontrol(dlgFig, 'Style', 'text', ...
                'String', nm, ...
                'Units', 'pixels', 'Position', [8, yRow, 110, 22], ...
                'FontSize', 9, ...
                'ForegroundColor', [0.9 0.85 0.5], ...
                'BackgroundColor', [0.15 0.15 0.18], ...
                'HorizontalAlignment', 'left');

            % Expression label
            uicontrol(dlgFig, 'Style', 'text', ...
                'String', expr, ...
                'Units', 'pixels', 'Position', [122, yRow, 340, 22], ...
                'FontSize', 9, ...
                'ForegroundColor', [0.85 0.85 0.85], ...
                'BackgroundColor', [0.12 0.12 0.15], ...
                'HorizontalAlignment', 'left');

            if isSaved
                % Status tag
                uicontrol(dlgFig, 'Style', 'text', ...
                    'String', 'SAVED', ...
                    'Units', 'pixels', 'Position', [468, yRow, 50, 22], ...
                    'FontSize', 8, 'FontWeight', 'bold', ...
                    'ForegroundColor', [0.4 0.9 0.4], ...
                    'BackgroundColor', [0.15 0.15 0.18]);

                % Delete button
                uicontrol(dlgFig, 'Style', 'pushbutton', ...
                    'String', 'Delete', ...
                    'Units', 'pixels', 'Position', [522, yRow, 60, 24], ...
                    'FontSize', 8, ...
                    'BackgroundColor', [0.6 0.2 0.2], ...
                    'ForegroundColor', [1 1 1], ...
                    'Callback', @(~,~) derivAction(figObj, dlgFig, nm, 'delete'));

                % Override button
                uicontrol(dlgFig, 'Style', 'pushbutton', ...
                    'String', 'Override', ...
                    'Units', 'pixels', 'Position', [585, yRow, 60, 24], ...
                    'FontSize', 8, ...
                    'BackgroundColor', [0.55 0.45 0.15], ...
                    'ForegroundColor', [1 1 1], ...
                    'Callback', @(~,~) derivAction(figObj, dlgFig, nm, 'override'));
            else
                % Unsaved tag
                uicontrol(dlgFig, 'Style', 'text', ...
                    'String', 'unsaved', ...
                    'Units', 'pixels', 'Position', [468, yRow, 50, 22], ...
                    'FontSize', 8, ...
                    'ForegroundColor', [0.9 0.6 0.3], ...
                    'BackgroundColor', [0.15 0.15 0.18]);

                % Save button
                uicontrol(dlgFig, 'Style', 'pushbutton', ...
                    'String', 'Save', ...
                    'Units', 'pixels', 'Position', [522, yRow, 120, 24], ...
                    'FontSize', 8, 'FontWeight', 'bold', ...
                    'BackgroundColor', [0.2 0.55 0.3], ...
                    'ForegroundColor', [1 1 1], ...
                    'Callback', @(~,~) derivAction(figObj, dlgFig, nm, 'save'));
            end
        end
    end

    function derivAction(figObj, dlgFig, name, action)
        h = guidata(figObj);

        switch action
            case 'save'
                % Mark as saved and write to file
                if ~ismember(name, h.savedDerivNames)
                    h.savedDerivNames{end+1} = name;
                end
                guidata(figObj, h);
                writeSavedDerivFile(h);
                updateDerivedListbox(h);
                fprintf('Saved derivative: %s = %s\n', name, h.derivedData.(name).expr);

            case 'delete'
                % Remove from saved list and update file
                h.savedDerivNames = h.savedDerivNames(~strcmp(h.savedDerivNames, name));
                guidata(figObj, h);
                writeSavedDerivFile(h);
                updateDerivedListbox(h);
                fprintf('Removed saved derivative: %s\n', name);

            case 'override'
                % Prompt for new expression
                oldExpr = h.derivedData.(name).expr;
                answer = inputdlg({sprintf('New expression for "%s":', name)}, ...
                    'Override Expression', [1 60], {oldExpr});
                if isempty(answer), return; end
                newExpr = strtrim(answer{1});
                if isempty(newExpr), return; end

                % Update the expression (recompute when log is loaded)
                h.derivedData.(name).expr = newExpr;
                h.derivedData.(name).values = [];
                h.derivedData.(name).time = [];

                % If log data exists, try to recompute now
                if ~isempty(h.logData)
                    try
                        [vals, tVec] = evalExpression(newExpr, h.logData, h.derivedData);
                        h.derivedData.(name).values = vals;
                        h.derivedData.(name).time = tVec;
                    catch ME
                        fprintf('Warning: could not evaluate "%s": %s\n', newExpr, ME.message);
                    end
                end

                if ~ismember(name, h.savedDerivNames)
                    h.savedDerivNames{end+1} = name;
                end
                guidata(figObj, h);
                writeSavedDerivFile(h);
                updateDerivedListbox(h);
                fprintf('Overridden derivative: %s = %s\n', name, newExpr);
        end

        % Refresh the manager dialog
        if isvalid(dlgFig), delete(dlgFig); end
        derivManagerCb(findobj(figObj, 'Tag', 'btnDerivMgr'), []);
    end

    %% ================== SEGMENT ANALYSIS ==================

    function segmentAnalysisCb(src, ~)
        figObj = ancestor(src, 'figure');
        h = guidata(figObj);

        if isempty(h.activePlots)
            msgbox('No parameters plotted. Add traces first.', 'Segment Analysis');
            return;
        end

        % Get current visible X range as defaults
        xl = get(h.axTime, 'XLim');
        defaultT0 = sprintf('%.2f', xl(1));
        defaultT1 = sprintf('%.2f', xl(2));

        % Prompt for segment range
        answer = inputdlg({'Start time (s):', 'End time (s):'}, ...
            'Segment Analysis Range', [1 40], {defaultT0, defaultT1});
        if isempty(answer), return; end

        t0 = str2double(answer{1});
        t1 = str2double(answer{2});
        if isnan(t0) || isnan(t1) || t1 <= t0
            errordlg('Invalid time range.', 'Segment Analysis');
            return;
        end

        % --- Determine flight modes in segment ---
        modeStr = 'N/A';
        if ~isempty(h.logData) && isfield(h.logData, 'MODE')
            if isfield(h.logData.MODE, 'Mode') && isfield(h.logData.MODE, 'TimeUS')
                modeTime = h.logData.MODE.TimeUS / 1e6;
                modeCodes = h.logData.MODE.Mode;
                modeMap = getModeMap();

                % Find modes active during [t0, t1]
                % Include the last mode before t0 (it's active at t0)
                idxBefore = find(modeTime <= t0, 1, 'last');
                idxInRange = find(modeTime >= t0 & modeTime <= t1);
                relevantIdx = unique([idxBefore; idxInRange(:)]);
                relevantIdx(relevantIdx == 0) = [];

                if ~isempty(relevantIdx)
                    uniqueCodes = unique(modeCodes(relevantIdx));
                    modeNames = {};
                    for mi = 1:numel(uniqueCodes)
                        mc = uniqueCodes(mi);
                        if isKey(modeMap, mc)
                            modeNames{end+1} = modeMap(mc); %#ok<AGROW>
                        else
                            modeNames{end+1} = sprintf('Mode%d', mc); %#ok<AGROW>
                        end
                    end
                    modeStr = strjoin(modeNames, ', ');
                end
            end
        end

        % --- Analyze each plotted parameter ---
        paramNames = {};
        minVals  = [];
        maxVals  = [];
        meanVals = [];
        freqVals = [];
        oscLoVals = [];    % 5th percentile (typical oscillation low)
        oscHiVals = [];    % 95th percentile (typical oscillation high)
        maxPosDevs = [];   % max positive deviation from mean
        maxNegDevs = [];   % max negative deviation from mean
        maxSigFreqs = [];  % highest meaningful (non-noise) frequency

        for pi = 1:numel(h.activePlots)
            expr = h.activePlots{pi};
            try
                [vals, tVec] = evalExpression(expr, h.logData, h.derivedData);
            catch
                continue;
            end

            % Segment mask
            mask = tVec >= t0 & tVec <= t1;
            vSeg = vals(mask);
            tSeg = tVec(mask);

            if numel(vSeg) < 2, continue; end

            paramNames{end+1} = expr; %#ok<AGROW>
            mnVal = min(vSeg); mxVal = max(vSeg); avVal = mean(vSeg);
            minVals(end+1)  = mnVal; %#ok<AGROW>
            maxVals(end+1)  = mxVal; %#ok<AGROW>
            meanVals(end+1) = avVal; %#ok<AGROW>

            % Dominant oscillation frequency via peak counting
            freqVals(end+1) = computeDominantFreq(tSeg, vSeg); %#ok<AGROW>

            % Highest meaningful (non-noise) frequency via FFT
            maxSigFreqs(end+1) = computeMaxSignalFreq(tSeg, vSeg); %#ok<AGROW>

            % Typical value range: 10th–90th percentile (80% band)
            sortedSeg = sort(vSeg);
            p10 = sortedSeg(max(1, round(0.10 * numel(sortedSeg))));
            p90 = sortedSeg(min(numel(sortedSeg), round(0.90 * numel(sortedSeg))));
            oscLoVals(end+1) = p10; %#ok<AGROW>
            oscHiVals(end+1) = p90; %#ok<AGROW>

            % Max deviations from mean
            dev = vSeg - avVal;
            maxPosDevs(end+1) = max(dev); %#ok<AGROW>
            maxNegDevs(end+1) = min(dev); %#ok<AGROW>
        end

        if isempty(paramNames)
            msgbox('No valid data in the selected segment.', 'Segment Analysis');
            return;
        end

        % --- Display results in a table figure ---
        resFig = figure('Name', sprintf('Segment Analysis [%.1fs – %.1fs]', t0, t1), ...
            'NumberTitle', 'off', ...
            'Color', [0.15 0.15 0.18], ...
            'Position', [200, 200, 1150, 60 + 26 * numel(paramNames) + 60], ...
            'MenuBar', 'none', 'ToolBar', 'none');

        % Mode label at top
        uicontrol(resFig, 'Style', 'text', ...
            'String', sprintf('Segment: %.2f s – %.2f s  |  Modes: %s', t0, t1, modeStr), ...
            'Units', 'normalized', 'Position', [0.02 0.88 0.96 0.10], ...
            'FontSize', 11, 'FontWeight', 'bold', ...
            'ForegroundColor', [0.9 0.85 0.5], ...
            'BackgroundColor', [0.15 0.15 0.18], ...
            'HorizontalAlignment', 'left');

        % Build table data
        nP = numel(paramNames);
        tableData = cell(nP, 10);
        for k = 1:nP
            tableData{k, 1} = paramNames{k};
            tableData{k, 2} = sprintf('%.4g', minVals(k));
            tableData{k, 3} = sprintf('%.4g', maxVals(k));
            tableData{k, 4} = sprintf('%.4g', meanVals(k));
            tableData{k, 5} = sprintf('%.4g', oscLoVals(k));
            tableData{k, 6} = sprintf('%.4g', oscHiVals(k));
            tableData{k, 7} = sprintf('+%.4g', maxPosDevs(k));
            tableData{k, 8} = sprintf('%.4g', maxNegDevs(k));
            if freqVals(k) > 0
                tableData{k, 9} = sprintf('%.2f Hz', freqVals(k));
            else
                tableData{k, 9} = '—';
            end
            if maxSigFreqs(k) > 0
                tableData{k, 10} = sprintf('%.2f Hz', maxSigFreqs(k));
            else
                tableData{k, 10} = '—';
            end
        end

        uit = uitable(resFig, ...
            'Data', tableData, ...
            'ColumnName', {'Parameter', 'Min', 'Max', 'Mean', ...
                           'Usual Low', 'Usual High', 'Peak Above Mean', 'Peak Below Mean', ...
                           'Main Osc Freq', 'Max Signal Freq'}, ...
            'ColumnWidth', {175, 65, 65, 65, 75, 75, 95, 95, 90, 90}, ...
            'Units', 'normalized', ...
            'Position', [0.02, 0.08, 0.96, 0.78], ...
            'FontSize', 10, ...
            'BackgroundColor', [0.12 0.12 0.15; 0.16 0.16 0.20], ...
            'ForegroundColor', [0.9 0.9 0.9], ...
            'RowName', []);

        % Export to CSV button
        csvName = sprintf('%s_%.0fs-%.0fs.csv', ...
            strrep(modeStr, ', ', '_'), t0, t1);
        uicontrol(resFig, 'Style', 'pushbutton', ...
            'String', 'Export CSV', ...
            'Units', 'normalized', 'Position', [0.35 0.01 0.30 0.06], ...
            'FontSize', 10, 'FontWeight', 'bold', ...
            'BackgroundColor', [0.25 0.60 0.35], ...
            'ForegroundColor', [1 1 1], ...
            'Callback', @(~,~) exportSegmentCSV(csvName, tableData));
    end

    function exportSegmentCSV(defaultName, tableData)
        [f, p] = uiputfile({'*.csv','CSV File (*.csv)'}, ...
            'Save Segment Analysis', defaultName);
        if isequal(f, 0), return; end
        fpath = fullfile(p, f);
        fid = fopen(fpath, 'w');
        fprintf(fid, 'Parameter,Min,Max,Mean,UsualLow,UsualHigh,PeakAboveMean,PeakBelowMean,MainOscFreq,MaxSignalFreq\n');
        for k = 1:size(tableData, 1)
            fprintf(fid, '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n', ...
                tableData{k,1}, tableData{k,2}, tableData{k,3}, ...
                tableData{k,4}, tableData{k,5}, tableData{k,6}, ...
                tableData{k,7}, tableData{k,8}, tableData{k,9}, tableData{k,10});
        end
        fclose(fid);
        msgbox(sprintf('Saved to:\n%s', fpath), 'Export Done');
    end

    function freq = computeDominantFreq(tVec, vals)
    %COMPUTEDOMINANTFREQ Avg oscillation frequency by counting peaks after smoothing
    %   Smooths the signal to remove noise, counts local maxima,
    %   and returns (nPeaks - 1) / duration as average frequency in Hz.
    %   Returns 0 if insufficient data or no oscillations detected.
        freq = 0;
        N = numel(vals);
        if N < 10, return; end

        duration = tVec(end) - tVec(1);
        if duration <= 0, return; end

        % Estimate sample rate
        dt = median(diff(tVec));
        if dt <= 0, return; end
        Fs = 1 / dt;

        % Smooth: moving-average window ~5% of signal length (min 3, max 51)
        winLen = max(3, min(51, 2*floor(N * 0.025) + 1));  % odd
        sig = vals(:);
        smoothed = movmean(sig, winLen);

        % Detrend the smoothed signal (remove DC + linear drift)
        smoothed = detrend(smoothed);

        % Find local maxima: points higher than both neighbors
        isPeak = false(size(smoothed));
        for k = 2:numel(smoothed)-1
            if smoothed(k) > smoothed(k-1) && smoothed(k) > smoothed(k+1)
                isPeak(k) = true;
            end
        end
        nPeaks = sum(isPeak);

        % Need at least 2 peaks to define one full cycle
        if nPeaks < 2, return; end

        % Average frequency = (nPeaks - 1) cycles / duration between first and last peak
        peakIdx = find(isPeak);
        peakDuration = tVec(peakIdx(end)) - tVec(peakIdx(1));
        if peakDuration > 0
            freq = (nPeaks - 1) / peakDuration;
        end
    end

    function maxFreq = computeMaxSignalFreq(tVec, vals)
    %COMPUTEMAXSIGNALFREQ  Highest frequency with power above the noise floor.
    %   Uses FFT, estimates noise floor from top 25% of frequency range,
    %   then finds the highest frequency whose power exceeds 3x the noise floor.
        maxFreq = 0;
        N = numel(vals);
        if N < 16, return; end

        dt = median(diff(tVec));
        if dt <= 0, return; end
        Fs = 1 / dt;

        sig = vals(:) - mean(vals);
        Y = fft(sig);
        P = abs(Y / N);
        P1 = P(1:floor(N/2)+1);
        P1(2:end-1) = 2 * P1(2:end-1);
        freqs = Fs * (0:floor(N/2)) / N;

        % Skip DC
        P1 = P1(2:end);
        freqs = freqs(2:end);
        if isempty(P1), return; end

        % Noise floor: median of upper 25% of spectrum
        upperQ = P1(round(0.75 * numel(P1)):end);
        noiseFloor = median(upperQ);
        if noiseFloor == 0, noiseFloor = eps; end

        % Find highest freq where power > 3x noise floor
        threshold = 3 * noiseFloor;
        aboveNoise = find(P1 > threshold);
        if isempty(aboveNoise), return; end

        maxFreq = freqs(aboveNoise(end));
    end

    %% ================== SPECTRUM ANALYSIS ==================

    function [recCutoff, recType, summary] = analyzeSpectrum(vals, Fs)
    %ANALYZESPECTRUM  Analyze FFT power spectrum to recommend filter settings.
    %   Returns recommended cutoff Hz, filter type, and a text summary.

        N = numel(vals);
        sig = vals - mean(vals);   % remove DC

        % Compute single-sided power spectrum
        Y = fft(sig);
        P2 = abs(Y / N);
        P1 = P2(1:floor(N/2)+1);
        P1(2:end-1) = 2 * P1(2:end-1);
        freqs = Fs * (0:floor(N/2)) / N;

        % Skip DC (index 1)
        P1 = P1(2:end);
        freqs = freqs(2:end);

        if isempty(P1) || all(P1 == 0)
            recCutoff = Fs / 10;
            recType   = 'lowpass';
            summary   = 'Flat spectrum — defaulting to Fs/10.';
            return;
        end

        % Cumulative energy fraction
        powerSq = P1.^2;
        cumPow  = cumsum(powerSq);
        totalPow = cumPow(end);
        if totalPow == 0
            recCutoff = Fs / 10;
            recType   = 'lowpass';
            summary   = 'Zero signal power — defaulting to Fs/10.';
            return;
        end
        cumFrac = cumPow / totalPow;

        % Find frequency containing 90% and 99% of signal energy
        idx90 = find(cumFrac >= 0.90, 1, 'first');
        idx99 = find(cumFrac >= 0.99, 1, 'first');
        f90   = freqs(idx90);
        f99   = freqs(idx99);

        % Peak frequency (dominant)
        [~, iPeak] = max(P1);
        fPeak = freqs(iPeak);

        % Noise floor: median of upper 25% of frequency range
        upperQuarter = P1(round(0.75*numel(P1)):end);
        noiseFloor = median(upperQuarter);

        % Signal-to-noise ratio at peak
        if noiseFloor > 0
            peakSNR = P1(iPeak) / noiseFloor;
        else
            peakSNR = Inf;
        end

        % Decide recommendation
        Fnyq = Fs / 2;

        % Check if most energy is at HIGH frequencies (vibration, noise on baseline)
        lowEnergyFrac = cumFrac(find(freqs >= Fnyq * 0.1, 1, 'first'));
        if isempty(lowEnergyFrac), lowEnergyFrac = cumFrac(1); end

        if fPeak > Fnyq * 0.3 && lowEnergyFrac < 0.2
            % Dominant energy at high frequencies — recommend highpass
            recType = 'highpass';
            % Cut below the peak: use 80% of peak freq
            recCutoff = round(fPeak * 0.8, 2);
        elseif fPeak < Fnyq * 0.1 && peakSNR > 5
            % Strong low-frequency signal with noise above — lowpass
            recType = 'lowpass';
            recCutoff = round(f90 * 1.2, 2);   % 20% margin above 90% energy
        else
            % General case: lowpass at 90% energy point with margin
            recType = 'lowpass';
            recCutoff = round(f90 * 1.2, 2);
        end

        % Clamp to valid range
        recCutoff = max(recCutoff, freqs(1));
        recCutoff = min(recCutoff, Fnyq * 0.95);

        % Build text summary
        summary = sprintf([ ...
            'Fs = %.1f Hz  |  Nyquist = %.1f Hz\n' ...
            'Peak frequency: %.2f Hz (SNR: %.1fx over noise floor)\n' ...
            '90%% energy below: %.2f Hz\n' ...
            '99%% energy below: %.2f Hz'], ...
            Fs, Fnyq, fPeak, peakSNR, f90, f99);
    end

    %% ================== FFT FILTER HELPERS ==================

    function filtered = fftLowPass(sig, Fs, fc)
    %FFTLOWPASS Zero-phase FFT low-pass filter
    %   Keeps frequencies below fc Hz, zeroes out above.
        N = numel(sig);
        sig = sig(:);
        % Remove mean to avoid spectral leakage at DC
        mu = mean(sig);
        sig = sig - mu;

        Y = fft(sig);
        freqs = (0:N-1)' * Fs / N;
        % Mirror: frequencies above Fs/2 correspond to negative freqs
        mask = ones(N, 1);
        mask(freqs > fc & freqs < (Fs - fc)) = 0;
        % Smooth transition (Hann taper over 10% of cutoff to avoid ringing)
        taperWidth = max(1, round(fc * 0.1 * N / Fs));
        for k = 1:N
            f = freqs(k);
            if f > fc && f < Fs - fc
                % Check if we're in the taper zone
                distFromCutoff = min(abs(f - fc), abs(f - (Fs - fc)));
                taperFreqWidth = taperWidth * Fs / N;
                if distFromCutoff < taperFreqWidth
                    mask(k) = 0.5 * (1 + cos(pi * (1 - distFromCutoff / taperFreqWidth)));
                end
            end
        end

        Y = Y .* mask;
        filtered = real(ifft(Y)) + mu;
    end

    function filtered = fftHighPass(sig, Fs, fc)
    %FFTHIGHPASS Zero-phase FFT high-pass filter
    %   Keeps frequencies above fc Hz, zeroes out below.
        N = numel(sig);
        sig = sig(:);
        mu = mean(sig);
        sig = sig - mu;

        Y = fft(sig);
        freqs = (0:N-1)' * Fs / N;
        mask = ones(N, 1);
        % Zero out below fc (and mirror above Fs-fc)
        mask(freqs < fc) = 0;
        mask(freqs > (Fs - fc)) = 0;
        % Smooth taper
        taperWidth = max(1, round(fc * 0.1 * N / Fs));
        taperFreqWidth = taperWidth * Fs / N;
        for k = 1:N
            f = freqs(k);
            if f < fc
                distFromCutoff = fc - f;
                if distFromCutoff < taperFreqWidth
                    mask(k) = 0.5 * (1 + cos(pi * distFromCutoff / taperFreqWidth));
                end
            elseif f > (Fs - fc)
                distFromCutoff = f - (Fs - fc);
                if distFromCutoff < taperFreqWidth
                    mask(k) = 0.5 * (1 + cos(pi * distFromCutoff / taperFreqWidth));
                end
            end
        end

        Y = Y .* mask;
        filtered = real(ifft(Y));  % no DC add-back for high-pass
    end

    function filtered = fftBandPass(sig, Fs, fLow, fHigh)
    %FFTBANDPASS Zero-phase FFT band-pass filter
    %   Keeps frequencies between fLow and fHigh Hz.
        N = numel(sig);
        sig = sig(:);
        mu = mean(sig);
        sig = sig - mu;

        Y = fft(sig);
        freqs = (0:N-1)' * Fs / N;
        mask = zeros(N, 1);
        % Pass band
        mask(freqs >= fLow & freqs <= fHigh) = 1;
        mask(freqs >= (Fs - fHigh) & freqs <= (Fs - fLow)) = 1;
        % Smooth taper at edges
        taperFreqWidth = max(0.1, (fHigh - fLow) * 0.1);
        for k = 1:N
            f = freqs(k);
            if mask(k) == 0
                % Check proximity to pass band edges
                distLow  = abs(f - fLow);
                distHigh = abs(f - fHigh);
                distLowM  = abs(f - (Fs - fHigh));
                distHighM = abs(f - (Fs - fLow));
                minDist = min([distLow, distHigh, distLowM, distHighM]);
                if minDist < taperFreqWidth
                    mask(k) = 0.5 * (1 + cos(pi * (1 - minDist / taperFreqWidth)));
                end
            end
        end

        Y = Y .* mask;
        filtered = real(ifft(Y));
    end

    %% ================== PLOT FUNCTIONS ==================

    function updateTimePlot(h)
        % Delete old extra axes and listener
        for ea = 1:numel(h.extraAxes)
            if isvalid(h.extraAxes(ea)), delete(h.extraAxes(ea)); end
        end
        h.extraAxes = [];
        h.crosshairLine = [];
        h.crosshairTexts = {};
        h.plotDataCache = {};
        if ~isempty(h.xlimListener)
            delete(h.xlimListener);
            h.xlimListener = [];
        end

        cla(h.axTime);
        hold(h.axTime, 'on');
        set(h.axTime, 'YTick', [], 'YColor', [0.15 0.15 0.18]);  % hide main Y

        if isempty(h.activePlots)
            title(h.axTime, 'Time Series Plot', 'Color', [0.9 0.9 0.9]);
            legend(h.axTime, 'off');
            hold(h.axTime, 'off');
            guidata(fig, h);
            return;
        end

        % --- Collect data ---
        nColors = size(h.plotColors, 1);
        allVals = {}; allTime = {}; allExprs = {}; allColors = [];
        validCount = 0;

        for pi = 1:numel(h.activePlots)
            expr = h.activePlots{pi};
            try
                [vals, tVec] = evalExpression(expr, h.logData, h.derivedData);
            catch ME
                fprintf('Plot error for "%s": %s\n', expr, ME.message);
                continue;
            end
            validCount = validCount + 1;
            cidx = mod(validCount - 1, nColors) + 1;
            col = h.plotColors(cidx, :);
            allVals{end+1} = vals;  %#ok<AGROW>
            allTime{end+1} = tVec;  %#ok<AGROW>
            allExprs{end+1} = expr; %#ok<AGROW>
            allColors(end+1, :) = col; %#ok<AGROW>
        end

        if isempty(allVals)
            hold(h.axTime, 'off');
            guidata(fig, h);
            return;
        end

        % Global time range
        globalTMin = Inf; globalTMax = -Inf;
        for k = 1:numel(allTime)
            globalTMin = min(globalTMin, min(allTime{k}));
            globalTMax = max(globalTMax, max(allTime{k}));
        end

        % Get axes position for creating overlay axes
        axPos = get(h.axTime, 'Position');

        % --- Draw mode shading on main axes (use full Y range 0-1, normalized) ---
        drawModeShading(h, globalTMin, globalTMax, 0, 1);
        set(h.axTime, 'YLim', [0 1]);
        set(h.axTime, 'XLim', [globalTMin globalTMax]);

        % --- Create one overlay axes per trace for independent Y-scaling ---
        nTraces = numel(allVals);
        maxAxesPerSide = 3;
        extraAxArr = gobjects(0);
        legendStrs = {};

        for ti = 1:nTraces
            vals = allVals{ti};
            tVec = allTime{ti};
            col  = allColors(ti, :);
            expr = allExprs{ti};

            % Create transparent overlay axes — same Position as main axes
            % so data always aligns horizontally
            ax = axes(fig, 'Units', 'pixels', ...
                'Position', axPos, ...
                'Color', 'none', ...
                'XLim', [globalTMin globalTMax], ...
                'XTick', [], ...
                'Box', 'off', ...
                'HitTest', 'off', ...
                'PickableParts', 'none', ...
                'FontSize', 8); %#ok<LAXES>

            hold(ax, 'on');
            plot(ax, tVec, vals, '-', 'Color', col, 'LineWidth', 1.3);
            hold(ax, 'off');

            % Y limits with padding
            mn = min(vals); mx = max(vals);
            pad = (mx - mn) * 0.08;
            if pad == 0, pad = 1; end
            set(ax, 'YLim', [mn - pad, mx + pad]);

            % Alternate Y-axis left(odd)/right(even), all ticks visible
            if mod(ti, 2) == 1
                set(ax, 'YAxisLocation', 'left');
                sideIdx = ceil(ti / 2);   % 1st left, 2nd left, ...
            else
                set(ax, 'YAxisLocation', 'right');
                sideIdx = ceil(ti / 2);
            end

            % Color the Y-axis to match the trace
            set(ax, 'YColor', col);

            % Smaller tick font for 2nd+ axes on same side
            if sideIdx > 1
                set(ax, 'FontSize', 7);
            end

            % Place ylabel offset so multiple on same side don't overlap
            labelOffset = -(sideIdx - 1) * 40;
            if mod(ti, 2) == 0
                labelOffset = -labelOffset;  % right side: offset outward
            end
            yl = ylabel(ax, expr, 'Color', col, 'FontSize', 8, ...
                'Interpreter', 'none', 'Rotation', 90, 'Units', 'pixels');
            ylPos = get(yl, 'Position');
            set(yl, 'Position', [ylPos(1) + labelOffset, ylPos(2), ylPos(3)]);

            extraAxArr(end+1) = ax; %#ok<AGROW>

            % Stats for legend
            av = mean(vals);
            legendStrs{end+1} = sprintf('%s | Min: %.2f  Max: %.2f  Mean: %.2f', ...
                expr, mn, mx, av); %#ok<AGROW>

            % Store for crosshair
            h.plotDataCache{end+1} = struct('vals', vals, 'time', tVec, ...
                'expr', expr, 'color', col, 'ax', ax);
        end

        h.extraAxes = extraAxArr;
        hold(h.axTime, 'off');

        % Legend on main axes (invisible proxy lines)
        hold(h.axTime, 'on');
        proxyHandles = [];
        for ti = 1:size(allColors, 1)
            if ti > numel(legendStrs), break; end
            proxyHandles(end+1) = plot(h.axTime, NaN, NaN, '-', ...
                'Color', allColors(ti,:), 'LineWidth', 1.5); %#ok<AGROW>
        end
        hold(h.axTime, 'off');

        if ~isempty(legendStrs)
            legend(h.axTime, proxyHandles, legendStrs, ...
                'TextColor', [0.85 0.85 0.85], ...
                'Color', [0.15 0.15 0.18], ...
                'EdgeColor', [0.4 0.4 0.4], ...
                'Location', 'northeast', ...
                'FontSize', 7, ...
                'Interpreter', 'none');
        end

        xlabel(h.axTime, 'time\_boot (s)', 'Color', [0.8 0.8 0.8], ...
            'Interpreter', 'none');
        [~, fn] = fileparts(h.filename);
        title(h.axTime, fn, 'Color', [0.9 0.9 0.9], ...
            'FontSize', 12, 'Interpreter', 'none');

        % --- Setup crosshair ---
        hold(h.axTime, 'on');
        h.crosshairLine = plot(h.axTime, [NaN NaN], [0 1], '-', ...
            'Color', [1 1 1 0.6], 'LineWidth', 1, ...
            'HandleVisibility', 'off');
        hold(h.axTime, 'off');
        set(fig, 'WindowButtonMotionFcn', @crosshairMotionCb);

        % --- Setup XLim sync listener: when user zooms main axes, sync overlays ---
        h.xlimListener = addlistener(h.axTime, 'XLim', 'PostSet', ...
            @(~,~) syncOverlayXLim(fig));

        guidata(fig, h);
    end

    function syncOverlayXLim(figObj)
    % Sync all overlay axes XLim to match the main time axes
        h = guidata(figObj);
        xl = get(h.axTime, 'XLim');
        for ea = 1:numel(h.extraAxes)
            if isvalid(h.extraAxes(ea))
                set(h.extraAxes(ea), 'XLim', xl);
            end
        end
        % Update flight path to show only the visible time window
        updateFlightPathForRange(h, xl);
    end

    function updateFlightPathForRange(h, xl)
    % Replot flight path showing only GPS points within time range xl=[t0 t1]
        gc = h.gpsCache;
        if isempty(gc), return; end

        cla(h.axMap);
        % Remove hidden-handle objects (range circles, labels) that cla misses
        remnants = allchild(h.axMap);
        if ~isempty(remnants), delete(remnants); end
        hold(h.axMap, 'on');

        % Filter to visible time range
        mask = gc.timeSec >= xl(1) & gc.timeSec <= xl(2);
        lat = gc.lat(mask);
        lng = gc.lng(mask);
        modeCodes = gc.modeCodes(mask);
        if isfield(gc, 'alt') && ~isempty(gc.alt)
            altData = gc.alt(mask);
        else
            altData = [];
        end

        if isempty(lat)
            title(h.axMap, 'No GPS data in view', 'Color', [0.9 0.5 0.5]);
            hold(h.axMap, 'off');
            return;
        end

        modeMap = getModeMap();
        modeColorMap = [ ...
            1.0  0.8  0.0;   1.0  0.2  0.2;   1.0  0.5  0.0; ...
            0.2  0.6  1.0;   0.0  0.9  0.5;   0.7  0.3  1.0; ...
            0.0  0.9  0.9;   1.0  0.4  0.7;   0.6  0.8  0.2; ...
            0.9  0.6  0.4;   0.4  0.4  1.0;   0.8  0.8  0.8];

        if ~isempty(modeCodes) && any(modeCodes ~= 0)
            uniqueModes = unique(modeCodes);
            legendEntries = {};
            legendHandles = [];
            for mi = 1:numel(uniqueModes)
                m = uniqueModes(mi);
                mMask = modeCodes == m;
                cidx = mod(mi - 1, size(modeColorMap, 1)) + 1;
                col = modeColorMap(cidx, :);
                hp = plot(h.axMap, lng(mMask), lat(mMask), '.', ...
                    'Color', col, 'MarkerSize', 4);
                if isKey(modeMap, m)
                    legendEntries{end+1} = modeMap(m); %#ok<AGROW>
                else
                    legendEntries{end+1} = sprintf('Mode %d', m); %#ok<AGROW>
                end
                legendHandles(end+1) = hp; %#ok<AGROW>
            end
            if ~isempty(legendEntries)
                legend(h.axMap, legendHandles, legendEntries, ...
                    'TextColor', [0.85 0.85 0.85], ...
                    'Color', [0.15 0.15 0.18], ...
                    'EdgeColor', [0.4 0.4 0.4], ...
                    'Location', 'best', 'FontSize', 8);
            end
        else
            plot(h.axMap, lng, lat, '-', 'Color', [1 0.6 0], 'LineWidth', 1.5);
        end

        % --- Range circles + max altitude ---
        maxAlt = [];
        if ~isempty(altData), maxAlt = max(altData); end
        drawRangeCircles(h.axMap, lat, lng, maxAlt);

        % Start/end markers
        plot(h.axMap, lng(1), lat(1), 'go', 'MarkerSize', 10, ...
            'MarkerFaceColor', 'g', 'LineWidth', 2);
        plot(h.axMap, lng(end), lat(end), 'rs', 'MarkerSize', 10, ...
            'MarkerFaceColor', 'r', 'LineWidth', 2);

        hold(h.axMap, 'off');
        xlabel(h.axMap, 'Longitude', 'Color', [0.8 0.8 0.8]);
        ylabel(h.axMap, 'Latitude', 'Color', [0.8 0.8 0.8]);
        title(h.axMap, 'Flight Path', 'Color', [0.9 0.9 0.9], 'FontSize', 12);
        axis(h.axMap, 'equal');
    end

    function crosshairMotionCb(~, ~)
    % Move vertical crosshair line and show values at cursor position
        h = guidata(fig);
        if isempty(h.crosshairLine) || ~isvalid(h.crosshairLine), return; end
        if isempty(h.plotDataCache), return; end

        % Get cursor position in main axes
        cp = get(h.axTime, 'CurrentPoint');
        tCur = cp(1, 1);
        xl = get(h.axTime, 'XLim');
        if tCur < xl(1) || tCur > xl(2), return; end

        % Update vertical line
        set(h.crosshairLine, 'XData', [tCur tCur], 'YData', [0 1]);

        % Delete old text labels
        for ci = 1:numel(h.crosshairTexts)
            if isvalid(h.crosshairTexts{ci}), delete(h.crosshairTexts{ci}); end
        end
        h.crosshairTexts = {};

        % Show value on each trace's axes
        for ti = 1:numel(h.plotDataCache)
            pc = h.plotDataCache{ti};
            if ~isvalid(pc.ax), continue; end
            % Find nearest time index
            [~, idx] = min(abs(pc.time - tCur));
            val = pc.vals(idx);
            yl = get(pc.ax, 'YLim');
            yNorm = (val - yl(1)) / (yl(2) - yl(1));
            yNorm = max(0.02, min(0.98, yNorm));

            txt = text(h.axTime, tCur, yNorm, ...
                sprintf('  %.2f', val), ...
                'Color', pc.color, 'FontSize', 7, 'FontWeight', 'bold', ...
                'HandleVisibility', 'off', 'Clipping', 'on');
            h.crosshairTexts{end+1} = txt;
        end
        guidata(fig, h);
    end

    function repositionExtraAxes(h, ~, ~, axPlotLeft, axPlotW, axBot, axH)
    % Reposition overlay axes on resize — all share same Position as axTime
        basePos = [axPlotLeft, axBot, axPlotW, axH];
        for ti = 1:numel(h.extraAxes)
            if ~isvalid(h.extraAxes(ti)), continue; end
            set(h.extraAxes(ti), 'Position', basePos);
        end
    end

    function drawModeShading(h, tMin, tMax, yLo, yHi)
    %DRAWMODESHADING Draw semi-transparent colored vertical bands for flight modes
        ld = h.logData;
        if isempty(ld) || ~isfield(ld, 'MODE'), return; end
        if ~isfield(ld.MODE, 'Mode') || ~isfield(ld.MODE, 'TimeUS'), return; end

        modeTime = ld.MODE.TimeUS / 1e6;  % seconds
        modeCodes = ld.MODE.Mode;
        if isempty(modeTime), return; end

        modeMap = getModeMap();

        % Assign a consistent color per mode code
        % Use soft pastel-like colors with alpha for background bands
        modeColorPalette = [ ...
            1.0  1.0  0.7;   % yellow-ish
            1.0  0.8  0.8;   % pink-ish
            0.7  1.0  0.7;   % green-ish
            0.7  0.8  1.0;   % blue-ish
            1.0  0.9  0.7;   % orange-ish
            0.9  0.7  1.0;   % purple-ish
            0.7  1.0  1.0;   % cyan-ish
            1.0  0.7  0.9;   % magenta-ish
            0.85 0.85 0.7;   % olive-ish
            0.8  1.0  0.85;  % mint-ish
            1.0  0.85 0.75;  % peach
            0.75 0.85 0.95;  % steel blue
        ];
        nPalette = size(modeColorPalette, 1);

        nModes = numel(modeTime);
        drawnModes = containers.Map('KeyType', 'double', 'ValueType', 'logical');

        for mi = 1:nModes
            t0 = modeTime(mi);
            if mi < nModes
                t1 = modeTime(mi + 1);
            else
                t1 = tMax;
            end

            % Clip to visible range
            if t1 < tMin || t0 > tMax, continue; end
            t0 = max(t0, tMin);
            t1 = min(t1, tMax);
            if t1 <= t0, continue; end

            mc = modeCodes(mi);
            cidx = mod(mc, nPalette) + 1;
            col = modeColorPalette(cidx, :);

            % Draw filled rectangle as a patch
            patch(h.axTime, ...
                [t0 t1 t1 t0], [yLo yLo yHi yHi], col, ...
                'FaceAlpha', 0.15, ...
                'EdgeColor', 'none', ...
                'HandleVisibility', 'off');

            % Draw mode name label at bottom (once per mode code)
            if ~isKey(drawnModes, mc) || ~drawnModes(mc)
                if isKey(modeMap, mc)
                    modeName = modeMap(mc);
                else
                    modeName = sprintf('M%d', mc);
                end
                tMid = (t0 + t1) / 2;
                text(h.axTime, tMid, yLo + (yHi - yLo) * 0.02, modeName, ...
                    'Color', col * 0.6, ...
                    'FontSize', 7, 'FontWeight', 'bold', ...
                    'HorizontalAlignment', 'center', ...
                    'VerticalAlignment', 'bottom', ...
                    'HandleVisibility', 'off', ...
                    'Interpreter', 'none');
                drawnModes(mc) = true;
            end
        end
    end

    function drawRangeCircles(ax, lat, lng, maxAlt)
    %DRAWRANGECIRCLES  Draw concentric range circles + max altitude annotation.
    %   4 circles: 3 inner equidistant + 1 outer (max radius), red dashed.
        if nargin < 4, maxAlt = []; end
        cLat = mean(lat);
        cLng = mean(lng);

        % Convert GPS offsets to metres using Haversine-approx scale factors
        mPerDegLat = 111320;                         % ~111.32 km per degree lat
        mPerDegLng = 111320 * cosd(cLat);            % shrinks with latitude

        dLat_m = (lat - cLat) * mPerDegLat;
        dLng_m = (lng - cLng) * mPerDegLng;

        dist_m = sqrt(dLat_m.^2 + dLng_m.^2);       % radial distance in metres
        maxR   = max(dist_m);
        if maxR < 0.5, return; end                    % nothing meaningful

        nCircles = 4;                                 % outer + 3 inner
        radii_m  = maxR * (1:nCircles) / nCircles;   % equidistant from center

        theta = linspace(0, 2*pi, 180);

        for ci = 1:nCircles
            r = radii_m(ci);
            % Convert metres back to lat/lng offsets (true circles on ground)
            cLatPts = cLat + (r * sin(theta)) / mPerDegLat;
            cLngPts = cLng + (r * cos(theta)) / mPerDegLng;

            if ci == nCircles
                % Outer circle: red dashed, slightly thicker
                plot(ax, cLngPts, cLatPts, '--', 'Color', [1 0.25 0.25], ...
                    'LineWidth', 1.2, 'HandleVisibility', 'off');
            else
                % Inner circles: grey dashed, thinner
                plot(ax, cLngPts, cLatPts, ':', 'Color', [0.55 0.55 0.55], ...
                    'LineWidth', 0.8, 'HandleVisibility', 'off');
            end

            % Label position: outer circle on right side, inner on top
            if ci == nCircles
                % Right side of circle
                labelLat = cLat;
                labelLng = cLng + r / mPerDegLng;
                hAlign = 'left';
                vAlign = 'middle';
            else
                % Top of circle
                labelLat = cLat + r / mPerDegLat;
                labelLng = cLng;
                hAlign = 'center';
                vAlign = 'bottom';
            end
            if r >= 1000
                radiusTxt = sprintf('%.1f km', r / 1000);
            else
                radiusTxt = sprintf('%.0f m', r);
            end
            text(ax, labelLng, labelLat, ['  ' radiusTxt], ...
                'Color', [0.85 0.85 0.85], 'FontSize', 7, ...
                'HorizontalAlignment', hAlign, ...
                'VerticalAlignment', vAlign, ...
                'HandleVisibility', 'off');
        end

        % Center dot
        plot(ax, cLng, cLat, '+', 'Color', [0.7 0.7 0.7], ...
            'MarkerSize', 8, 'LineWidth', 1, 'HandleVisibility', 'off');

        % Max altitude annotation (bottom-left of circles)
        if ~isempty(maxAlt) && isfinite(maxAlt)
            labelLat = cLat - maxR / mPerDegLat;      % bottom of outer circle
            labelLng = cLng - maxR / mPerDegLng * 0.7; % offset left
            if maxAlt >= 1000
                altTxt = sprintf('Max Alt: %.1f km', maxAlt / 1000);
            else
                altTxt = sprintf('Max Alt: %.0f m', maxAlt);
            end
            text(ax, labelLng, labelLat, altTxt, ...
                'Color', [0.3 0.85 1.0], 'FontSize', 8, 'FontWeight', 'bold', ...
                'HorizontalAlignment', 'left', ...
                'VerticalAlignment', 'top', ...
                'HandleVisibility', 'off');
        end
    end

    function h = plotFlightPath(h)
        cla(h.axMap);
        % Remove hidden-handle objects (range circles, labels) that cla misses
        remnants = allchild(h.axMap);
        if ~isempty(remnants), delete(remnants); end
        hold(h.axMap, 'on');

        % Find GPS data with Lat/Lng
        ld = h.logData;
        gpsName = '';
        msgNames = fieldnames(ld);
        for mi = 1:numel(msgNames)
            nm = msgNames{mi};
            if isfield(ld.(nm), 'Lat') && isfield(ld.(nm), 'Lng')
                gpsName = nm;
                break;
            end
        end

        if isempty(gpsName)
            title(h.axMap, 'No GPS data found', 'Color', [0.9 0.5 0.5]);
            hold(h.axMap, 'off');
            return;
        end

        lat = ld.(gpsName).Lat;
        lng = ld.(gpsName).Lng;

        % Try to get altitude (Alt or RAlt field)
        altData = [];
        if isfield(ld.(gpsName), 'Alt')
            altData = ld.(gpsName).Alt;
        elseif isfield(ld.(gpsName), 'RAlt')
            altData = ld.(gpsName).RAlt;
        end

        % Filter out zeros
        valid = lat ~= 0 & lng ~= 0;
        lat = lat(valid);
        lng = lng(valid);
        if ~isempty(altData), altData = altData(valid); end

        if isempty(lat)
            title(h.axMap, 'No valid GPS positions', 'Color', [0.9 0.5 0.5]);
            hold(h.axMap, 'off');
            return;
        end

        % Try to color by flight mode
        modeData = [];
        modeTime = [];
        if isfield(ld, 'MODE')
            if isfield(ld.MODE, 'Mode') && isfield(ld.MODE, 'TimeUS')
                modeData = ld.MODE.Mode;
                modeTime = ld.MODE.TimeUS;
            end
        end

        if ~isempty(modeData) && isfield(ld.(gpsName), 'TimeUS')
            gpsTime = ld.(gpsName).TimeUS(valid);
            gpsTimeSec = gpsTime / 1e6;
            % Assign mode to each GPS point
            modeCodes = zeros(size(gpsTime));
            for gi = 1:numel(gpsTime)
                idx = find(modeTime <= gpsTime(gi), 1, 'last');
                if ~isempty(idx)
                    modeCodes(gi) = modeData(idx);
                end
            end

            % Cache GPS data for zoom-linked filtering
            h.gpsCache = struct('lat', lat, 'lng', lng, ...
                'timeSec', gpsTimeSec, 'modeCodes', modeCodes, ...
                'alt', altData);

            % Mode colors and names (ArduPilot plane modes)
            modeMap = getModeMap();
            uniqueModes = unique(modeCodes);
            % Distinct, well-separated colors for flight modes
            modeColorMap = [ ...
                1.0  0.8  0.0;   % yellow
                1.0  0.2  0.2;   % red
                1.0  0.5  0.0;   % orange
                0.2  0.6  1.0;   % blue
                0.0  0.9  0.5;   % green
                0.7  0.3  1.0;   % purple
                0.0  0.9  0.9;   % cyan
                1.0  0.4  0.7;   % pink
                0.6  0.8  0.2;   % lime
                0.9  0.6  0.4;   % salmon
                0.4  0.4  1.0;   % indigo
                0.8  0.8  0.8;   % grey
            ];

            legendEntries = {};
            legendHandles = [];
            for mi = 1:numel(uniqueModes)
                m = uniqueModes(mi);
                mask = modeCodes == m;
                cidx = mod(mi - 1, size(modeColorMap, 1)) + 1;
                col = modeColorMap(cidx, :);

                hp = plot(h.axMap, lng(mask), lat(mask), '.', ...
                    'Color', col, 'MarkerSize', 4);

                if isKey(modeMap, m)
                    modeName = modeMap(m);
                else
                    modeName = sprintf('Mode %d', m);
                end
                legendEntries{end+1} = modeName;
                legendHandles(end+1) = hp;
            end

            if ~isempty(legendEntries)
                legend(h.axMap, legendHandles, legendEntries, ...
                    'TextColor', [0.85 0.85 0.85], ...
                    'Color', [0.15 0.15 0.18], ...
                    'EdgeColor', [0.4 0.4 0.4], ...
                    'Location', 'best', 'FontSize', 8);
            end
        else
            % No mode data — still cache with zero mode codes if TimeUS exists
            if isfield(ld.(gpsName), 'TimeUS')
                gpsTimeSec = ld.(gpsName).TimeUS(valid) / 1e6;
                h.gpsCache = struct('lat', lat, 'lng', lng, ...
                    'timeSec', gpsTimeSec, 'modeCodes', zeros(size(lat)), ...
                    'alt', altData);
            end
            plot(h.axMap, lng, lat, '-', 'Color', [1 0.6 0], 'LineWidth', 1.5);
        end

        % --- Range circles + max altitude ---
        maxAlt = [];
        if ~isempty(altData), maxAlt = max(altData); end
        drawRangeCircles(h.axMap, lat, lng, maxAlt);

        % Start marker
        plot(h.axMap, lng(1), lat(1), 'go', 'MarkerSize', 10, ...
            'MarkerFaceColor', 'g', 'LineWidth', 2);
        % End marker
        plot(h.axMap, lng(end), lat(end), 'rs', 'MarkerSize', 10, ...
            'MarkerFaceColor', 'r', 'LineWidth', 2);

        hold(h.axMap, 'off');
        xlabel(h.axMap, 'Longitude', 'Color', [0.8 0.8 0.8]);
        ylabel(h.axMap, 'Latitude', 'Color', [0.8 0.8 0.8]);
        title(h.axMap, 'Flight Path', 'Color', [0.9 0.9 0.9], 'FontSize', 12);
        axis(h.axMap, 'equal');
    end
end

%% ==================== LOCAL FUNCTIONS ====================

function paramList = buildParamList(logData)
%BUILDPARAMLIST Build sorted MSG.Field list from logData
    paramList = {};
    msgNames = sort(fieldnames(logData));
    for mi = 1:numel(msgNames)
        msg = msgNames{mi};
        fields = sort(fieldnames(logData.(msg)));
        for fi = 1:numel(fields)
            fld = fields{fi};
            % Skip TimeUS/TimeMS for cleaner display (they're still plottable)
            paramList{end+1} = [msg '.' fld]; %#ok<AGROW>
        end
    end
end

function [result, timeVec] = evalExpression(exprStr, logData, derivedData)
%EVALEXPRESSION Evaluate a parameter expression against log data
%   Interpolates all referenced signals to a common time vector.

    % Sanitize: keep only printable ASCII (32-126)
    exprStr = char(exprStr);
    exprStr = exprStr(exprStr >= 32 & exprStr <= 126);
    exprStr = strtrim(exprStr);
    if isempty(exprStr)
        error('Empty expression after sanitization');
    end

    % Normalize bracket notation: GPS[0].Spd -> GPS_0.Spd
    exprStr = regexprep(exprStr, '(\w+)\[(\d+)\]', '$1_$2');

    % Find all MSG.Field references
    allTokens = regexp(exprStr, '([A-Za-z_]\w*)\.(\w+)', 'tokens');
    if isempty(allTokens)
        error('No parameter references found in: %s', exprStr);
    end

    % Get unique references, sort longest first (avoid partial replacement)
    fullRefs = cellfun(@(t) [t{1} '.' t{2}], allTokens, 'UniformOutput', false);
    [uniqueRefs, ia] = unique(fullRefs);
    uniqueTokens = allTokens(ia);
    [~, sortIdx] = sort(cellfun(@numel, uniqueRefs), 'descend');
    uniqueRefs   = uniqueRefs(sortIdx);
    uniqueTokens = uniqueTokens(sortIdx);

    % Resolve data and individual time vectors
    nRef    = numel(uniqueRefs);
    varData = cell(nRef, 1);
    varTime = cell(nRef, 1);
    evalStr = exprStr;

    for i = 1:nRef
        msg = uniqueTokens{i}{1};
        fld = uniqueTokens{i}{2};
        vn  = sprintf('V__%d', i);

        if strcmp(msg, 'DERIVED')
            if nargin < 3 || ~isstruct(derivedData) || ~isfield(derivedData, fld)
                error('Unknown derived parameter: %s', fld);
            end
            varData{i} = derivedData.(fld).values(:)';
            varTime{i} = derivedData.(fld).time(:)';
        elseif isfield(logData, msg) && isfield(logData.(msg), fld)
            varData{i} = logData.(msg).(fld)(:)';
            if isfield(logData.(msg), 'TimeUS')
                varTime{i} = logData.(msg).TimeUS(:)' / 1e6;
            elseif isfield(logData.(msg), 'TimeMS')
                varTime{i} = logData.(msg).TimeMS(:)' / 1e3;
            else
                varTime{i} = [];
            end
        else
            error('Unknown parameter: %s.%s', msg, fld);
        end

        evalStr = strrep(evalStr, uniqueRefs{i}, vn);
    end

    % Auto-convert operators to element-wise: ^ -> .^, * -> .*, / -> ./
    evalStr = regexprep(evalStr, '(?<!\.)\^', '.^');
    evalStr = regexprep(evalStr, '(?<!\.)\*', '.*');
    evalStr = regexprep(evalStr, '(?<!\.)/', './');

    % ---- Interpolate all signals to a common time vector ----
    % If only one reference or all share the same time, skip interpolation
    hasTime = ~cellfun(@isempty, varTime);

    if sum(hasTime) == 0
        % No time data at all: truncate to common length
        minLen = min(cellfun(@numel, varData));
        S = struct();
        for i = 1:nRef
            S.(sprintf('V__%d', i)) = varData{i}(1:minLen);
        end
        timeVec = 1:minLen;
    elseif sum(hasTime) == 1 || nRef == 1
        % Single reference or only one has time: truncate to common length
        minLen = min(cellfun(@numel, varData));
        idx = find(hasTime, 1);
        timeVec = varTime{idx}(1:minLen);
        S = struct();
        for i = 1:nRef
            S.(sprintf('V__%d', i)) = varData{i}(1:minLen);
        end
    else
        % Multiple references with time: use slowest signal's timestamps
        % and pick nearest actual sample from each faster signal
        tLens = cellfun(@numel, varTime);
        tLens(~hasTime) = Inf;
        [~, slowIdx] = min(tLens);         % fewest samples = lowest rate
        timeVec = varTime{slowIdx};

        % Remove duplicate timestamps from base time vector
        [timeVec, uIdx] = unique(timeVec, 'stable');
        varData{slowIdx} = varData{slowIdx}(uIdx);

        % Clamp to overlapping time range
        tMin = -Inf; tMax = Inf;
        for i = 1:nRef
            if hasTime(i)
                tMin = max(tMin, varTime{i}(1));
                tMax = min(tMax, varTime{i}(end));
            end
        end
        if tMin > tMax
            error('Time ranges of parameters do not overlap.');
        end
        mask = timeVec >= tMin & timeVec <= tMax;
        timeVec = timeVec(mask);
        varData{slowIdx} = varData{slowIdx}(mask);

        S = struct();
        for i = 1:nRef
            vn = sprintf('V__%d', i);
            if hasTime(i) && i ~= slowIdx
                % Nearest-neighbour without interp1 (handles duplicate timestamps)
                tOther = varTime{i}(:);
                [~, uOtherIdx] = unique(tOther, 'stable');
                tUniq = tOther(uOtherIdx);
                dUniq = varData{i}(uOtherIdx);
                nearIdx = zeros(size(timeVec));
                for qi = 1:numel(timeVec)
                    [~, nearIdx(qi)] = min(abs(tUniq - timeVec(qi)));
                end
                S.(vn) = dUniq(nearIdx);
            else
                % Base (slowest) signal — already aligned
                S.(vn) = varData{slowIdx}(1:numel(timeVec));
            end
        end
    end

    % Evaluate using a helper that unpacks from struct (avoids eval workspace issues)
    result = evalExprHelper(evalStr, S);
end

function result = evalExprHelper(evalStr, S)
%EVALEXPRHELPER Evaluate expression string with variables from struct S
    flds = fieldnames(S);
    for k = 1:numel(flds)
        eval([flds{k} ' = S.(flds{k});']); %#ok<EVLCS>
    end
    result = eval(evalStr); %#ok<EVLCS>
end

function modeMap = getModeMap()
%GETMODEMAP Return containers.Map of ArduPilot flight mode codes to names
    modeMap = containers.Map('KeyType', 'double', 'ValueType', 'char');
    % Plane modes
    modeMap(0)  = 'MANUAL';
    modeMap(1)  = 'CIRCLE';
    modeMap(2)  = 'STABILIZE';
    modeMap(3)  = 'TRAINING';
    modeMap(4)  = 'ACRO';
    modeMap(5)  = 'FBWA';
    modeMap(6)  = 'FBWB';
    modeMap(7)  = 'CRUISE';
    modeMap(8)  = 'AUTOTUNE';
    modeMap(10) = 'AUTO';
    modeMap(11) = 'RTL';
    modeMap(12) = 'LOITER';
    modeMap(13) = 'TAKEOFF';
    modeMap(14) = 'AVOID_ADSB';
    modeMap(15) = 'GUIDED';
    modeMap(17) = 'QSTABILIZE';
    modeMap(18) = 'QHOVER';
    modeMap(19) = 'QLOITER';
    modeMap(20) = 'QLAND';
    modeMap(21) = 'QRTL';
    modeMap(22) = 'QAUTOTUNE';
    modeMap(23) = 'QACRO';
    modeMap(24) = 'THERMAL';
    % Copter modes (overlap with plane — context dependent)
    modeMap(9)  = 'LAND';
    modeMap(16) = 'POSHOLD';
    modeMap(25) = 'SYSTEMID';
    modeMap(26) = 'AUTOROTATE';
end
