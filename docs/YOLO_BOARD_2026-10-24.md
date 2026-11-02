# 板上 YOLO 检测：yolo01 位流（2026-10-24，Claude）

**一句话**：`release/contest_work_v3_20261024_yolo01.bit` 把 YOLOv3-tiny 裁剪定点模型完整放进了 FPGA。流程是每帧取样、片上 CNN 推理、检测头解码 + NMS、画框和标签。全程不经过 PC，也不读写 DDR。TD 完整构建通过，时序收敛，系统级仿真与 Python 整数参考逐位一致。**还没有上板验证。** 权重目前只用合成数据训练过，真实零件的精度需要先用本位流的“数据采集”模式采图微调，之后才能声称。

## 1. 开启操作（给上板的同学）

1. BitWriter 以 PROGRAM_SRAM 方式下载 `release/contest_work_v3_20261024_yolo01.bit`（SHA256 `2b69318b757ade1305f91d7f2b3cfeb43a54421b9d5f83bda45d61954307d1f3`，1,789,539 字节）。只写 SRAM，不写 Flash；回退用 color4 或 isplite01。
2. 上电后是**模式 0（传统检测）**：画面左下角状态行显示 `CV`。原有的开关、按键和 UART 报告与 isplite01 相同。
3. **同时按下 KEY3 + KEY4**（和弦）切换模式：0 `CV` → 1 `YOLO` → 2 `CV+YOLO` → 3 `CAPTURE` → 回到 0。
   - 模式 1 `YOLO`：只叠加 YOLO 框，画面不带传统检测的叠加层。每个框按类别着色（红 / 绿 / 蓝），框上方标签是“类别字母 + 置信度%”，例如 `R87`。状态行显示 `YOLO 30FPS 27MS N=3`，依次是每秒检测次数、取样到出框的延迟和当前框数。
   - 模式 2 `CV+YOLO`：传统检测的 OSD 和 YOLO 框同时显示，可当面对比两种方法。
   - 模式 3 `CAPTURE`：不推理，把每帧网络输入图（128×72）经 UART 发到 PC，状态行显示已发送帧数（十六进制）。用来采集训练数据，见第 6 节。
   - 单按 KEY3 / KEY4 仍是移动计数线。和弦期间计数线会左右各走一步、相互抵消。
4. 诊断模式（SW1–SW3 全下）下按键仍归平场诊断块，和弦不会切换 YOLO 模式。
5. 模式 1、2 下，UART（115200 8N1）每 200 ms 输出一次检测结果文本；模式 0 下 UART 仍是原来的传统检测报告。

## 2. 结构与时序

```
DDR 读出（调色前，像素时钟 74.25 MHz）─┬─> camera_tone ─> contest_vision_v2（传统检测/OSD）─┐
                                       │                                                  ├─> yolo_osd ─> HDMI
                                       └─> yolo_top: video_pos_adapter ─> yolo_box_down（10×10 平均）
                                             ─> bank A ─> yolo_net_engine（34 条描述符，卷积核 8 lane）
                                             ─> bank D ─> yolo_decode（sigmoid/exp 表、阈值、32 槽、NMS）─> 8 个框
```

- **单时钟域**：检测器全部运行在 HDMI 像素时钟上，和它采样的视频流同频，所以没有任何跨时钟逻辑。它只“旁听”视频流，不会让 HDMI 停顿。
- **节奏**：取样一帧（16.7 ms）→ 推理约 10.9 ms → 解码 < 0.15 ms → 锁存。在 60 Hz 下每 2 帧出一次结果，即**每秒 30 次检测**。取样开始到出框约 **27 ms**。这两个数由片上计数器测量，状态行和 UART 里显示的就是它们。目前的 27 ms 和 30 次/秒来自系统级仿真里同一套计数器，不是板上实测。
- 结果超过 30 帧（0.5 s）没有更新就自动撤框。帧号随 UART 报告输出。
- 不访问 DDR，不改 MIPI、PLL、摄像头寄存器和 HDMI 编码器。只在顶层增加两个实例，UART 和 HDMI 输入各加一个选择器。

## 3. 模型

| 项目 | 值 |
|---|---|
| 结构 | YOLOv3-tiny 拓扑裁剪：conv0…conv14、两个检测头（stride 32 / 16，各 3 anchor × (5+3 类)）、1×1 + 上采样 + concat 分支，去掉 stride-1 池化 |
| 通道 | `8,8,16,16,24,32,24 / 16,24,8,16`，31,496 个参数（含 BN），int8 权重 3,883 个 8-lane 字（31 KB，片上 ROM） |
| 输入 | 128×96 int8：1280×720 经 10×10 平均得到 128×72，上下各 12 行灰色 letterbox |
| 量化 | 逐通道对称 int8 权重；激活尺度按校准集确定；每通道 M(u16)/S；检测头尺度固定 1/16；leaky 13/128 |
| anchor（网络像素） | 头 1：13×11、19×19、34×30；头 2：4×6、8×5、8×10 |
| 训练数据 | **合成**：24,000 张训练、2,000 张验证、2,000 张测试（`tools/yolo/train/synth.py`）。内容是红/绿/蓝零件状物体、杂乱低饱和背景、非目标色干扰物、遮挡、亮度与色偏、模拟板上“中心绿/四周红”的径向色偏。格式和板上输入完全一致 |
| 训练 | PyTorch 2.11 + CUDA（RTX 4060），150 epoch，约 30 分钟 |
| 文件 | `models/p5_synth_20261024/`（model.pt、BN 折叠权重、int8 参数、anchors、指标、manifest、SHA256） |

