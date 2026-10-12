/*
  ============================================================
  BASE STATION FIRMWARE  (ESP8266)  -  UPGRADED VERSION
  LoRa-Integrated GPS Geo-Fencing System for Smart Livestock
  Monitoring in Himalayan Pastures
  ============================================================

  RULES KEPT FROM OLD VERSION
  - Pins are NOT changed (LoRa SS 15, RST 16, DIO0 4).
  - LoRa packet formats are NOT changed (MH, POLL, LIVE, FENCE, ACK,
    ALERT, DATA). The new collar code and this code agree on them.
  - WebSocket messages for the Flutter app are NOT changed:
      to app:   STATUS,CONNECTED  COMMAND_SENT,..  COMMAND_SUCCESS,..
                COMMAND_FAILED,..  EVENT,..  EVENTS_END  EVENTS_EMPTY
                EVENT_ACK_SUCCESS,id  EVENT_ACK_FAILED,..
                ALERT,...  and  DATA,...  (raw lines)
      from app: GET_EVENTS  EVENT_ACK,id  POLL,Axx  LIVE,Axx,ON/OFF
                FENCE,Axx,n,lat,lon,...
  - Event file format is NOT changed:
      eventID,animalID,alertPacketID,alertType,lat,lon,alt,date,time

  WHAT IS NEW (short list)
  - Packet number saved once per 10 packets (less flash wear, no 16-bit cut)
  - Alert is never lost: no ACK is sent if it could not be saved or shown
  - Same alert is never saved twice (even after the duplicate list is full)
  - FENCE command is checked and rounded to 5 decimals (fits the collar)
  - Bad commands are rejected at once with COMMAND_FAILED
  - Poll timeout configured for 30 s; verify against collar slot schedule
  - A collar that does not answer is skipped for a while (no more 40 s
    delay for every other collar)
  - Late DATA is still forwarded to the app
  - Events file has a size limit and backup-based replace/recovery
  - No more String in the LoRa path (stable for weeks)
  - No more endless hang if LoRa fails (it restarts)
  - Optional: CRC, sync word, WebSocket heartbeat, base battery report
*/

#include <SPI.h>
#include <LoRa.h>
#include <ESP8266WiFi.h>
#include <WebSocketsServer.h>
#include <LittleFS.h>
#include <math.h>

// ============================================================
// 1. CONFIGURATION  (change values here only)
// ============================================================

// ---- Debug (1 = print on Serial 9600) ----
#define DEBUG 1

// ---- Optional features (default OFF = same as old behaviour) ----
#define USE_CRC                0   // 1 = LoRa CRC (collar USE_CRC must match)
#define USE_SYNCWORD           0   // 1 = private sync word (collar must match)
#define SYNC_WORD              0x34
#define SUPPORT_DIRECT_PACKETS 1   // 1 = also accept old non-MH packets
#define BASE_RELAY             1   // 1 = base forwards packets for other nodes
#define USE_WS_HEARTBEAT       0   // 1 = ping app clients (see note)
#define SEND_BASE_BATTERY      0   // 1 = send BASE_BATTERY,x.xx to the app
/*
  HEARTBEAT NOTE: normal WebSocket clients (Flutter web_socket_channel)
  answer pings by themselves. Test with your app before turning it on.
  BASE_BATTERY is a NEW message. Turn it on only after the app can ignore
  or show it.
*/

// ---- WiFi / WebSocket ----
#define WIFI_SSID       "BaseStation"
#define WIFI_PASSWORD   "12345678"
#define WEBSOCKET_PORT  81

// ---- Files (LittleFS) ----
#define EVENTS_FILE           "/events.txt"
#define EVENTS_TEMP_FILE      "/events_tmp.txt"
#define EVENTS_BACKUP_FILE    "/events_backup.txt"
#define PACKET_SEQUENCE_FILE  "/packet_sequence.txt"
#define EVENTS_MAX            100     // oldest event is removed after this
#define EVENT_SEND_GAP_MS     20

// ---- LoRa (pins NOT changed) ----
#define LORA_SS         15   // D8
#define LORA_RST        16   // D0
#define LORA_DIO0        4   // D2
#define LORA_FREQUENCY  433E6
#define LORA_INIT_TRIES  3

// ---- Packet sizes ----
#define PACKET_MAX       256   // biggest LoRa packet we read
#define WS_CMD_MAX       256   // biggest text from the app
#define COMMAND_MAX_LEN  100   // biggest command sent by LoRa (collar relay limit)
#define EVENT_LINE_MAX   200

// ---- Multihop ----
#define MAX_HOPS 1
#define SEQ_SAVE_STEP 10             // save packet number once per 10 packets
#define DUPLICATE_HISTORY_SIZE 20

// ---- Command ACK / RETRY ----
#define COMMAND_RETRY_INTERVAL 5000UL
#define COMMAND_MAX_RETRIES    3
#define COMMAND_QUEUE_SIZE     10
/*
  NOTE: 5 s is fine when the collar is in direct range.
  If the answer must travel through another collar (relay), it can take
  much longer (relay waits for its time slot). In that case raise
  COMMAND_RETRY_INTERVAL to about 40000UL.
*/

// ---- Fence (must match the collar MAX_FENCE_POINTS) ----
#define MAX_FENCE_POINTS 4

// ---- Multi-node polling ----
#define MAX_ANIMAL_NODES 10
#define POLL_TIMEOUT     30000UL   // Must match the collar response window; verify against slot timing
#define POLL_FAIL_LIMIT  3         // timeouts in a row before skipping
#define POLL_COOLDOWN    300000UL  // skip time (5 minutes)

