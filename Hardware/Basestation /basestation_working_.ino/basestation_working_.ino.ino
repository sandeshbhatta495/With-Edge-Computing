#include <SPI.h>
#include <LoRa.h>

#include <ESP8266WiFi.h>
#include <WebSocketsServer.h>

// =====================================================
// WIFI ACCESS POINT
// =====================================================

const char* ssid = "ESP8266_Control";
const char* password = "12345678";

WebSocketsServer webSocket = WebSocketsServer(81);

// =====================================================
// LORA PINS
// =====================================================

#define LORA_SS    15   // D8
#define LORA_RST   16   // D0
#define LORA_DIO0   4   // D2

// =====================================================
// BASE STATION
// =====================================================

const char* BASE_STATION_ID = "BASE01";

const int BATTERY_PIN = A0;

const float R1 = 10000.0;
const float R2 = 10000.0;

float baseStationBattery = 0;

// =====================================================
// ANIMAL CACHE
// =====================================================
//
// The ESP8266 keeps the latest data for each animal.
//
// LoRa reception:
//     LoRa -> update cache
//
// WebSocket:
//     Flutter -> GET_ANIMALS -> send cache
// =====================================================

#define MAX_ANIMALS 5

struct AnimalData
{
  bool valid;

  String deviceID;

  float battery;

  float latitude;
  float longitude;
  float altitude;

  int satellites;

  float speed;

  int movement;

  String timestamp;

  int rssi;
  float snr;

  int packetSize;

  unsigned long lastPacketTime;
};

AnimalData animals[MAX_ANIMALS];

// =====================================================
// TIMING
// =====================================================

unsigned long lastBatteryRead = 0;

const unsigned long BATTERY_INTERVAL = 5000;

// =====================================================
// READ BASE STATION BATTERY
// =====================================================

void ReadBaseStationBattery()
{
  int adcValue = analogRead(BATTERY_PIN);

  float voltageA0 =
    adcValue * (3.2 / 1023.0);

  baseStationBattery =
    voltageA0 * ((R1 + R2) / R2);
}

// =====================================================
// INITIALIZE ANIMAL CACHE
// =====================================================

void InitializeAnimalCache()
{
  for (int i = 0; i < MAX_ANIMALS; i++)
  {
    animals[i].valid = false;

    animals[i].deviceID = "";

    animals[i].battery = 0;

    animals[i].latitude = 0;
    animals[i].longitude = 0;
    animals[i].altitude = 0;

    animals[i].satellites = 0;

    animals[i].speed = 0;

    animals[i].movement = 0;

    animals[i].timestamp = "";

    animals[i].rssi = 0;
    animals[i].snr = 0;

    animals[i].packetSize = 0;

    animals[i].lastPacketTime = 0;
  }
}

// =====================================================
// READ LORA PACKET
// =====================================================

String ReadPacket()
{
  String packet = "";

  while (LoRa.available())
  {
    packet += (char)LoRa.read();
  }

  return packet;
}

// =====================================================
// PARSE LORA PACKET
//
// Expected:
//
// DEVICE_ID,
// BATTERY,
// LATITUDE,
// LONGITUDE,
// ALTITUDE,
// SATELLITES,
// SPEED,
// MOVEMENT,
// TIMESTAMP
// =====================================================

