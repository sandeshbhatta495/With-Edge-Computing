/*
  ============================================================
  COLLAR FIRMWARE  (Arduino Nano)  -  UPGRADED VERSION
  LoRa-Integrated GPS Geo-Fencing System for Smart Livestock
  Monitoring in Himalayan Pastures
  ============================================================

  RULES KEPT FROM OLD VERSION
  - Pins are NOT changed (GPS_RX 4, GPS_TX 3, LoRa library default pins).
  - Packet formats are NOT changed (MH, ALERT, DATA, ACK, POLL, LIVE, FENCE).
  - Conditional relay, duplicate check, alert ACK/retry, LIVE, POLL, FENCE
    and the EEPROM packet number are all still here.

  WHAT IS NEW (short list)
  - Fence is saved in EEPROM (kept after reboot or power loss)
  - A bad FENCE packet can no longer damage the working fence
  - GPS quality check + debounce (3 readings) + optional buffer distance
  - EXIT/RETURN alert keeps retrying slowly until the base answers
  - Poll timeout, safe GPS time, EEPROM wear fix
  - No more String (uses char arrays, saves Nano RAM)
  - Better battery reading (average of samples) + low battery flag
  - No more while(1) hang. Restarts if LoRa fails.
  - MPU6050 movement is turned on
  - Optional: watchdog, LoRa CRC, LoRa sync word (default OFF)

  TO MAKE COLLAR A02: change ANIMAL_NUMBER to 2. Nothing else.
*/

#include <SPI.h>
#include <Wire.h>
#include <LoRa.h>
#include <TinyGPS++.h>
#include <SoftwareSerial.h>
#include <Adafruit_MPU6050.h>
#include <EEPROM.h>
#include <math.h>

// ============================================================
// 1. CONFIGURATION  (change values here only)
// ============================================================

// ---- Which animal is this collar? (1 = A01, 2 = A02) ----
#define ANIMAL_NUMBER 1

#define STR_(x) #x
#define STR(x) STR_(x)
#define ANIMAL_ID "A0" STR(ANIMAL_NUMBER)     // becomes "A01" or "A02"
static_assert(ANIMAL_NUMBER >= 1 && ANIMAL_NUMBER <= 2,
              "Only A01 and A02 have time slots");

// ---- Debug (1 = print on Serial 9600, 0 = off) ----
#define DEBUG 1

// ---- Optional features (default OFF = same as old behaviour) ----
#define USE_WATCHDOG        0   // 1 = reset if code freezes (see note below)
#define USE_CRC             0   // 1 = LoRa CRC  (base station must match)
#define USE_SYNCWORD        0   // 1 = private sync word (base must match)
#define SYNC_WORD           0x34
#define SUPPORT_DIRECT_PACKETS 1 // 1 = also accept old non-MH packets
#define USE_REAL_VCC        0   // 1 = measure real Vcc (needs calibration)
#define USE_DEFAULT_TEST_FENCE 1 // 1 = use test fence if EEPROM has none
                                 // 0 = no fence until a FENCE command comes
/*
  WATCHDOG NOTE: Old Nano bootloaders can get stuck in a reset loop with
  the watchdog. Test with a spare board first. At SF12 one long packet can
  take about 7 seconds to send, and the watchdog is 8 seconds. Keep
  packets short.
*/

// ---- Pins (NOT changed) ----
#define GPS_RX 4
#define GPS_TX 3

// ---- LoRa ----
#define LORA_FREQUENCY      433E6
#define LORA_INIT_TRIES     3

// ---- Packet sizes (RAM control) ----
#define PACKET_MAX          160   // biggest packet we accept
#define PAYLOAD_MAX         100   // biggest payload we can relay

// ---- Multihop ----
#define MAX_HOPS            1

// ---- Fence ----
#define MAX_FENCE_POINTS    4
#define GEOFENCE_CONFIRM    3       // readings in a row before an alert
#define GEOFENCE_CHECK_MS   900UL   // check fence about once per second
#define FENCE_BUFFER_M      0.0     // metres. 0 = off. Example 5.0

// ---- GPS quality ----
#define MIN_SATS            4
#define MAX_HDOP            3.0
#define GPS_MAX_AGE_MS      2000UL    // fix older than this is not used
#define GPS_TIME_MAX_AGE_MS 2000UL    // GPS time older than this is not used
#define TELEMETRY_MAX_AGE_MS 10000UL  // DATA shows 0,0 if fix older than this

// ---- Time slots (30 second frame, from GPS time) ----
// A01: data 0-6,  relay 7-14
// A02: data 15-21, relay 22-29
#define GPS_SLOT_FRAME      30UL
#define MY_DATA_START       ((unsigned long)(ANIMAL_NUMBER - 1) * 15UL)
#define MY_RELAY_START      (MY_DATA_START + 7UL)

// ---- Poll ----
#define POLL_SLOT_TIMEOUT   35000UL   // drop a poll that waited too long

// ---- Relay ----
#define RELAY_WAIT_TIME       3500UL
#define POLL_RELAY_WAIT_TIME  8000UL
#define RELAY_MAX_AGE         60000UL  // forget a relay that never got a slot

// ---- Alert ----
#define ALERT_BACKOFF_BASE      500UL
#define ALERT_BACKOFF_STEP      3000UL
#define ALERT_BACKOFF_RANDOM    500UL
#define ALERT_ACK_TIMEOUT       4000UL
#define MAX_ALERT_RETRIES       4
#define ALERT_SLOW_RETRY_INTERVAL 60000UL  // after quick retries fail

// ---- Duplicate memory ----
#define RECENT_PACKET_COUNT 10