**精度（合成测试集，2,000 张，5,927 个目标；不代表真实零件）**

| 指标 | 浮点网络 | int8 网络（与 FPGA 逐位一致的计算） |
|---|---:|---:|
| AP50 红 / 绿 / 蓝 | 0.565 / 0.579 / 0.616 | 0.555 / 0.577 / 0.624 |
| mAP50 | 0.587 | **0.585** |
| FPGA 工作点（分数 ≥ 0.4、最多 8 框）精确率 / 召回率 | 0.672 / 0.632 | **0.674 / 0.632** |
| 召回率：大目标（≥160 帧像素）/ 中（80–160）/ 小（<80） | 0.72 / 0.61 / 0.44 | 0.73 / 0.61 / 0.43 |

- 量化几乎无损，mAP 只差 0.002。
- 这套合成数据刻意做得很难（最小目标 50 像素、重遮挡、相似色干扰），绝对值不能外推到真实场景。
- 真实零件的指标要在采集、标注、按批次划分之后，在独立测试集上测。

## 4. 资源与时序（TD 6.2.1 完整构建 `cli_yolo01`，0 错误，129 条警告）

| 资源 | color4 | isplite01 | **yolo01** | 其中检测器 |
|---|---:|---:|---:|---:|
| Slice | 18,445（86.94%） | 15,190（71.60%） | **18,084（85.24%）** | — |
| LUT6 | 16,656 | 14,250 | **17,441（82.21%）** | — |
| 寄存器 | 18,024 | 13,242 | **18,052（42.54%）** | — |
| ERAM20K | 50 | 45 | **106 / 108（98.15%）** | 61（4 个激活体 35、权重/参数/描述符 ROM 20、解码 4、下采样 2） |
| DSP | 22 | 24 | **36 / 40（90%）** | 15（卷积核 11、下采样 3、解码 1） |
| Setup / Hold WNS | +0.119 / +0.020 ns | +0.738 / +0.020 ns | **+0.161 / +0.020 ns** | |
| STA 覆盖 | 97.31% | 96.39% | 97.40% | |

- 最紧的是 HDMI 像素时钟域（STA 按 75.002 MHz 约束，余量 0.161 ns）。最差路径在原有的 `contest_vision_v2` OSD 字库地址上，不在检测器里。
- 综合阶段曾发现叠加层的 8 个百分比乘法和下采样的常数乘法占了 11 个 DSP，使总数达到 47/40，已改为移位加法。
- 另一个教训：TD 只在数组索引宽度恰好为 ⌈log2(深度)⌉ 时才推断成 ERAM。

**为什么别人的 Slice 能到 98%**：Slice 占用率本身不是质量指标。本作品真正吃满的是 ERAM（98%）和 DSP（90%）。ERAM 里 19 块是 128×96 输入图，20 块是权重 ROM。要放更大的网络，得先腾出 ERAM。可选办法有：取消 Logo（5 块）或诊断块（2 块）；或者把 conv0 改成直接吃下采样流、不存整张输入图（可省约 15 块）。后一种是下一步可以做的结构优化。

## 5. 验证记录

- **系统级仿真** `tb_custom/tb_yolo_top.v`（`python tools/yolo/run_top_test.py`，Icarus，849 万个时钟）：
  - 按真实 720p 时序（1650×750、RGB 晚 de 两拍）输入测试图。
  - 两次结果都是 8 个框，与 Python 整数参考（qref + decode_ref）**逐位一致**。片上测得延迟 27 ms，两次结果间隔 2 帧。
  - 切到模式 3 后，UART 输出 27,654 字节，帧头、27,648 个图像字节和校验和全部正确。
  - 结果：PASS（训练模型），之后用最新 RTL 又跑了一次，同样 PASS。
- **叠加层** `tb_custom/tb_yolo_osd.v`：渲染一整帧并自动检查边框、框内、标签像素，PASS。截图见 `logs_custom/yolo_vec/osd_crop.png`、`osd_status.png`。去掉乘法器前后输出逐字节相同。
- **算子回归** `python tools/yolo/run_all.py --mutants --modelsim --full-frame`，结果见第 9 节。
- **量化**：`tools/yolo/train/eval_int.py` 用和 FPGA 相同的整数运算评估 2,000 张测试图，数字见第 3 节。
- **工程一致性** `tb_custom/verify_contest_work.py contest_work_v3_yolo`：PASS（`release/verify_contest_work_v3_yolo01_at_build.txt`）。
- **未运行**：板上任何测试；在实际 HDMI 屏上观察；真实零件精度；30 分钟连续运行；整机（含厂商 IP）的门级仿真。

