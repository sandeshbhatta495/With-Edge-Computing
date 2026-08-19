#include <SPI.h>
#include <LoRa.h>
#include <Wire.h>
#include <TinyGPS++.h>
#include <SoftwareSerial.h>
#include <Adafruit_MPU6050.h>
#include <Adafruit_Sensor.h>
#include <math.h>

// ============================================================
// DEVICE CONFIGURATION
// ============================================================

const char DEVICE_ID[] = "A02";

// ============================================================
// HARDWARE PINS (GPS TX -> Nano D4, GPS RX -> Nano D3)
// ============================================================

SoftwareSerial gpsSerial(4, 3);
TinyGPSPlus gps;
Adafruit_MPU6050 mpu;

const int BATTERY_PIN = A0;
const float R1 = 10000.0;
const float R2 = 10000.0;
float batteryVoltage = 0.0;

// ============================================================
// LORA & TRANSMISSION CONTROL
// ============================================================

const long LORA_FREQUENCY = 433E6;
unsigned long lastSendTime = 0;
unsigned long currentInterval = 60000;  // Default: 1 minute (60000 ms)
bool movementBasedMode = false;
bool lastSentWhileMoving = false;

// ============================================================
// MPU6050 DATA & MOVEMENT DETECTION
// ============================================================

float ax = 0.0, ay = 0.0, az = 0.0;
float gx = 0.0, gy = 0.0, gz = 0.0;

float accelerationMagnitude = 0.0;
float filteredAcceleration = 9.81;
float previousAcceleration = 9.81;
float accelerationChange = 0.0;
float gyroMagnitude = 0.0;

bool animalMoving = false;
bool previousAnimalMoving = false;

const float ACCEL_MOVEMENT_THRESHOLD = 0.35;
const float GYRO_MOVEMENT_THRESHOLD  = 0.15;
const float FILTER_ALPHA = 0.20;

int movementCount = 0;
int stationaryCount = 0;
const int MOVEMENT_CONFIRM_COUNT = 5;
const int STATIONARY_CONFIRM_COUNT = 15;

// ============================================================
// RECEIVE LORA COMMAND
// ============================================================

void CheckLoRaCommand() {
  int packetSize = LoRa.parsePacket();
  if (!packetSize) return;

  String command = "";
  while (LoRa.available()) {
    command += (char)LoRa.read();
  }
  command.trim();

  Serial.println(F("\n================================"));
  Serial.println(F("LoRa Command Received"));
  Serial.print(F("Command: "));
  Serial.println(command);
  Serial.println(F("================================"));

  if (command.startsWith("SET_INTERVAL:")) {
    String value = command.substring(13);

    if (value == "MOVEMENT") {
      movementBasedMode = true;
      Serial.println(F("Mode set to: MOVEMENT-BASED"));

      LoRa.beginPacket();
      LoRa.print(F("ACK:SET_INTERVAL:MOVEMENT"));
      LoRa.endPacket();
    } else {
      unsigned long interval = value.toInt();

      // Validate interval range (1 sec to 1 hour)
      if (interval >= 1000 && interval <= 3600000) {
        currentInterval = interval;
        movementBasedMode = false;
        lastSendTime = millis();

        Serial.print(F("Transmission interval changed to: "));
        Serial.print(currentInterval);
        Serial.println(F(" ms"));

        LoRa.beginPacket();
        LoRa.print(F("ACK:SET_INTERVAL:"));
        LoRa.print(currentInterval);
        LoRa.endPacket();
      } else {
        Serial.println(F("Invalid interval range (1000 ms - 3600000 ms)"));
      }
    }
  }
}

// ============================================================
// SENSOR & POWER READINGS
// ============================================================

void ReadBattery() {
  int adcValue = analogRead(BATTERY_PIN);
  float voltageA0 = adcValue * (5.0 / 1023.0);
  float rawVoltage = voltageA0 *1; //((R1 + R2) / R2);
  batteryVoltage = round(rawVoltage * 100.0) / 100.0;
}

void ReadGPS() {
  while (gpsSerial.available()) {
    gps.encode(gpsSerial.read());
  }
}