// ---- Base battery ----
#define BATTERY_PIN      A0
#define BATTERY_R1       10000.0
#define BATTERY_R2       10000.0
#define BATTERY_ADC_REF  3.2
#define BATTERY_REPORT_INTERVAL 60000UL

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

// ============================================================
// 3. TYPES AND GLOBAL VARIABLES
// ============================================================

WebSocketsServer webSocket = WebSocketsServer(WEBSOCKET_PORT);

// ---- Animals ----
const char *animalIDs[MAX_ANIMAL_NODES] =
  {"A01","A02","A03","A04","A05","A06","A07","A08","A09","A10"};
bool animalLive[MAX_ANIMAL_NODES] = {false};

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

char rxBuf[PACKET_MAX];

// ---- Storage state ----
bool fsOk = false;
unsigned long nextEventID = 1;
unsigned int eventCount = 0;
unsigned long packetSequence = 0;
unsigned long sequenceCeiling = 0;

// ---- Duplicate memory ----
struct RecentPacket
{
  byte src;               // 0 = empty slot
  unsigned long id;
};
RecentPacket recentPackets[DUPLICATE_HISTORY_SIZE];
byte recentPacketIndex = 0;

// ---- Last alerts already handled (per animal, last 4) ----
#define ALERT_MEMORY 4
unsigned long alertMemory[MAX_ANIMAL_NODES][ALERT_MEMORY];
byte alertMemoryIndex[MAX_ANIMAL_NODES];

// ---- Command queue ----
struct QueuedCommand
{
  char original[WS_CMD_MAX];       // text from the app (used in replies)
  char payload[COMMAND_MAX_LEN];   // text sent by LoRa (checked and rounded)
};
QueuedCommand commandQueue[COMMAND_QUEUE_SIZE];
byte commandQueueHead = 0;
byte commandQueueTail = 0;
byte commandQueueCount = 0;

bool commandPending = false;
char pendingOriginal[WS_CMD_MAX];
char pendingPayload[COMMAND_MAX_LEN];
char pendingAnimalID[8];
unsigned long lastCommandSend = 0;
byte commandRetryCount = 0;
// The collar echoes the MH packet ID in its ACK. Keep IDs from all attempts
// of the current command because each retry uses a fresh packet ID.
unsigned long pendingPacketIDs[COMMAND_MAX_RETRIES];
byte pendingPacketIDCount = 0;

// ---- Polling ----
byte pollIndex = 0;
int pollAnimalIndex = -1;
bool pollPending = false;
unsigned long pollSendTime = 0;
unsigned long lastPollAction = 0;
byte pollFailCount[MAX_ANIMAL_NODES];
unsigned long pollSkipUntil[MAX_ANIMAL_NODES];   // 0 = not skipped

unsigned long lastBatteryReport = 0;
unsigned long lastHeapPrint = 0;

// ============================================================
// 4. SMALL HELPERS
// ============================================================

void copyStr(char *dst, const char *src, size_t size)
{
  if (size == 0) return;
  size_t i = 0;
  while (i < size - 1 && src[i]) { dst[i] = src[i]; i++; }
  dst[i] = '\0';
}

// Remove spaces and new lines at both ends (in place)
void trimInPlace(char *s)
{
  size_t len = strlen(s);
  while (len > 0 && (s[len - 1] == ' ' || s[len - 1] == '\r' ||
                     s[len - 1] == '\n' || s[len - 1] == '\t'))
  {
    s[--len] = '\0';
  }
  char *p = s;
  while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n') p++;
  if (p != s) memmove(s, p, strlen(p) + 1);
}

// Copy text up to the next comma into "out". Returns pointer after comma.
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

// Cut text into comma fields IN PLACE. The last field keeps any extra commas.
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

// Read a whole number text. Returns false if it is not a clean number.
bool parseNumber(const char *s, double &value)
{
  char *end;
  double v = strtod(s, &end);
  if (end == s) return false;
  while (*end == ' ') end++;
  if (*end != '\0') return false;
  if (!isfinite(v)) return false;
  value = v;
  return true;
}

// Forward declaration used by the MH header validator.
byte sourceCode(const char *s);

// Packet: MH,packetID,source,destination,hop,maxHop,payload
bool parseMH(char *pkt, MHPacket &mh)
{
  if (pkt == NULL || strncmp(pkt, "MH,", 3) != 0) return false;

  char *p = pkt + 3;
  char *end = NULL;
  unsigned long id = strtoul(p, &end, 10);
  if (end == p || *end != ',' || id == 0) return false;
  mh.id = id;
  p = end + 1;

  p = getField(p, mh.source, sizeof(mh.source));
  if (p == NULL) return false;
  p = getField(p, mh.dest, sizeof(mh.dest));
  if (p == NULL) return false;

  long hop = strtol(p, &end, 10);
  if (end == p || *end != ',' || hop < 0 || hop > 255) return false;
  mh.hop = (byte)hop;
  p = end + 1;

  long maxHop = strtol(p, &end, 10);
  if (end == p || *end != ',' || maxHop < 0 || maxHop > 255) return false;
  mh.maxHop = (byte)maxHop;
  mh.payload = end + 1;

  if (mh.source[0] == '\0' || mh.dest[0] == '\0' || mh.payload[0] == '\0') return false;
  if (sourceCode(mh.source) == 255) return false;
  if (strcmp(mh.dest, "BASE") != 0 && sourceCode(mh.dest) == 255) return false;
  if (mh.hop > mh.maxHop) return false;
  return true;
}

// Short number for each sender (used by duplicate memory)
byte sourceCode(const char *s)
{
  if (strcmp(s, "BASE") == 0) return 100;
  if (s[0] == 'A')
  {
    int n = atoi(s + 1);
    if (n > 0 && n < 100) return (byte)n;
  }
  return 255;
}

