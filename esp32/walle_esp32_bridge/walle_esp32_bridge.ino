// walle_esp32_bridge.ino - FPGA recognition report -> WALL-E robot and a local status terminal, without a PC (contest extension item 3, phase B)
//
// Hardware: ESP32 DevKit V1 (ESP-WROOM-32, 30 pins, CP2102) on the 30P expansion board (V jumper on 3.3V).
//   FPGA J1 pin 1 (V2, UART TX of the FPGA, 3.3 V) -> GPIO16 (RX2), J1 pin 12 (GND) -> GND.
//   Local terminal (all optional, the bridge runs without them):
//     0.96" OLED SSD1306 / SSD1315, I2C 0x3C/0x3D: SDA GPIO21, SCL GPIO22, VCC 3.3 V
//     R / G / B LEDs (through 220 / 100 / 100 ohm to GND): GPIO25 / 26 / 27 - colour present in the FPGA report
//     buzzer module, low-level trigger, VCC 3.3 V: GPIO23 - beep on appear (1) and line crossing (3)
//     MG90S pointer servo, 5 V: GPIO18 - turns towards the x position of the dominant colour
// FPGA report (rtl_custom/uart_report.v, 115200 8N1, one line every 0.2 s):
//   R:OBJ ,X0529,Y0238,A000487,N00000;G:----,X----,Y----,A000000,N00000;B:----,X----,Y----,A000083,N00000;CAM059,DSP061
// Robot: the WALL-E firmware's own LAN control socket ws://<robot>/ws (tools/robot/wali_ws.py): MCP-style tools/call of self.wali.*,
//   {"type":"move","dir":"stop"} for an immediate stop, the text "ping" every 1.5 s. One connection only, re-opened with back-off.
// Rules: the same as tools/robot/robot_rules.py + rules.json (gestures) / rules_drive.json (driving), and the motion queue of
//   tools/robot/walle_bridge.py (one motion at a time, the newest waiting one kept, eye commands at once, stop at once).
// Settings (no passwords in the source): Wi-Fi SSID / password, optional robot IP, minimum target area, rule set, buzzer, servo
//   direction - stored in NVS. No settings, or BOOT held 3 s while running: the ESP32 opens the access point "WALLE-BRIDGE"
//   (password walle1234); http://192.168.4.1 shows the form. The local terminal keeps working in that mode.
//   (BOOT = GPIO0 is a strapping pin: held at power-on it starts the ROM bootloader, so it is only read while running.)
// BOOT short press: gestures <-> driving (saved). Blue LED: fast blink = settings AP, slow blink = waiting for Wi-Fi / robot / FPGA,
//   steady = robot connected and FPGA lines arriving.
#include "driver/gpio.h"
#include "lwip/sockets.h"
#include <WiFi.h>
#include <WebServer.h>
#include <Preferences.h>
#include <ESPmDNS.h>
#include <Wire.h>

static const int PIN_RX = 16, PIN_TX = 17, PIN_LED = 2, PIN_BOOT = 0;
static const int PIN_SDA = 21, PIN_SCL = 22, PIN_LR = 25, PIN_LG = 26, PIN_LB = 27, PIN_BUZ = 23, PIN_SERVO = 18;
static const int PIN_CHECK = 4;                                        // spare input with pull-up, level printed on the status line (wiring checks: 0 = tied to ground)
static const char *AP_SSID = "WALLE-BRIDGE", *AP_PASS = "walle1234";

// types used by functions: declared before the first function, because the Arduino builder puts its generated prototypes there
enum Kind : uint8_t { TOOL, STOP };
struct Cmd { Kind kind; const char *tool; const char *args; bool motion; };   // robot command (rule tables below)
struct Det { bool valid; int x, area, cross; char shape[5]; };               // one colour of an FPGA report line

// ------------------------------------------------------------------ settings
Preferences prefs;
String cfgSsid, cfgPass, cfgRobot;
int cfgMinArea = 4000;
bool driveMode = false, cfgBuzz = true, cfgServoRev = false;

void loadSettings() {
  prefs.begin("bridge", true);
  cfgSsid = prefs.getString("ssid", "");
  cfgPass = prefs.getString("pass", "");
  cfgRobot = prefs.getString("robot", "");
  cfgMinArea = prefs.getInt("minarea", 4000);
  driveMode = prefs.getBool("drive", false);
  cfgBuzz = prefs.getBool("buzz", true);
  cfgServoRev = prefs.getBool("srev", false);
  prefs.end();
}
void saveMode() {
  prefs.begin("bridge", false);
  prefs.putBool("drive", driveMode);
  prefs.end();
}

// ------------------------------------------------------------------ settings portal
WebServer web(80);
bool portal = false;