bool ParsePacket(
  String packet,
  int rssi,
  float snr,
  int packetSize
)
{
  packet.trim();

  String value[9];

  int index = 0;

  while (packet.length() > 0 && index < 9)
  {
    int commaIndex =
      packet.indexOf(',');

    if (commaIndex == -1)
    {
      value[index] = packet;

      index++;

      break;
    }

    value[index] =
      packet.substring(
        0,
        commaIndex
      );

    packet =
      packet.substring(
        commaIndex + 1
      );

    index++;
  }

  // Must have exactly 9 fields

  if (index != 9)
  {
    Serial.println(
      "ERROR: Invalid LoRa packet"
    );

    return false;
  }

  // ===================================================
  // PARSE VALUES
  // ===================================================

  String receivedDeviceID =
    value[0];

  float receivedBattery =
    value[1].toFloat();

  float receivedLatitude =
    value[2].toFloat();

  float receivedLongitude =
    value[3].toFloat();

  float receivedAltitude =
    value[4].toFloat();

  int receivedSatellites =
    value[5].toInt();

  float receivedSpeed =
    value[6].toFloat();

  int receivedMovement =
    value[7].toInt();

  String receivedTimestamp =
    value[8];

  // ===================================================
  // FIND EXISTING ANIMAL
  // ===================================================

  int animalIndex = -1;

  for (int i = 0; i < MAX_ANIMALS; i++)
  {
    if (
      animals[i].valid &&
      animals[i].deviceID == receivedDeviceID
    )
    {
      animalIndex = i;
      break;
    }
  }

  // ===================================================
  // IF NOT FOUND, FIND EMPTY SLOT
  // ===================================================

  if (animalIndex == -1)
  {
    for (int i = 0; i < MAX_ANIMALS; i++)
    {
      if (!animals[i].valid)
      {
        animalIndex = i;
        break;
      }
    }
  }

  // ===================================================
  // CACHE FULL
  // ===================================================

  if (animalIndex == -1)
  {
    Serial.println(
      "ERROR: Animal cache is full"
    );

    return false;
  }

  // ===================================================
  // UPDATE CACHE
  // ===================================================

  animals[animalIndex].valid = true;

  animals[animalIndex].deviceID =
    receivedDeviceID;

  animals[animalIndex].battery =
    receivedBattery;

  animals[animalIndex].latitude =
    receivedLatitude;

  animals[animalIndex].longitude =
    receivedLongitude;

  animals[animalIndex].altitude =
    receivedAltitude;

  animals[animalIndex].satellites =
    receivedSatellites;

  animals[animalIndex].speed =
    receivedSpeed;

  animals[animalIndex].movement =
    receivedMovement;

  animals[animalIndex].timestamp =
    receivedTimestamp;

  animals[animalIndex].rssi =
    rssi;

  animals[animalIndex].snr =
    snr;

  animals[animalIndex].packetSize =
    packetSize;

  animals[animalIndex].lastPacketTime =
    millis();

  return true;
}

// =====================================================
// CREATE ANIMAL JSON
// =====================================================

String CreateAnimalJSON(
  const AnimalData& animal
)
{
  String json = "{";

  json += "\"type\":\"animal\"";

  // Device ID

  json += ",\"device_id\":\"";
  json += animal.deviceID;
  json += "\"";

  // Battery

  json += ",\"battery\":";
  json += String(
    animal.battery,
    2
  );

  // Latitude

  json += ",\"latitude\":";
  json += String(
    animal.latitude,
    5
  );

  // Longitude

  json += ",\"longitude\":";
  json += String(
    animal.longitude,
    5
  );

  // Altitude

  json += ",\"altitude\":";
  json += String(
    animal.altitude,
    1
  );

  // Satellites

  json += ",\"satellites\":";
  json += animal.satellites;

  // Speed

  json += ",\"speed\":";
  json += String(
    animal.speed,
    2
  );

  // Movement

  json += ",\"movement\":";
  json += animal.movement;

  // GPS timestamp

  json += ",\"timestamp\":\"";
  json += animal.timestamp;
  json += "\"";

  // LoRa RSSI

  json += ",\"rssi\":";
  json += animal.rssi;

  // LoRa SNR

  json += ",\"snr\":";
  json += String(
    animal.snr,
    2
  );

  // Last packet time on base station

  json += ",\"last_packet_ms\":";
  json += animal.lastPacketTime;

  json += "}";

  return json;
}

// =====================================================
// CREATE BASE STATION JSON
// =====================================================

String CreateBaseStationJSON()
{
  String json = "{";

  json += "\"type\":\"base_station\"";

  // Base station ID

  json += ",\"device_id\":\"";
  json += BASE_STATION_ID;
  json += "\"";

  // Battery

  json += ",\"battery\":";
  json += String(
    baseStationBattery,
    2
  );

  // Uptime

  json += ",\"uptime\":";
  json += millis();

  // Number of cached animals

  int animalCount = 0;

  for (int i = 0; i < MAX_ANIMALS; i++)
  {
    if (animals[i].valid)
    {
      animalCount++;
    }
  }

  json += ",\"animal_count\":";
  json += animalCount;

  json += "}";

  return json;
}

// =====================================================
// SEND ONE ANIMAL TO A CLIENT
// =====================================================

void SendAnimalToClient(
  uint8_t clientNumber,
  const AnimalData& animal
)
{
  String json =
    CreateAnimalJSON(animal);

  webSocket.sendTXT(
    clientNumber,
    json
  );
}

// =====================================================
// SEND ALL ANIMALS TO CLIENT
// =====================================================