bool isDuplicatePacket(byte src, unsigned long id)
{
  for (byte i = 0; i < DUPLICATE_HISTORY_SIZE; i++)
  {
    if (recentPackets[i].src == src && recentPackets[i].id == id) return true;
  }
  return false;
}

void rememberPacket(byte src, unsigned long id)
{
  recentPackets[recentPacketIndex].src = src;
  recentPackets[recentPacketIndex].id = id;
  recentPacketIndex++;
  if (recentPacketIndex >= DUPLICATE_HISTORY_SIZE) recentPacketIndex = 0;
}

// Find animal in the list. Returns -1 if unknown.
int getAnimalIndex(const char *animalID)
{
  for (byte i = 0; i < MAX_ANIMAL_NODES; i++)
  {
    if (strcmp(animalIDs[i], animalID) == 0) return i;
  }
  return -1;
}

// Alerts that were already saved and shown (so a repeat is only acknowledged)
bool alertSeen(int idx, unsigned long id)
{
  if (idx < 0) return false;
  for (byte i = 0; i < ALERT_MEMORY; i++)
  {
    if (alertMemory[idx][i] == id) return true;
  }
  return false;
}

void alertRemember(int idx, unsigned long id)
{
  if (idx < 0) return;
  alertMemory[idx][alertMemoryIndex[idx]] = id;
  alertMemoryIndex[idx]++;
  if (alertMemoryIndex[idx] >= ALERT_MEMORY) alertMemoryIndex[idx] = 0;
}

// ============================================================
// 5. PACKET NUMBER (saved in LittleFS)
// ============================================================

void loadPacketSequence()
{
  unsigned long stored = 0;

  if (fsOk && LittleFS.exists(PACKET_SEQUENCE_FILE))
  {
    File file = LittleFS.open(PACKET_SEQUENCE_FILE, "r");
    if (file)
    {
      char buf[16];
      int n = file.readBytesUntil('\n', buf, sizeof(buf) - 1);
      buf[n] = '\0';
      file.close();
      stored = strtoul(buf, NULL, 10);
    }
  }
  else if (!fsOk)
  {
    // No storage: start at a random number so we do not repeat old numbers
    stored = 1000 + (ESP.getCycleCount() % 50000);
  }

  // The saved number is a "ceiling": numbers up to it may already be used.
  packetSequence = stored;
  sequenceCeiling = stored;
}

void saveSequenceCeiling()
{
  if (!fsOk) return;
  File file = LittleFS.open(PACKET_SEQUENCE_FILE, "w");
  if (!file) return;
  file.println(sequenceCeiling);
  file.close();
}

// Next packet number. Writes the file only once per SEQ_SAVE_STEP packets.
unsigned long nextPacketID()
{
  packetSequence++;
  if (packetSequence > sequenceCeiling)
  {
    sequenceCeiling = packetSequence + SEQ_SAVE_STEP - 1;
    saveSequenceCeiling();
  }
  return packetSequence;
}

// ============================================================
// 6. EVENTS (offline storage for the app)
// ============================================================

// Read next non-empty line. Returns false at end of file.
bool readLine(File &f, char *buf, size_t size)
{
  while (f.available())
  {
    int n = f.readBytesUntil('\n', buf, size - 1);
    buf[n] = '\0';
    trimInPlace(buf);
    if (buf[0] != '\0') return true;
  }
  return false;
}

// Recover an interrupted event-file replacement.
// Prefer the fully written temporary file; fall back to the old backup.
void recoverEventsFile()
{
  if (!LittleFS.exists(EVENTS_FILE))
  {
    if (LittleFS.exists(EVENTS_TEMP_FILE) &&
        LittleFS.rename(EVENTS_TEMP_FILE, EVENTS_FILE))
    {
      DBGLN(F("Recovered new events file"));
    }
    else if (LittleFS.exists(EVENTS_BACKUP_FILE) &&
             LittleFS.rename(EVENTS_BACKUP_FILE, EVENTS_FILE))
    {
      DBGLN(F("Recovered backup events file"));
    }
  }

  // If the main file is present, any remaining temp/backup files are stale.
  if (LittleFS.exists(EVENTS_FILE))
  {
    if (LittleFS.exists(EVENTS_TEMP_FILE)) LittleFS.remove(EVENTS_TEMP_FILE);
    if (LittleFS.exists(EVENTS_BACKUP_FILE)) LittleFS.remove(EVENTS_BACKUP_FILE);
  }
}

// Find the highest event ID and count events
void loadNextEventID()
{
  nextEventID = 1;
  eventCount = 0;

  File file = LittleFS.open(EVENTS_FILE, "r");
  if (!file) return;

  unsigned long highest = 0;
  char line[EVENT_LINE_MAX];

  while (readLine(file, line, sizeof(line)))
  {
    char *c = strchr(line, ',');
    if (c == NULL) continue;
    *c = '\0';
    unsigned long id = strtoul(line, NULL, 10);
    if (id > highest) highest = id;
    eventCount++;
  }
  file.close();
  nextEventID = highest + 1;
}

