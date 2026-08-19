#include <TinyGPS++.h>
#include <SoftwareSerial.h>
#include <LoRa.h>
#include <EEPROM.h>
#include <LowPower.h>
#include <Wire.h>
#include <MPU6050.h>

// ============================================================================
// CONFIGURATION
// ============================================================================
#define GPS_RX 10
#define GPS_TX 11
#define LORA_CS 8
#define LORA_RST 4
#define LORA_DIO0 2
#define BATTERY_PIN A0
#define MOTION_THRESHOLD 2.0  // m/s speed threshold for movement

// ============================================================================
// GLOBAL STATE
// ============================================================================
TinyGPSPlus gps;
SoftwareSerial ss(GPS_RX, GPS_TX);
MPU6050 mpu;

unsigned long lastWakeTime = 0;
unsigned long lastLiveTransmit = 0;
unsigned long lastBoundaryCheck = 0;
unsigned long lastBoundaryTransmit = 0;

// Deep Sleep & Live Mode
bool liveMode = false;
unsigned long liveInterval = 5000;  // Default 5 sec (ms)
bool boundaryViolation = false;
bool boundaryChanged = false;

// Geofence Polygon (max 10 vertices)
const int MAX_VERTICES = 10;
struct {
  double lat[MAX_VERTICES];
  double lon[MAX_VERTICES];
  int count;
} geofence;

// Battery
float batteryVoltage = 0;
int batteryPercent = 100;

// Last known state
double lastLat = 0, lastLon = 0;
bool lastBoundaryStatus = false;

// ============================================================================
// EEPROM MANAGEMENT
// ============================================================================
#define GEOFENCE_ADDR 0
#define GEOFENCE_SIZE 200

void saveGeofenceToEEPROM() {
  int addr = GEOFENCE_ADDR;
  EEPROM.write(addr++, geofence.count);
  for (int i = 0; i < geofence.count; i++) {
    // Store as bytes (simplified serialization)
    byte* latPtr = (byte*)&geofence.lat[i];
    byte* lonPtr = (byte*)&geofence.lon[i];
    for (int j = 0; j < 8; j++) {
      EEPROM.write(addr++, latPtr[j]);
    }
    for (int j = 0; j < 8; j++) {
      EEPROM.write(addr++, lonPtr[j]);
    }
  }
}

void loadGeofenceFromEEPROM() {
  int addr = GEOFENCE_ADDR;
  geofence.count = EEPROM.read(addr++);
  if (geofence.count > MAX_VERTICES) geofence.count = 0;
  
  for (int i = 0; i < geofence.count; i++) {
    byte* latPtr = (byte*)&geofence.lat[i];
    byte* lonPtr = (byte*)&geofence.lon[i];
    for (int j = 0; j < 8; j++) {
      latPtr[j] = EEPROM.read(addr++);
    }
    for (int j = 0; j < 8; j++) {
      lonPtr[j] = EEPROM.read(addr++);
    }
  }
}

// ============================================================================
// GEOFENCE OPERATIONS
// ============================================================================

// Point-in-polygon using ray casting algorithm
bool isInsidePolygon(double lat, double lon) {
  if (geofence.count < 3) return false;
  
  int crossings = 0;
  for (int i = 0; i < geofence.count; i++) {
    int j = (i + 1) % geofence.count;
    
    if ((geofence.lat[i] <= lat && lat < geofence.lat[j]) ||
        (geofence.lat[j] <= lat && lat < geofence.lat[i])) {
      double xinters = (geofence.lon[j] - geofence.lon[i]) * 
                       (lat - geofence.lat[i]) / 
                       (geofence.lat[j] - geofence.lat[i]) + 
                       geofence.lon[i];
      if (lon < xinters) crossings++;
    }
  }
  return (crossings % 2 == 1);
}

// Calculate distance from point to polygon edge (simplified)
double distanceToBoundary(double lat, double lon) {
  if (geofence.count < 2) return 1000.0;
  
  double minDist = 1000.0;
  for (int i = 0; i < geofence.count; i++) {
    int j = (i + 1) % geofence.count;
    
    // Haversine distance to each vertex
    double dlat = (geofence.lat[i] - lat) * 111000;  // meters
    double dlon = (geofence.lon[i] - lon) * 111000 * cos(lat * 0.01745);
    double dist = sqrt(dlat * dlat + dlon * dlon);
    minDist = min(minDist, dist);
  }
  return minDist;
}

// ============================================================================
// BATTERY
// ============================================================================
void updateBattery() {
  int raw = analogRead(BATTERY_PIN);
  batteryVoltage = (raw / 1023.0) * 5.0;  // Adjust based on voltage divider
  batteryPercent = map(raw, 512, 1023, 0, 100);  // Adjust min/max
  batteryPercent = constrain(batteryPercent, 0, 100);
}

// ============================================================================
// LORA TRANSMISSION
// ============================================================================
void sendPacket(bool includeFullData) {
  String packet = "A01,";
  packet += batteryPercent;
  packet += ",";
  packet += gps.location.lat();
  packet += ",";
  packet += gps.location.lng();
  packet += ",";
  packet += gps.altitude.meters();
  packet += ",";
  packet += gps.satellites.value();
  packet += ",";
  packet += gps.speed.mps();
  packet += ",";
  packet += (gps.speed.mps() > MOTION_THRESHOLD ? 1 : 0);
  packet += ",";
  packet += millis() / 1000;  // Timestamp (seconds)
  packet += ",";
  packet += (boundaryViolation ? "OUTSIDE" : "INSIDE");
  
  if (includeFullData) {
    packet += ",LIVE";
  }
  
  LoRa.beginPacket();
  LoRa.print(packet);
  LoRa.endPacket();
  
  Serial.println("TX: " + packet);
}

