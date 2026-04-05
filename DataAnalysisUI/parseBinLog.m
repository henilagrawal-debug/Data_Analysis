function [logData, fmtInfo] = parseBinLog(filename)
%PARSEBINLOG Parse ArduPilot DataFlash binary log file (.bin)
%
%   logData = parseBinLog(filename)
%   [logData, fmtInfo] = parseBinLog(filename)
%
%   Two-pass parser for efficiency:
%     Pass 1: Scan headers, parse FMT messages, catalog positions
%     Pass 2: Preallocate matrices, parse all data
%
%   Messages with an 'I' (instance) field are split: GPS_0, GPS_1, etc.
%
%   Example:
%       log = parseBinLog('2026-04-02 09-23-59.bin');
%       plot(log.GPS_0.TimeUS/1e6, log.GPS_0.Spd);

    %% Read entire file into memory
    fid = fopen(filename, 'rb');
    if fid < 0
        error('parseBinLog:FileError', 'Cannot open: %s', filename);
    end
    raw = fread(fid, Inf, '*uint8')';
    fclose(fid);
    nBytes = numel(raw);
    fprintf('Loaded %s (%.1f MB)\n', filename, nBytes / 1e6);

    %% Constants
    HDR1 = uint8(163);   % 0xA3
    HDR2 = uint8(149);   % 0x95
    FMT_TYPE = 128;
    FMT_LEN  = 89;

    %% Format table: cell array indexed by (type+1), 1..256
    fmts = cell(256, 1);
    fmts{FMT_TYPE + 1} = makeFormat('FMT', 'BBnNZ', ...
        'Type,Length,Name,Format,Labels', FMT_LEN);

    %% ===== Pass 1: Scan for FMT definitions and catalog all messages =====
    INIT_CAP = 500000;
    msgPos   = zeros(1, INIT_CAP, 'uint32');
    msgTyp   = zeros(1, INIT_CAP, 'uint8');
    nMsg     = 0;
    pos      = 1;

    while pos <= nBytes - 2
        if raw(pos) ~= HDR1 || raw(pos + 1) ~= HDR2
            pos = pos + 1;
            continue;
        end

        t  = raw(pos + 2);        % message type (0-255)
        ti = double(t) + 1;       % 1-indexed

        if isempty(fmts{ti})
            pos = pos + 1;
            continue;
        end

        def = fmts{ti};
        if pos + def.len - 1 > nBytes
            break;
        end

        % Record this message
        nMsg = nMsg + 1;
        if nMsg > numel(msgPos)
            msgPos(end * 2) = 0;
            msgTyp(end * 2) = 0;
        end
        msgPos(nMsg) = pos;
        msgTyp(nMsg) = t;

        % If FMT, parse it now to learn about new message types
        if t == FMT_TYPE
            payload = raw(pos + 3 : pos + def.len - 1);
            vals = decodePayload(payload, def.fmt);
            if ~isempty(vals)
                nType = vals{1};
                nLen  = vals{2};
                nName = strtrim(vals{3});
                nFmt  = strtrim(vals{4});
                nLbl  = strtrim(vals{5});
                if nType >= 0 && nType <= 255 && nLen > 2 && ~isempty(nName)
                    fmts{nType + 1} = makeFormat(nName, nFmt, nLbl, double(nLen));
                end
            end
        end

        pos = pos + def.len;
    end

    msgPos = msgPos(1:nMsg);
    msgTyp = msgTyp(1:nMsg);
    fprintf('Pass 1 complete: %d messages cataloged\n', nMsg);

    %% Count messages per type
    typeCounts = zeros(256, 1);
    for k = 1:nMsg
        typeCounts(double(msgTyp(k)) + 1) = typeCounts(double(msgTyp(k)) + 1) + 1;
    end

    %% ===== Pass 2: Preallocate and parse into matrices =====
    dataMats   = cell(256, 1);
    dataCount  = zeros(256, 1);

    for ti = 1:256
        if typeCounts(ti) == 0 || isempty(fmts{ti}), continue; end
        if ti - 1 == FMT_TYPE, continue; end
        def = fmts{ti};
        if def.numCols > 0
            dataMats{ti} = zeros(typeCounts(ti), def.numCols);
        end
    end

    for k = 1:nMsg
        t  = msgTyp(k);
        ti = double(t) + 1;
        if t == FMT_TYPE, continue; end
        def = fmts{ti};
        if isempty(def) || def.numCols == 0, continue; end

        p = double(msgPos(k));
        payload = raw(p + 3 : p + def.len - 1);
        vals = decodePayload(payload, def.fmt);

        if isempty(vals), continue; end

        dataCount(ti) = dataCount(ti) + 1;
        row = dataCount(ti);

        col = 0;
        for j = 1:numel(vals)
            if j <= numel(def.numMask) && def.numMask(j) ...
                    && isnumeric(vals{j}) && isscalar(vals{j})
                col = col + 1;
                if col <= def.numCols
                    dataMats{ti}(row, col) = vals{j};
                end
            end
        end

        % Progress
        if mod(k, 200000) == 0
            fprintf('  Parsed %d / %d messages...\n', k, nMsg);
        end
    end

    fprintf('Pass 2 complete: all messages parsed\n');

    %% Build output struct with named fields, split by instance
    logData = struct();

    for ti = 1:256
        if dataCount(ti) == 0 || isempty(fmts{ti}), continue; end
        def = fmts{ti};
        mat = dataMats{ti}(1:dataCount(ti), :);
        safeName = matlab.lang.makeValidName(def.name);
        numLabels = def.numLabels;

        % Check for instance field 'I' — only treat as instance if values
        % are small non-negative integers (not floats like PID integral terms)
        iCol = find(strcmp(numLabels, 'I'), 1);
        isInstance = false;
        if ~isempty(iCol) && size(mat, 1) > 0
            iVals = mat(:, iCol);
            instances = unique(iVals);
            % Instance IDs must be non-negative integers in a small range
            if all(instances >= 0) && all(instances == round(instances)) ...
                    && max(instances) < 16
                isInstance = true;
            end
        end
        if isInstance
            if numel(instances) > 1
                for ii = 1:numel(instances)
                    inst = instances(ii);
                    mask = mat(:, iCol) == inst;
                    instName = sprintf('%s_%d', safeName, inst);
                    for ci = 1:numel(numLabels)
                        lbl = matlab.lang.makeValidName(numLabels{ci});
                        logData.(instName).(lbl) = mat(mask, ci)';
                    end
                end
                continue;
            end
        end

        % No instance splitting needed
        for ci = 1:numel(numLabels)
            lbl = matlab.lang.makeValidName(numLabels{ci});
            logData.(safeName).(lbl) = mat(:, ci)';
        end
    end

    %% Format info output
    if nargout > 1
        fmtInfo = fmts;
    end

    msgNames = fieldnames(logData);
    fprintf('Done. %d message types: %s\n', numel(msgNames), strjoin(msgNames, ', '));
