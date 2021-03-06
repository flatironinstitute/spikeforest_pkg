function p_kilosort2(kilosort_src, temp_path, raw_fname, geom_fname, firings_out_fname, arg_fname)

if exist(temp_path, 'dir') ~= 7
    mkdir(temp_path);
end

% prepare for kilosort execution
addpath(genpath(kilosort_src));
ops = import_ksort_(raw_fname, geom_fname, arg_fname, temp_path);

% Run kilosort
t1=tic;
fprintf('Running kilosort on %s\n', raw_fname);
% preprocess data to create temp_wh.dat
rez = preprocessDataSub(ops);

% time-reordering as a function of drift
rez = clusterSingleBatches(rez);
% save(fullfile(rootZ, 'rez.mat'), 'rez', '-v7.3');

% main tracking and template matching algorithm
rez = learnAndSolve8b(rez);

% final merges
rez = find_merges(rez, 1);

% final splits by SVD
rez = splitAllClusters(rez, 1);

% final splits by amplitudes
rez = splitAllClusters(rez, 0);

% decide on cutoff
rez = set_cutoff(rez);

% discard features in final rez file (too slow to save)
rez.cProj = [];
rez.cProjPC = [];

fprintf('\n\tfound %d good units \n', sum(rez.good>0))

fprintf('\n\ttook %0.1fs\n', toc(t1));

% Export kilosort
mr_out = export_ksort_(rez, firings_out_fname);

fprintf('Clustering result wrote to %s\n', firings_out_fname);

end %func


%--------------------------------------------------------------------------
function mr_out = export_ksort_(rez, firings_out_fname)