String htmlEscape(const String &s) {
  String o;
  for (char c : s) {
    if (c == '<') o += "&lt;"; else if (c == '>') o += "&gt;"; else if (c == '"') o += "&quot;"; else if (c == '&') o += "&amp;"; else o += c;
  }
  return o;
}
String opt(const char *v, const char *label, bool sel) { return String("<option value='") + v + "'" + (sel ? " selected" : "") + ">" + label + "</option>"; }
void handleRoot() {
  String h = F("<!doctype html><html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'>"
               "<title>WALL-E bridge</title><style>body{font-family:sans-serif;margin:16px}input,select{width:100%;padding:8px;margin:4px 0 12px}"
               "button{padding:10px 20px}</style></head><body><h3>FPGA → WALL-E 桥接设置</h3><form method='POST' action='/save'>");
  h += "Wi-Fi 名称（与瓦力在同一网络）<input name='ssid' value='" + htmlEscape(cfgSsid) + "'>";
  h += F("Wi-Fi 密码（留空则保持原密码）<input name='pass' type='password' value=''>");
  h += "瓦力 IP（可空，空则自动查找 wali.local）<input name='robot' value='" + htmlEscape(cfgRobot) + "'>";
  h += "最小目标面积（像素）<input name='minarea' type='number' value='" + String(cfgMinArea) + "'>";
  h += "规则<select name='drive'>" + opt("0", "手势（不移动）", !driveMode) + opt("1", "移动（绿行 / 红停 / 蓝退）", driveMode) + "</select>";
  h += "蜂鸣器<select name='buzz'>" + opt("1", "开", cfgBuzz) + opt("0", "关", !cfgBuzz) + "</select>";
  h += "指示舵机方向<select name='srev'>" + opt("0", "正向", !cfgServoRev) + opt("1", "反向", cfgServoRev) + "</select>";
  h += F("<button type='submit'>保存并重启</button></form></body></html>");
  web.send(200, "text/html; charset=utf-8", h);
}
void handleSave() {
  prefs.begin("bridge", false);
  prefs.putString("ssid", web.arg("ssid"));
  if (web.arg("pass").length() > 0) prefs.putString("pass", web.arg("pass"));
  prefs.putString("robot", web.arg("robot"));
  prefs.putInt("minarea", web.arg("minarea").toInt() > 0 ? web.arg("minarea").toInt() : 4000);
  prefs.putBool("drive", web.arg("drive") == "1");
  prefs.putBool("buzz", web.arg("buzz") != "0");
  prefs.putBool("srev", web.arg("srev") == "1");
  prefs.end();
  web.send(200, "text/html; charset=utf-8", "<meta charset='utf-8'>已保存，正在重启……");
  delay(800);
  ESP.restart();
}
void startPortal() {
  portal = true;
  WiFi.mode(WIFI_AP);
  WiFi.softAP(AP_SSID, AP_PASS);
  WiFi.setTxPower(WIFI_POWER_13dBm);                                    // lower transmit peaks (USB-powered board with a servo)
  web.on("/", HTTP_GET, handleRoot);
  web.on("/save", HTTP_POST, handleSave);
  web.begin();
  Serial.printf("settings: connect to %s, open http://%s\n", AP_SSID, WiFi.softAPIP().toString().c_str());
}

// ------------------------------------------------------------------ minimal WebSocket client (RFC 6455, text frames)
WiFiClient tcp;
bool wsUp = false;
uint32_t nextId = 1;
uint32_t lastPing = 0, lastRx = 0;
static const uint32_t WS_DEAD_MS = 6000;
extern uint32_t nextTry, backoff;
uint8_t rxHdr[14];
int rxState = 0, rxNeed = 2, rxHave = 0;
uint64_t rxLen = 0;
String rxText;
bool rxIsText = false;

bool wsConnect(IPAddress ip) {
  if (!tcp.connect(ip, 80, 3000)) return false;
  uint8_t key[16];
  for (int i = 0; i < 16; i++) key[i] = (uint8_t)esp_random();
  static const char *b64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  String k;
  for (int i = 0; i < 16; i += 3) {
    uint32_t v = (uint32_t)key[i] << 16 | (i + 1 < 16 ? key[i + 1] << 8 : 0) | (i + 2 < 16 ? key[i + 2] : 0);
    k += b64[(v >> 18) & 63]; k += b64[(v >> 12) & 63];
    k += (i + 1 < 16) ? b64[(v >> 6) & 63] : '='; k += (i + 2 < 16) ? b64[v & 63] : '=';
  }
  tcp.print("GET /ws HTTP/1.1\r\nHost: " + ip.toString() + "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: " + k +
            "\r\nSec-WebSocket-Version: 13\r\n\r\n");
  uint32_t t0 = millis();
  String resp;
  while (millis() - t0 < 3000) {
    while (tcp.available()) {
      resp += (char)tcp.read();
      if (resp.endsWith("\r\n\r\n")) {
        if (resp.indexOf(" 101 ") < 0) { tcp.stop(); return false; }
        wsUp = true; rxState = 0; rxNeed = 2; rxHave = 0; lastPing = millis(); lastRx = millis();
        return true;
      }
    }
    delay(5);
  }
  tcp.stop();
  return false;
}
void wsSend(const String &s, uint8_t op = 0x1) {
  if (!wsUp) return;
  size_t n = s.length();
  uint8_t h[8];
  int hl = 0;
  h[hl++] = 0x80 | op;
  if (n < 126) h[hl++] = 0x80 | n;
  else { h[hl++] = 0x80 | 126; h[hl++] = n >> 8; h[hl++] = n & 0xFF; }
  uint8_t m[4];
  for (int i = 0; i < 4; i++) m[i] = (uint8_t)esp_random();
  uint8_t *buf = (uint8_t *)malloc(hl + 4 + n);
  if (!buf) return;
  memcpy(buf, h, hl);
  memcpy(buf + hl, m, 4);
  for (size_t i = 0; i < n; i++) buf[hl + 4 + i] = (uint8_t)s[i] ^ m[i & 3];
  if (tcp.write(buf, hl + 4 + n) != hl + 4 + n) wsUp = false;
  free(buf);
}

// ------------------------------------------------------------------ robot commands and the motion queue
#define N(a) (sizeof(a) / sizeof(a[0]))

uint32_t busyId = 0, busyUntil = 0;
bool havePending = false;
static const Cmd G_ARMS_DOWN[] = {{TOOL, "self.wali.servo", "{\"servo\":\"left_arm\",\"angle\":120}", false}, {TOOL, "self.wali.servo", "{\"servo\":\"right_arm\",\"angle\":120}", false}};
static const uint32_t ARMS_UP_MS = 1800;
uint32_t armsDownAt = 0;                                                // 0 = no lowering scheduled
Cmd pending;
String lastCmd = "-", lastEvent = "-";