// ---- EEPROM ----
#define EEPROM_PACKET_SEQ_ADDR  0     // 4 bytes
#define EEPROM_FENCE_ADDR       16    // about 35 bytes
#define FENCE_MAGIC             0xF1  // change if MAX_FENCE_POINTS changes
#define SEQ_SAVE_STEP           10    // write EEPROM once per 10 packets

// ---- Battery ----
#define BATTERY_INTERVAL    30000UL
#define BATTERY_SAMPLES     10
#define VCC_NOMINAL         5.0       // used when USE_REAL_VCC is 0
#define BATTERY_CAL         1.0       // tune with a multimeter
#if ANIMAL_NUMBER == 1
  #define BATTERY_DIVIDER   2.0       // A01 uses a voltage divider
#else
  #define BATTERY_DIVIDER   1.0       // other nodes read battery directly
#endif
#define LOW_BATTERY_VOLTAGE 3.50
#define LOW_BATTERY_HYST    0.10

// ---- Movement (MPU6050) ----
#define ACCEL_THRESHOLD     0.35
#define GYRO_THRESHOLD      0.15
#define MOVEMENT_CONFIRM    5
#define STATIONARY_CONFIRM  15
#define FILTER_ALPHA        0.20
#define MPU_INTERVAL        50UL

// ============================================================
// 2. DEBUG MACROS
// ============================================================
#if DEBUG
  #define DBG(x)    Serial.print(x)
  #define DBGLN(x)  Serial.println(x)
#else
  #define DBG(x)
  #define DBGLN(x)
#endif

#if USE_WATCHDOG
  #define FEED_WDT() wdt_reset()
#else
  #define FEED_WDT()
#endif

// ============================================================
// 3. TYPES AND GLOBAL VARIABLES
// ============================================================

// ---- Hardware objects ----
SoftwareSerial gpsSerial(GPS_RX, GPS_TX);
TinyGPSPlus gps;
Adafruit_MPU6050 mpu;
bool mpuOk = false;

// ---- Fence ----
struct FencePoint
{
  float lat;
  float lon;
};

struct FenceStore               // what is saved in EEPROM
{
  byte magic;
  byte count;
  FencePoint pts[MAX_FENCE_POINTS];
  byte checksum;
};

FencePoint fence[MAX_FENCE_POINTS];
byte fenceCount = 0;
bool fenceStateKnown = false;
bool animalInside = false;
byte confirmCount = 0;
unsigned long lastGeofenceCheck = 0;

// ---- Multihop packet (parsed header) ----
struct MHPacket
{
  unsigned long id;
  char source[8];
  char dest[8];
  byte hop;
  byte maxHop;
  char *payload;          // points inside the receive buffer
};

// ---- Receive buffer ----
char rxBuf[PACKET_MAX];

// ---- Packet numbers ----
unsigned long packetSequence = 0;
unsigned long sequenceCeiling = 0;

// ---- Duplicate memory ----
struct RecentPacket
{
  byte src;               // 0 = empty slot
  unsigned long id;
};
RecentPacket recentPackets[RECENT_PACKET_COUNT];
byte recentPacketIndex = 0;

// ---- Battery ----
float batteryVoltage = 0.0;
bool lowBattery = false;
unsigned long lastBatteryRead = 0;

// ---- Live mode / poll ----
bool liveMode = false;
bool pollWaitingForSlot = false;
unsigned long pollReceivedTime = 0;
unsigned long currentCommandPacketID = 0;

// ---- Slot memory ----
unsigned long lastDataFrame = 0xFFFFFFFFUL;
unsigned long lastRelayFrame = 0xFFFFFFFFUL;

// ---- Alert ----
bool alertPending = false;
bool alertWaitingAck = false;
bool alertWaitingBackoff = false;
unsigned long alertSendTime = 0;
unsigned long alertRetryTime = 0;
byte alertRetryCount = 0;
unsigned long activeAlertPacketID = 0;
bool activeAlertExit = false;
bool activeAlertValid = false;

// ---- Relay (one pending packet) ----
bool relayPending = false;
unsigned long relayStartTime = 0;
unsigned long relayId = 0;
char relaySource[8];
char relayDest[8];
byte relayHop = 0;
byte relayMaxHop = 0;
char relayPayload[PAYLOAD_MAX];

// ---- Movement ----
unsigned long lastMPURead = 0;
float filteredAcceleration = 9.81;
bool animalMoving = false;
byte movementCount = 0;
byte stationaryCount = 0;

// ============================================================
// 4. SMALL HELPERS
// ============================================================

#if USE_WATCHDOG
// Turn the watchdog off right after a reset (needed for old bootloaders)
void wdtEarlyDisable(void) __attribute__((naked)) __attribute__((section(".init3")));
void wdtEarlyDisable(void)
{
  MCUSR = 0;
  wdt_disable();
}
#endif

void rebootNow()
{
#if USE_WATCHDOG
  wdt_enable(WDTO_15MS);
  while (1);
#else
  asm volatile ("jmp 0");
#endif
}

// Copy text up to the next comma into "out".
// Returns pointer just after the comma, or NULL if it fails.
char *getField(char *p, char *out, byte outSize)
{
  char *c = strchr(p, ',');
  if (c == NULL) return NULL;
  size_t len = c - p;
  if (len >= outSize) return NULL;
  memcpy(out, p, len);
  out[len] = '\0';
  return c + 1;
}

// Cut a text into comma fields IN PLACE (commas become zeros).
// Returns how many fields were found (max maxF).
byte splitFields(char *s, char *f[], byte maxF)
{
  byte n = 0;
  f[n++] = s;
  while (*s && n < maxF)
  {
    if (*s == ',')
    {
      *s = '\0';
      f[n++] = s + 1;
    }
    s++;
  }
  return n;
}

