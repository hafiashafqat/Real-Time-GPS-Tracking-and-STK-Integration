%% real_time_data.m — Production Tracker with Indoor/Outdoor Mode
% =========================================================================
% Real-Time GPS Tracker: NavCast TCP Server --> MATLAB --> STK 11 GroundVehicle
% Features:
%   - Environment Presets: 'INDOOR_DESK' (12m noise gate) vs 'OUTDOOR_VEHICLE'
%   - Explicit 'eGroundVehicle' instantiation (fixes satellite type error)
%   - HDOP Uncertainty Gate & Automatic Deadband Re-Anchoring
%   - Realtime 3D Animation Clock Sync per packet
% =========================================================================
clc;
fprintf('=================================================\n');
fprintf('  STK 11 Real-Time GroundVehicle Tracker (TCP)  \n');
fprintf('=================================================\n\n');

% =========================================================================
%% CONFIGURATION & ENVIRONMENT PRESET
% =========================================================================
PHONE_IP    = '192.168.5.132';   % Set to your phone IP
TCP_PORT    = 10110;             % NavCast TCP Server Port
VEHICLE_NAME= 'GPS_Van';

% MODE SELECTOR: Set to 'INDOOR_DESK' or 'OUTDOOR_VEHICLE'
TEST_MODE   = 'INDOOR_DESK';

switch upper(TEST_MODE)
    case 'INDOOR_DESK'
        UNCERTAINTY_RADIUS_M  = 12.0;  % 12m radius to ignore indoor wall/window bounce
        MAX_ALLOWED_HDOP      = 2.0;   % Strict HDOP requirement
        REQUIRED_MOVE_PACKETS = 4;     % Require 4 consecutive updates outside 12m to move
        STOP_DWELL_PACKETS    = 2;     % Re-anchor quickly on stop
        STOP_SPEED_KMH        = 2.5;   % Speed threshold below which vehicle is static
        ALPHA_POSITION        = 0.25;  % Heavy smoothing
        
    case 'OUTDOOR_VEHICLE'
        UNCERTAINTY_RADIUS_M  = 4.0;   % Standard outdoor GPS accuracy radius
        MAX_ALLOWED_HDOP      = 2.5;   % Standard HDOP threshold
        REQUIRED_MOVE_PACKETS = 3;     % 3 consecutive updates to confirm movement
        STOP_DWELL_PACKETS    = 3;     % 3 consecutive slow updates to re-anchor
        STOP_SPEED_KMH        = 1.5;   % Stop threshold
        ALPHA_POSITION        = 0.40;  % Moderate motion smoothing
end

ALPHA_ALTITUDE      = 0.05;  % Mute altitude noise to keep vehicle grounded
MAX_VALID_SPEED_KMH = 150;   % Discard single-packet teleportation errors

fprintf('Active Mode: [%s]\n', upper(TEST_MODE));
fprintf('  - Noise Gate Radius : %.1f meters\n', UNCERTAINTY_RADIUS_M);
fprintf('  - Max Allowed HDOP  : %.1f\n\n', MAX_ALLOWED_HDOP);

% =========================================================================
%% STEP 1 — Connect to STK 11
% =========================================================================
fprintf('[1/6] Connecting to STK 11 via COM...\n');
try
    stkApp = actxGetRunningServer('STK11.application');
catch
    error('STK 11 is not running. Launch STK 11 and open a scenario first.');
end
stkApp.Visible = 1;
stkRoot  = stkApp.Personality2;
scenario = stkRoot.CurrentScenario;
fprintf('    Connected! Scenario: "%s"\n\n', char(scenario.InstanceName));

sendCmd = @(cmd) stkRoot.ExecuteCommand(cmd);
%Create coordiinate legend box on STK 2D map
try 
    sendCmd('VO*Annotation Add "GPS_Coords"');
    sendCmd('VO*Annotation Add "GPS_Coords"Show On');
    sendCmd('VO*Annotation Add "GPS_Coords"Color Cyan');
    sendCmd('VO*Annotation Add "GPS_Coords"Position 10 10');
    fprintf('Coordinate legend created on STK.\n');
