#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLE2902.h>
#include <atomic>
#include <cstring>
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>

constexpr char kDeviceName[] = "SkinCare-Sim";
constexpr char kServiceUuid[] = "6e400001-b5a3-f393-e0a9-e50e24dcca9e";
constexpr char kWriteUuid[] = "6e400002-b5a3-f393-e0a9-e50e24dcca9e";
constexpr char kNotifyUuid[] = "6e400003-b5a3-f393-e0a9-e50e24dcca9e";

constexpr uint8_t kGetDeviceId[] = {
    0x50, 0x80, 0x01, 0x04, 0x81, 0x00, 0x01, 0xC0, 0xC5,
};

BLECharacteristic* notifyChar = nullptr;
SemaphoreHandle_t notifyMutex = nullptr;
std::atomic<bool> deviceConnected{false};
int battery = 100;

void sendNotification(uint8_t* bytes, size_t length) {
  xSemaphoreTake(notifyMutex, portMAX_DELAY);
  if (deviceConnected.load()) {
    notifyChar->setValue(bytes, length);
    notifyChar->notify();
  }
  xSemaphoreGive(notifyMutex);
}

void sendSimulatedDeviceId() {
  // Simulator-only C0 reply. Verify the field layout against a real device capture.
  // DATA uses a one-byte command length here, including C0 and the ASCII ID.
  uint8_t reply[] = {
      0x50, 0x80, 0x01, 0x0B, 0x91, 0x00, 0x08, 0xC0,
      'S', 'I', 'M', '-', '0', '0', '1', 0x00,
  };

  // XOR CTL through the end of DATA. Store the result in the last byte.
  for (size_t i = 1; i < sizeof(reply) - 1; ++i) {
    reply[sizeof(reply) - 1] ^= reply[i];
  }

  Serial.println("TX simulator-only C0 reply: SIM-001");
  sendNotification(reply, sizeof(reply));
}

class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* server) override {
    deviceConnected.store(true);
    Serial.println("Phone connected");
  }

  void onDisconnect(BLEServer* server) override {
    deviceConnected.store(false);
    Serial.println("Phone disconnected, advertising again");
    BLEDevice::startAdvertising();
  }
};

class WriteCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* characteristic) override {
    auto value = characteristic->getValue();
    if (value.length() == 0) return;

    Serial.print("RX HEX:");
    for (size_t i = 0; i < value.length(); ++i) {
      Serial.printf(" %02X", static_cast<unsigned int>(
          static_cast<uint8_t>(value[i])));
    }
    Serial.println();

    if (value.length() == sizeof(kGetDeviceId) &&
        std::memcmp(value.c_str(), kGetDeviceId, sizeof(kGetDeviceId)) == 0) {
      sendSimulatedDeviceId();
      return;
    }

    // Preserve the original echo for the demo's text commands.
    sendNotification(reinterpret_cast<uint8_t*>(&value[0]), value.length());
  }
};

void setup() {
  Serial.begin(115200);
  notifyMutex = xSemaphoreCreateMutex();
  if (notifyMutex == nullptr) {
    Serial.println("Could not initialize BLE notification mutex");
    return;
  }

  BLEDevice::init(kDeviceName);
  BLEServer* server = BLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());
  BLEService* service = server->createService(kServiceUuid);

  BLECharacteristic* writeChar = service->createCharacteristic(
      kWriteUuid,
      BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR);
  writeChar->setCallbacks(new WriteCallbacks());

  notifyChar = service->createCharacteristic(
      kNotifyUuid, BLECharacteristic::PROPERTY_NOTIFY);
  notifyChar->addDescriptor(new BLE2902());

  service->start();
  BLEDevice::getAdvertising()->addServiceUUID(kServiceUuid);
  BLEDevice::startAdvertising();
  Serial.printf("Advertising as %s\n", kDeviceName);
}

void loop() {
  if (deviceConnected.load()) {
    char status[32];
    snprintf(status, sizeof(status), "STATUS:battery=%d", battery);
    sendNotification(reinterpret_cast<uint8_t*>(status), strlen(status));
    battery = battery > 0 ? battery - 1 : 100;
  }
  delay(2000);
}