String cmdName(const Cmd &c) {                                          // "self.wali.move" + {"direction":"left",..} -> "MOVE LEFT"
  if (c.kind == STOP) return "STOP";
  String t = c.tool, a = c.args;
  t.replace("self.wali.", "");
  int p = a.lastIndexOf(":\"");
  if (p >= 0) t += " " + a.substring(p + 2, a.indexOf('"', p + 2));
  return t;
}
uint32_t sendCmd(const Cmd &c) {
  if (c.kind == STOP) { wsSend("{\"type\":\"move\",\"dir\":\"stop\",\"speed\":40}"); return 0; }
  uint32_t id = nextId++;
  wsSend(String("{\"type\":\"mcp\",\"payload\":{\"jsonrpc\":\"2.0\",\"id\":") + id +
         ",\"method\":\"tools/call\",\"params\":{\"name\":\"" + c.tool + "\",\"arguments\":" + c.args + "}}}");
  return id;
}
void runMotion(const Cmd &c) {
  busyId = sendCmd(c);
  busyUntil = millis() + 8000;
  Serial.printf("-> %s %s\n", c.tool, c.args);
}
void doCmd(const Cmd &c) {
  if (!wsUp) { lastCmd = "OFF " + cmdName(c); Serial.printf("robot offline, dropped %s\n", c.kind == STOP ? "stop" : c.tool); return; }
  lastCmd = cmdName(c);
  if (c.kind == STOP) { havePending = false; sendCmd(c); Serial.println("-> stop"); return; }
  if (c.motion) {
    if (busyId && (int32_t)(millis() - busyUntil) < 0) { pending = c; havePending = true; return; }
    runMotion(c);
  } else {
    sendCmd(c);
    Serial.printf("-> %s %s\n", c.tool, c.args);
  }
}
void doList(const Cmd *l, size_t n) { for (size_t i = 0; i < n; i++) doCmd(l[i]); }
void pollQueue() {
  if (armsDownAt && (int32_t)(millis() - armsDownAt) >= 0) { armsDownAt = 0; doList(G_ARMS_DOWN, N(G_ARMS_DOWN)); }
  if (busyId && (int32_t)(millis() - busyUntil) >= 0) busyId = 0;
  if (!busyId && havePending && wsUp) { havePending = false; runMotion(pending); }
}
void onRobotText(const String &t) {
  int p = t.indexOf("\"id\":");
  if (p >= 0) {
    uint32_t id = t.substring(p + 5).toInt();
    if (id && id == busyId) busyId = 0;
  }
  if (t != "pong") Serial.println("<- " + t.substring(0, 120));
}
void wsPoll() {
  if (!wsUp) return;
  if (!tcp.connected()) { wsUp = false; Serial.println("robot: connection closed"); return; }
  if (millis() - lastPing > 1500) { lastPing = millis(); wsSend("ping"); }
  if (millis() - lastRx > WS_DEAD_MS) {                 // the robot answers every ping with "pong": silence = it was switched off
    tcp.stop(); wsUp = false; nextTry = 0; backoff = 1000;
    Serial.println("robot: no reply for 6 s, connection dropped (robot off?)");
    lastEvent = "ROBOT LOST";
    return;
  }
  while (tcp.available()) {
    uint8_t b = tcp.read();
    lastRx = millis();
    if (rxState == 0) {                                   // header
      rxHdr[rxHave++] = b;
      if (rxHave == 2) {
        int l = rxHdr[1] & 0x7F;
        rxIsText = (rxHdr[0] & 0x0F) == 0x1;
        rxNeed = 2 + (l == 126 ? 2 : l == 127 ? 8 : 0) + ((rxHdr[1] & 0x80) ? 4 : 0);
      }
      if (rxHave >= 2 && rxHave == rxNeed) {
        int l = rxHdr[1] & 0x7F;
        rxLen = l;
        if (l == 126) rxLen = (rxHdr[2] << 8) | rxHdr[3];
        if (l == 127) { rxLen = 0; for (int i = 0; i < 8; i++) rxLen = (rxLen << 8) | rxHdr[2 + i]; }
        rxText = "";
        rxHave = 0;
        rxState = rxLen ? 1 : 0;
        if (!rxLen && rxIsText) onRobotText(rxText);
      }
    } else {                                              // payload (server frames are not masked)
      if (rxText.length() < 600) rxText += (char)b;
      if (--rxLen == 0) {
        rxState = 0;
        if (rxIsText) onRobotText(rxText);
      }
    }
  }
}

// ------------------------------------------------------------------ local status terminal: OLED, R/G/B LEDs, buzzer, pointer servo
uint8_t oledAddr = 0;
uint8_t fb[8][128];
static const uint8_t FONT[][5] = {                                       // ASCII 32..95, 5 x 7, one byte per column, LSB = top row
  {0x00,0x00,0x00,0x00,0x00}, {0x00,0x00,0x5F,0x00,0x00}, {0x00,0x07,0x00,0x07,0x00}, {0x14,0x7F,0x14,0x7F,0x14},   //   ! " #
  {0x24,0x2A,0x7F,0x2A,0x12}, {0x23,0x13,0x08,0x64,0x62}, {0x36,0x49,0x55,0x22,0x50}, {0x00,0x05,0x03,0x00,0x00},   // $ % & '
  {0x00,0x1C,0x22,0x41,0x00}, {0x00,0x41,0x22,0x1C,0x00}, {0x14,0x08,0x3E,0x08,0x14}, {0x08,0x08,0x3E,0x08,0x08},   // ( ) * +
  {0x00,0x50,0x30,0x00,0x00}, {0x08,0x08,0x08,0x08,0x08}, {0x00,0x60,0x60,0x00,0x00}, {0x20,0x10,0x08,0x04,0x02},   // , - . /
  {0x3E,0x51,0x49,0x45,0x3E}, {0x00,0x42,0x7F,0x40,0x00}, {0x42,0x61,0x51,0x49,0x46}, {0x21,0x41,0x45,0x4B,0x31},   // 0 1 2 3
  {0x18,0x14,0x12,0x7F,0x10}, {0x27,0x45,0x45,0x45,0x39}, {0x3C,0x4A,0x49,0x49,0x30}, {0x01,0x71,0x09,0x05,0x03},   // 4 5 6 7
  {0x36,0x49,0x49,0x49,0x36}, {0x06,0x49,0x49,0x29,0x1E}, {0x00,0x36,0x36,0x00,0x00}, {0x00,0x56,0x36,0x00,0x00},   // 8 9 : ;
  {0x08,0x14,0x22,0x41,0x00}, {0x14,0x14,0x14,0x14,0x14}, {0x00,0x41,0x22,0x14,0x08}, {0x02,0x01,0x51,0x09,0x06},   // < = > ?
  {0x32,0x49,0x79,0x41,0x3E}, {0x7E,0x11,0x11,0x11,0x7E}, {0x7F,0x49,0x49,0x49,0x36}, {0x3E,0x41,0x41,0x41,0x22},   // @ A B C
  {0x7F,0x41,0x41,0x22,0x1C}, {0x7F,0x49,0x49,0x49,0x41}, {0x7F,0x09,0x09,0x09,0x01}, {0x3E,0x41,0x49,0x49,0x7A},   // D E F G
  {0x7F,0x08,0x08,0x08,0x7F}, {0x00,0x41,0x7F,0x41,0x00}, {0x20,0x40,0x41,0x3F,0x01}, {0x7F,0x08,0x14,0x22,0x41},   // H I J K
  {0x7F,0x40,0x40,0x40,0x40}, {0x7F,0x02,0x0C,0x02,0x7F}, {0x7F,0x04,0x08,0x10,0x7F}, {0x3E,0x41,0x41,0x41,0x3E},   // L M N O
  {0x7F,0x09,0x09,0x09,0x06}, {0x3E,0x41,0x51,0x21,0x5E}, {0x7F,0x09,0x19,0x29,0x46}, {0x46,0x49,0x49,0x49,0x31},   // P Q R S
  {0x01,0x01,0x7F,0x01,0x01}, {0x3F,0x40,0x40,0x40,0x3F}, {0x1F,0x20,0x40,0x20,0x1F}, {0x3F,0x40,0x38,0x40,0x3F},   // T U V W
  {0x63,0x14,0x08,0x14,0x63}, {0x07,0x08,0x70,0x08,0x07}, {0x61,0x51,0x49,0x45,0x43}, {0x00,0x7F,0x41,0x41,0x00},   // X Y Z [
  {0x02,0x04,0x08,0x10,0x20}, {0x00,0x41,0x41,0x7F,0x00}, {0x04,0x02,0x01,0x02,0x04}, {0x40,0x40,0x40,0x40,0x40},   // \ ] ^ _
};