// Copy the events file to a temp file without one event, then replace.
// skipFirst = true  : leave out the oldest event
// skipFirst = false : leave out the event with ID skipID
// Returns true if an event was removed.
bool rewriteEvents(unsigned long skipID, bool skipFirst)
{
  File src = LittleFS.open(EVENTS_FILE, "r");
  if (!src) return false;

  if (LittleFS.exists(EVENTS_TEMP_FILE)) LittleFS.remove(EVENTS_TEMP_FILE);

  File tmp = LittleFS.open(EVENTS_TEMP_FILE, "w");
  if (!tmp)
  {
    src.close();
    return false;
  }

  bool removed = false;
  char line[EVENT_LINE_MAX];

  while (readLine(src, line, sizeof(line)))
  {
    bool skip = false;

    if (skipFirst)
    {
      if (!removed) skip = true;
    }
    else
    {
      // Lines without a comma are kept (never lose strange lines)
      if (strchr(line, ',') != NULL && strtoul(line, NULL, 10) == skipID)
      {
        skip = true;
      }
    }

    if (skip)
    {
      removed = true;
      continue;
    }
    tmp.println(line);
  }

  src.close();
  tmp.close();

  if (!removed)
  {
    LittleFS.remove(EVENTS_TEMP_FILE);
    return false;
  }

  // Keep the old file until the new file has been installed successfully.
  // This also gives setup() a recovery path if power fails between renames.
  if (LittleFS.exists(EVENTS_BACKUP_FILE)) LittleFS.remove(EVENTS_BACKUP_FILE);
  if (!LittleFS.rename(EVENTS_FILE, EVENTS_BACKUP_FILE))
  {
    LittleFS.remove(EVENTS_TEMP_FILE);
    DBGLN(F("Could not back up events file"));
    return false;
  }

  if (!LittleFS.rename(EVENTS_TEMP_FILE, EVENTS_FILE))
  {
    // Restore the original file if installing the new one fails.
    if (!LittleFS.rename(EVENTS_BACKUP_FILE, EVENTS_FILE))
      DBGLN(F("CRITICAL: could not restore events backup"));
    return false;
  }

  LittleFS.remove(EVENTS_BACKUP_FILE);
  return true;
}

// Save one event. Line format (same as before):
// eventID,animalID,alertPacketID,alertType,lat,lon,alt,date,time
bool saveEvent(const char *animalID, const char *alertPacketID,
               const char *alertType, const char *eventData)
{
  if (!fsOk) return false;

  if (eventCount >= EVENTS_MAX)
  {
    if (rewriteEvents(0, true))
    {
      if (eventCount > 0) eventCount--;
      DBGLN(F("Events full: oldest event removed"));
    }
    else
    {
      DBGLN(F("Events full: could not evict oldest event"));
      return false;
    }
  }

  File file = LittleFS.open(EVENTS_FILE, "a");
  if (!file) return false;

  char line[EVENT_LINE_MAX];
  snprintf(line, sizeof(line), "%lu,%s,%s,%s,%s",
           nextEventID, animalID, alertPacketID, alertType, eventData);

  size_t expectedBytes = strlen(line) + 2; // println() writes CR/LF
  size_t written = file.println(line);
  file.flush();
  file.close();
  if (written < expectedBytes) {
    DBGLN(F("Event write incomplete"));
    return false;
  }

  nextEventID++;
  eventCount++;
  return true;
}

// Was this alert already saved? (animal + alert packet ID)
bool isAlertAlreadySaved(const char *animalID, const char *alertPacketID)
{
  if (!fsOk) return false;

  File file = LittleFS.open(EVENTS_FILE, "r");
  if (!file) return false;

  char line[EVENT_LINE_MAX];

  while (readLine(file, line, sizeof(line)))
  {
    // eventID,animalID,alertPacketID,...
    char *f[4];
    if (splitFields(line, f, 4) < 4) continue;

    if (strcmp(f[1], animalID) == 0 && strcmp(f[2], alertPacketID) == 0)
    {
      file.close();
      return true;
    }
  }
  file.close();
  return false;
}

// App sent GET_EVENTS
void sendStoredEvents(uint8_t clientNum)
{
  File file = LittleFS.open(EVENTS_FILE, "r");
  if (!file)
  {
    webSocket.sendTXT(clientNum, "EVENTS_EMPTY");
    return;
  }

  char line[EVENT_LINE_MAX];
  char msg[EVENT_LINE_MAX + 8];

  while (readLine(file, line, sizeof(line)))
  {
    snprintf(msg, sizeof(msg), "EVENT,%s", line);
    webSocket.sendTXT(clientNum, msg);
    delay(EVENT_SEND_GAP_MS);
  }
  file.close();

  webSocket.sendTXT(clientNum, "EVENTS_END");
}

// App sent EVENT_ACK,id  -> remove that event
bool acknowledgeEvent(unsigned long eventID)
{
  bool ok = rewriteEvents(eventID, false);
  if (ok && eventCount > 0) eventCount--;
  return ok;
}

// ============================================================
// 7. SENDING BY LORA
// ============================================================

// MH,packetID,BASE,destination,0,maxHop,payload
void sendMH(const char *destination, unsigned long packetID,
            byte maxHop, const char *payload)
{
  LoRa.beginPacket();

  LoRa.print(F("MH,"));
  LoRa.print(packetID);
  LoRa.print(',');
  LoRa.print(F("BASE"));
  LoRa.print(',');
  LoRa.print(destination);
  LoRa.print(F(",0,"));
  LoRa.print(maxHop);
  LoRa.print(',');
  LoRa.print(payload);

  LoRa.endPacket();
  LoRa.receive();
}

// ACK,A01,ALERT,EXIT,<original alert packet ID>
void sendAlertAck(const char *animalID, const char *alertType,
                  unsigned long originalAlertID, byte maxHop)
{
  char payload[48];
  snprintf(payload, sizeof(payload), "ACK,%s,ALERT,%s,%lu",
           animalID, alertType, originalAlertID);

  sendMH(animalID, nextPacketID(), maxHop, payload);

  DBG(F("ALERT ACK sent for alert ID "));
  DBGLN(originalAlertID);
}

// ============================================================
// 8. COMMANDS FROM THE APP  (LIVE / FENCE)
// ============================================================