// Read a coordinate number. Returns false if it is not a number.
bool parseCoord(const char *s, float &value)
{
  char *end;
  float v = strtod(s, &end);
  if (end == s) return false;
  value = v;
  return true;
}

// Packet: MH,packetID,source,destination,hop,maxHop,payload
bool parseMH(char *pkt, MHPacket &mh)
{
  if (pkt[0] != 'M' || pkt[1] != 'H' || pkt[2] != ',') return false;

  char *p = pkt + 3;

  mh.id = strtoul(p, NULL, 10);
  p = strchr(p, ',');
  if (p == NULL) return false;
  p++;

  p = getField(p, mh.source, sizeof(mh.source));
  if (p == NULL) return false;

  p = getField(p, mh.dest, sizeof(mh.dest));
  if (p == NULL) return false;

  mh.hop = (byte)atoi(p);
  p = strchr(p, ',');
  if (p == NULL) return false;
  p++;

  mh.maxHop = (byte)atoi(p);
  p = strchr(p, ',');
  if (p == NULL) return false;
  p++;

  mh.payload = p;
  return true;
}

// Short number for each sender (used by duplicate memory)
byte sourceCode(const char *s)
{
  if (strcmp_P(s, PSTR("BASE")) == 0) return 100;
  if (s[0] == 'A')
  {
    int n = atoi(s + 1);
    if (n > 0 && n < 100) return (byte)n;
  }
  return 255;
}

bool isDuplicatePacket(byte src, unsigned long id)
{
  for (byte i = 0; i < RECENT_PACKET_COUNT; i++)
  {
    if (recentPackets[i].src == src && recentPackets[i].id == id)
    {
      return true;
    }
  }
  return false;
}

void rememberPacket(byte src, unsigned long id)
{
  recentPackets[recentPacketIndex].src = src;
  recentPackets[recentPacketIndex].id = id;
  recentPacketIndex++;
  if (recentPacketIndex >= RECENT_PACKET_COUNT) recentPacketIndex = 0;
}

// ============================================================
// 5. EEPROM  (packet number and fence)
// ============================================================

void loadPacketSequence()
{
  unsigned long stored;
  EEPROM.get(EEPROM_PACKET_SEQ_ADDR, stored);
  if (stored == 0xFFFFFFFFUL) stored = 0;

  // The saved value is a "ceiling". Numbers up to the ceiling may have
  // been used before the last reboot, so we continue from the ceiling.
  packetSequence = stored;
  sequenceCeiling = stored;
}

// Gives the next packet number. Writes EEPROM only once per 10 packets.
unsigned long nextPacketID()
{
  packetSequence++;
  if (packetSequence > sequenceCeiling)
  {
    sequenceCeiling = packetSequence + SEQ_SAVE_STEP - 1;
    EEPROM.put(EEPROM_PACKET_SEQ_ADDR, sequenceCeiling);
  }
  return packetSequence;
}

byte fenceChecksum(const FenceStore &s)
{
  const byte *p = (const byte *)&s;
  byte sum = 0x5A;
  for (size_t i = 0; i < sizeof(FenceStore) - 1; i++)
  {
    sum = ((sum << 1) | (sum >> 7)) ^ p[i];
  }
  return sum;
}

void saveFence()
{
  FenceStore s;
  memset(&s, 0, sizeof(s));
  s.magic = FENCE_MAGIC;
  s.count = fenceCount;
  memcpy(s.pts, fence, sizeof(fence));
  s.checksum = fenceChecksum(s);
  EEPROM.put(EEPROM_FENCE_ADDR, s);
}

void loadDefaultFence()
{
  // Test fence from the old code
  fenceCount = 4;
  fence[0].lat = 27.68600; fence[0].lon = 85.29500;
  fence[1].lat = 27.68800; fence[1].lon = 85.29500;
  fence[2].lat = 27.68800; fence[2].lon = 85.29800;
  fence[3].lat = 27.68600; fence[3].lon = 85.29800;
}

void loadFence()
{
  FenceStore s;
  EEPROM.get(EEPROM_FENCE_ADDR, s);

  if (s.magic == FENCE_MAGIC &&
      s.count >= 3 && s.count <= MAX_FENCE_POINTS &&
      s.checksum == fenceChecksum(s))
  {
    fenceCount = s.count;
    memcpy(fence, s.pts, sizeof(fence));
    DBGLN(F("Fence loaded from EEPROM"));
    return;
  }

#if USE_DEFAULT_TEST_FENCE
  loadDefaultFence();
  DBGLN(F("Default test fence loaded"));
#else
  fenceCount = 0;
  DBGLN(F("No fence stored. Waiting for FENCE command."));
#endif
}

// ============================================================
// 6. BATTERY
// ============================================================

#if USE_REAL_VCC
// Measure the real supply voltage (mV) using the internal 1.1 V reference
long readVccMv()
{
  ADMUX = _BV(REFS0) | _BV(MUX3) | _BV(MUX2) | _BV(MUX1);
  delay(2);
  for (byte i = 0; i < 2; i++)          // first reading is thrown away
  {
    ADCSRA |= _BV(ADSC);
    while (bit_is_set(ADCSRA, ADSC));
  }
  uint8_t low = ADCL;
  uint8_t high = ADCH;
  long result = ((long)high << 8) | low;
  if (result == 0) return (long)(VCC_NOMINAL * 1000);
  return 1125300L / result;             // 1.1 * 1023 * 1000
}
#endif

