# Real-Time GPS Tracking and Visualization Using MATLAB and STK 11

## Overview

This project implements a real-time GPS tracking pipeline that streams GPS data from a mobile device to MATLAB and visualizes the vehicle's position and trajectory in Systems Tool Kit (STK) 11.

The system uses a TCP connection to receive NMEA GPS sentences from NavCast, processes incoming position and movement data, and updates an STK GroundVehicle object in real time.

## System Architecture

**NavCast GPS Stream → TCP/IP → MATLAB Processing → STK 11 Visualization**

### Key Features

* Real-time GPS data reception through TCP/IP.
* NMEA sentence processing, including GGA, RMC, and VTG.
* Latitude and longitude conversion from NMEA coordinates to decimal degrees.
* GPS fix quality, satellite count, and HDOP-based filtering.
* Rejection of implausible position jumps.
* Static-versus-moving detection using displacement and reported speed.
* Position smoothing and stationary-position anchoring.
* Real-time GroundVehicle updates in STK 11.
* Trajectory visualization and on-screen coordinate annotations.
* Indoor desk and outdoor vehicle configuration presets.

## Technologies

* MATLAB
* AGI Systems Tool Kit (STK) 11
* NavCast GPS streaming application
* TCP/IP communication
* NMEA GPS data

## Requirements

* MATLAB on a Windows system with the required COM/ActiveX support.
* STK 11 installed and running.
* An STK scenario open before starting the MATLAB script.
* A phone configured to stream GPS data through NavCast.
* Network connectivity between the computer and phone.

## Setup

1. Open STK 11 and load a scenario.
2. Configure NavCast on the phone to provide a TCP GPS stream.
3. Find the phone's local IP address.
4. Update `PHONE_IP` and `TCP_PORT` in `real_time_data.m`.
5. Select the appropriate `TEST_MODE`:

   * `INDOOR_DESK`
   * `OUTDOOR_VEHICLE`
6. Run the MATLAB script.
7. Observe the incoming GPS fixes, tracking status, and vehicle trajectory in STK.

## Processing Workflow

1. Receive and buffer incoming NMEA sentences.
2. Extract GPS position, fix quality, satellite count, and reported speed.
3. Reject invalid or low-quality fixes.
4. Convert coordinates into decimal latitude and longitude.
5. Estimate displacement and movement speed.
6. Determine whether the tracked object is stationary or moving.
7. Apply position smoothing and update the STK GroundVehicle.
8. Display the updated position and trajectory.

## Current Scope and Limitations

This is a real-time tracking and visualization prototype. Its accuracy depends on the quality of the incoming GPS data, device configuration, network connectivity, and the selected filtering thresholds.

The indoor and outdoor settings are configurable filtering presets, not a validated guarantee of positioning accuracy. The current implementation does not independently establish ground-truth position accuracy.

## Future Improvements

* Add recorded GPS replay for repeatable testing.
* Evaluate position error against a known reference trajectory.
* Add logging and performance metrics.
* Improve reconnection and error-handling tests.
* Separate GPS parsing, filtering, and STK communication into reusable modules.

## Author

Developed as a practical project in MATLAB-based real-time data processing and satellite mission visualization.