void oledCmd(const uint8_t *c, int n) {
  Wire.beginTransmission(oledAddr);
  Wire.write(0x00);
  Wire.write(c, n);
  Wire.endTransmission();
}
void oledInit() {
  static const uint8_t ADDRS[] = {0x3C, 0x3D};
  Wire.begin(PIN_SDA, PIN_SCL, 400000);
  for (uint8_t a : ADDRS) { Wire.beginTransmission(a); if (Wire.endTransmission() == 0) { oledAddr = a; break; } }
  if (!oledAddr) { Serial.println("oled: not found"); return; }
  // SSD1306 / SSD1315 128 x 64, page addressing (also what an SH1106 understands)
  static const uint8_t INIT[] = {0xAE, 0xD5, 0x80, 0xA8, 0x3F, 0xD3, 0x00, 0x40, 0x8D, 0x14, 0x20, 0x02, 0xA1, 0xC8,
                                 0xDA, 0x12, 0x81, 0xCF, 0xD9, 0xF1, 0xDB, 0x40, 0xA4, 0xA6, 0xAF};
  oledCmd(INIT, sizeof(INIT));
  Serial.printf("oled: 0x%02X\n", oledAddr);
}
void oledText(int row, const String &s) {                               // one row of 21 characters, shown in upper case
  memset(fb[row], 0, 128);
  for (int i = 0; i < 21 && i < (int)s.length(); i++) {
    char c = toupper(s[i]);
    if (c < 32 || c > 95) c = '?';
    memcpy(&fb[row][i * 6], FONT[c - 32], 5);
  }
}
void oledFlush() {
  for (int p = 0; p < 8; p++) {
    uint8_t c[3] = {(uint8_t)(0xB0 | p), 0x00, 0x10};
    oledCmd(c, 3);
    for (int x = 0; x < 128; x += 32) {                                 // the Wire buffer holds 128 bytes: send 32 at a time
      Wire.beginTransmission(oledAddr);
      Wire.write(0x40);
      Wire.write(&fb[p][x], 32);
      Wire.endTransmission();
    }
  }
}

int buzzLeft = 0;
uint32_t buzzNext = 0;
float servoPos = 90, servoGoal = 90;
uint32_t servoNext = 0;

void buzzer(bool on) { ledcWrite(PIN_BUZ, on ? 128 : 255); }            // 2.7 kHz square wave / constant high (low-level trigger: silent)
void beep(int n) { if (cfgBuzz && !buzzLeft) { buzzLeft = 2 * n; buzzNext = millis(); } }
// the servo gets its PWM only SERVO_START_MS after reset: its start-up current on top of the Wi-Fi start tripped the brownout detector in a reset loop
// (2026-10-31, servo on the 5 V pin of a USB-powered board); without a pulse train the servo stays limp and draws almost nothing
static const uint32_t SERVO_START_MS = 6000;
bool servoOn = false;
void servoWrite(float deg) { if (servoOn) ledcWrite(PIN_SERVO, (uint32_t)((500 + deg * 2000 / 180) * 16384 / 20000)); }   // 0.5-2.5 ms of 20 ms, 14 bit
void servoStart() {
  ledcAttachChannel(PIN_SERVO, 50, 14, 0);                              // channels 0 and 2: separate LEDC timers for 50 Hz and 2.7 kHz
  servoOn = true;
  servoWrite(servoPos);
  Serial.println("servo: on");
}
void localInit() {
  pinMode(PIN_LR, OUTPUT); pinMode(PIN_LG, OUTPUT); pinMode(PIN_LB, OUTPUT);
  for (int p : {PIN_LR, PIN_LG, PIN_LB}) gpio_set_drive_capability((gpio_num_t)p, GPIO_DRIVE_CAP_0);   // weakest drive: limits the current if an LED has no series resistor
  pinMode(PIN_BUZ, OUTPUT); digitalWrite(PIN_BUZ, HIGH);
  ledcAttachChannel(PIN_BUZ, 2700, 8, 2);
  buzzer(false);
  oledInit();
}

// ------------------------------------------------------------------ rule tables (tools/robot/rules.json, rules_drive.json)
static const Cmd STOP_C = {STOP, "", "", false};
static const Cmd G_APP_R[] = {{TOOL, "self.wali.eye", "{\"action\":\"color\",\"color\":\"#FF0000\"}", false}, {TOOL, "self.wali.action", "{\"action\":\"wave\"}", true}};
static const Cmd G_APP_G[] = {{TOOL, "self.wali.eye", "{\"action\":\"color\",\"color\":\"#00FF00\"}", false}, {TOOL, "self.wali.action", "{\"action\":\"nod\"}", true}};
static const Cmd G_APP_B[] = {{TOOL, "self.wali.eye", "{\"action\":\"color\",\"color\":\"#0040FF\"}", false}, {TOOL, "self.wali.eye", "{\"action\":\"pulse\",\"pulse_times\":3}", false},
                               {TOOL, "self.wali.servo", "{\"servo\":\"left_arm\",\"angle\":60}", false}, {TOOL, "self.wali.servo", "{\"servo\":\"right_arm\",\"angle\":60}", false}};