catch
    fprintf('Legend:will try updating directly.\n');
end
% =========================================================================
%% STEP 2 — Create or reuse GroundVehicle "GPS_Van"
% =========================================================================
fprintf('[2/6] Setting up Ground Vehicle "%s"...\n', VEHICLE_NAME);
objPath = ['*/GroundVehicle/' VEHICLE_NAME];

try
    vehicle = stkRoot.GetObjectFromPath(objPath);
    if ~contains(class(vehicle), 'IAgGroundVehicle', 'IgnoreCase', true)
        fprintf('    Existing object type mismatch. Recreating as GroundVehicle...\n');
        vehicle.Unload();
        vehicle = scenario.Children.New('eGroundVehicle', VEHICLE_NAME);
    else
        fprintf('    Reusing existing GroundVehicle "%s".\n', VEHICLE_NAME);
    end
catch
    fprintf('    Creating GroundVehicle "%s"...\n', VEHICLE_NAME);
    vehicle = scenario.Children.New('eGroundVehicle', VEHICLE_NAME);
end

% =========================================================================
%% STEP 3 — Configure Realtime Propagator
% =========================================================================
fprintf('[3/6] Setting up STK Realtime Propagator...\n');
try
    vehicle.SetRouteType('ePropagatorRealtime');
    route = vehicle.Route;
    
    route.TimeStep    = 1;
    route.TimeoutGap  = 5;
    
    route.LookAheadPropagator = 'eLookAheadHoldCBFPosition';
    route.Duration.LookAhead  = 5;
    route.Duration.LookBehind = 5;
    
    route.Propagate();
    
    pb  = route.PointBuilder;
    p   = invoke(pb, 'get');
    lla = p.LLA;
    fprintf('    Realtime LLA PointBuilder ready.\n');
    
    try
        sendCmd('Animate * SetMode Realtime');
        sendCmd('Animate * Start Realtime');
        fprintf('    STK animation clock initialized.\n\n');
    catch
        fprintf('    Animation command processed.\n\n');
    end
catch ME
    error('Failed to initialize Realtime Propagator: %s', ME.message);
end

% =========================================================================
%% STEP 4 — Trajectory Trail Setup
% =========================================================================
fprintf('[4/6] Enabling trajectory trail...\n');
try
    sendCmd(sprintf('VO %s TrackHistory Show', objPath));
    sendCmd(sprintf('VO %s TrackHistory Color Yellow', objPath));
    sendCmd(sprintf('VO %s TrackHistory LineWidth 3', objPath));
    fprintf('    Trail enabled.\n\n');
catch
    fprintf('    Trail configuration skipped — set manually in STK if needed.\n\n');
end

% =========================================================================
%% STEP 5 — Connect to NavCast TCP Server
% =========================================================================
fprintf('[5/6] Connecting to NavCast on phone (%s:%d)...\n', PHONE_IP, TCP_PORT);
maxRetries = 5;
tcpClient  = [];
for attempt = 1:maxRetries
    try
        tcpClient = tcpclient(PHONE_IP, TCP_PORT, "Timeout", 10);
        fprintf('    Connected to NavCast!\n\n');
        break;
    catch ME
        if attempt < maxRetries
            fprintf('    Attempt %d failed. Retrying in 3s...\n', attempt);
            pause(3);
        else
            error('Could not connect to NavCast: %s', ME.message);
        end
    end
end
cleanupTCP = onCleanup(@() delete(tcpClient));

% Diagnostic Buffer Flush
diagStart  = tic;
diagBuffer = '';
while toc(diagStart) < 2
    if tcpClient.NumBytesAvailable > 0
        raw        = read(tcpClient, tcpClient.NumBytesAvailable, 'char');
        diagBuffer = [diagBuffer, raw];
    end
    pause(0.1);
end

% =========================================================================
%% STEP 6 — Main Real-Time Streaming Loop
% =========================================================================
fprintf('[6/6] Live tracking active...\n');
fprintf('Press Ctrl+C in MATLAB to stop.\n\n');
fprintf('%-8s %-22s %-10s %-10s %-7s %-7s %-8s\n', ...
        'Packet', 'STK UTC Time', 'Latitude', 'Longitude', 'HDOP', 'km/h', 'Status');