end

%% ========== Local Functions ==========

function def = makeFormat(name, fmt, lblStr, len)
%MAKEFORMAT Create a format definition struct
    labels = strsplit(lblStr, ',');
    nMask  = true(1, numel(fmt));
    for k = 1:numel(fmt)
        if any(fmt(k) == 'nNZa')
            nMask(k) = false;
        end
    end
    nLabels = {};
    for k = 1:numel(labels)
        if k <= numel(nMask) && nMask(k)
            nLabels{end + 1} = strtrim(labels{k}); %#ok<AGROW>
        end
    end
    def = struct('name', name, 'fmt', fmt, 'labels', {labels}, ...
        'len', len, 'numMask', nMask, 'numLabels', {nLabels}, ...
        'numCols', numel(nLabels));
end

function vals = decodePayload(data, fmt)
%DECODEPAYLOAD Decode binary payload bytes according to DataFlash format
    vals = {};
    p = 1;
    n = numel(data);
    for k = 1:numel(fmt)
        if p > n, vals = {}; return; end
        switch fmt(k)
            case 'b'
                vals{end+1} = double(typecast(data(p), 'int8')); p = p+1; %#ok<*AGROW>
            case 'B'
                vals{end+1} = double(data(p)); p = p+1;
            case 'M'
                vals{end+1} = double(data(p)); p = p+1;
            case 'h'
                if p+1>n, vals={}; return; end
                vals{end+1} = double(typecast(data(p:p+1), 'int16')); p = p+2;
            case 'H'
                if p+1>n, vals={}; return; end
                vals{end+1} = double(typecast(data(p:p+1), 'uint16')); p = p+2;
            case 'i'
                if p+3>n, vals={}; return; end
                vals{end+1} = double(typecast(data(p:p+3), 'int32')); p = p+4;
            case 'I'
                if p+3>n, vals={}; return; end
                vals{end+1} = double(typecast(data(p:p+3), 'uint32')); p = p+4;
            case 'f'
                if p+3>n, vals={}; return; end
                vals{end+1} = double(typecast(data(p:p+3), 'single')); p = p+4;
            case 'd'
                if p+7>n, vals={}; return; end
                vals{end+1} = typecast(data(p:p+7), 'double'); p = p+8;
            case 'n'
                if p+3>n, vals={}; return; end
                vals{end+1} = deblank(char(data(p:p+3))); p = p+4;
            case 'N'
                if p+15>n, vals={}; return; end
                vals{end+1} = deblank(char(data(p:p+15))); p = p+16;
            case 'Z'
                if p+63>n, vals={}; return; end
                vals{end+1} = deblank(char(data(p:p+63))); p = p+64;
            case 'c'
                if p+1>n, vals={}; return; end
                vals{end+1} = double(typecast(data(p:p+1), 'int16')) * 0.01; p = p+2;
            case 'C'
                if p+1>n, vals={}; return; end
                vals{end+1} = double(typecast(data(p:p+1), 'uint16')) * 0.01; p = p+2;
            case 'e'
                if p+3>n, vals={}; return; end
                vals{end+1} = double(typecast(data(p:p+3), 'int32')) * 0.01; p = p+4;
            case 'E'
                if p+3>n, vals={}; return; end
                vals{end+1} = double(typecast(data(p:p+3), 'uint32')) * 0.01; p = p+4;
            case 'L'
                if p+3>n, vals={}; return; end
                vals{end+1} = double(typecast(data(p:p+3), 'int32')) * 1e-7; p = p+4;
            case 'q'
                if p+7>n, vals={}; return; end
                vals{end+1} = double(typecast(data(p:p+7), 'int64')); p = p+8;
            case 'Q'
                if p+7>n, vals={}; return; end
                vals{end+1} = double(typecast(data(p:p+7), 'uint64')); p = p+8;
            case 'a'
                if p+63>n, vals={}; return; end
                vals{end+1} = double(typecast(data(p:p+63), 'int16')); p = p+64;
            otherwise
                vals{end+1} = double(data(p)); p = p+1;
        end
    end
end