// blue: eyes blue + 3 pulses + both arms up, lowered again ARMS_UP_MS later (no shake_head: the head only tilts; no mood: some moods drive the wheels)
static const Cmd G_LEFT[] = {{TOOL, "self.wali.action", "{\"action\":\"arm_left\"}", true}};
static const Cmd G_RIGHT[] = {{TOOL, "self.wali.action", "{\"action\":\"arm_right\"}", true}};
static const Cmd G_CROSS[] = {{TOOL, "self.wali.eye", "{\"action\":\"flash\"}", false}};
static const Cmd G_LOST[] = {{TOOL, "self.wali.mood", "{\"mood\":\"neutral\"}", true}};
static const Cmd D_APP_R[] = {STOP_C, {TOOL, "self.wali.eye", "{\"action\":\"color\",\"color\":\"#FF0000\"}", false}};
static const Cmd D_APP_G[] = {{TOOL, "self.wali.eye", "{\"action\":\"color\",\"color\":\"#00FF00\"}", false}};
static const Cmd D_APP_B[] = {{TOOL, "self.wali.eye", "{\"action\":\"color\",\"color\":\"#0040FF\"}", false}};
static const Cmd D_CROSS[] = {{TOOL, "self.wali.eye", "{\"action\":\"flash\"}", false}};
static const Cmd D_LOST[] = {STOP_C, {TOOL, "self.wali.eye", "{\"action\":\"mood\"}", false}};
static const Cmd D_G_LEFT = {TOOL, "self.wali.move", "{\"direction\":\"left\",\"speed\":40,\"duration\":500}", true};
static const Cmd D_G_CENTRE = {TOOL, "self.wali.move", "{\"direction\":\"forward\",\"speed\":40,\"duration\":700}", true};
static const Cmd D_G_RIGHT = {TOOL, "self.wali.move", "{\"direction\":\"right\",\"speed\":40,\"duration\":500}", true};
static const Cmd D_B_BACK = {TOOL, "self.wali.move", "{\"direction\":\"backward\",\"speed\":40,\"duration\":600}", true};

// ------------------------------------------------------------------ report parser and rules (tools/robot/robot_rules.py)
static const int APPEAR = 2, LOST = 10, LEFT_X = 520, RIGHT_X = 760, HYST = 30;
static const uint32_t MIN_GAP = 1500, DRIVE_PERIOD = 600;
int dom = -1, cand = -1, candN = 0, side = -1, noneLines = 0;          // side: 0 left 1 centre 2 right
int sideCand = -1, sideN = 0;                                           // a new side must be seen in SIDE_N reports in a row (YOLO box centres jitter)
uint32_t appearAt = 0;                                                  // side gestures wait APPEAR_HOLD after an appear, so the colour gesture is not replaced
static const int SIDE_N = 2;
static const uint32_t APPEAR_HOLD = 2500;
bool anySeen = false;
long lastCross[3] = {-1, -1, -1};
uint32_t lastEv[5] = {0, 0, 0, 0, 0};                                   // appear cross side lost drive
bool evUsed[5] = {false, false, false, false, false};
uint32_t lastLine = 0, lineCount = 0;
uint32_t rxBytes = 0, badLines = 0;                                     // wiring check without the OLED: raw bytes and lines that did not parse
String lastRaw;
Det cur[3];
int camFps = -1, dspFps = -1;