void SendAllAnimals(
  uint8_t clientNumber
)
{
  Serial.println();
  Serial.println(
    "GET_ANIMALS received"
  );

  int count = 0;

  for (int i = 0; i < MAX_ANIMALS; i++)
  {
    if (!animals[i].valid)
    {
      continue;
    }

    SendAnimalToClient(
      clientNumber,
      animals[i]
    );

    count++;
  }

  Serial.print(
    "Animals sent: "
  );

  Serial.println(count);
}

// =====================================================
// SEND BASE STATION STATUS TO CLIENT
// =====================================================

void SendBaseStationToClient(
  uint8_t clientNumber
)
{
  ReadBaseStationBattery();

  String json =
    CreateBaseStationJSON();

  webSocket.sendTXT(
    clientNumber,
    json
  );

  Serial.println(
    "Base station status sent"
  );
}

// =====================================================
// SEND ALL CURRENT DATA
//
// Optional convenience command.
//
// Flutter can send:
//
// GET_ALL
// =====================================================

void SendAllData(
  uint8_t clientNumber
)
{
  SendBaseStationToClient(
    clientNumber
  );

  SendAllAnimals(
    clientNumber
  );
}

// =====================================================
// CLEAR ANIMAL CACHE
//
// Flutter command:
//
// CLEAR_ANIMALS
// =====================================================

void ClearAnimalCache()
{
  for (int i = 0; i < MAX_ANIMALS; i++)
  {
    animals[i].valid = false;

    animals[i].deviceID = "";
  }

  Serial.println(
    "Animal cache cleared"
  );
}

// =====================================================
// PRINT ANIMAL CACHE
// =====================================================

void PrintAnimalCache()
{
  Serial.println();
  Serial.println(
    "========== ANIMAL CACHE =========="
  );

  int count = 0;

  for (int i = 0; i < MAX_ANIMALS; i++)
  {
    if (!animals[i].valid)
    {
      continue;
    }

    count++;

    Serial.print(
      "Animal: "
    );

    Serial.println(
      animals[i].deviceID
    );

    Serial.print(
      "Battery: "
    );

    Serial.println(
      animals[i].battery,
      2
    );

    Serial.print(
      "Latitude: "
    );

    Serial.println(
      animals[i].latitude,
      5
    );

    Serial.print(
      "Longitude: "
    );

    Serial.println(
      animals[i].longitude,
      5
    );

    Serial.print(
      "RSSI: "
    );

    Serial.println(
      animals[i].rssi
    );

    Serial.print(
      "SNR: "
    );

    Serial.println(
      animals[i].snr,
      2
    );

    Serial.print(
      "Last packet millis: "
    );

    Serial.println(
      animals[i].lastPacketTime
    );

    Serial.println(
      "--------------------------------"
    );
  }

  Serial.print(
    "Total cached animals: "
  );

  Serial.println(count);

  Serial.println(
    "=================================="
  );
}

// =====================================================
// CHECK LORA
// =====================================================

void CheckLoRa()
{
  int packetSize =
    LoRa.parsePacket();

  if (!packetSize)
  {
    return;
  }

  // ===================================================
  // READ PACKET
  // ===================================================

  String receivedPacket =
    ReadPacket();
  // ===================================================
// COLLAR COMMAND ACK
// ===================================================

if (receivedPacket.startsWith("ACK:"))
{
  Serial.println(F("Collar ACK received:"));
  Serial.println(receivedPacket);

  // Forward ACK to Flutter clients
  String ackJson = "{";
  ackJson += "\"type\":\"ack\",";
  ackJson += "\"message\":\"";
  ackJson += receivedPacket;
  ackJson += "\"";
  ackJson += "}";

  webSocket.broadcastTXT(ackJson);

  return;
}

  Serial.println();
  Serial.println(
    "================================"
  );

  Serial.println(
    "LoRa Packet Received"
  );

  Serial.print(
    "Raw Packet: "
  );

  Serial.println(
    receivedPacket
  );

  // ===================================================
  // GET LORA INFORMATION
  // ===================================================

  int rssi =
    LoRa.packetRssi();

  float snr =
    LoRa.packetSnr();

  // ===================================================
  // PARSE AND CACHE
  // ===================================================

  if (
    ParsePacket(
      receivedPacket,
      rssi,
      snr,
      packetSize
    )
  )
  {
    Serial.println(
      "Packet parsed successfully"
    );

    Serial.print(
      "Device ID: "
    );

    Serial.println(
      animals[0].deviceID
    );

    // Find and print the correct animal
    for (int i = 0; i < MAX_ANIMALS; i++)
    {
      if (
        animals[i].valid &&
        animals[i].lastPacketTime == millis()
      )
      {
        break;
      }
    }

    // Print values from the newest packet
    Serial.print(
      "RSSI: "
    );

    Serial.println(
      rssi
    );

    Serial.print(
      "SNR: "
    );

    Serial.println(
      snr,
      2
    );

    Serial.println(
      "Animal data stored in cache."
    );

    Serial.println(
      "Waiting for Flutter GET_ANIMALS request..."
    );
  }
  else
  {
    Serial.println(
      "Packet parsing FAILED"
    );
  }

  Serial.println(
    "================================"
  );
}