void readBattery()
{
  float vcc = VCC_NOMINAL;
#if USE_REAL_VCC
  vcc = readVccMv() / 1000.0;
#endif

  analogRead(A0);                       // throw away first reading
  unsigned long sum = 0;
  for (byte i = 0; i < BATTERY_SAMPLES; i++)
  {
    sum += analogRead(A0);
    delay(2);
  }
  float adc = (float)sum / BATTERY_SAMPLES;

  batteryVoltage = adc * (vcc / 1023.0) * BATTERY_DIVIDER * BATTERY_CAL;

  // Low battery flag with a small gap so it does not flicker
  if (batteryVoltage < LOW_BATTERY_VOLTAGE)
  {
    lowBattery = true;
  }
  else if (batteryVoltage > LOW_BATTERY_VOLTAGE + LOW_BATTERY_HYST)
  {
    lowBattery = false;
  }

  DBG(F("Battery V: "));
  DBG(batteryVoltage);
  DBGLN(lowBattery ? F("  LOW") : F("  OK"));
}

void updateBattery()
{
  if (millis() - lastBatteryRead < BATTERY_INTERVAL) return;
  lastBatteryRead = millis();
  readBattery();
}

// ============================================================
// 7. MOVEMENT (MPU6050)
// ============================================================

void readMPU()
{
  sensors_event_t a;
  sensors_event_t g;
  sensors_event_t temp;

  mpu.getEvent(&a, &g, &temp);

  float previousAcceleration = filteredAcceleration;

  float acceleration = sqrt(
    a.acceleration.x * a.acceleration.x +
    a.acceleration.y * a.acceleration.y +
    a.acceleration.z * a.acceleration.z);

  filteredAcceleration =
    FILTER_ALPHA * acceleration +
    (1.0 - FILTER_ALPHA) * filteredAcceleration;

  float accelerationChange = fabs(filteredAcceleration - previousAcceleration);

  float gyroMagnitude = sqrt(
    g.gyro.x * g.gyro.x +
    g.gyro.y * g.gyro.y +
    g.gyro.z * g.gyro.z);

  bool movementDetected =
    accelerationChange > ACCEL_THRESHOLD ||
    gyroMagnitude > GYRO_THRESHOLD;

  if (movementDetected)
  {
    if (movementCount < MOVEMENT_CONFIRM) movementCount++;
    stationaryCount = 0;
    if (movementCount >= MOVEMENT_CONFIRM) animalMoving = true;
  }
  else
  {
    if (stationaryCount < STATIONARY_CONFIRM) stationaryCount++;
    movementCount = 0;
    if (stationaryCount >= STATIONARY_CONFIRM) animalMoving = false;
  }
}

void updateMPU()
{
  if (!mpuOk) return;
  if (millis() - lastMPURead < MPU_INTERVAL) return;
  lastMPURead = millis();
  readMPU();
}

// ============================================================
// 8. GPS, TIME SLOTS, GEOFENCE
// ============================================================

// True only when the GPS position is good enough to trust
bool gpsGood()
{
  if (!gps.location.isValid()) return false;
  if (gps.location.age() > GPS_MAX_AGE_MS) return false;
  if (gps.satellites.isValid() && gps.satellites.value() < MIN_SATS) return false;
  if (gps.hdop.isValid() && gps.hdop.hdop() > MAX_HDOP) return false;
  return true;
}

// True when we have a position that is not too old
bool hasFreshFix(unsigned long maxAgeMs)
{
  return gps.location.isValid() && gps.location.age() <= maxAgeMs;
}

// GPS time of day in seconds. Returns false if time is not usable.
bool getGPSTimeSeconds(unsigned long &secs)
{
  if (!gps.time.isValid()) return false;
  if (gps.time.age() > GPS_TIME_MAX_AGE_MS) return false;

  secs = (unsigned long)gps.time.hour() * 3600UL +
         (unsigned long)gps.time.minute() * 60UL +
         (unsigned long)gps.time.second();
  return true;
}

// True once per frame, in the first 2 seconds of the given slot
bool slotStart(unsigned long startSlot, unsigned long &lastFrame)
{
  unsigned long secs;
  if (!getGPSTimeSeconds(secs)) return false;

  unsigned long frame = secs / GPS_SLOT_FRAME;
  unsigned long slot = secs % GPS_SLOT_FRAME;

  if (slot >= startSlot && slot <= startSlot + 1 && frame != lastFrame)
  {
    lastFrame = frame;
    return true;
  }
  return false;
}

bool isMyDataSlotStart()  { return slotStart(MY_DATA_START, lastDataFrame); }
bool isMyRelaySlotStart() { return slotStart(MY_RELAY_START, lastRelayFrame); }

// Point in polygon. Uses differences from the animal position
// (better accuracy with 32-bit float).
bool insideFence(float lat, float lon)
{
  if (fenceCount < 3) return false;

  bool inside = false;
  byte j = fenceCount - 1;

  for (byte i = 0; i < fenceCount; i++)
  {
    float xi = fence[i].lat - lat;
    float yi = fence[i].lon - lon;
    float xj = fence[j].lat - lat;
    float yj = fence[j].lon - lon;

    if (((yi > 0) != (yj > 0)) &&
        (0 < (xj - xi) * (0 - yi) / (yj - yi) + xi))
    {
      inside = !inside;
    }
    j = i;
  }
  return inside;
}