bool parseField(const char *s, char tag, int digits, int &v) {          // "X0529" -> 529, "X----" -> -1
  if (s[0] != tag) return false;
  v = 0;
  for (int i = 1; i <= digits; i++) {
    if (s[i] == '-') { v = -1; continue; }
    if (s[i] < '0' || s[i] > '9') return false;
    v = v * 10 + (s[i] - '0');
  }
  return true;
}
bool parseLine(const String &ln, Det d[3]) {
  const char *tags = "RGB";
  for (int c = 0; c < 3; c++) {
    char key[3] = {tags[c], ':', 0};
    int p = ln.indexOf(key);
    if (p < 0 || ln.length() < (unsigned)(p + 33)) return false;
    const char *s = ln.c_str() + p + 2;                                  // SHAP,Xdddd,Ydddd,Adddddd,Nddddd
    bool noShape = strncmp(s, "----", 4) == 0;
    int x, y, a, n;
    if (!parseField(s + 5, 'X', 4, x) || !parseField(s + 11, 'Y', 4, y) || !parseField(s + 17, 'A', 6, a) || !parseField(s + 25, 'N', 5, n)) return false;
    d[c] = {!noShape && x >= 0 && a >= cfgMinArea, x, a, n};
    memcpy(d[c].shape, s, 4);
    d[c].shape[4] = 0;
  }
  int q = ln.indexOf("CAM");
  if (q >= 0) camFps = ln.substring(q + 3, q + 6).toInt();
  q = ln.indexOf("DSP");
  if (q >= 0) dspFps = ln.substring(q + 3, q + 6).toInt();
  return true;
}
// YOLO pages of the FPGA (yolo_top modes 1, 2): every 200 ms "Y <n:1 hex> <frame:4 hex> <lat:2 hex>" then n lines "<cls><score:2 hex> <x0> <y0> <x1> <y1>"
// (3 hex digits each, 1280 x 720 pixels; class 0 red, 1 green, 2 blue). A complete report becomes one Det[3] like a traditional line: per class the
// highest-scoring box, x = box centre, area = box area. YOLO has no crossing counter (cross = -1: no crossing events from YOLO pages).
int yN = -1, yGot = 0, yScore[3];
Det yd[3];
bool yoloSrc = false;                                                   // the last parsed report came from a YOLO page
int hexv(const char *s, int n) {
  int v = 0;
  for (int i = 0; i < n; i++) {
    char c = s[i];
    int d = (c >= '0' && c <= '9') ? c - '0' : (c >= 'A' && c <= 'F') ? c - 'A' + 10 : -1;
    if (d < 0) return -1;
    v = v * 16 + d;
  }
  return v;
}
// 0: not a YOLO line, 1: consumed (report not complete yet), 2: report complete -> d[]
int yoloLine(const String &ln, Det d[3]) {
  const char *s = ln.c_str();
  if (ln.length() == 11 && s[0] == 'Y' && s[1] == ' ' && s[3] == ' ' && s[8] == ' ') {
    int n = hexv(s + 2, 1);
    if (n < 0 || hexv(s + 4, 4) < 0) return 0;
    yN = n; yGot = 0;
    for (int c = 0; c < 3; c++) { yd[c] = {false, -1, 0, -1}; strcpy(yd[c].shape, "----"); yScore[c] = -1; }
  }
  else if (ln.length() == 19 && yN > yGot && s[3] == ' ' && s[7] == ' ' && s[11] == ' ' && s[15] == ' ') {
    int c = hexv(s, 1), sc = hexv(s + 1, 2), x0 = hexv(s + 4, 3), y0 = hexv(s + 8, 3), x1 = hexv(s + 12, 3), y1 = hexv(s + 16, 3);
    if (c < 0 || c > 2 || sc < 0 || x0 < 0 || y0 < 0 || x1 < x0 || y1 < y0) { yN = -1; return 0; }
    if (sc > yScore[c]) {
      int a = (x1 - x0) * (y1 - y0);
      yScore[c] = sc;
      yd[c] = {a >= cfgMinArea, (x0 + x1) / 2, a, -1};
      strcpy(yd[c].shape, "YOLO");
    }
    yGot++;
  }
  else { yN = -1; return 0; }
  if (yGot < yN) return 1;
  yN = -1;
  memcpy(d, yd, sizeof(yd));
  return 2;
}
bool gapOk(int ev) {
  uint32_t now = millis();
  if (evUsed[ev] && now - lastEv[ev] < MIN_GAP) return false;
  lastEv[ev] = now; evUsed[ev] = true;
  return true;
}
void decide(Det d[3]) {
  int best = -1;
  for (int c = 0; c < 3; c++) if (d[c].valid && (best < 0 || d[c].area > d[best].area)) best = c;
  if (best >= 0 && best != dom) {
    if (dom >= 0 && d[dom].valid && d[best].area * 2 < d[dom].area * 3) { cand = -1; candN = 0; }   // new colour must be 1.5x larger
    else {
      candN = (cand == best) ? candN + 1 : 1;
      cand = best;
      if (candN >= APPEAR) {
        dom = best; cand = -1; candN = 0; appearAt = millis();
        Serial.printf("event: appear %c\n", "RGB"[dom]);
        lastEvent = String("APPEAR ") + "RGB"[dom];
        beep(1);
        if (gapOk(0)) {
          if (!driveMode) { if (dom == 0) doList(G_APP_R, N(G_APP_R)); else if (dom == 1) doList(G_APP_G, N(G_APP_G)); else { doList(G_APP_B, N(G_APP_B)); armsDownAt = millis() + ARMS_UP_MS; if (!armsDownAt) armsDownAt = 1; } }
          else            { if (dom == 0) doList(D_APP_R, N(D_APP_R)); else if (dom == 1) doList(D_APP_G, N(D_APP_G)); else doList(D_APP_B, N(D_APP_B)); }
        }
      }
    }
  } else if (best == dom) { cand = -1; candN = 0; }
  for (int c = 0; c < 3; c++) {
    if (c == dom && lastCross[c] >= 0 && d[c].cross > lastCross[c]) {
      Serial.printf("event: cross %c\n", "RGB"[c]);
      lastEvent = String("CROSS ") + "RGB"[c];
      beep(3);
      if (gapOk(1)) { if (driveMode) doList(D_CROSS, N(D_CROSS)); else doList(G_CROSS, N(G_CROSS)); }
    }
    lastCross[c] = d[c].cross;
  }
  if (dom >= 0 && d[dom].valid) {
    int x = d[dom].x, s = side, hy = yoloSrc ? 2 * HYST : HYST;
    if (x < LEFT_X - (side == 0 ? hy : 0)) s = 0;
    else if (x > RIGHT_X + (side == 2 ? hy : 0)) s = 2;
    else if ((x >= LEFT_X + hy && x <= RIGHT_X - hy) || side < 0) s = 1;
    if (s != side && side >= 0) {                                       // debounce: the new side must hold for SIDE_N reports
      sideN = (sideCand == s) ? sideN + 1 : 1;
      sideCand = s;
      if (sideN < SIDE_N) s = side;
    }
    if (s == side) { sideCand = -1; sideN = 0; }
    if (s != side) {
      bool ok = true;
      if (!driveMode && s != 1) ok = millis() - appearAt >= APPEAR_HOLD && gapOk(2);
      if (ok) {
        side = s;
        Serial.printf("event: side %d\n", side);
        lastEvent = side == 0 ? "SIDE LEFT" : side == 2 ? "SIDE RIGHT" : "SIDE CENTRE";
        if (!driveMode) { if (side == 0) doList(G_LEFT, N(G_LEFT)); else if (side == 2) doList(G_RIGHT, N(G_RIGHT)); }
      }
    }
    if (driveMode && (dom == 1 || dom == 2)) {
      uint32_t now = millis();
      if (!evUsed[4] || now - lastEv[4] >= DRIVE_PERIOD) {
        lastEv[4] = now; evUsed[4] = true;
        if (dom == 1) doCmd(side == 0 ? D_G_LEFT : side == 2 ? D_G_RIGHT : D_G_CENTRE);
        else doCmd(D_B_BACK);
      }
    }
  }
  bool any = d[0].valid || d[1].valid || d[2].valid;
  if (any) { noneLines = 0; anySeen = true; }
  else if (++noneLines == LOST && anySeen) {
    anySeen = false; side = -1; dom = -1; cand = -1; candN = 0;
    Serial.println("event: lost");
    lastEvent = "LOST";
    if (gapOk(3)) { if (driveMode) doList(D_LOST, N(D_LOST)); else doList(G_LOST, N(G_LOST)); }
  }
}

// ------------------------------------------------------------------ local terminal update
uint32_t oledNext = 0, rateT = 0, rateN = 0, lps = 0, statT = 0;
Det shown[3];
uint32_t shownAt[3] = {0, 0, 0};
static const uint32_t SHOW_HOLD_MS = 800;

