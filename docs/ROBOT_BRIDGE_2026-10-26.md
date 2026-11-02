# FPGA 识别结果驱动瓦力机器人（外部控制，扩展要求 3）（Claude，2026-10-26）

## 1. 瓦力是什么（实测）

USB 插电脑后出现 COM5，`VID_303A&PID_1001` = 乐鑫 ESP32-S3 自带的 USB 串口/JTAG（**打开 COM5 会让瓦力复位**，平时不要开）。开机日志在 `logs_custom/walle_boot_log.txt`、`walle_log_hotspot.txt`：

- ESP32-S3，8 MB PSRAM，ILI9341 屏，眼灯 2 颗 WS2812；`SKU=linxia-wali`；固件小智 AI v2.4.2（ESP-IDF 5.5.2）。
- `WaliMovements: arms=1 head=1`；MCP 工具 `self.wali.move / action / mood / eye / servo / servo_calibrate / get_status / wake_word` 等。
- 固件里自带“瓦力控制台”网页（`http://<瓦力IP>/`，备份在 `logs_custom/robot/wali_root.html`、`wali_control.js`），网页通过 **WebSocket `ws://<瓦力IP>/ws`** 直接控制瓦力。

## 2. 控制方式（最终采用）：瓦力自带的局域网 WebSocket

不改瓦力的任何设置（OTA 地址、Wi-Fi 之外都不动），云端语音对话照常可用。协议取自控制台 `control.js`：

| 消息 | 内容 |
|---|---|
| 行走 | `{"type":"move","dir":"forward|backward|left|right|spinleft|spinright|stop","speed":20..100}` |
| 工具 | `{"type":"mcp","payload":{"jsonrpc":"2.0","id":n,"method":"tools/call","params":{"name":"self.wali.<工具>","arguments":{...}}}}` |
| 心跳 | 每 1.5 s 发文本 `ping`（控制台也这样做） |

工具参数以瓦力自己通过 WebSocket 返回的 `tools/list` 为准（`logs_custom/robot/tools_ws.json`；控制台 js 里的动作名与固件不完全一致）：

- `action` = wave / arm_left（举左臂挥动）/ arm_right / dance / nod / shake_head / stop：阻塞执行，**做完才回复**（wave 约 6 s、arm_right 约 4 s）。
- `mood` = 21 种（neutral、happy、surprised、thinking、sad……）：同时改眼灯和身体动作。实测屏幕一直是待机画面，不显示表情。
- `eye` = blink / double_blink / pulse / flash / wake / off / mood / brightness / color(`#RRGGBB`)。
- `servo`：物理角度 0..180。手臂：抬起约 60、自然约 120、放下约 170。**头只能上下动**：平视约 120、仰 180、低头 0。servo 调用会打断正在做的心情动作。
- `move`：{direction, speed, duration 毫秒}，定时动作。
- `servo_calibrate`：trim ±10°，可能写入瓦力的存储，未使用。
- 动作会互相打断：首次联调时，紧跟挥手发出的 mood 把挥手打断了，用户看到“手没动”。

网络：电脑开 Windows 移动热点（2.4 GHz），瓦力连上后地址 **192.168.137.238**（电脑 192.168.137.1）。电脑有 Clash 代理，curl 访问瓦力要加 `--noproxy '*'`；Python 原生 socket 不受影响。

## 3. 本机软件（`tools/robot/`）