// ============================================================================
// COMMAND HANDLER
// ============================================================================
void handleLoRaCommand(String cmd) {
  Serial.println("CMD: " + cmd);
  
  if (cmd.startsWith("SET_BOUNDARY:")) {
    // Parse: SET_BOUNDARY:lat1,lon1;lat2,lon2;...
    String coords = cmd.substring(13);
    geofence.count = 0;
    
    int startIdx = 0;
    for (int i = 0; i < MAX_VERTICES; i++) {
      int commaIdx = coords.indexOf(',', startIdx);
      int semiIdx = coords.indexOf(';', startIdx);
      if (commaIdx < 0 || semiIdx < 0) break;
      
      geofence.lat[i] = coords.substring(startIdx, commaIdx).toDouble();
      geofence.lon[i] = coords.substring(commaIdx + 1, semiIdx).toDouble();
      geofence.count++;
      
      startIdx = semiIdx + 1;
    }
    
    saveGeofenceToEEPROM();
    boundaryChanged = true;
    
    // Acknowledge
    LoRa.beginPacket();
    LoRa.print("ACK:BOUNDARY_SET");
    LoRa.endPacket();
  }
  
  else if (cmd.startsWith("START_LIVE:")) {
    // Parse: START_LIVE:5000 (interval in ms)
    String interval = cmd.substring(11);
    liveInterval = interval.toInt();
    if (liveInterval < 1000) liveInterval = 5000;
    liveMode = true;
    lastLiveTransmit = millis();
    
    LoRa.beginPacket();
    LoRa.print("ACK:LIVE_START");
    LoRa.endPacket();
  }
  
  else if (cmd.equals("STOP_LIVE")) {
    liveMode = false;
    
    LoRa.beginPacket();
    LoRa.print("ACK:LIVE_STOP");
    LoRa.endPacket();
  }
}

void checkLoRaCommand() {
  int packetSize = LoRa.parsePacket();
  if (packetSize) {
    String cmd = "";
    while (LoRa.available()) {
      cmd += (char)LoRa.read();
    }
    handleLoRaCommand(cmd);
  }
}

// ============================================================================
// GPS UPDATE
// ============================================================================
void updateGPS() {
  while (ss.available() > 0) {
    if (gps.encode(ss.read())) {
      if (gps.location.isUpdated()) {
        lastLat = gps.location.lat();
        lastLon = gps.location.lng();
      }
    }
  }
}

// ============================================================================
// BOUNDARY MONITORING
// ============================================================================
void checkBoundary() {
  bool currentStatus = isInsidePolygon(lastLat, lastLon);
  double distToBoundary = distanceToBoundary(lastLat, lastLon);
  
  // Wake immediately if approaching boundary (< 100m)
  if (distToBoundary < 100.0) {
    liveMode = true;  // Activate live mode temporarily
    liveInterval = 5000;
  }
  
  // Detect boundary crossing
  if (currentStatus != lastBoundaryStatus) {
    boundaryViolation = currentStatus;
    lastBoundaryStatus = currentStatus;
    boundaryChanged = true;
  }
}

// ============================================================================
// SLEEP LOGIC
// ============================================================================
void enterDeepSleep() {
  // Only sleep if NOT in live mode
  if (liveMode) return;
  
  Serial.println("SLEEP: 60 sec");
  
  // Configure wakeup on timer (60 sec = 8 x 8sec cycles)
  for (int i = 0; i < 8; i++) {
    LowPower.powerDown(SLEEP_8S, ADC_OFF, BOD_OFF);
    
    // Check geofence every 8 sec during sleep
    updateGPS();
    checkBoundary();
    
    // If boundary risk detected, wake up
    if (boundaryChanged) {
      Serial.println("WAKE: Boundary change detected");
      break;
    }
  }
}

// ============================================================================
// MAIN SETUP
// ============================================================================
void setup() {
  Serial.begin(9600);
  ss.begin(9600);
  
  // LoRa setup
  LoRa.setPins(LORA_CS, LORA_RST, LORA_DIO0);
  if (!LoRa.begin(915E6)) {
    Serial.println("LoRa init failed");
    while (1);
  }
  
  // MPU6050 setup (for motion detection)
  Wire.begin();
  mpu.initialize();
  if (!mpu.testConnection()) {
    Serial.println("MPU6050 failed");
  }
  
  // Load geofence from EEPROM
  loadGeofenceFromEEPROM();
  Serial.print("Loaded geofence vertices: ");
  Serial.println(geofence.count);
  
  lastWakeTime = millis();
}

// ============================================================================
// MAIN LOOP
// ============================================================================
void loop() {
  unsigned long now = millis();
  
  // Check for LoRa commands
  checkLoRaCommand();
  
  // Update GPS & Battery
  updateGPS();
  updateBattery();
  
  // Check boundary status
  checkBoundary();
  
  // ========================================================================
  // LIVE MODE: Send at user-selected interval
  // ========================================================================
  if (liveMode && (now - lastLiveTransmit >= liveInterval)) {
    sendPacket(true);  // Full data with LIVE flag
    lastLiveTransmit = now;
    lastBoundaryTransmit = now;
    boundaryChanged = false;
  }
  
  // ========================================================================
  // SLEEP MODE: Send only on boundary change OR every 60 sec
  // ========================================================================
  else if (!liveMode) {
    // If boundary violation, send immediately
    if (boundaryChanged) {
      sendPacket(false);  // Boundary status only
      lastBoundaryTransmit = now;
      boundaryChanged = false;
    }
    
    // Or send every 60 seconds if no change
    else if (now - lastBoundaryTransmit >= 60000) {
      sendPacket(false);  // Regular status update
      lastBoundaryTransmit = now;
    }
    
    // Enter deep sleep
    enterDeepSleep();
  }
}