void localPoll(uint32_t now) {
  bool fresh = lineCount && now - lastLine < 1000;
  // display hold: a target the FPGA misses in one or two reports (backlight, YOLO score just under the threshold) keeps its LED and OLED row for
  // SHOW_HOLD_MS, so the indicators follow the object instead of flickering. The robot rules still use the raw reports.
  for (int c = 0; c < 3; c++) if (fresh && cur[c].x >= 0) { shown[c] = cur[c]; shownAt[c] = now; }
  bool held[3];
  for (int c = 0; c < 3; c++) held[c] = shownAt[c] && now - shownAt[c] < SHOW_HOLD_MS;
  digitalWrite(PIN_LR, held[0] && shown[0].valid);
  digitalWrite(PIN_LG, held[1] && shown[1].valid);
  digitalWrite(PIN_LB, held[2] && shown[2].valid);
  if (buzzLeft && (int32_t)(now - buzzNext) >= 0) { buzzLeft--; buzzer(buzzLeft & 1); buzzNext = now + 70; }
  if (!servoOn && now >= SERVO_START_MS) servoStart();
  if ((int32_t)(now - servoNext) >= 0) {                                // pointer: 30..150 degrees across the image, 125 deg/s at most
    servoNext = now + 20;
    if (fresh && dom >= 0 && cur[dom].valid) {
      float a = cur[dom].x * 120.0f / 1280;
      servoGoal = cfgServoRev ? 30 + a : 150 - a;
    } else if (!anySeen) servoGoal = 90;
    float e = servoGoal - servoPos;
    if (e > 1 || e < -1) { servoPos += e > 2.5f ? 2.5f : e < -2.5f ? -2.5f : e; servoWrite(servoPos); }
  }
  if (now - rateT >= 1000) { lps = lineCount - rateN; rateN = lineCount; rateT = now; }
  if (now - statT >= 5000) {                                            // USB status line every 5 s: lets the PC check the FPGA wire with no OLED fitted
    statT = now;
    Serial.printf("fpga: %u lines/s, %u bytes, %u unparsed, cam %d dsp %d, d4 %d, wifi %d, robot %d%s | %s\n", (unsigned)lps, (unsigned)rxBytes, (unsigned)badLines, camFps, dspFps,
                  digitalRead(PIN_CHECK), WiFi.status() == WL_CONNECTED, wsUp, yoloSrc ? ", yolo" : "", lastRaw.c_str());
  }
  if (!oledAddr || (int32_t)(now - oledNext) < 0) return;
  oledNext = now + 250;
  oledText(0, String(driveMode ? "DRIVE" : "GESTURE") + (portal ? "   SETUP" : wsUp ? "   ROBOT OK" : "   ROBOT --"));
  if (portal) oledText(1, "AP WALLE-BRIDGE");
  else if (WiFi.status() == WL_CONNECTED) oledText(1, "IP " + WiFi.localIP().toString());
  else oledText(1, "WIFI " + cfgSsid + " ...");
  if (fresh && yoloSrc) oledText(2, "FPGA " + String(lps) + "L/S YOLO");
  else if (fresh) oledText(2, "FPGA " + String(lps) + "L/S CAM" + camFps + " DSP" + dspFps);
  else oledText(2, "FPGA NO DATA");
  for (int c = 0; c < 3; c++) {
    String s = String(c == dom ? ">" : " ") + "RGB"[c] + " ";
    if (!held[c]) s += "--";
    else s += String(shown[c].shape) + " X" + shown[c].x + " A" + shown[c].area;
    oledText(3 + c, s);
  }
  oledText(6, "EV " + lastEvent);
  oledText(7, "> " + lastCmd);
  oledFlush();
}

// ------------------------------------------------------------------ network
uint32_t nextTry = 0, backoff = 1000;
IPAddress robotIp;