void PrintGPSTimestampToLoRa() {
  if (!gps.date.isValid() || !gps.time.isValid()) {
    LoRa.print(F("000000000000"));
    return;
  }

  char timestamp[13];
  sprintf(
    timestamp,
    "%02d%02d%02d%02d%02d%02d",
    gps.date.year() % 100,
    gps.date.month(),
    gps.date.day(),
    gps.time.hour(),
    gps.time.minute(),
    gps.time.second()
  );
  LoRa.print(timestamp);
}

void ReadMPU() {
  sensors_event_t a, g, temp;
  mpu.getEvent(&a, &g, &temp);

  ax = a.acceleration.x;
  ay = a.acceleration.y;
  az = a.acceleration.z;

  gx = g.gyro.x;
  gy = g.gyro.y;
  gz = g.gyro.z;

  accelerationMagnitude = sqrt(ax * ax + ay * ay + az * az);
  filteredAcceleration = FILTER_ALPHA * accelerationMagnitude + (1.0 - FILTER_ALPHA) * filteredAcceleration;
  accelerationChange = fabs(filteredAcceleration - previousAcceleration);
  previousAcceleration = filteredAcceleration;

  gyroMagnitude = sqrt(gx * gx + gy * gy + gz * gz);

  bool accelerationMovement = accelerationChange > ACCEL_MOVEMENT_THRESHOLD;
  bool gyroMovement = gyroMagnitude > GYRO_MOVEMENT_THRESHOLD;
  bool movementDetected = accelerationMovement || gyroMovement;

  if (movementDetected) {
    movementCount++;
    stationaryCount = 0;
    if (movementCount >= MOVEMENT_CONFIRM_COUNT) {
      animalMoving = true;
      movementCount = MOVEMENT_CONFIRM_COUNT;
    }
  } else {
    stationaryCount++;
    movementCount = 0;
    if (stationaryCount >= STATIONARY_CONFIRM_COUNT) {
      animalMoving = false;
      stationaryCount = STATIONARY_CONFIRM_COUNT;
    }
  }
}

// ============================================================
// DEBUG OUTPUT
// ============================================================

void PrintDebug() {
  Serial.println(F("\n================================"));
  Serial.println(F("SENSOR STATUS"));
  Serial.println(F("================================"));

  Serial.print(F("Battery        : "));
  Serial.print(batteryVoltage, 2);
  Serial.println(F(" V"));

  Serial.println(F("\n------ GPS ------"));
  if (gps.location.isValid()) {
    Serial.print(F("Latitude      : ")); Serial.println(gps.location.lat(), 5);
    Serial.print(F("Longitude     : ")); Serial.println(gps.location.lng(), 5);
    Serial.print(F("Altitude      : ")); Serial.print(gps.altitude.meters(), 1); Serial.println(F(" m"));
    Serial.print(F("Satellites    : ")); Serial.println(gps.satellites.value());
    Serial.print(F("GPS Speed     : ")); Serial.print(gps.speed.kmph(), 2); Serial.println(F(" km/h"));
  } else {
    Serial.println(F("GPS: No valid fix"));
  }

  Serial.print(F("GPS Date      : "));
  if (gps.date.isValid()) {
    Serial.print(gps.date.year()); Serial.print('-');
    Serial.print(gps.date.month()); Serial.print('-');
    Serial.println(gps.date.day());
  } else {
    Serial.println(F("INVALID"));
  }

  Serial.print(F("GPS Time      : "));
  if (gps.time.isValid()) {
    Serial.print(gps.time.hour()); Serial.print(':');
    Serial.print(gps.time.minute()); Serial.print(':');
    Serial.println(gps.time.second());
  } else {
    Serial.println(F("INVALID"));
  }

  Serial.println(F("\n------ MPU6050 ------"));
  Serial.print(F("Acceleration  : ")); Serial.print(accelerationMagnitude, 2); Serial.println(F(" m/s2"));
  Serial.print(F("Accel Change  : ")); Serial.print(accelerationChange, 3); Serial.println(F(" m/s2"));
  Serial.print(F("Gyro Magnitude: ")); Serial.print(gyroMagnitude, 3); Serial.println(F(" rad/s"));
  Serial.print(F("Animal Status : ")); Serial.println(animalMoving ? F("MOVING") : F("STATIONARY"));
}

