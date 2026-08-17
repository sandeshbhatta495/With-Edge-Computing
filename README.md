# Livestock Tracker

A Flutter-based livestock monitoring and tracking application designed to work with a GPS- and communication-enabled livestock tracking system.

The application provides a centralized interface for monitoring livestock locations, viewing maps, managing geofences, downloading map areas for offline use, viewing alerts, and interacting with the connected livestock tracking hardware.

---

## Table of Contents

- [Overview](#overview)
- [Objectives](#objectives)
- [System Architecture](#system-architecture)
- [Key Features](#key-features)
- [Application Navigation](#application-navigation)
- [Map and Offline Map System](#map-and-offline-map-system)
- [Livestock Tracking](#livestock-tracking)
- [Geofencing](#geofencing)
- [Notifications and Alerts](#notifications-and-alerts)
- [Hardware Communication](#hardware-communication)
- [Project Structure](#project-structure)
- [Technology Stack](#technology-stack)
- [Requirements](#requirements)
- [Installation](#installation)
- [Running the Application](#running-the-application)
- [Application Architecture](#application-architecture)
- [Development Status](#development-status)
- [Future Improvements](#future-improvements)
- [Contributors](#contributors)
- [License](#license)

---

# Overview

Livestock Tracker is a mobile application developed using Flutter for monitoring livestock equipped with tracking devices.

The application is designed around a livestock tracking system where location information can be collected from tracking devices and displayed on a map.

The application provides:

- Live location monitoring
- Livestock identification and location markers
- Interactive maps
- Offline map support
- Rectangular offline-map area selection
- Geofence management
- Notifications and alerts
- Dashboard information
- Wi-Fi-based communication with the connected device
- LED control for the connected hardware
- Local data storage

The application is structured so that common application functionality is separated from Map-specific functionality.

---

# Objectives

The main objectives of the application are:

1. Monitor livestock locations.
2. Display livestock positions on an interactive map.
3. Provide location information without depending entirely on continuous Internet access.
4. Allow users to define and manage geographical boundaries.
5. Download selected map regions for offline use.
6. Provide alerts and notifications related to the livestock tracking system.
7. Communicate with the connected tracking hardware.
8. Provide a simple interface for herders or system operators.

---

# System Architecture

The application is one component of the overall livestock tracking system.

```text
                    Livestock
                        |
                        v
              +-------------------+
              | GPS Tracking Node |
              | GPS + Controller  |
              | Communication     |
              +-------------------+
                        |
                        | Wireless Communication
                        v
              +-------------------+
              | Receiver / ESP    |
              | Communication     |
              +-------------------+
                        |
                        | Wi-Fi
                        v
              +-------------------+
              | Flutter App       |
              | Livestock Tracker |
              +-------------------+
                        |
          +-------------+-------------+
          |             |             |
          v             v             v
       Map View      Dashboard     Alerts
          |
          +-------------------------+
          |
          v
   Geofence / Offline Maps