| 文件 | 作用 |
|---|---|
| `wali_ws.py` | 不依赖第三方库的最小 WebSocket 客户端 `WaliWS`（connect/move/tool/action/mood/eye/servo，后台心跳与收包）；命令行单发：`python tools/robot/wali_ws.py --host 192.168.137.238 eye_color "#FF0000"` |
| `robot_rules.py` | 把 FPGA 串口报文变成事件：主导颜色（面积最大）出现/切换（连续 2 行，新颜色需 1.5 倍面积）、主导目标在左/中/右（x<520 / 520..760 / >760，回差 30）、主导颜色过线计数增加、全部目标消失（连续 10 行）；同类事件至少间隔 1.5 s；面积 < MIN_AREA（默认 300，联调用 3000）当噪声 |
| `rules.json` | 事件 → 瓦力命令表（可直接改，不用改代码） |
| `walle_bridge.py` | 主程序：读 FPGA 串口 COM3 → `robot_rules` → `WaliWS`；保持一条连接，断线按 1..15 s 退避重连；日志 `logs_custom/robot/bridge.log` |
| `walle_server.py`、`fake_robot.py` | 早先的方案 ①（让瓦力改连本机 OTA/MQTT 服务器），已不需要，保留作历史；不要再改瓦力的 OTA 地址 |

当前 `rules.json`（第二版，按瓦力实际能力）：

| 事件 | 瓦力动作 |
|---|---|
| 红色目标出现 | 眼睛红色 + 挥手（wave） |
| 绿色目标出现 | 眼睛绿色 + 点头（nod） |
| 蓝色目标出现 | 眼睛蓝色 + 闪烁 3 次 + 双臂举起（舵机 60°，1.8 s 后回 120°；2026-10-29 ESP32 固件起）。原来的 shake_head 不能用：瓦力的头只能上下动，当前固件回复“未知动作”；改成 cool 表情后，瓦力会往前走一点，在桌面上有风险 |
| 目标移到画面左 / 右 | 举左臂挥动 / 举右臂挥动（arm_left / arm_right）；回到中间不动作 |
| 目标过线（任一颜色） | 眼睛闪烁（2026-10-27 去掉了 surprised：cool 或 surprised 表情会带动轮子前进，两者同时测试过，没有分开确认是哪一个） |
| 全部目标消失 | 心情回 neutral |

`walle_bridge.py` 一次只发一个动作类命令（action / mood / servo / move）：等上一个回复或 8 s 后再发；等待期间只保留最新的一个，过时的丢掉。眼灯命令立即发送。

默认**不发行走命令**（瓦力放在桌上，固件默认速度 100）。需要时在 `rules.json` 里加 `{"name":"move","arguments":{"move":"left","speed":30}}` 一类条目。

**移动规则 `rules_drive.json`（2026-10-26 20:15，用户已把瓦力放在地面并同意加移动）**：红绿灯 + 方向盘。

| 主导颜色 | 瓦力 |
|---|---|
| 绿色 | 眼睛绿；每 0.6 s 一段定时移动：目标在画面左 → 左转 0.5 s，中 → 前进 0.7 s，右 → 右转 0.5 s（速度 40/90） |
| 蓝色 | 眼睛蓝；后退 0.6 s 一段 |
| 红色 | 立即停（WebSocket stop）+ 眼睛红 |
| 全部消失 | 停 + 眼灯回情绪 |
| 过线 | 眼睛闪烁 |

全部是定时的 `self.wali.move`：电脑或链路断了，瓦力走完当前一小段就停。没有 `--drive` 时，含移动命令的规则文件拒绝启动；Ctrl+C 退出时发 stop。自检加了移动场景（绿中 → F F，绿左 → L L，红 → stop）PASS。真机：前进/左/右/后退各 0.5 s 都回复“移动完成”；WebSocket stop 在 2 s 前进的 0.5 s 处发出，瓦力仍在 2 s 时回复完成，**stop 能否打断进行中的定时移动待用户确认**（每段 ≤ 0.7 s，影响有限）。

运行（pyserial 装在 `F:/yolo_env`，系统 Python 没有）：

```
F:/yolo_env/Scripts/python.exe tools/robot/walle_bridge.py --robot 192.168.137.238 --fpga COM3            # 实际控制
F:/yolo_env/Scripts/python.exe tools/robot/walle_bridge.py --dry-run                                      # 只打印不发送
F:/yolo_env/Scripts/python.exe tools/robot/walle_bridge.py --min-area 3000 --rules tools/robot/rules_drive.json --drive   # 红绿灯驾驶
F:/yolo_env/Scripts/python.exe tools/robot/walle_bridge.py --min-area 3000                                # 背景有杂色时提高阈值（当前场景用 3000）
```