// =====================================================
// SEND COMMAND TO COLLAR
// =====================================================

void SendLoRaCommand(String command)
{
  Serial.println();
  Serial.println("================================");
  Serial.println("Sending LoRa Command");
  Serial.print("Command: ");
  Serial.println(command);
  Serial.println("================================");

  LoRa.beginPacket();
  LoRa.print(command);
  LoRa.endPacket();

  Serial.println("LoRa command sent.");
}
// =====================================================
// WEBSOCKET EVENT
// =====================================================

void webSocketEvent(
  uint8_t num,
  WStype_t type,
  uint8_t *payload,
  size_t length
)
{
  switch (type)
  {
    // =================================================
    // CLIENT CONNECTED
    // =================================================

    case WStype_CONNECTED:
    {
      Serial.print(
        "WebSocket client connected: "
      );

      Serial.println(
        num
      );

      // IMPORTANT:
      //
      // We DO NOT automatically send
      // animal data or base station data.
      //
      // Flutter must explicitly request it.

      Serial.println(
        "Waiting for client request..."
      );

      break;
    }

    // =================================================
    // CLIENT DISCONNECTED
    // =================================================

    case WStype_DISCONNECTED:
    {
      Serial.print(
        "WebSocket client disconnected: "
      );

      Serial.println(
        num
      );

      break;
    }

    // =================================================
    // TEXT MESSAGE
    // =================================================

    case WStype_TEXT:
    {
      String command =
        String(
          (char*)payload
        );

      command.trim();

      Serial.print(
        "WebSocket command: "
      );

      Serial.println(
        command
      );

      // ===============================================
      // GET ANIMALS
      // ===============================================

      if (
        command == "GET_ANIMALS"
      )
      {
        SendAllAnimals(num);
      }

      // ===============================================
      // GET BASE STATION
      // ===============================================

      else if (
        command == "GET_BASE_STATION"
      )
      {
        SendBaseStationToClient(
          num
        );
      }

      // ===============================================
      // GET EVERYTHING
      // ===============================================

      else if (
        command == "GET_ALL"
      )
      {
        SendAllData(num);
      }

      // ===============================================
      // CLEAR ANIMAL CACHE
      // ===============================================

      else if (
        command == "CLEAR_ANIMALS"
      )
      {
        ClearAnimalCache();

        webSocket.sendTXT(
          num,
          "{\"type\":\"ack\",\"command\":\"CLEAR_ANIMALS\",\"success\":true}"
        );
      }

      // ===============================================
      // PRINT CACHE
      // ===============================================

      else if (
        command == "PRINT_CACHE"
      )
      {
        PrintAnimalCache();

        webSocket.sendTXT(
          num,
          "{\"type\":\"ack\",\"command\":\"PRINT_CACHE\",\"success\":true}"
        );
      }

      // ===============================================
      // LED ON
      // ===============================================

      else if (
        command == "LED_ON"
      )
      {
        digitalWrite(
          LED_BUILTIN,
          LOW
        );

        webSocket.sendTXT(
          num,
          "{\"type\":\"ack\",\"command\":\"LED_ON\",\"success\":true}"
        );

        Serial.println(
          "LED ON"
        );
      }

      // ===============================================
      // LED OFF
      // ===============================================

      else if (
        command == "LED_OFF"
      )
      {
        digitalWrite(
          LED_BUILTIN,
          HIGH
        );

        webSocket.sendTXT(
          num,
          "{\"type\":\"ack\",\"command\":\"LED_OFF\",\"success\":true}"
        );

        Serial.println(
          "LED OFF"
        );
      }
      // ===============================================
      // SET COLLAR INTERVAL
      //
      // Flutter command examples:
      //
      // SET_INTERVAL:60000
      // SET_INTERVAL:300000
      // SET_INTERVAL:1800000
      // ===============================================
      
     else if (
      command.startsWith("SET_INTERVAL:")
    )
    {
      Serial.println("Interval configuration requested.");
    
      Serial.print("Forwarding to collar: ");
      Serial.println(command);
    
      SendLoRaCommand(command);
    
      webSocket.sendTXT(
        num,
        "{\"type\":\"ack\",\"command\":\"SET_INTERVAL\",\"success\":true}"
      );
    }

      // ===============================================
      // UNKNOWN COMMAND
      // ===============================================

      else
      {
        Serial.print(
          "Unknown command: "
        );

        Serial.println(
          command
        );

        String response =
          "{\"type\":\"error\",\"message\":\"Unknown command: ";

        response += command;

        response += "\"}";

        webSocket.sendTXT(
          num,
          response
        );
      }

      break;
    }

    default:
      break;
  }
}