// Shortest distance from the animal to the fence line, in metres
float distanceToFenceM(float lat, float lon)
{
  const float mPerDegLat = 111320.0;
  float mPerDegLon = 111320.0 * cos(lat * 0.0174533);
  float best = 1.0e9;

  byte j = fenceCount - 1;
  for (byte i = 0; i < fenceCount; i++)
  {
    float ax = (fence[j].lon - lon) * mPerDegLon;
    float ay = (fence[j].lat - lat) * mPerDegLat;
    float bx = (fence[i].lon - lon) * mPerDegLon;
    float by = (fence[i].lat - lat) * mPerDegLat;

    float dx = bx - ax;
    float dy = by - ay;
    float len2 = dx * dx + dy * dy;

    float t = 0;
    if (len2 > 0) t = -(ax * dx + ay * dy) / len2;
    if (t < 0) t = 0;
    if (t > 1) t = 1;

    float px = ax + t * dx;
    float py = ay + t * dy;
    float d = sqrt(px * px + py * py);

    if (d < best) best = d;
    j = i;
  }
  return best;
}

// ============================================================
// 9. SENDING PACKETS
// ============================================================

// Start a multihop packet. Format:
// MH,packetID,source,destination,hop,maxHop,
void beginMultiHop(const char *destination, unsigned long packetID)
{
  LoRa.beginPacket();

  LoRa.print(F("MH,"));
  LoRa.print(packetID);
  LoRa.print(',');
  LoRa.print(ANIMAL_ID);
  LoRa.print(',');
  LoRa.print(destination);
  LoRa.print(F(",0,"));
  LoRa.print(MAX_HOPS);
  LoRa.print(',');
}

void print2(Print &out, int v)
{
  if (v < 10) out.print('0');
  out.print(v);
}

// Prints: YYYY-MM-DD,HH:MM:SS  (same as old code)
void printUTCDateTime(Print &out)
{
  if (!gps.date.isValid() || !gps.time.isValid())
  {
    out.print(F("0000-00-00,00:00:00"));
    return;
  }

  out.print(gps.date.year());
  out.print('-');
  print2(out, gps.date.month());
  out.print('-');
  print2(out, gps.date.day());
  out.print(',');
  print2(out, gps.time.hour());
  out.print(':');
  print2(out, gps.time.minute());
  out.print(':');
  print2(out, gps.time.second());
}

// ACK for a command. Examples:
// ...,ACK,A01,LIVE,ON,<commandID>
// ...,ACK,A01,FENCE,OK,<commandID>
void sendCommandAck(const char *command, const char *value)
{
  beginMultiHop("BASE", nextPacketID());

  LoRa.print(F("ACK,"));
  LoRa.print(ANIMAL_ID);
  LoRa.print(',');
  LoRa.print(command);

  if (value[0] != '\0')
  {
    LoRa.print(',');
    LoRa.print(value);
  }

  LoRa.print(',');
  LoRa.print(currentCommandPacketID);

  FEED_WDT();
  LoRa.endPacket();
  LoRa.receive();

  DBG(F("ACK sent: "));
  DBGLN(command);
}

// DATA,A01,battery,lat,lon,alt,sats,speed,moving
void sendTelemetry()
{
  beginMultiHop("BASE", nextPacketID());

  LoRa.print(F("DATA,"));
  LoRa.print(ANIMAL_ID);
  LoRa.print(',');
  LoRa.print(batteryVoltage, 2);
  LoRa.print(',');

  if (hasFreshFix(TELEMETRY_MAX_AGE_MS))
  {
    LoRa.print(gps.location.lat(), 5);
    LoRa.print(',');
    LoRa.print(gps.location.lng(), 5);
    LoRa.print(',');
    LoRa.print(gps.altitude.meters(), 1);
    LoRa.print(',');
    LoRa.print(gps.satellites.value());
    LoRa.print(',');
    LoRa.print(gps.speed.kmph(), 2);
    LoRa.print(',');
  }
  else
  {
    LoRa.print(F("0,0,0,0,0,"));
  }

  LoRa.print(animalMoving ? '1' : '0');

  FEED_WDT();
  LoRa.endPacket();
  LoRa.receive();

  DBGLN(F("Telemetry sent"));
}

// ============================================================
// 10. ALERT (EXIT / RETURN)
// ============================================================

void queueAlert(bool exitAlert)
{
  activeAlertPacketID = nextPacketID();
  activeAlertExit = exitAlert;
  activeAlertValid = true;

  alertPending = true;
  alertWaitingAck = false;
  alertWaitingBackoff = false;
  alertRetryCount = 0;

  DBG(F("ALERT QUEUED: "));
  DBGLN(exitAlert ? F("EXIT") : F("RETURN"));
}

// Wait time before a retry. Different for each animal so they do not collide.
unsigned long getAlertBackoff()
{
  unsigned long animalOffset =
    (unsigned long)(ANIMAL_NUMBER - 1) * ALERT_BACKOFF_STEP;
  unsigned long randomOffset = random(0, ALERT_BACKOFF_RANDOM);
  return ALERT_BACKOFF_BASE + animalOffset + randomOffset;
}

// ALERT,A01,EXIT,lat,lon,alt,YYYY-MM-DD,HH:MM:SS
void transmitAlert()
{
  if (!activeAlertValid) return;

  beginMultiHop("BASE", activeAlertPacketID);

  LoRa.print(F("ALERT,"));
  LoRa.print(ANIMAL_ID);
  LoRa.print(',');
  LoRa.print(activeAlertExit ? F("EXIT") : F("RETURN"));
  LoRa.print(',');

  // Last known position is sent here (even if a little old)
  if (gps.location.isValid())
  {
    LoRa.print(gps.location.lat(), 5);
    LoRa.print(',');
    LoRa.print(gps.location.lng(), 5);
    LoRa.print(',');
    LoRa.print(gps.altitude.meters(), 1);
  }
  else
  {
    LoRa.print(F("0,0,0"));
  }

  LoRa.print(',');
  printUTCDateTime(LoRa);

  FEED_WDT();
  LoRa.endPacket();
  LoRa.receive();

  alertWaitingAck = true;
  alertPending = false;
  alertSendTime = millis();
  if (alertRetryCount < 255) alertRetryCount++;

  DBG(F("ALERT SENT, attempt "));
  DBGLN(alertRetryCount);
}