mr_out = zeros(size(rez.st3,1), 3, 'double'); 
mr_out(:,2) = rez.st3(:,1); %time
mr_out(:,3) = rez.st3(:,2); %cluster
writemda(mr_out', firings_out_fname, 'float32');
end %func


%--------------------------------------------------------------------------
function ops = import_ksort_(raw_fname, geom_fname, arg_fname, fpath)
% fpath: output path
S_txt = meta2struct_(arg_fname);
useGPU = 1;
[freq_min, pc_per_chan, sRateHz, spkTh, minFR, adjacency_radius] = ...
    struct_get_(S_txt, 'freq_min', 'pc_per_chan', 'samplerate', 'detect_threshold', 'minFR', 'adjacency_radius');
spkTh = -abs(spkTh);

% convert to binary file (int16)
fbinary = strrep(raw_fname, '.mda', '.bin');
[Nchannels, ~] = mda2bin_(raw_fname, fbinary, S_txt.detect_sign);

% create a probe file
mrXY_site = csvread(geom_fname);
vcFile_chanMap = fullfile(fpath, 'chanMap.mat');
createChannelMapFile_(vcFile_chanMap, Nchannels, mrXY_site(:,1), mrXY_site(:,2));
nChans = size(mrXY_site,1);

S_ops = makeStruct_(fpath, fbinary, nChans, vcFile_chanMap, spkTh, useGPU, sRateHz, pc_per_chan, freq_min, minFR, adjacency_radius);
ops = config_kilosort2_(S_ops); %obtain ops

end %func


%--------------------------------------------------------------------------
function S = makeStruct_(varargin)
%MAKESTRUCT all the inputs must be a variable. 
%don't pass function of variables. ie: abs(X)
%instead create a var AbsX an dpass that name
S = struct();
for i=1:nargin, S.(inputname(i)) =  varargin{i}; end
end %func


%--------------------------------------------------------------------------
function S_chanMap = createChannelMapFile_(vcFile_channelMap, Nchannels, xcoords, ycoords, shankInd)
if nargin<6, shankInd = []; end

connected = true(Nchannels, 1);
chanMap   = 1:Nchannels;
chanMap0ind = chanMap - 1;

xcoords   = xcoords(:);
ycoords   = ycoords(:);

if isempty(shankInd)
    shankInd   = ones(Nchannels,1); % grouping of channels (i.e. tetrode groups)
end
[~, name, ~] = fileparts(vcFile_channelMap);
S_chanMap = makeStruct_(chanMap, connected, xcoords, ycoords, shankInd, chanMap0ind, name);
save(vcFile_channelMap, '-struct', 'S_chanMap')
end %func


%--------------------------------------------------------------------------
% convert mda to int16 binary format, flip polarity if detect sign is
% positive
function [nChans, nSamples] = mda2bin_(raw_fname, fbinary, detect_sign)

mr = readmda(raw_fname);
% adjust scale to fit int16 range with a margin
if isa(mr,'single') || isa(mr,'double')
    uV_per_bit = 2^14 / max(abs(mr(:)));
    mr = int16(mr * uV_per_bit);
end
[nChans, nSamples] = size(mr);
if detect_sign > 0, mr = -mr; end % force negative detection
fid = fopen(fbinary, 'w');
fwrite(fid, mr, 'int16');
fclose(fid);
end %func


%--------------------------------------------------------------------------
function ops = config_kilosort2_(S_opt)
% S_opt: fpath, fbinary, nChans, vcFile_chanMap, spkTh, useGPU, sRateHz,
%       pc_per_chan, freq_min

% rootH = '~/kilosort';
ops.fig = 0;
ops.fproc       = fullfile(S_opt.fpath, 'temp_wh.dat'); % proc file on a fast SSD  ;
ops.trange = [0 Inf]; % time range to sort
ops.NchanTOT    = S_opt.nChans; % total number of channels in your recording

% the binary file is in this folder
ops.fbinary = S_opt.fbinary;

ops.chanMap = S_opt.vcFile_chanMap;
% ops.chanMap = 1:ops.Nchan; % treated as linear probe if no chanMap file

% sample rate
ops.fs = S_opt.sRateHz;  

% frequency for high pass filtering (150)
ops.fshigh = S_opt.freq_min;   

% minimum firing rate on a "good" channel (0 to skip)
ops.minfr_goodchannels = 0.1; 

% threshold on projections (like in Kilosort1, can be different for last pass like [10 4])
ops.Th = [6, 2];  

% how important is the amplitude penalty (like in Kilosort1, 0 means not used, 10 is average, 50 is a lot) 
ops.lam = 10;  

% splitting a cluster at the end requires at least this much isolation for each sub-cluster (max = 1)
ops.AUCsplit = 0.9; 

% minimum spike rate (Hz), if a cluster falls below this for too long it gets removed
ops.minFR = S_opt.minFR; 

% number of samples to average over (annealed from first to second value) 
ops.momentum = [20 400]; 

% spatial constant in um for computing residual variance of spike
ops.sigmaMask = S_opt.adjacency_radius; 

% threshold crossings for pre-clustering (in PCA projection space)
ops.ThPre = 8;

% danger, changing these settings can lead to fatal errors
% options for determining PCs
ops.spkTh           = S_opt.spkTh;      % spike threshold in standard deviations (-6)
ops.reorder         = 1;       % whether to reorder batches for drift correction. 
ops.nskip           = 25;  % how many batches to skip for determining spike PCs

ops.GPU                 = S_opt.useGPU; % has to be 1, no CPU version yet, sorry
% ops.Nfilt               = 1024; % max number of clusters
ops.nfilt_factor        = 4; % max number of clusters per good channel (even temporary ones)
ops.ntbuff              = 64;    % samples of symmetrical buffer for whitening and spike detection
ops.NT                  = 64*1024+ ops.ntbuff; % must be multiple of 32 + ntbuff. This is the batch size (try decreasing if out of memory). 
ops.whiteningRange      = min(S_opt.nChans,32); % number of channels to use for whitening each channel
ops.nSkipCov            = 25; % compute whitening matrix from every N-th batch
ops.scaleproc           = 200;   % int16 scaling of whitened data
ops.nPCs                = S_opt.pc_per_chan; % how many PCs to project the spikes into
ops.useRAM              = 0; % not yet available

end %func


%--------------------------------------------------------------------------
% 8/22/18 JJJ: changed from the cell output to varargout
% 9/26/17 JJJ: Created and tested
function varargout = struct_get_(varargin)
% Obtain a member of struct
% cvr = cell(size(varargin));
% if varargin is given as cell output is also cell
S = varargin{1};
for iArg=1:nargout
    vcName = varargin{iArg+1};
    if iscell(vcName)
        csName_ = vcName;
        cell_ = cell(size(csName_));
        for iCell = 1:numel(csName_)
            vcName_ = csName_{iCell};
            if isfield(S, vcName_)
                cell_{iCell} = S.(vcName_);
            end
        end %for
        varargout{iArg} = cell_;
    elseif ischar(vcName)
        if isfield(S, vcName)
            varargout{iArg} = S.(vcName);
        else
            varargout{iArg} = [];
        end
    else
        varargout{iArg} = [];
    end
end %for
end %func


%--------------------------------------------------------------------------
% 8/2/17 JJJ: Documentation and test
function S = meta2struct_(vcFile)
    % Convert text file to struct
    S = struct();
    if ~exist_file_(vcFile, 1), return; end
    
    fid = fopen(vcFile, 'r');
    mcFileMeta = textscan(fid, '%s%s', 'Delimiter', '=',  'ReturnOnError', false);
    fclose(fid);
    csName = mcFileMeta{1};
    csValue = mcFileMeta{2};
    for i=1:numel(csName)
        vcName1 = csName{i};
        if vcName1(1) == '~', vcName1(1) = []; end
        try         
            eval(sprintf('%s = ''%s'';', vcName1, csValue{i}));
            eval(sprintf('num = str2double(%s);', vcName1));
            if ~isnan(num)
                eval(sprintf('%s = num;', vcName1));
            end
            eval(sprintf('S = setfield(S, ''%s'', %s);', vcName1, vcName1));
        catch
            fprintf('%s = %s error\n', csName{i}, csValue{i});
        end
    end
    end %func
    
    
    %--------------------------------------------------------------------------
    % 7/21/2018 JJJ: rejecting directories, strictly search for flies
    % 9/26/17 JJJ: Created and tested
    function flag = exist_file_(vcFile, fVerbose)
    if nargin<2, fVerbose = 0; end
    if isempty(vcFile)
        flag = false; 
    elseif iscell(vcFile)
        flag = cellfun(@(x)exist_file_(x, fVerbose), vcFile);
        return;
    else
        S_dir = dir(vcFile);
        if numel(S_dir) == 1
            flag = ~S_dir.isdir;
        else
            flag = false;
        end
    end
    if fVerbose && ~flag
        fprintf(2, 'File does not exist: %s\n', vcFile);
    end
    end %func
    
    
    