// ============================================================
// SEND LORA PACKET
// ============================================================

void SendLoRaPacket() {
  LoRa.beginPacket();

  LoRa.print(DEVICE_ID); LoRa.print(',');
  LoRa.print(batteryVoltage, 2); LoRa.print(',');

  if (gps.location.isValid()) LoRa.print(gps.location.lat(), 5);
  else LoRa.print(0);
  LoRa.print(',');

  if (gps.location.isValid()) LoRa.print(gps.location.lng(), 5);
  else LoRa.print(0);
  LoRa.print(',');

  if (gps.altitude.isValid()) LoRa.print(gps.altitude.meters(), 1);
  else LoRa.print(0);
  LoRa.print(',');

  if (gps.satellites.isValid()) LoRa.print(gps.satellites.value());
  else LoRa.print(0);
  LoRa.print(',');

  if (gps.speed.isValid()) LoRa.print(gps.speed.kmph(), 2);
  else LoRa.print(0);
  LoRa.print(',');

  LoRa.print(animalMoving ? 1 : 0); LoRa.print(',');

  PrintGPSTimestampToLoRa();

  LoRa.endPacket();

  Serial.println(F("\n================================"));
  Serial.println(F("LoRa Packet Sent"));
  Serial.println(F("================================"));
  Serial.print(F("Device ID: ")); Serial.println(DEVICE_ID);
  Serial.print(F("Battery: "));   Serial.print(batteryVoltage, 2); Serial.println(F(" V"));
  Serial.print(F("Movement: "));  Serial.println(animalMoving ? F("MOVING") : F("STATIONARY"));
  Serial.println(F("================================"));
}

// ============================================================
// SETUP & MAIN LOOP
// ============================================================

void setup() {
  Serial.begin(9600);
  gpsSerial.begin(9600);
  Wire.begin();

  Serial.println(F("\n================================"));
  Serial.println(F("GPS + MPU6050 + LoRa Sender"));
  Serial.println(F("================================"));
  Serial.print(F("Device ID: ")); Serial.println(DEVICE_ID);

  Serial.println(F("Initializing LoRa..."));
  if (!LoRa.begin(LORA_FREQUENCY)) {
    Serial.println(F("Starting LoRa failed!"));
    while (1) { delay(1000); }
  }

  LoRa.setSpreadingFactor(7);
  LoRa.setSignalBandwidth(125E3);
  LoRa.setCodingRate4(5);
  Serial.println(F("LoRa OK"));

  Serial.println(F("Initializing MPU6050..."));
  if (!mpu.begin()) {
    Serial.println(F("MPU6050 not found!"));
    while (1) { delay(1000); }
  }

  Serial.println(F("MPU6050 OK"));
  mpu.setAccelerometerRange(MPU6050_RANGE_8_G);
  mpu.setGyroRange(MPU6050_RANGE_500_DEG);
  mpu.setFilterBandwidth(MPU6050_BAND_21_HZ);

  Serial.println(F("GPS initialized"));
  Serial.println(F("Waiting for GPS...\n"));
  delay(1000);
}

void loop() {
  ReadGPS();
  ReadMPU();
  CheckLoRaCommand();

  if (movementBasedMode) {
    // Immediate transmission when movement starts
    if (animalMoving && !lastSentWhileMoving) {
      ReadBattery();
      PrintDebug();
      SendLoRaPacket();
      lastSentWhileMoving = true;
      Serial.println(F("Movement detected -> Packet sent immediately"));
    } else if (!animalMoving) {
      lastSentWhileMoving = false;
    }
  } else {
    // Regular interval transmission using currentInterval
    if (millis() - lastSendTime >= currentInterval) {
      lastSendTime = millis();
      ReadBattery();
      PrintDebug();
      SendLoRaPacket();
    }
  }
}