// Check a FENCE text and write it again with 5 decimals.
// Input : FENCE,A01,4,27.6860000001,85.29500,...
// Output: FENCE,A01,4,27.68600,85.29500,...
bool normalizeFence(const char *in, char *out, size_t outSize, char *animal)
{
  char tmp[WS_CMD_MAX];
  copyStr(tmp, in, sizeof(tmp));

  char *f[3 + 2 * MAX_FENCE_POINTS];
  byte n = splitFields(tmp, f, 3 + 2 * MAX_FENCE_POINTS);
  if (n < 3) return false;

  trimInPlace(f[1]);
  trimInPlace(f[2]);

  if (getAnimalIndex(f[1]) < 0) return false;

  int count = atoi(f[2]);
  if (count < 3 || count > MAX_FENCE_POINTS) return false;
  if (n != 3 + 2 * count) return false;
  if (strchr(f[n - 1], ',') != NULL) return false;

  int len = snprintf(out, outSize, "FENCE,%s,%d", f[1], count);

  for (int i = 0; i < count; i++)
  {
    double la, lo;
    if (!parseNumber(f[3 + 2 * i], la) || !parseNumber(f[4 + 2 * i], lo))
    {
      return false;
    }
    if (la < -90.0 || la > 90.0 || lo < -180.0 || lo > 180.0) return false;
    if (la == 0.0 && lo == 0.0) return false;

    char a[16], b[16];
    dtostrf(la, 1, 5, a);
    dtostrf(lo, 1, 5, b);

    len += snprintf(out + len, outSize - len, ",%s,%s", a, b);
    if (len >= (int)outSize) return false;
  }

  copyStr(animal, f[1], 8);
  return true;
}

// Check a command from the app and make the text that goes on air.
// Only LIVE and FENCE are accepted.
bool buildPayload(const char *command, char *payload, size_t size, char *animal)
{
  char tmp[WS_CMD_MAX];
  copyStr(tmp, command, sizeof(tmp));

  if (strncmp(tmp, "LIVE,", 5) == 0)
  {
    char *f[3];
    if (splitFields(tmp, f, 3) != 3) return false;
    trimInPlace(f[1]);
    trimInPlace(f[2]);

    if (getAnimalIndex(f[1]) < 0) return false;
    if (strcmp(f[2], "ON") != 0 && strcmp(f[2], "OFF") != 0) return false;

    snprintf(payload, size, "LIVE,%s,%s", f[1], f[2]);
    copyStr(animal, f[1], 8);
    return true;
  }

  if (strncmp(tmp, "FENCE,", 6) == 0)
  {
    return normalizeFence(command, payload, size, animal);
  }

  return false;
}

bool queueCommand(const char *original, const char *payload)
{
  if (commandQueueCount >= COMMAND_QUEUE_SIZE) return false;

  copyStr(commandQueue[commandQueueTail].original, original, WS_CMD_MAX);
  copyStr(commandQueue[commandQueueTail].payload, payload, COMMAND_MAX_LEN);

  commandQueueTail++;
  if (commandQueueTail >= COMMAND_QUEUE_SIZE) commandQueueTail = 0;
  commandQueueCount++;
  return true;
}

// Send the pending command by LoRa (new packet number each time)
void transmitPendingCommand()
{
  unsigned long packetID = nextPacketID();
  if (pendingPacketIDCount < COMMAND_MAX_RETRIES) {
    pendingPacketIDs[pendingPacketIDCount++] = packetID;
  }
  sendMH(pendingAnimalID, packetID, MAX_HOPS, pendingPayload);
  lastCommandSend = millis();
}

void startNextQueuedCommand()
{
  if (commandPending) return;
  if (commandQueueCount == 0) return;

  QueuedCommand &c = commandQueue[commandQueueHead];

  copyStr(pendingOriginal, c.original, sizeof(pendingOriginal));
  copyStr(pendingPayload, c.payload, sizeof(pendingPayload));

  commandQueueHead++;
  if (commandQueueHead >= COMMAND_QUEUE_SIZE) commandQueueHead = 0;
  commandQueueCount--;

  // Animal ID is the second field of the payload
  char tmp[COMMAND_MAX_LEN];
  copyStr(tmp, pendingPayload, sizeof(tmp));
  char *f[3];
  splitFields(tmp, f, 3);
  copyStr(pendingAnimalID, f[1], sizeof(pendingAnimalID));

  commandPending = true;
  commandRetryCount = 1;
  pendingPacketIDCount = 0;

  DBG(F("Sending command: "));
  DBGLN(pendingPayload);

  transmitPendingCommand();
}

void sendToApp(const char *prefix, const char *text)
{
  char resp[WS_CMD_MAX + 24];
  snprintf(resp, sizeof(resp), "%s%s", prefix, text);
  webSocket.broadcastTXT(resp);
}

void updateCommandRetry()
{
  if (!commandPending) return;
  if (millis() - lastCommandSend < COMMAND_RETRY_INTERVAL) return;

  // All attempts used: declare failure
  if (commandRetryCount >= COMMAND_MAX_RETRIES)
  {
    commandPending = false;
    DBGLN(F("COMMAND FAILED"));
    sendToApp("COMMAND_FAILED,", pendingOriginal);
    startNextQueuedCommand();
    return;
  }

  commandRetryCount++;
  DBGLN(F("Command retry"));
  transmitPendingCommand();
}

