# PH1P35 全流水线实时视觉处理与机器人联动系统

2026 全国大学生嵌入式芯片与系统设计竞赛 · FPGA 创新设计赛道 · 安路选题二（HX1P35A 开发板，PH1P35MDG324-3）。

SC500CS 摄像头的 1280×720@60 视频进入 FPGA 后，依次经过自研 ISP、DDR2 帧缓存、传统视觉与片上 int8 YOLO，再叠加 OSD，由 FPGA 自己的 HDMI 发送逻辑输出。识别结果从一根 GPIO 串口单向发给 ESP32，ESP32 通过 Wi-Fi 控制 WALL-E 机器人。所有功能在同一个位流里，已固化到配置 Flash，上电即运行，演示时不需要电脑。

本仓库只放我们自己写的代码。厂商参考工程（MIPI 接收、DDR2 控制器、HDMI 发送等 IP 和 lab1 例程）没有放进来；完整工程见竞赛系统里提交的 RAR 包。

## 目录

| 路径 | 内容 |
|---|---|
| `hdl/rtl_custom/` | 自研 RTL（Verilog-2001）：ISP（isp_color）、颜色分割与形状识别（contest_vision_v2 及子模块）、目标跟踪、越线计数、YOLO 推理引擎（yolo_*）、帧差运动检测（motion_det）、延迟测量（lat_probe）、直方图均衡（he_eq）、白平衡页（wb_ctrl / wb_osd）、OSD 与 Logo 叠加（top_osd、osd_*）、串口报告等 |
| `hdl/tb_custom/` | 测试台与回归脚本：每个模块都有自检测试台，算法模块与 Python 参考模型逐位、逐像素比对；变异测试脚本 |
| `tools/yolo/` | 检测网络的整数参考模型、量化、ROM 生成、单元测试向量；`train/`：合成数据、训练、int8 评估、导出到 FPGA；`board/`：板上数据采集、自动标注、检测结果监视 |
| `tools/shade/` | 平场与暗场分析、镜头阴影校正表生成、ISP 参考模型 |
| `tools/wb/` | 白平衡、延迟、运动检测等模块的变异测试 |
| `tools/board/` | BitWriter 命令行下载（只写 SRAM / 写 Flash）、串口稳定性记录 |
| `tools/robot/` | 电脑端桥接程序（开发调试用）与机器人规则文件 |
| `tools/report/` | 报告插图生成脚本 |
| `esp32/walle_esp32_bridge/` | ESP32 桥接固件（Arduino-ESP32 3.3）：解析 FPGA 报告（传统识别与 YOLO 两种格式）、事件规则、WebSocket 客户端、自动查找机器人、OLED 与三色灯本地终端 |
| `models/real04_final/` | 板上使用的检测模型（实拍数据加反例微调）：PyTorch 权重、int8 参数、评估结果、生成的 ROM |
| `models/p5_synth_20261024/` | 只用合成数据训练的初始模型（微调的起点） |
| `bitstream/` | 最终位流 `contest_work_v3_20261028_advy03.bit` 及 SHA256 |
| `docs/` | 设计与测试记录、开关按键速查表、接线图与插图 |

## 怎么用

**上板**：把 `bitstream/contest_work_v3_20261028_advy03.bit` 写入 HX1P35A 的配置 Flash（TD 6.2.1 的 BitWriter，或 `tools/board/program_flash.ps1`），断电重启即可。操作方法见 `docs/SWITCH_QUICKREF.md`：KEY3+KEY4 在 7 个页面间切换（CV、YOLO、CV+YOLO、CAPTURE、WB、MOTION、HIST EQ），SW1–SW4 选择视图。

**ESP32 与机器人**：接线见 `docs/img/esp32_wiring.png`（FPGA J1 第 1 脚接 ESP32 GPIO16，第 30 脚接地）。固件用 arduino-cli 编译烧录；第一次上电进入设置热点 WALLE-BRIDGE，在 `http://192.168.4.1` 填写 Wi-Fi。详见 `docs/ESP32_BRIDGE_2026-10-27.md`。

**仿真**：`hdl/tb_custom/run_all.ps1` 运行核心回归（Icarus Verilog；部分测试台需要 ModelSim）。`python tools/yolo/run_all.py` 运行检测器各算子的逐位比对与变异测试。

**训练检测模型**：`tools/yolo/board/capture_uart.py` 在 CAPTURE 页采集板上网络的真实输入，`autolabel.py` 标注，`tools/yolo/train/train_yolo.py` 微调，`eval_int.py` / `thr_sweep.py` 按板上 int8 运算评估，`export_board.py` 生成 ROM 后放回工程重新构建。

## 主要结果

| 项目 | 结果 |
|---|---|
| 视频 | 1280×720@60；30 分钟连续运行，摄像头 59.5 帧/秒，显示 60.6 帧/秒，串口报告 0 秒中断 |
| 采集→显示延迟 | 约 35 ms（2 帧），屏幕实时显示 |
| 片上 YOLO | 取样到出框 27 ms；实拍验证集 int8 mAP50 0.84（只用合成数据时为 0.04） |
| ISP | 白纸平场四角 R/G 相对中心 1.21 → 1.02；板上回传白纸 R/G/B 均值 112/113/113 |
| 资源与时序 | Slice 99.58%，ERAM 107/108，DSP 37/40；建立裕量 +0.144 ns，保持裕量 +0.020 ns |