// Payload: ACK,A01,ALERT,EXIT,<packetID>   (changes the text in place)
void processAlertAck(char *payload)
{
  if (strncmp_P(payload, PSTR("ACK,"), 4) != 0) return;
  if (!activeAlertValid) return;

  char *f[5];
  if (splitFields(payload, f, 5) < 5) return;

  if (strcmp(f[1], ANIMAL_ID) != 0) return;
  if (strcmp_P(f[2], PSTR("ALERT")) != 0) return;
  if (strcmp_P(f[3], activeAlertExit ? PSTR("EXIT") : PSTR("RETURN")) != 0) return;

  if (strtoul(f[4], NULL, 10) != activeAlertPacketID)
  {
    DBGLN(F("Stale alert ACK ignored"));
    return;
  }

  // SUCCESS
  alertWaitingAck = false;
  alertPending = false;
  alertWaitingBackoff = false;
  alertRetryCount = 0;
  activeAlertValid = false;

  DBGLN(F("ALERT ACK received. Alert delivered."));
}

// Alert scheduler: send, wait for ACK, retry quickly, then retry slowly.
// It never gives up until an ACK comes or a new alert replaces it.
void updateAlert()
{
  if (!alertPending && !alertWaitingAck && !alertWaitingBackoff) return;

  unsigned long now = millis();

  if (alertWaitingAck)
  {
    if (now - alertSendTime < ALERT_ACK_TIMEOUT) return;

    alertWaitingAck = false;

    unsigned long wait = getAlertBackoff();
    if (alertRetryCount >= MAX_ALERT_RETRIES)
    {
      wait += ALERT_SLOW_RETRY_INTERVAL;      // slow mode
      DBGLN(F("Alert: quick retries used, slow retry mode"));
    }
    alertRetryTime = now + wait;
    alertWaitingBackoff = true;
    return;
  }

  if (alertWaitingBackoff)
  {
    if ((long)(now - alertRetryTime) >= 0)
    {
      alertWaitingBackoff = false;
      alertPending = true;
    }
    return;
  }

  if (alertPending)
  {
    transmitAlert();
  }
}

// ============================================================
// 11. GEOFENCE CHECK
// ============================================================

void checkGeofence()
{
  if (fenceCount < 3) return;                 // no fence yet
  if (!gpsGood()) return;                     // GPS not good enough

  unsigned long now = millis();
  if (now - lastGeofenceCheck < GEOFENCE_CHECK_MS) return;
  lastGeofenceCheck = now;

  float lat = gps.location.lat();
  float lon = gps.location.lng();
  bool inside = insideFence(lat, lon);

  // First valid position
  if (!fenceStateKnown)
  {
    fenceStateKnown = true;
    animalInside = inside;
    confirmCount = 0;

    DBGLN(inside ? F("Initial: INSIDE") : F("Initial: OUTSIDE"));

    if (!inside) queueAlert(true);
    return;
  }

  // Decide if the state wants to change
  bool wantInside = animalInside;
  if (inside != animalInside)
  {
    if (FENCE_BUFFER_M <= 0.0 || distanceToFenceM(lat, lon) > FENCE_BUFFER_M)
    {
      wantInside = inside;
    }
  }

  if (wantInside == animalInside)
  {
    confirmCount = 0;                         // nothing changed
    return;
  }

  // Debounce: need several readings in a row
  confirmCount++;
  if (confirmCount < GEOFENCE_CONFIRM) return;

  confirmCount = 0;
  animalInside = wantInside;
  queueAlert(!animalInside);                  // outside = EXIT alert
}

void readGPS()
{
  while (gpsSerial.available())
  {
    if (gps.encode(gpsSerial.read()))
    {
      if (gps.location.isUpdated())
      {
        checkGeofence();
      }
    }
  }
}

// ============================================================
// 12. COMMANDS FROM THE BASE
// ============================================================

// POLL,A01
void receivePollCommand(char *payload)
{
  if (strncmp_P(payload, PSTR("POLL,"), 5) != 0) return;
  if (strcmp(payload + 5, ANIMAL_ID) != 0) return;

  DBGLN(F("POLL received"));

  if (liveMode)
  {
    pollWaitingForSlot = true;
    pollReceivedTime = millis();
  }
}

// LIVE,A01,ON   or   LIVE,A01,OFF
void processLiveCommand(char *payload)
{
  char *f[3];
  if (splitFields(payload, f, 3) < 3) return;
  if (strcmp(f[1], ANIMAL_ID) != 0) return;

  if (strcmp_P(f[2], PSTR("ON")) == 0)
  {
    liveMode = true;
    sendCommandAck("LIVE", "ON");
    DBGLN(F("LIVE ON"));
  }
  else if (strcmp_P(f[2], PSTR("OFF")) == 0)
  {
    liveMode = false;
    pollWaitingForSlot = false;
    sendCommandAck("LIVE", "OFF");
    DBGLN(F("LIVE OFF"));
  }
}