// ACK,A01,LIVE,ON,<commandID>   ACK,A01,FENCE,OK,<commandID>
void processAck(char *payload, const char *mhSource = NULL)
{
  if (strncmp(payload, "ACK,", 4) != 0) return;
  if (!commandPending) return;

  char *f[5];
  if (splitFields(payload, f, 5) < 5) return;

  trimInPlace(f[1]);
  trimInPlace(f[2]);
  trimInPlace(f[3]);
  trimInPlace(f[4]);

  if (strcmp(f[1], pendingAnimalID) != 0) return;
  if (mhSource != NULL && strcmp(mhSource, pendingAnimalID) != 0) return;

  char *idEnd = NULL;
  unsigned long ackCommandID = strtoul(f[4], &idEnd, 10);
  if (idEnd == f[4] || *idEnd != '\0') return;
  bool knownAttempt = false;
  for (byte i = 0; i < pendingPacketIDCount; i++) {
    if (pendingPacketIDs[i] == ackCommandID) {
      knownAttempt = true;
      break;
    }
  }
  if (!knownAttempt) {
    DBG(F("Ignoring ACK for unknown command packet ID: "));
    DBGLN(ackCommandID);
    return;
  }

  bool validACK = false;
  const char *expectedAction = "";

  if (strncmp(pendingPayload, "LIVE,", 5) == 0)
  {
    expectedAction = strrchr(pendingPayload, ',') + 1;
    if (strcmp(f[2], "LIVE") == 0 && strcmp(f[3], expectedAction) == 0)
    {
      validACK = true;
    }
  }
  else if (strncmp(pendingPayload, "FENCE,", 6) == 0)
  {
    if (strcmp(f[2], "FENCE") == 0 && strcmp(f[3], "OK") == 0)
    {
      validACK = true;
    }
  }

  if (!validACK) return;

  // SUCCESS
  commandPending = false;

  if (strncmp(pendingPayload, "LIVE,", 5) == 0)
  {
    int idx = getAnimalIndex(pendingAnimalID);
    if (idx >= 0)
    {
      if (strcmp(expectedAction, "ON") == 0)
      {
        animalLive[idx] = true;
        pollFailCount[idx] = 0;       // fresh start for this collar
        pollSkipUntil[idx] = 0;
      }
      else
      {
        animalLive[idx] = false;
      }
    }
  }

  DBGLN(F("COMMAND SUCCESS"));
  sendToApp("COMMAND_SUCCESS,", pendingOriginal);
  startNextQueuedCommand();
}

// ============================================================
// 9. POLLING
// ============================================================

bool inCooldown(byte i)
{
  return pollSkipUntil[i] != 0 && (long)(millis() - pollSkipUntil[i]) < 0;
}

void advancePollIndex()
{
  pollIndex++;
  if (pollIndex >= MAX_ANIMAL_NODES) pollIndex = 0;
  lastPollAction = millis();
}

// command = "POLL,A01". Returns false if the animal is unknown.
bool sendPoll(const char *command)
{
  char tmp[48];
  copyStr(tmp, command, sizeof(tmp));

  char *f[3];
  byte n = splitFields(tmp, f, 3);
  if (n < 2) return false;
  trimInPlace(f[1]);

  int idx = getAnimalIndex(f[1]);
  if (idx < 0) return false;

  // Never report success for a request that was not actually transmitted.
  if (pollPending || commandPending || commandQueueCount > 0) return false;

  pollIndex = (byte)idx;
  pollAnimalIndex = idx;

  char payload[16];
  snprintf(payload, sizeof(payload), "POLL,%s", animalIDs[idx]);

  sendMH(animalIDs[idx], nextPacketID(), MAX_HOPS, payload);

  pollPending = true;
  pollSendTime = millis();

  DBG(F("POLL sent to "));
  DBGLN(animalIDs[idx]);
  return true;
}

void updatePollScheduler()
{
  // Do not poll while a command is waiting
  if (commandPending || commandQueueCount > 0) return;

  // Waiting for DATA: check timeout
  if (pollPending)
  {
    if (millis() - pollSendTime >= POLL_TIMEOUT)
    {
      DBGLN(F("POLL timeout"));

      if (pollAnimalIndex >= 0 && pollAnimalIndex < MAX_ANIMAL_NODES)
      {
        byte i = pollAnimalIndex;
        pollFailCount[i]++;
        if (pollFailCount[i] >= POLL_FAIL_LIMIT)
        {
          pollFailCount[i] = 0;
          pollSkipUntil[i] = millis() + POLL_COOLDOWN;
          if (pollSkipUntil[i] == 0) pollSkipUntil[i] = 1;
          DBG(F("No answer from "));
          DBG(animalIDs[i]);
          DBGLN(F(". Skipping for a while."));
        }
      }

      pollPending = false;
      pollAnimalIndex = -1;
      advancePollIndex();
    }
    return;
  }

  // Find the next live animal that is not skipped
  for (byte checked = 0; checked < MAX_ANIMAL_NODES; checked++)
  {
    if (animalLive[pollIndex] && !inCooldown(pollIndex))
    {
      char command[16];
      snprintf(command, sizeof(command), "POLL,%s", animalIDs[pollIndex]);
      sendPoll(command);
      return;
    }

    pollIndex++;
    if (pollIndex >= MAX_ANIMAL_NODES) pollIndex = 0;
  }

  lastPollAction = millis();     // nobody to poll
}

// DATA,A01,3.82,27.68708,85.29596,1331.7,5,1.67,0
void processPollData(char *payload, const char *mhSource = NULL)
{
  if (strncmp(payload, "DATA,", 5) != 0) return;

  char animal[8];
  if (getField(payload + 5, animal, sizeof(animal)) == NULL) return;
  trimInPlace(animal);

  int idx = getAnimalIndex(animal);
  if (idx < 0) return;
  if (mhSource != NULL && strcmp(mhSource, animal) != 0) {
    DBGLN(F("DATA rejected: MH source and payload animal differ"));
    return;
  }

  // Telemetry is always forwarded (even a late answer is useful)
  webSocket.broadcastTXT(payload);

  // Was this the answer we were waiting for?
  if (pollPending && pollAnimalIndex == idx)
  {
    pollPending = false;
    pollAnimalIndex = -1;
    pollFailCount[idx] = 0;
    pollSkipUntil[idx] = 0;
    advancePollIndex();
    DBGLN(F("POLL success"));
  }
  else if (pollFailCount[idx] != 0 || pollSkipUntil[idx] != 0)
  {
    // Collar is alive again
    pollFailCount[idx] = 0;
    pollSkipUntil[idx] = 0;
  }
}