## 4. 测试记录（2026-10-26）

- `robot_rules.py` 自检 PASS（left → red → cross → right → lost 顺序与限速）。
- FPGA（isp04 在 SRAM）COM3 报文正常，约 5 行/s，例：`R:OVAL,X0639,Y0000,A001908,N00066;G:----...;B:----,...,A000377,N00017;CAM059,DSP061`。
- `walle_bridge.py --dry-run`：正确解析，画面中已有的红色目标（x≈639，面积约 1900）触发“头 45° / 眼红 / 挥手”；蓝色约 380 像素的小目标在阈值附近闪烁，触发了一次“蓝色出现”——演示场景背景要干净，或用 `--min-area` 提高阈值。
- 真机：`wali_ws.py` 发送 眼睛红、眼睛绿、头 70°、头 20°、头 45°、点头、情绪灯，**全部返回 ok**（点头返回“动作执行完成”）。用户肉眼确认结果和头部转向方向：待反馈。
- 第一次端到端联调（19:48，第一版规则）：用户确认 红出现 → 头动 + 眼红；绿 → 点头 + 眼绿；蓝 → 也是点头（mood happy 的身体动作）；目标左右移动 → 头上下动（头只能上下）；挥手时**手没动**（被紧接着的 mood 打断）；屏幕无表情。过线触发 3 次（日志 19:55:13/15/51；计数线默认不显示，SW4 上才画线 x=640 和目标框，KEY1 开三色面板）。
- 手臂单独测试：左右臂都能动；用户观察到两臂的初始和结束姿态不对称（开机时就不对称），原因未查（可能是舵机安装或校准；`servo_calibrate` 仅 ±10°，未动）。
- 动作排队实测（20:01）：眼红 → wave → arm_left → arm_right：wave 6 s 后回复“动作执行完成”，随后执行 arm_right（4 s），过时的 arm_left 被丢弃，符合设计。
- 背景里一直存在的红/蓝小块面积约 1700–1900，用户拿的物体 1.5 万以上；联调用 `--min-area 3000`，启动时 R/G/B 全空。第二版规则端到端（20:07–20:09）：用户确认 挥手、点头、摇头、左右举臂、过线惊讶都正常，**只有绿色物体出现时眼睛没变绿**。原因（日志）：拿绿色物体时 FPGA 同时报 G≈15 万、R≈2 万、B≈1 万像素（边缘串色/背景），先触发了“红色出现”（眼红），紧接着的“绿色出现”被按工具名 1.5 s 限速挡掉，而出现事件只触发一次。
- 第三版 `robot_rules.py`（20:15）：只跟随**主导颜色**（面积最大；新颜色需大于当前颜色的 1.5 倍且持续 2 行才切换），出现/过线/左右都按主导颜色；限速按事件种类（appear/cross/side/lost）而不是工具名。自检加串色场景（G 14.7 万 + R 2 万 + B 1.2 万 → 只触发 green；R 3 万 vs G 4 万不切换；R 15 万切到 red）PASS。重新联调：待用户反馈。

## 5. 限制与后续

- 演示时电脑在链路中间（FPGA 系统本身独立运行；电脑只负责外部控制链路）。第二阶段可用 ESP32 开发套件代替电脑：FPGA 在 J1 第 1 脚（V2，3.3 V）多引一路 UART，ESP32 读报文后直接连瓦力的 `ws://<瓦力IP>/ws`（需要下一版位流加一路 UART 输出）。
- 瓦力的 WebSocket 连接数少：桥接程序运行时，手机/浏览器的瓦力控制台可能连不上，反之亦然。
- 识别来源目前是 CV 页的颜色/形状检测；YOLO 页的框信息要接到串口报文后才能驱动瓦力（下一步）。