// is there a WALL-E console ("WALI" in the page) at this address? short timeouts: used by the subnet scan
bool isRobot(IPAddress ip, int ms) {
  WiFiClient c;
  if (!c.connect(ip, 80, ms)) return false;
  c.print("GET / HTTP/1.0\r\n\r\n");
  uint32_t t = millis();
  String b;
  // read window 1.5 s: the robot's page took ~0.7 s on 2026-10-31
  while (millis() - t < 1500 && b.length() < 1500) { while (c.available()) b += (char)c.read(); if (!c.connected() && !c.available()) break; delay(2); }
  c.stop();
  return b.indexOf("WALI") >= 0;
}
// robot address: the configured IP, else the last address that worked (NVS "lastip"), else mDNS wali.local, else a scan of the /24 subnet
// hosts of our /24 with TCP port 80 open: non-blocking connects, SCAN_BATCH addresses at a time, SCAN_WAIT_MS each batch (whole subnet ~5-8 s)
static const int SCAN_BATCH = 8, SCAN_WAIT_MS = 250;
int scanPort80(IPAddress me, IPAddress *found, int maxFound) {
  int nf = 0;
  for (int base = 1; base < 255 && nf < maxFound; base += SCAN_BATCH) {
    int fd[SCAN_BATCH], host[SCAN_BATCH], n = 0;
    bool done[SCAN_BATCH];
    for (int i = base; i < base + SCAN_BATCH && i < 255; i++) {
      if (i == me[3]) continue;
      int sk = lwip_socket(AF_INET, SOCK_STREAM, 0);
      if (sk < 0) continue;
      lwip_fcntl(sk, F_SETFL, lwip_fcntl(sk, F_GETFL, 0) | O_NONBLOCK);
      struct sockaddr_in sa;
      memset(&sa, 0, sizeof(sa));
      sa.sin_family = AF_INET;
      sa.sin_port = htons(80);
      sa.sin_addr.s_addr = (uint32_t)me[0] | ((uint32_t)me[1] << 8) | ((uint32_t)me[2] << 16) | ((uint32_t)i << 24);   // network byte order
      lwip_connect(sk, (struct sockaddr *)&sa, sizeof(sa));
      fd[n] = sk; host[n] = i; done[n] = false; n++;
    }
    uint32_t t0 = millis();
    int left = n;
    while (left && millis() - t0 < (uint32_t)SCAN_WAIT_MS) {
      fd_set w;
      FD_ZERO(&w);
      int mx = -1;
      for (int k = 0; k < n; k++) if (!done[k]) { FD_SET(fd[k], &w); if (fd[k] > mx) mx = fd[k]; }
      struct timeval tv = {0, 20000};
      if (lwip_select(mx + 1, NULL, &w, NULL, &tv) <= 0) continue;
      for (int k = 0; k < n; k++) {
        if (done[k] || !FD_ISSET(fd[k], &w)) continue;
        done[k] = true; left--;
        int err = 0;
        socklen_t len = sizeof(err);
        lwip_getsockopt(fd[k], SOL_SOCKET, SO_ERROR, &err, &len);
        if (err == 0 && nf < maxFound) found[nf++] = IPAddress(me[0], me[1], me[2], host[k]);
      }
    }
    for (int k = 0; k < n; k++) lwip_close(fd[k]);
  }
  return nf;
}
// robot address: the configured IP, else the last address that worked (NVS "lastip"), else mDNS wali.local, else a scan of the /24 subnet
// (the robot gets a new DHCP address almost every time it is switched on)
bool findRobot() {
  if (cfgRobot.length() && robotIp.fromString(cfgRobot)) return true;
  prefs.begin("bridge", true);
  String last = prefs.getString("lastip", "");
  prefs.end();
  IPAddress a;
  if (last.length() && a.fromString(last) && isRobot(a, 300)) { robotIp = a; return true; }
  a = MDNS.queryHost("wali", 1000);
  if (a != IPAddress(0, 0, 0, 0)) { robotIp = a; return true; }
  static uint32_t lastScan = 0;
  if (lastScan && millis() - lastScan < 8000) return false;
  lastScan = millis();
  IPAddress me = WiFi.localIP(), open[8];
  uint32_t t0 = millis();
  int n = scanPort80(me, open, 8);
  Serial.printf("robot: subnet scan %u ms, %d host(s) with port 80\n", (unsigned)(millis() - t0), n);
  for (int k = 0; k < n; k++)
    if (isRobot(open[k], 300)) { robotIp = open[k]; Serial.printf("robot: found at %s\n", robotIp.toString().c_str()); return true; }
  return false;
}
bool mdnsUp = false;
void netPoll() {
  if (WiFi.status() != WL_CONNECTED) { wsUp = false; return; }
  if (!mdnsUp) { mdnsUp = MDNS.begin("walle-bridge"); Serial.printf("wifi: %s\n", WiFi.localIP().toString().c_str()); }
  if (wsUp || (int32_t)(millis() - nextTry) < 0) return;
  bool found = findRobot();
  if (found && wsConnect(robotIp)) {
    Serial.printf("robot: connected ws://%s/ws (%s rules)\n", robotIp.toString().c_str(), driveMode ? "driving" : "gesture");
    prefs.begin("bridge", false); prefs.putString("lastip", robotIp.toString()); prefs.end();
    backoff = 1000;
    busyId = 0; havePending = false;
  } else {
    if (found) Serial.printf("robot: %s refused the websocket (another client, or a stale connection after a reset), retry in %u s\n", robotIp.toString().c_str(), (unsigned)(backoff / 1000));
    else Serial.printf("robot: not found, retry in %u s\n", (unsigned)(backoff / 1000));
    lastEvent = found ? "ROBOT REFUSED" : "ROBOT NOT FOUND";
    nextTry = millis() + backoff;
    backoff = backoff * 2 > 4000 ? 4000 : backoff * 2;                  // retry at least every 4 s: the robot is found soon after it is switched on
  }
}

// ------------------------------------------------------------------ setup / loop
String line;
uint32_t bootDown = 0;

void setup() {
  Serial.begin(115200);
  Serial2.setRxBufferSize(2048);                         // the robot look-up may block for 2 s: keep ~1.5 s of FPGA lines
  Serial2.begin(115200, SERIAL_8N1, PIN_RX, PIN_TX);
  pinMode(PIN_LED, OUTPUT);
  pinMode(PIN_BOOT, INPUT_PULLUP);
  pinMode(PIN_CHECK, INPUT_PULLUP);
  loadSettings();
  localInit();
  if (cfgSsid.length() == 0) { startPortal(); return; }
  WiFi.mode(WIFI_STA);
  WiFi.begin(cfgSsid.c_str(), cfgPass.c_str());
  WiFi.setTxPower(WIFI_POWER_13dBm);                                    // lower transmit peaks (USB-powered board with a servo)
  Serial.printf("bridge: Wi-Fi %s, %s rules, min area %d\n", cfgSsid.c_str(), driveMode ? "driving" : "gesture", cfgMinArea);
}

void loop() {
  uint32_t now = millis();
  if (portal) {
    web.handleClient();
    digitalWrite(PIN_LED, (now / 100) & 1);
  } else {
    // BOOT: short press toggles the rule set, 3 s hold opens the settings access point
    if (digitalRead(PIN_BOOT) == LOW) { if (!bootDown) bootDown = now; if (now - bootDown > 3000) { prefs.begin("bridge", false); prefs.putString("ssid", ""); prefs.end(); ESP.restart(); } }
    else if (bootDown) {
      if (now - bootDown > 50) {
        if (driveMode && wsUp) doCmd(STOP_C);
        driveMode = !driveMode; saveMode();
        dom = cand = side = -1; candN = 0;
        Serial.printf("mode: %s\n", driveMode ? "driving" : "gesture");
      }
      bootDown = 0;
    }
    netPoll();
    wsPoll();
    pollQueue();
  }
  while (Serial2.available()) {
    char c = Serial2.read();
    rxBytes++;
    if (c == '\n') {
      Det d[3];
      line.trim();
      if (line.length()) lastRaw = line.substring(0, 80);
      int yr = 0;
      if (parseLine(line, d)) { yoloSrc = false; lastLine = now; lineCount++; memcpy(cur, d, sizeof(cur)); decide(d); }
      else if ((yr = yoloLine(line, d)) == 2) { yoloSrc = true; lastLine = now; lineCount++; memcpy(cur, d, sizeof(cur)); decide(d); }
      else if (yr == 1) { }
      else if (line.length()) badLines++;
      line = "";
    } else if (line.length() < 200) line += c;
  }
  localPoll(now);
  if (!portal) digitalWrite(PIN_LED, wsUp && (now - lastLine < 1000) ? HIGH : ((now / 500) & 1));
}