fprintf('%s\n', repmat('-', 1, 76));

packetCount = 0;
lineBuffer  = diagBuffer;
gpsDate     = ''; 

% Filter State Variables
anchorLat      = NaN;
anchorLon      = NaN;
anchorAlt      = NaN;

smoothLat      = NaN;
smoothLon      = NaN;
smoothAlt      = NaN;

lastDT         = [];
isStatic       = true;
consecutiveOut = 0;
consecutiveStop= 0;

while true
    % Reconnection Handler
    if ~isvalid(tcpClient)
        fprintf('\n    Connection lost. Reconnecting...\n');
        pause(2);
        try
            tcpClient  = tcpclient(PHONE_IP, TCP_PORT, "Timeout", 10);
            cleanupTCP = onCleanup(@() delete(tcpClient));
            lineBuffer = '';
            fprintf('    Reconnected!\n\n');
        catch
            pause(3);
            continue;
        end
    end

    if tcpClient.NumBytesAvailable < 1
        pause(0.05);
        continue;
    end

    newData    = read(tcpClient, tcpClient.NumBytesAvailable, 'char');
    lineBuffer = [lineBuffer, newData];
    lines      = strsplit(lineBuffer, {'\n', '\r\n', '\r'}, 'CollapseDelimiters', false);
    lineBuffer = lines{end};
    lines      = lines(1:end-1);

    for k = 1:numel(lines)
        sentence = strtrim(lines{k});
        if isempty(sentence); continue; end

        % Extract UTC Date from RMC
        if startsWith(sentence, '$GPRMC') || startsWith(sentence, '$GNRMC')
            fields = split(sentence, ',');
            if numel(fields) >= 10 && strcmpi(strtrim(fields{3}), 'A')
                dateUTC = strtrim(fields{10});
                if strlength(dateUTC) >= 6; gpsDate = dateUTC; end
            end
        end

        % Process GGA Sentences
        if ~(startsWith(sentence, '$GPGGA') || startsWith(sentence, '$GNGGA')); continue; end
        fields = split(sentence, ',');
        if numel(fields) < 11; continue; end
        
        fixQ = str2double(fields{7});
        if isnan(fixQ) || fixQ == 0; continue; end

        % HDOP Gate
        hdop = str2double(fields{9});
        if isnan(hdop); hdop = 1.0; end
        if hdop > MAX_ALLOWED_HDOP; continue; end

        timeUTC = strtrim(fields{2});
        rawLat  = str2double(fields{3});
        if isnan(rawLat); continue; end
        lat     = floor(rawLat/100) + (rawLat - floor(rawLat/100)*100)/60;
        if strcmpi(strtrim(fields{4}), 'S'); lat = -lat; end

        rawLon  = str2double(fields{5});
        if isnan(rawLon); continue; end
        lon     = floor(rawLon/100) + (rawLon - floor(rawLon/100)*100)/60;
        if strcmpi(strtrim(fields{6}), 'W'); lon = -lon; end

        alt     = str2double(fields{10});
        if isnan(alt); alt = 0; end

        if strlength(timeUTC) < 6; continue; end

        % Parse UTC Timestamp
        hh = str2double(timeUTC(1:2));
        mm = str2double(timeUTC(3:4));
        ss = str2double(timeUTC(5:end));

        if strlength(gpsDate) >= 6
            dd = str2double(gpsDate(1:2));
            mo = str2double(gpsDate(3:4));
            yy = str2double(gpsDate(5:6)) + 2000;
        else
            nowUTC = datetime('now', 'TimeZone', 'UTC');
            dd = nowUTC.Day; mo = nowUTC.Month; yy = nowUTC.Year;
        end

        try
            currDT  = datetime(yy, mo, dd, hh, mm, ss, 'TimeZone', 'UTC');
            stkTime = char(string(currDT, 'dd MMM yyyy HH:mm:ss.SSS'));
        catch
            continue;
        end

        % Speed Gate & Telemetry
        speedKmh = 0;
        if ~isempty(lastDT)
            dt = seconds(currDT - lastDT);
            if dt > 0 && ~isnan(smoothLat)
                dLatM = (lat - smoothLat) * 111000;
                dLonM = (lon - smoothLon) * 111000 * cosd(lat);
                distM = sqrt(dLatM^2 + dLonM^2);
                speedKmh = (distM / dt) * 3.6;
                
                % Rejection gate for single-packet teleportation errors
                if speedKmh > MAX_VALID_SPEED_KMH
                    continue; 
                end
            end
        end
        lastDT = currDT;

        % Initialize Filters on First Valid Packet
        if isnan(anchorLat)
            anchorLat = lat; anchorLon = lon; anchorAlt = alt;
            smoothLat = lat; smoothLon = lon; smoothAlt = alt;
        end

        % -----------------------------------------------------------------
        % State Machine: Dynamic Re-Anchoring & Deadband
        % -----------------------------------------------------------------
        dLatAnchor = (lat - anchorLat) * 111000;
        dLonAnchor = (lon - anchorLon) * 111000 * cosd(anchorLat);
        distFromAnchor = sqrt(dLatAnchor^2 + dLonAnchor^2);

        if isStatic
            if distFromAnchor > UNCERTAINTY_RADIUS_M
                consecutiveOut = consecutiveOut + 1;
                if consecutiveOut >= REQUIRED_MOVE_PACKETS
                    isStatic        = false;
                    consecutiveOut  = 0;
                    consecutiveStop = 0;
                end
            else
                consecutiveOut = 0;
            end
        else
            % Check for Vehicle Dwell / Stop
            if speedKmh < STOP_SPEED_KMH || distFromAnchor < UNCERTAINTY_RADIUS_M
                consecutiveStop = consecutiveStop + 1;
                if consecutiveStop >= STOP_DWELL_PACKETS
                    isStatic        = true;
                    anchorLat       = smoothLat;
                    anchorLon       = smoothLon;
                    anchorAlt       = smoothAlt;
                    consecutiveStop = 0;
                end
            else
                consecutiveStop = 0;
            end
        end

        % -----------------------------------------------------------------
        % Position Selection / Smoothing
        % -----------------------------------------------------------------
        if isStatic
            outLat    = anchorLat;
            outLon    = anchorLon;
            outAlt    = anchorAlt;
            statusStr = 'STATIC';
        else
            smoothLat = ALPHA_POSITION * lat + (1 - ALPHA_POSITION) * smoothLat;
            smoothLon = ALPHA_POSITION * lon + (1 - ALPHA_POSITION) * smoothLon;
            smoothAlt = ALPHA_ALTITUDE * alt + (1 - ALPHA_ALTITUDE) * smoothAlt;
            
            outLat    = smoothLat;
            outLon    = smoothLon;
            outAlt    = smoothAlt;
            statusStr = 'MOVING';
        end