// ============================================================
// 10. ALERT FROM A COLLAR
// ============================================================

// ALERT,A02,EXIT,27.68708,85.29596,1331.7,2026-10-11,12:00:00
void processAlert(const char *payloadIn, unsigned long packetID, byte maxHop,
                  const char *mhSource)
{
  char tmp[PACKET_MAX];
  copyStr(tmp, payloadIn, sizeof(tmp));

  char *f[4];                          // ALERT, animal, type, eventData
  if (splitFields(tmp, f, 4) < 4) return;

  trimInPlace(f[1]);
  trimInPlace(f[2]);
  trimInPlace(f[3]);

  if (strcmp(f[0], "ALERT") != 0) return;
  if (strcmp(f[2], "EXIT") != 0 && strcmp(f[2], "RETURN") != 0) return;

  int idx = getAnimalIndex(f[1]);
  if (idx < 0 || strcmp(mhSource, f[1]) != 0) {
    DBGLN(F("ALERT rejected: unknown animal or source mismatch"));
    return;
  }

  char idText[12];
  snprintf(idText, sizeof(idText), "%lu", packetID);

  // Already handled before? Then only send the ACK again.
  bool repeat = alertSeen(idx, packetID) || isAlertAlreadySaved(f[1], idText);
  if (repeat)
  {
    sendAlertAck(f[1], f[2], packetID, maxHop);
    return;
  }

  bool stored = saveEvent(f[1], idText, f[2], f[3]);
  bool shown = webSocket.connectedClients() > 0;

  // If we could neither save nor show it, do NOT acknowledge.
  // The collar will send it again later.
  if (!stored && !shown)
  {
    DBGLN(F("ALERT not acknowledged (no storage, no app)"));
    return;
  }

  alertRemember(idx, packetID);
  sendAlertAck(f[1], f[2], packetID, maxHop);

  if (shown) webSocket.broadcastTXT(payloadIn);

  DBG(F("ALERT handled: "));
  DBGLN(payloadIn);
}

// ============================================================
// 11. RECEIVING BY LORA
// ============================================================

// MH,packetID,source,destination,hop,maxHop,payload
void processMultiHopPacket(char *packet)
{
  MHPacket mh;
  if (!parseMH(packet, mh)) return;

  // Duplicate check (same sender + same packet number)
  byte src = sourceCode(mh.source);
  bool duplicate = isDuplicatePacket(src, mh.id);
  if (!duplicate) rememberPacket(src, mh.id);

  // ---- Packet is for BASE ----
  if (strcmp(mh.dest, "BASE") == 0)
  {
    if (strncmp(mh.payload, "ACK,", 4) == 0)
    {
      processAck(mh.payload, mh.source);
    }
    else if (strncmp(mh.payload, "DATA,", 5) == 0)
    {
      if (!duplicate) processPollData(mh.payload, mh.source);
    }
    else if (strncmp(mh.payload, "ALERT,", 6) == 0)
    {
      // Repeats are handled inside (so a failed first try is never lost)
      processAlert(mh.payload, mh.id, mh.maxHop, mh.source);
    }
    return;                        // reached destination: never forward
  }

#if BASE_RELAY
  // ---- Base can also relay for other nodes ----
  if (strcmp(mh.source, "BASE") == 0) return;   // never forward our own
  if (duplicate) return;                        // forward only once

  if (mh.hop < mh.maxHop)
  {
    LoRa.beginPacket();

    LoRa.print(F("MH,"));
    LoRa.print(mh.id);
    LoRa.print(',');
    LoRa.print(mh.source);
    LoRa.print(',');
    LoRa.print(mh.dest);
    LoRa.print(',');
    LoRa.print(mh.hop + 1);
    LoRa.print(',');
    LoRa.print(mh.maxHop);
    LoRa.print(',');
    LoRa.print(mh.payload);

    LoRa.endPacket();
    LoRa.receive();
  }
#endif
}

void receiveLoRaPacket()
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
  trimInPlace(rxBuf);

  DBG(F("RX: "));
  DBGLN(rxBuf);

  if (strncmp(rxBuf, "MH,", 3) == 0)
  {
    processMultiHopPacket(rxBuf);
    return;
  }

#if SUPPORT_DIRECT_PACKETS
  // Old style packets without the MH header
  if (strncmp(rxBuf, "ACK,", 4) == 0)
  {
    processAck(rxBuf);
  }
  else if (strncmp(rxBuf, "DATA,", 5) == 0)
  {
    processPollData(rxBuf);
  }
#endif
}

// ============================================================
// 12. WEBSOCKET (Flutter app)
// ============================================================

void sendFailed(uint8_t num, const char *command)
{
  char resp[WS_CMD_MAX + 24];
  snprintf(resp, sizeof(resp), "COMMAND_FAILED,%s", command);
  webSocket.sendTXT(num, resp);
}

float readBaseBattery()
{
  int adc = analogRead(BATTERY_PIN);
  float v = adc * (BATTERY_ADC_REF / 1023.0);
  return v * ((BATTERY_R1 + BATTERY_R2) / BATTERY_R2);
}