// FENCE,A01,4,lat,lon,lat,lon,lat,lon,lat,lon
// The new fence is checked first. The old fence is kept if anything is wrong.
void processFenceCommand(char *payload)
{
  char *f[3 + 2 * MAX_FENCE_POINTS];
  byte n = splitFields(payload, f, 3 + 2 * MAX_FENCE_POINTS);

  if (n < 3) return;
  if (strcmp(f[1], ANIMAL_ID) != 0) return;

  int newCount = atoi(f[2]);
  if (newCount < 3 || newCount > MAX_FENCE_POINTS)
  {
    DBGLN(F("FENCE rejected: bad point count"));
    return;
  }

  if (n < 3 + 2 * newCount)
  {
    DBGLN(F("FENCE rejected: too few numbers"));
    return;
  }

  // Parse into a temporary list
  FencePoint temp[MAX_FENCE_POINTS];

  for (byte i = 0; i < newCount; i++)
  {
    float la, lo;
    if (!parseCoord(f[3 + 2 * i], la) || !parseCoord(f[4 + 2 * i], lo))
    {
      DBGLN(F("FENCE rejected: not a number"));
      return;
    }
    if (la < -90.0 || la > 90.0 || lo < -180.0 || lo > 180.0 ||
        (la == 0.0 && lo == 0.0))
    {
      DBGLN(F("FENCE rejected: bad range"));
      return;
    }
    temp[i].lat = la;
    temp[i].lon = lo;
  }

  // All good. Now use it.
  for (byte i = 0; i < newCount; i++) fence[i] = temp[i];
  fenceCount = newCount;
  saveFence();

  // Check the position again with the new fence
  fenceStateKnown = false;
  confirmCount = 0;

  sendCommandAck("FENCE", "OK");
  DBGLN(F("New fence active and saved"));
}

// ============================================================
// 13. CONDITIONAL RELAY
// ============================================================

void clearPendingRelay()
{
  relayPending = false;
  relayStartTime = 0;
  relayPayload[0] = '\0';
}

void scheduleRelay(const MHPacket &mh)
{
  if (relayPending) return;                       // one at a time
  if (strlen(mh.payload) >= PAYLOAD_MAX) return;  // too long to store

  relayId = mh.id;
  strncpy(relaySource, mh.source, sizeof(relaySource));
  strncpy(relayDest, mh.dest, sizeof(relayDest));
  relaySource[sizeof(relaySource) - 1] = '\0';
  relayDest[sizeof(relayDest) - 1] = '\0';
  relayHop = mh.hop;
  relayMaxHop = mh.maxHop;
  strcpy(relayPayload, mh.payload);

  relayPending = true;
  relayStartTime = millis();

  DBGLN(F("Relay scheduled"));
}

// Is this packet the answer we were waiting for? (it travels backwards)
bool isExpectedRelayResponse(const MHPacket &mh)
{
  if (!relayPending) return false;

  if (strcmp(mh.source, relayDest) != 0) return false;
  if (strcmp(mh.dest, relaySource) != 0) return false;

  // LIVE / FENCE command -> ACK
  if (strncmp_P(relayPayload, PSTR("LIVE,"), 5) == 0 ||
      strncmp_P(relayPayload, PSTR("FENCE,"), 6) == 0)
  {
    return strncmp_P(mh.payload, PSTR("ACK,"), 4) == 0;
  }

  // POLL -> DATA from the expected animal
  if (strncmp_P(relayPayload, PSTR("POLL,"), 5) == 0)
  {
    if (strncmp_P(mh.payload, PSTR("DATA,"), 5) != 0) return false;

    size_t len = strlen(relayDest);
    return strncmp(mh.payload + 5, relayDest, len) == 0 &&
           mh.payload[5 + len] == ',';
  }

  return false;
}

void updateConditionalRelay()
{
  if (!relayPending) return;

  unsigned long waitTime = RELAY_WAIT_TIME;
  if (strncmp_P(relayPayload, PSTR("POLL,"), 5) == 0)
  {
    waitTime = POLL_RELAY_WAIT_TIME;
  }

  unsigned long age = millis() - relayStartTime;

  // Never got a slot (for example no GPS time): forget it
  if (age > RELAY_MAX_AGE)
  {
    clearPendingRelay();
    return;
  }

  if (age < waitTime) return;

  // Wait for our own relay slot
  if (!isMyRelaySlotStart()) return;

  DBGLN(F("Relay timeout: forwarding stored packet"));

  if (relayHop < relayMaxHop)
  {
    LoRa.beginPacket();

    LoRa.print(F("MH,"));
    LoRa.print(relayId);
    LoRa.print(',');
    LoRa.print(relaySource);
    LoRa.print(',');
    LoRa.print(relayDest);
    LoRa.print(',');
    LoRa.print(relayHop + 1);
    LoRa.print(',');
    LoRa.print(relayMaxHop);
    LoRa.print(',');
    LoRa.print(relayPayload);

    FEED_WDT();
    LoRa.endPacket();
    LoRa.receive();
  }

  clearPendingRelay();
}

// ============================================================
// 14. RECEIVING
// ============================================================

// MH,packetID,source,destination,hop,maxHop,payload
void processMultiHopPacket(char *packet)
{
  MHPacket mh;
  if (!parseMH(packet, mh)) return;

  // Ignore our own packet
  if (strcmp(mh.source, ANIMAL_ID) == 0) return;

  // Was this the answer we were waiting for? Then cancel the relay.
  if (isExpectedRelayResponse(mh))
  {
    DBGLN(F("Expected response heard. Relay cancelled."));
    clearPendingRelay();
  }

  // Duplicate check
  byte src = sourceCode(mh.source);
  if (isDuplicatePacket(src, mh.id))
  {
    DBGLN(F("Duplicate MH packet ignored"));
    return;
  }
  rememberPacket(src, mh.id);

  // ---- Packet is for this animal ----
  if (strcmp(mh.dest, ANIMAL_ID) == 0)
  {
    char *payload = mh.payload;

    if (strncmp_P(payload, PSTR("ACK,"), 4) == 0)
    {
      processAlertAck(payload);
    }
    else if (strncmp_P(payload, PSTR("POLL,"), 5) == 0)
    {
      receivePollCommand(payload);
    }
    else if (strncmp_P(payload, PSTR("LIVE,"), 5) == 0)
    {
      currentCommandPacketID = mh.id;
      processLiveCommand(payload);
    }
    else if (strncmp_P(payload, PSTR("FENCE,"), 6) == 0)
    {
      currentCommandPacketID = mh.id;
      processFenceCommand(payload);
    }
    else
    {
      DBGLN(F("Unknown payload for this animal"));
    }
    return;       // reached destination: never forward
  }

  // ---- Not for us: maybe relay it ----
  if (mh.hop < mh.maxHop)
  {
    // DATA is the answer to a POLL. It is not relayed.
    if (strncmp_P(mh.payload, PSTR("DATA,"), 5) == 0)
    {
      return;
    }
    scheduleRelay(mh);
  }
}