%Updating live coordinate legend on stk SCREEN
% Update live coordinate legend on STK screen
try
    legendText = sprintf(['GPS Van Live\n' ...
        ' Lat  : %.6f\n' ...
        ' Lon  : %.6f\n' ...
        ' Alt  : %.1f m\n' ...
        ' Speed: %.1f kmh\n' ...
        ' State: %s\n' ...
        ' Pkt  : %d'], ...
        outLat, outLon, outAlt, speedKmh, statusStr, packetCount);
    sendCmd(sprintf('VO * Annotation "GPS_Coords" Text "%s"', legendText));
catch; end

        % -----------------------------------------------------------------
        % Send Point to STK & Advance 3D Clock
        % -----------------------------------------------------------------
        try
            invoke(lla, 'AddPosition', stkTime, outLat, outLon, outAlt);
            sendCmd(sprintf('SetAnimation * CurrentTime "%s"', stkTime));

            packetCount = packetCount + 1;
            
            fprintf('%-8s %-22s %-10.6f %-10.6f %-7.1f %-7.1f %-8s\n', ...
                    sprintf('#%d', packetCount), stkTime, outLat, outLon, hdop, speedKmh, statusStr);
        catch ME
            fprintf('    ! STK Realtime Error: %s\n', ME.message);
        end
    end
end