// LIVE or FENCE from the app
void handleAppCommand(uint8_t num, const char *command)
{
  char payload[COMMAND_MAX_LEN];
  char animal[8];

  if (!buildPayload(command, payload, sizeof(payload), animal))
  {
    DBGLN(F("Command rejected (not valid)"));
    sendFailed(num, command);
    return;
  }

  // A manual command cancels the automatic poll that is running
  if (pollPending)
  {
    pollPending = false;
    pollAnimalIndex = -1;
    advancePollIndex();
  }

  if (!queueCommand(command, payload))
  {
    DBGLN(F("Command queue full"));
    sendFailed(num, command);
    return;
  }

  startNextQueuedCommand();            // does nothing if one is running

  char resp[WS_CMD_MAX + 24];
  snprintf(resp, sizeof(resp), "COMMAND_SENT,%s", command);
  webSocket.sendTXT(num, resp);
}

void webSocketEvent(uint8_t num, WStype_t type, uint8_t *payload, size_t length)
{
  // ---- Client connected ----
  if (type == WStype_CONNECTED)
  {
    DBGLN(F("WebSocket client connected"));
    webSocket.sendTXT(num, "STATUS,CONNECTED");

#if SEND_BASE_BATTERY
    char b[32];
    snprintf(b, sizeof(b), "BASE_BATTERY,%.2f", readBaseBattery());
    webSocket.sendTXT(num, b);
#endif
    return;
  }

  // ---- Client disconnected ----
  if (type == WStype_DISCONNECTED)
  {
    DBGLN(F("WebSocket client disconnected"));
    return;
  }

  if (type != WStype_TEXT) return;

  // ---- Text message ----
  char command[WS_CMD_MAX];
  if (length >= sizeof(command))
  {
    webSocket.sendTXT(num, "COMMAND_FAILED,TOO_LONG");
    return;
  }
  memcpy(command, payload, length);
  command[length] = '\0';
  trimInPlace(command);

  if (command[0] == '\0') return;

  DBG(F("WS command: "));
  DBGLN(command);

  // GET_EVENTS
  if (strcmp(command, "GET_EVENTS") == 0)
  {
    sendStoredEvents(num);
    return;
  }

  // EVENT_ACK,3
  if (strncmp(command, "EVENT_ACK,", 10) == 0)
  {
    char *idText = command + 10;
    trimInPlace(idText);
    char *idEnd = NULL;
    unsigned long eventID = strtoul(idText, &idEnd, 10);
    while (idEnd != NULL && (*idEnd == ' ' || *idEnd == '\t')) idEnd++;

    if (idText[0] == '\0' || idEnd == idText || *idEnd != '\0' || eventID == 0)
    {
      webSocket.sendTXT(num, "EVENT_ACK_FAILED,INVALID_ID");
      return;
    }

    char resp[40];
    if (acknowledgeEvent(eventID))
    {
      snprintf(resp, sizeof(resp), "EVENT_ACK_SUCCESS,%lu", eventID);
    }
    else
    {
      snprintf(resp, sizeof(resp), "EVENT_ACK_FAILED,%lu", eventID);
    }
    webSocket.sendTXT(num, resp);
    return;
  }

  // POLL,A01 (manual poll)
  if (strncmp(command, "POLL,", 5) == 0)
  {
    if (sendPoll(command))
    {
      char resp[WS_CMD_MAX + 24];
      snprintf(resp, sizeof(resp), "COMMAND_SENT,%s", command);
      webSocket.sendTXT(num, resp);
    }
    else
    {
      sendFailed(num, command);
    }
    return;
  }

  // LIVE / FENCE
  handleAppCommand(num, command);
}

// ============================================================
// 13. SETUP AND LOOP
// ============================================================

void setup()
{
  Serial.begin(9600);
  delay(1000);

  // ---- LittleFS ----
  fsOk = LittleFS.begin();
  if (fsOk)
  {
    recoverEventsFile();
    loadNextEventID();
  }
  else
  {
    DBGLN(F("LittleFS failed. Events will not be saved."));
  }
  loadPacketSequence();

  // ---- WiFi access point ----
  WiFi.mode(WIFI_AP);
  WiFi.softAP(WIFI_SSID, WIFI_PASSWORD);

  // ---- LoRa (no more endless hang) ----
  SPI.begin();
  LoRa.setPins(LORA_SS, LORA_RST, LORA_DIO0);

  bool loraOk = false;
  for (byte i = 0; i < LORA_INIT_TRIES && !loraOk; i++)
  {
    loraOk = LoRa.begin(LORA_FREQUENCY);
    if (!loraOk) delay(500);
  }
  if (!loraOk)
  {
    DBGLN(F("LoRa failed. Restarting."));
    delay(5000);
    ESP.restart();
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

  // ---- WebSocket ----
  webSocket.begin();
  webSocket.onEvent(webSocketEvent);
#if USE_WS_HEARTBEAT
  webSocket.enableHeartbeat(15000, 3000, 2);
#endif

  DBGLN(F("BASE STATION READY"));
}

void loop()
{
  webSocket.loop();
  receiveLoRaPacket();
  updateCommandRetry();
  updatePollScheduler();

#if SEND_BASE_BATTERY
  if (millis() - lastBatteryReport >= BATTERY_REPORT_INTERVAL)
  {
    lastBatteryReport = millis();
    if (webSocket.connectedClients() > 0)
    {
      char b[32];
      snprintf(b, sizeof(b), "BASE_BATTERY,%.2f", readBaseBattery());
      webSocket.broadcastTXT(b);
    }
  }
#endif

#if DEBUG
  // Free memory every minute (to see if memory is leaking)
  if (millis() - lastHeapPrint >= 60000UL)
  {
    lastHeapPrint = millis();
    Serial.print(F("Free heap: "));
    Serial.println(ESP.getFreeHeap());
  }
#endif
}