## 6. 用真实零件把模型变准（PC 只做训练，板上推理不依赖 PC）

1. 下载 yolo01，按 3 次 KEY3+KEY4 进入 `CAPTURE`，PC 端运行：
   `F:/yolo_env/Scripts/python.exe tools/yolo/board/capture_uart.py --port COM3 --out F:/yolo_capture/session01 --n 200`。
   每帧约 2.4 s；收到的就是板上网络的真实输入（同一传感器、镜头、ISP、10×10 平均）。
2. 至少采 5 个批次，每个批次换一次光照、背景、位置或日期，并包含无目标帧和相近色背景。
3. 运行 `autolabel.py label --session <批次>`，按颜色给出初始框，生成 `review/` 拼图。**必须人工检查、修正或删除错误标注。**
4. 运行 `autolabel.py dataset --sessions s01 s02 s03 --val s04 --test s05 --out F:/yolo_data_real`，按批次划分。
5. 微调：`train_yolo.py --data F:/yolo_data_real --init models/p5_synth_20261024/model.pt --anchors models/p5_synth_20261024/anchors.json --out F:/yolo_runs/real01 --epochs 80`。
   然后依次运行 `eval_int.py` 和 `export_board.py --rtl-out contest_work_v3_yolo/user_source/hdl_source/custom`，重新 TD 构建（只是 ROM 内容变了）。
6. 模式 1/2 下可用 `monitor_uart.py --port COM3 --csv det.csv` 记录板上检测结果，用来统计空背景误检等指标。

## 7. ISP 与镜头（闹闹的建议：AWB 要自己调、可以自己换镜头、不限制）

- AWB 已经是我们自己的：isplite/yolo01 里用的是帧保持的 `awb_frame`，替换了厂商那套逐帧重启增益的 AWB。
- “中心绿、四周红”这种随位置变化的色偏，单靠全局白平衡去不掉。典型原因是镜头主光线角（CRA）和 SC500CS 不匹配，或者红外截止片在斜入射时透过率变化。**换一颗 CRA 匹配、带 650 nm IR-cut 的 M12 镜头，可能是最便宜的修复**。
- 也可以先用 shade01 做平场测量（`docs/IMAGE_SHADING_2026-10-16.md`）定量。如果确认是镜头色阴影，再加一个可开关的径向增益补偿（LSC）。没有测量数据之前不叠加强增益。
- 检测模型在合成数据里加了这种色偏，所以对它有一定鲁棒性。真实数据微调会进一步适应实际镜头。

## 8. Codex 上板步骤

- T1：PROGRAM_SRAM 下载 yolo01，确认画面正常；对比 isplite01，原有功能应不受影响。
- T2：左下角应出现 `CV`。按 KEY3+KEY4，确认依次出现 `YOLO`、`CV+YOLO`、`CAPTURE`、`CV`。
- T3：模式 1 下放红/绿/蓝物体，拍屏幕记录框、标签和状态行（`xxFPS xxMS N=x`）。预期约 30 FPS、约 27 ms。
- T4：模式 1 下串口（115200）应每 200 ms 出一组 `Y …` 报告。可用 `monitor_uart.py` 查看。
- T5：模式 3 下用 `capture_uart.py` 收 5 帧，检查 PNG 是否和画面一致、校验和有无错误。
- T6：空背景 1 分钟，记录误检；连续运行 30 分钟，记录有无异常。
- T7：如有问题，回退 isplite01 / color4。

## 9. 回归结果（2026-10-24，`python tools/yolo/run_all.py --mutants --modelsim --full-frame --jobs 8`，全部退出码 0）

| 步骤 | 结果 |
|---|---|
| decode_ref 自检 | PASS |
| yolo_conv_core / aux / net_engine / decode / box_down（Icarus） | 44 / 31 / 4 / 27 / 9 例，0 失败 |
| quantize 自检（随机浮点模型 → int8 包 → RTL） | PASS，逐字节一致 |
| 变异测试 conv / aux / net / decode / box | 43/43、50/50、54/54（含 1 个论证等价）、66/66、35/35 |
| ModelSim SE-64 2020.4（同一批向量） | 44 / 31 / 4 / 27 / 9 例全部通过 |
| 系统级 tb_yolo_top（训练模型，单独运行） | PASS：8 个框逐位一致 ×2，导出 27,654 字节正确 |
| 叠加层 tb_yolo_osd | PASS |

本轮 RTL 变动：
- `yolo_decode` 的 anchor 从参数改为输入端口，由生成的 `yolo_model_cfg` 提供。
- `yolo_box_down` 去掉乘法器：常数乘法改为移位加法，行地址改为累加，删除未用的行计数器。
- `yolo_osd` 补全组合赋值（消除锁存），百分比改用移位加法。
- 新增 `yolo_top`、`yolo_osd`；`mininet` 增加 letterbox 清零描述符。