// =====================================================
// SETUP
// =====================================================

void setup()
{
  Serial.begin(115200);

  // ===================================================
  // LED
  // ===================================================

  pinMode(
    LED_BUILTIN,
    OUTPUT
  );

  // ESP8266 onboard LED is active LOW

  digitalWrite(
    LED_BUILTIN,
    HIGH
  );

  // ===================================================
  // ANIMAL CACHE
  // ===================================================

  InitializeAnimalCache();

  // ===================================================
  // WIFI AP
  // ===================================================

  WiFi.mode(
    WIFI_AP
  );

  WiFi.softAP(
    ssid,
    password
  );

  Serial.println();

  Serial.println(
    "================================"
  );

  Serial.println(
    "ESP8266 LIVESTOCK BASE STATION"
  );

  Serial.println(
    "================================"
  );

  Serial.print(
    "SSID: "
  );

  Serial.println(
    ssid
  );

  Serial.print(
    "IP Address: "
  );

  Serial.println(
    WiFi.softAPIP()
  );

  // ===================================================
  // LORA
  // ===================================================

  SPI.begin();

  LoRa.setPins(
    LORA_SS,
    LORA_RST,
    LORA_DIO0
  );

  Serial.println();

  Serial.println(
    "Initializing LoRa..."
  );

  if (!LoRa.begin(433E6))
  {
    Serial.println(
      "LoRa initialization FAILED!"
    );

    while (true)
    {
      delay(1000);
    }
  }

  LoRa.setFrequency(
    433E6
  );

  LoRa.setSpreadingFactor(
    7
  );

  LoRa.setSignalBandwidth(
    125E3
  );

  LoRa.setCodingRate4(
    5
  );

  Serial.println(
    "LoRa initialization SUCCESS!"
  );

  // ===================================================
  // BATTERY
  // ===================================================

  ReadBaseStationBattery();

  // ===================================================
  // WEBSOCKET
  // ===================================================

  webSocket.begin();

  webSocket.onEvent(
    webSocketEvent
  );

  Serial.println();

  Serial.println(
    "WebSocket Server Started"
  );

  Serial.println(
    "WebSocket: ws://192.168.4.1:81/"
  );

  Serial.println();

  Serial.println(
    "Base Station Ready!"
  );

  Serial.println(
    "================================"
  );

  Serial.println(
    "Commands:"
  );

  Serial.println(
    "GET_ANIMALS"
  );

  Serial.println(
    "GET_BASE_STATION"
  );

  Serial.println(
    "GET_ALL"
  );

  Serial.println(
    "CLEAR_ANIMALS"
  );

  Serial.println(
    "PRINT_CACHE"
  );

  Serial.println(
    "LED_ON"
  );

  Serial.println(
    "LED_OFF"
  );

  Serial.println(
    "================================"
  );
}

// =====================================================
// LOOP
// =====================================================

void loop()
{
  // ===================================================
  // WEBSOCKET
  // ===================================================

  webSocket.loop();

  // ===================================================
  // LORA
  // ===================================================

  CheckLoRa();

  // ===================================================
  // BATTERY
  //
  // Battery is read locally.
  //
  // It is NOT automatically transmitted.
  // ===================================================

  if (
    millis() - lastBatteryRead >=
    BATTERY_INTERVAL
  )
  {
    lastBatteryRead =
      millis();

    ReadBaseStationBattery();
  }
}