void receiveCommand()
{
  int packetSize = LoRa.parsePacket();
  if (packetSize <= 0) return;

  // Too big: throw it away
  if (packetSize >= PACKET_MAX)
  {
    while (LoRa.available()) LoRa.read();
    DBGLN(F("Packet too big, dropped"));
    return;
  }

  int len = 0;
  while (LoRa.available() && len < PACKET_MAX - 1)
  {
    rxBuf[len++] = (char)LoRa.read();
  }
  rxBuf[len] = '\0';

  // Remove spaces and new lines at both ends
  while (len > 0 &&
         (rxBuf[len - 1] == ' ' || rxBuf[len - 1] == '\r' || rxBuf[len - 1] == '\n'))
  {
    rxBuf[--len] = '\0';
  }
  char *pkt = rxBuf;
  while (*pkt == ' ' || *pkt == '\r' || *pkt == '\n') pkt++;

  DBG(F("RX: "));
  DBGLN(pkt);

  if (strncmp_P(pkt, PSTR("MH,"), 3) == 0)
  {
    processMultiHopPacket(pkt);
    return;
  }

#if SUPPORT_DIRECT_PACKETS
  // Old style packets without the MH header
  if (strncmp_P(pkt, PSTR("ACK,"), 4) == 0)
  {
    processAlertAck(pkt);
  }
  else if (strncmp_P(pkt, PSTR("POLL,"), 5) == 0)
  {
    receivePollCommand(pkt);
  }
  else if (strncmp_P(pkt, PSTR("LIVE,"), 5) == 0)
  {
    processLiveCommand(pkt);
  }
  else if (strncmp_P(pkt, PSTR("FENCE,"), 6) == 0)
  {
    processFenceCommand(pkt);
  }
#endif
}

// ============================================================
// 15. DEBUG TEST (only when DEBUG is 1)
// ============================================================
// Type  e  = test EXIT alert,   r  = test RETURN alert
#if DEBUG
void debugCommands()
{
  if (!Serial.available()) return;
  char c = Serial.read();
  if (c == 'e') queueAlert(true);
  if (c == 'r') queueAlert(false);
}
#endif

// ============================================================
// 16. SETUP AND LOOP
// ============================================================

void setup()
{
#if DEBUG
  Serial.begin(9600);
  Serial.println(F("COLLAR START"));
#endif

  loadPacketSequence();
  randomSeed(analogRead(A0) ^ micros());

  gpsSerial.begin(9600);
  Wire.begin();

  // ---- LoRa (no more endless hang) ----
  bool loraOk = false;
  for (byte i = 0; i < LORA_INIT_TRIES && !loraOk; i++)
  {
    loraOk = LoRa.begin(LORA_FREQUENCY);
    if (!loraOk) delay(500);
  }
  if (!loraOk)
  {
    DBGLN(F("LoRa failed. Restarting."));
    rebootNow();
  }

  // Long range settings (same as old code)
  LoRa.setTxPower(18);
  LoRa.setSpreadingFactor(12);
  LoRa.setSignalBandwidth(125E3);
  LoRa.setCodingRate4(8);
  LoRa.setPreambleLength(12);

#if USE_CRC
  LoRa.enableCrc();
#endif
#if USE_SYNCWORD
  LoRa.setSyncWord(SYNC_WORD);
#endif

  // ---- MPU6050 (collar still works without it) ----
  mpuOk = mpu.begin();
  if (mpuOk)
  {
    mpu.setAccelerometerRange(MPU6050_RANGE_8_G);
    mpu.setGyroRange(MPU6050_RANGE_500_DEG);
    mpu.setFilterBandwidth(MPU6050_BAND_21_HZ);
  }
  else
  {
    DBGLN(F("MPU6050 not found. Movement will stay 0."));
  }

  // ---- Fence from EEPROM ----
  loadFence();

  delay(2000);

  // ---- Battery ----
  readBattery();
  lastBatteryRead = millis();

#if USE_WATCHDOG
  wdt_enable(WDTO_8S);
#endif

  DBGLN(F("COLLAR READY"));
}

void loop()
{
  FEED_WDT();

  readGPS();

  // Send telemetry when a POLL is waiting and our data slot starts
  if (pollWaitingForSlot)
  {
    if (!liveMode || millis() - pollReceivedTime > POLL_SLOT_TIMEOUT)
    {
      pollWaitingForSlot = false;               // old poll: drop it
      DBGLN(F("Poll dropped (timeout)"));
    }
    else if (isMyDataSlotStart())
    {
      pollWaitingForSlot = false;
      sendTelemetry();
    }
  }

#if DEBUG
  debugCommands();
#endif

  updateConditionalRelay();
  updateAlert();
  updateMPU();
  updateBattery();
  receiveCommand();
}
