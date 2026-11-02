# 算法与显示模块接口说明（rgb_to_gray / color_segment / frame_bbox / video_pos_adapter / OSD / 集成块）

编写日期：2026-10-05（北京时间），2026-10-06 随第 3 批与集成工程更新。对应任务：[handoff/FIRST_TASK.md](../handoff/FIRST_TASK.md)。

## 0. 状态声明（先读）

- 模块（`rgb_to_gray`、`color_segment`、`frame_bbox`、`video_pos_adapter`、`osd_overlay` 及其辅助模块、集成块 `contest_vision_path`）是**纯 RTL**（Verilog-2001 可综合子集，无厂商原语、无浮点、无除法）；字体 / Logo ROM 由脚本生成，用 TD 模板写法推断为块存储。`contest_vision_path` 与其余模块已接入 `contest_work` 工程（lab1 的完整副本，只多 3 处改动，见 §4d），lab1 / lab2 / lab3 没有修改。
- 已运行的检查：Icarus Verilog 13.0 与 ModelSim SE-64 2020.4 上九个 testbench 全部 PASS（含用未修改的 `uivtc.v` 驱动的适配器测试、真实 1280×720 的链路 / OSD 整机测试和集成块测试）、灰度和分割各自的全部 2^24 色穷举 PASS、注入缺陷的变异测试；TD 读入 + `optimize_rtl`、testbench `analyze`；**`contest_work` 的 TD 命令行完整构建（Read Design → 综合 → 布局布线 → 位流）成功**。逐项结果见 §7，完整清单与数字以 [STATUS_FOR_CODEX.md](STATUS_FOR_CODEX.md) 为准。
- 同一份 RTL 在 Icarus Verilog 和 ModelSim SE-64 2020.4 两个仿真器上结果一致（计数和结束时刻都相同）。
- **没有**位流下载 / 摄像头 / HDMI 实测 / 帧率 / 时延的实机结果。仿真通过不代表实机通过；构建通过不代表功能正确。接口里的"归一化像素流"是新模块合同，其中 `user/last` 与 `uivtc` 的对应已在未修改的 `uivtc.v` 上仿真证实，**RGB 与 `de` 的相对拍数（`SKEW`）仍是推断**（见 §8）。

> v2 功能版（`contest_work_v2`）的新增模块（`color_seg_rt`、`hit_open`、`luma_mean`、`thr_adapt`、`shape_classify`、`edge_style`、`view_mux_style`、`osd_ext`、`ui_ctrl`、`fps_meter`、`uart_report`、`seg7_scan`、`beep_ctrl`、集成块 `contest_vision_v2` 等）的接口与行为写在 [V2_DESIGN.md](V2_DESIGN.md)，不重复列在本文件里。

## 1. 归一化像素接口（模块合同）

| 信号 | 方向 | 含义 |
|---|---|---|
| `clk` | in | 像素处理时钟，一拍最多一个有效像素 |
| `rst_n` | in | 低有效**异步**复位；释放须由集成方同步到 `clk` |
| `in_de` | in | 本拍像素有效；消隐为 0 |
| `in_rgb[23:0]` | in | 规范顺序 `[23:16]=R [15:8]=G [7:0]=B`；基线顺序待波形 / 彩条确认 |
| `in_x[11:0]` `in_y[11:0]` | in | 有效像素坐标，0..WIDTH-1 / 0..HEIGHT-1 |
| `in_sof` | in | 帧内第一个有效像素同拍为 1 |
| `in_eol` | in | 每行最后一个有效像素同拍为 1 |
| `in_eof` | in | 整帧最后一个有效像素同拍为 1 |

通用约定：

- 没有 ready / 反压端口，不丢像素，吞吐一有效拍一像素。
- `in_sof/eol/eof` 仅在 `in_de=1` 时有意义；模块内部都用 `in_de` 限定，`de=0` 时它们取任何值都被忽略（testbench 在消隐拍里故意灌 1）。
- 1×1、1×N、N×1 的帧合法：`sof/eol/eof` 可以在同一像素同时为 1。
- **所有输出在 `out_de=0` 时一律为 0**（gray/rgb/hit/mask/x/y/sof/eol/eof），消隐干净。
- RGB 与同步侧带按相同的固定拍数延迟，彼此始终对齐。

## 2. rgb_to_gray（[rtl_custom/rgb_to_gray.v](../rtl_custom/rgb_to_gray.v)）

`Y = floor((77*R + 150*G + 29*B) / 256)`，实现为三个 16 位常数乘积 → 17 位加法 → 取 `sum[15:8]`。

位宽：`77*255=19635`、`150*255=38250`、`29*255=7395`，最大和 `65280 < 2^16`。已知值：黑 0、红 76、绿 149、蓝 28、白 255，且 `(v,v,v)→v`（因 77+150+29=256）。

| 端口 | 方向 | 说明 |
|---|---|---|
| 输入 | in | 见 §1 |
| `out_de` | out | `in_de` 延迟 2 拍 |
| `out_gray[7:0]` | out | 灰度 Y；`out_de=0` 时为 0 |
| `out_rgb[23:0]` | out | `{Y,Y,Y}`（组合拼接自 `out_gray`，无额外寄存器） |
| `out_x/out_y/out_sof/out_eol/out_eof` | out | 延迟 2 拍；`de=0` 时为 0 |

- **固定延迟 LATENCY = 2 个 `clk`**（阶段 1：三个乘积 + 侧带；阶段 2：求和、`de` 门控）。吞吐 1 像素/拍。
- 控制优先级：复位 > 数据；无使能、无停顿。复位清零全部寄存器，在途像素被丢弃。
- TD `optimize_rtl` 把三个常数乘法识别为 3 个 `MACRO_MULT`（见 §7）。若后期 DSP 紧张可改为移位加法，功能不变。
- 这是理论流水线周期，**不是**传感器到屏幕的实测时延。

## 3. color_segment（[rtl_custom/color_segment.v](../rtl_custom/color_segment.v)）

```
hit = in_de && X0<=x<X1 && Y0<=y<Y1 && R>=R_MIN && R>=G+DELTA && R>=B+DELTA
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `R_MIN` | 80 | 10 位，0..1023；>255 表示永不命中 |
| `DELTA` | 30 | 10 位，0..1023；>255 表示永不命中 |
| `X0,X1,Y0,Y1` | 0,1280,0,720 | 半开区间 ROI，13 位（`X1=4096` 可表示）；`X0>=X1` 或 `Y0>=Y1` 为空 ROI。换分辨率须覆盖 `X1/Y1` |

位宽：`G+DELTA`、`B+DELTA` 在 11 位无符号里算（最大 255+1023=1278），不会出现 8 位回卷（例如 G=226、DELTA=30 时和为 256）。所有比较都是等宽无符号向量。阈值本批只是编译期参数，没有自适应逻辑。

| 输出 | 说明 |
|---|---|
| `out_de` | `in_de` 延迟 2 拍 |
| `out_hit` | 命中；`de=0` 时为 0 |
| `out_rgb[23:0]` | 原始 RGB 延迟 2 拍（供后续叠加 / OSD）；`de=0` 时为 0 |
| `out_mask[23:0]` | `out_hit ? 24'hFFFFFF : 24'h000000`（组合） |
| `out_x/out_y/out_sof/out_eol/out_eof` | 延迟 2 拍；`de=0` 时为 0 |

- **固定延迟 LATENCY = 2 个 `clk`**（阶段 1：四个条件位 + 侧带；阶段 2：与 `de` 相与）。吞吐 1 像素/拍。
- 优先级：复位 > 数据；`de=0` 强制 `hit=0`；ROI 外强制 `hit=0`。

## 4. frame_bbox（[rtl_custom/frame_bbox.v](../rtl_custom/frame_bbox.v)）

每帧统计命中像素数、包围框、整数框中心、有效标志。

| 参数 | 默认 | 说明 |
|---|---|---|
| `CNT_W` | 20 | 计数位宽；`1280*720=921600 < 2^20`。其它帧尺寸需 `CNT_W >= ceil(log2(WIDTH*HEIGHT+1))` |
| `MIN_PIXELS` | 16 | 最少命中数（编译期） |

输入：`in_de, in_hit, in_x, in_y, in_sof, in_eol, in_eof`。`in_eol` 仅为接口一致而保留，**不参与统计，更不当 EOF**。

输出：

| 输出 | 说明 |
|---|---|
| `frame_done` | 单拍脉冲，出现在**送入 EOF 像素那一拍的下一拍**（延迟 1） |
| `frame_abort` | 单拍脉冲，SOF 打断了一个正在统计的帧时，在该 SOF 像素的下一拍出现；被打断的帧不产生结果 |
| `res_frame_id[15:0]` | 复位后已完成的帧数（回卷 65536）；用于判断结果是否更新 |
| `res_valid` | `res_count != 0 && res_count >= MIN_PIXELS` |
| `res_count[CNT_W-1:0]` | 命中数。饱和于 `2^CNT_W-1`；`res_valid=0` 时仍为真实计数（用于诊断） |
| `res_sat` | 本帧计数曾饱和（粘滞到下次完成） |
| `res_xmin/xmax/ymin/ymax` | 包围框；`res_valid=0` 时强制为 0 |
| `res_cx/res_cy` | `(xmin+xmax)>>1`、`(ymin+ymax)>>1`，13 位加法后再右移；是**框中心，不是质心**；`res_valid=0` 时为 0 |

帧协议（对每个 `in_de=1` 的像素，优先级由上至下）：

1. `in_sof`：开新帧并**计入本像素**；若上一帧未结束则丢弃它并拉 `frame_abort`。
2. 帧进行中：`in_hit` 则累加。
3. 无帧进行：像素被忽略（例如复位后同一帧剩余像素）。不会凭空输出结果。
4. `in_eof`（作用于已在统计的帧）：先把本像素计入，再结束并锁存结果。SOF 与 EOF 可同一像素。

锁存与跨帧：累加器与结果寄存器分开，下一帧累加不会改动已锁存的结果；结果在 `frame_done` 同一时钟沿更新，之后保持到下一次 `frame_done`。复位丢弃未完成帧并清零全部结果（`res_frame_id=0`）。`de=0` 的拍里 `hit/sof/eof/x/y` 一律忽略。

**帧号与滞后**：第 N 帧的统计结果在第 N 帧最后一个像素之后才有，因此叠加只能用于第 N+1 帧，**固定滞后一帧**。建议叠加模块在 SOF 时把 `res_*` 复制到自己的寄存器，保证一帧内框不被半途刷新。显示缓存可能重复某个采集帧，计数和 fps 指标要区分采集帧与显示帧。

已知算法局限（后续要处理，不属于首批）：单个孤立噪点命中就会撑大包围框，`MIN_PIXELS` 只限制数量，不限制位置；之后需要行内连续长度或 3×3 形态学滤波。

## 4b. video_pos_adapter（[rtl_custom/video_pos_adapter.v](../rtl_custom/video_pos_adapter.v)，第二批）

把基线风格的流 `de + user + last + rgb` 转成本项目的归一化像素流。**纯 RTL，已随 `contest_vision_path` 接入 `contest_work`（§4d），尚无实机结果。**

| 参数 | 默认 | 说明 |
|---|---|---|
| `WIDTH` | 1280 | 每行有效像素数，1..4096 |
| `HEIGHT` | 720 | 每帧行数，1..4096 |
| `SYNC_DELAY` | 0 | `vid_de/user/last` 在模块内延迟的拍数。RGB 若比 `de` 晚 N 拍到达（基线疑似 2 拍，**未证实**）就设 N，让它们在模块内重新对齐；RGB 与 `de` 已对齐则为 0 |

| 端口 | 方向 | 说明 |
|---|---|---|
| `vid_de` / `vid_user` / `vid_last` | in | 像素有效 / 帧首像素 / 行末像素（均与 `vid_de` 同拍；来源 `uivtc.v` 的 `O_vtc_de_valid/user/last`） |
| `vid_rgb[23:0]` | in | 其 `de` 在 `SYNC_DELAY` 拍之前的那个像素的颜色 |
| `out_de` `out_rgb` `out_x` `out_y` `out_sof` `out_eol` `out_eof` | out | 归一化像素流（§1），`out_de=0` 时全部为 0 |
| `frame_active` | out | 一帧正在进行（`active` 寄存器，与输出寄存器同沿更新），诊断用 |
| `geom_err` | out | 单拍脉冲：几何违规，或帧中又来一个 `user`（重启）；比出错像素晚 1 拍可见 |

计数：`x_cur = user ? 0 : x_nxt`、`y_cur = user ? 0 : y_nxt`（组合）；通过的像素上，行末则 `x_nxt<=0, y_nxt<=y_cur+1`，否则 `x_nxt<=x_cur+1, y_nxt<=y_cur`。不复用基线 `hdmi_mixer` 的 `S_x/S_y`（见 §8.1 第 7 点）。

每个 `vid_de=1` 的像素，优先级由上至下：

1. 像素属于某帧：`vid_user=1`（开新帧），或已有一帧在进行。**没有帧在进行**（复位后、EOF 之后、几何违规之后，直到下一个 `user`）的像素被丢弃：`out_de=0`、全部输出 0，不报错。
2. 帧内几何检查，两项之一违规：`x_cur >= WIDTH`（行过长），或 `vid_last && x_cur != WIDTH-1`（行过短或 `last` 位置不对）。违规像素被丢弃、本帧中止（不虚构 EOF）、直到下一个 `user` 全部丢弃，`geom_err` 拉一拍。
3. 否则像素通过，输出 `x_cur/y_cur`，`out_sof=vid_user`、`out_eol=vid_last`、`out_eof=vid_last && y_cur==HEIGHT-1`（它同时结束这一帧）。
4. 帧进行中又来 `vid_user`：在该像素重启一帧（旧帧没有 EOF），同时 `geom_err` 拉一拍。
5. `vid_de=0` 时 `vid_user/vid_last` 一律忽略。`WIDTH=1` 或 `HEIGHT=1` 合法（`sof/eol/eof` 可在同一像素）。没有"行数过多"检查：最后一行结束时帧即结束，之后多出来的行是无帧像素，被静默丢弃。

延迟：输出为寄存器；`vid_de` → `out_de` 为 `SYNC_DELAY+1` 拍，`vid_rgb` → `out_rgb` 为 1 拍；吞吐 1 像素/拍，不停顿。复位：低有效异步，释放须由集成方同步。

时序示意（`SYNC_DELAY=2`，`t=0` 为帧首像素的 `vid_de`；`rgb` 比 `de` 晚 2 拍到达）：

```
t            :  0    1    2    3    4    5    6   ...
vid_de/user  :  1/1  1/0  1/0  ...                  (de,user,last 在模块内再延迟 2 拍)
vid_rgb      :  .    .    P0   P1   P2   P3   P4   (P0 是 t=0 那个像素的颜色)
内部 s_de    :  .    .    1    1    1    1    1
out_de       :  .    .    .    1    1    1    1     (比 vid_de 晚 SYNC_DELAY+1 = 3 拍)
out_rgb      :  .    .    .    P0   P1   P2   P3   (与 out_x/out_y/out_sof 同拍对齐)
out_x/out_y  :  .    .    .    0/0  1/0  2/0  3/0
out_sof      :  .    .    .    1    0    0    0
```

资源（TD `optimize_rtl` 后的 RTL 级统计，默认参数，**不是布局后占用**）：76 个 DFF，0 个锁存器，无乘法器、无 RAM。

## 4c. OSD、Logo 与显示辅助模块（第 3 批，赛题基础要求 4）

**纯 RTL，已随 `contest_vision_path` 接入 `contest_work`（§4d），尚无实机结果。** 模块：`osd_overlay`（OSD 主体）、`osd_bin2bcd`（动态数字）、`osd_font_rom`、`osd_logo_rom`（生成的 ROM）、`view_mux`（显示模式选择）、`sync_delay`（时序信号延迟）。

### osd_overlay（[rtl_custom/osd_overlay.v](../rtl_custom/osd_overlay.v)）

归一化像素流进、归一化像素流出：`in_de/in_rgb/in_x/in_y/in_sof/in_eol/in_eof` → `out_*`。**固定延迟 3 拍**，一拍一像素，不停顿；`out_de=0` 时所有输出为 0；复位同其它模块。

图层，自下而上（后画的覆盖先画的，Logo 是 alpha 混合）：

| # | 图层 | 说明 |
|---|---|---|
| 0 | 视频 | `in_rgb` |
| 1 | 文字衬底 | 文字块四周各 8 像素的矩形，视频每通道 `>>1` 变暗 |
| 2 | Logo 衬底 | Logo 四周各 6 像素的矩形，向 `PLATE_COLOR`（白）混合，权重 `PLATE_A/16`（默认 12/16），让深蓝的 Logo 在深色视频上也看得见 |
| 3 | 计数线 | 竖线 `x=line_x` 与 `line_x+1`（2 像素宽），整列，`LINE_COLOR` |
| 4 | 目标框 | 在 `[xmin..xmax]×[ymin..ymax]` **外侧**画 2 像素宽的框（不盖住目标），`BOX_COLOR`；仅 `tgt_valid=1` 时 |
| 5 | 十字 | 以 `(cx,cy)` 为中心，臂长 ±`CROSS_ARM`（默认 12），3 像素粗，`CROSS_COLOR`；仅 `tgt_valid=1` 时 |
| 6 | Logo | 安路标识，`osd_logo_rom`：`out = (下层*(16-α) + Logo色*α) >> 4`，每通道，α=0..16 |
| 7 | 文字 | 22 列 × 6 行字符网格的字形像素，`TEXT_COLOR`（白） |

控制输入（**在 `in_de & in_sof` 的那个像素采样，整帧保持**；该像素本身已经使用新值）：

| 端口 | 含义 |
|---|---|
| `cfg_flags[4:0]` | `[0]` 文字 `[1]` 目标框 `[2]` 十字 `[3]` 计数线 `[4]` Logo，1 = 画 |
| `cfg_mode[1:0]` | 只用于文字显示：0 `ORIG`、1 `GRAY`、2 `MASK`、3 `TINT`（画面本身由 `view_mux` 选择） |
| `tgt_valid`、`tgt_xmin/xmax/ymin/ymax`、`tgt_cx/cy`、`tgt_count[19:0]` | 目标有效 / 框 / 中心 / 像素数，可直接接 `frame_bbox` 的 `res_*` |
| `line_x[11:0]`、`cross_cnt[15:0]` | 计数线位置、越线计数 |

文字块（默认原点 `(200,16)`，`SCALE=1`：每个字符格 16×32 像素，整块 352×192）：

| 行 | 内容 |
|---|---|
| 0 | `安路 PH1P35 实时视觉`（中文字符占两个字符格） |
| 1 | `MODE:ORIG` / `GRAY` / `MASK` / `TINT` |
| 2 | `TARGET:FOUND` / `TARGET:LOST` |
| 3 | `X:dddd Y:dddd`（`tgt_valid=0` 时数字显示为 `----`） |
| 4 | `AREA:dddddd`（`tgt_count`，超过 999999 显示为 999999） |
| 5 | `CROSS:ddddd`（`cross_cnt`） |

几何默认值针对 1280×720：Logo 原点 `(16,16)`，大小 160×94；文字原点 `(200,16)`。`TEXT_X/TEXT_Y` 须 ≥ 8，否则衬底会越出画面左 / 上边。

**帧一致性与一帧滞后**：所有控制量只在帧首像素采样一次，帧中间改变它们不会影响当前帧（testbench 在每帧中间改变并验证）。因此叠加的是**上一帧**的统计结果（`frame_bbox` 的结果在一帧结束后才有），**固定滞后一帧**，这是设计内的。数字由 `osd_bin2bcd` 对实时输入连续转换，输入须在 `in_sof` 前至少稳定 43 拍；`frame_bbox` 的结果在帧末尾后就稳定了，比下一帧的 SOF 早整个垂直消隐（数万拍）。

### 其它模块

| 模块 | 说明 |
|---|---|
| `osd_bin2bcd`（`BITS, DIGITS`） | 移位加 3 的二进制转 BCD，一位一拍，连续运行；超过 `10^DIGITS-1` 时钳位；`bin` 变化后至多 `2*(BITS+1)` 拍出现新结果，稳定 `2*BITS+3` 拍后保证等于十进制表示；`bcd` 任何时刻都是合法 BCD。无除法、无乘法器 |
| `view_mux`（`TINT_COLOR`） | 4 种显示：0 原图、1 灰度、2 掩膜、3 原图 + 命中像素涂 `TINT_COLOR`。所有数据输入须由集成方事先对齐；寄存输出，延迟 1 拍 |
| `sync_delay`（`N, W`） | 把 W 位向量精确延迟 N 拍（N=0 为直连）。OSD 等模块使数据路径多出若干拍后，`vsync/hsync/de` 要用它延迟同样的拍数 |
| `osd_font_rom` | 8×16 字体：ASCII 0x20..0x7E（DejaVu Sans Mono），0x80..0x97 为 12 个汉字的左 / 右半格（安路实时视觉目标计数越线，黑体） |
| `osd_logo_rom` | 160×94 的安路 Logo，每像素 6 位 `{类别,α[4:0]}` |

### 素材与 TD 的 ROM 推断（实测）

- 素材由 [tb_custom/gen_osd_assets.py](../tb_custom/gen_osd_assets.py) 生成（`python gen_osd_assets.py`，确定性）：ASCII 字形用 DejaVu Sans Mono（宽松的 Bitstream Vera / DejaVu 许可）；12 个汉字用本机黑体渲染成 1 位点阵；**Logo 的像素数据取自参考例程 Lab3 的 `anlogic_logo_rom.v`（只读）**，把它边缘与白色混合后的像素还原成"颜色类别 + 透明度"，所以能叠加到任何视频上而没有白边。叠加逻辑、存储方式、衬底等都是我们自己的。预览图在 `logs_custom/osd_preview/`。汉字字体和 Logo 素材若要在提交材料里随源码发布，请团队自行确认字体与商标的使用许可。
- **TD 的 ROM 推断**：用 `case` 写的 ROM 被 TD 综合成约 1 万个逻辑门（字体），Logo 那个 15040 项的 `case` 甚至 `optimize_rtl` 超过 280 秒不结束。现在改成 TD 自带模板（`F:\TD\template\verilog\Synthesis-Structure\Directive\ROM-Inference-Styles`）的写法：`(*rom_style="bram"*)` 数组 + `initial` 里非阻塞赋值 + 同步读。TD 把它映射成带初值的块存储：**字体 2 个 ERAM20K，Logo 5 个，共 7/108（6.5%）**，网表里能看到 `PH1P_PHY_ERAM_V2` 与 `INIT` 数据（已核对 INIT 内容与字体逐位对应：一块存 `[7:5]`，一块存 `[3:0]`，第 4 位在校验区）。TD 会对它们报 `HDL-5314: net 'mem' does not have a driver`，**这是预期的、无害的**，`initial` 的内容仍被用作初值。

### 集成示意（设计说明；实际接法见 §4d，**未在硬件上验证**）

OSD 把"显示用 RGB"整体延后若干拍，所以显示时序必须同步延后。以基线为例：数据取 `S_video_rd_data`，`S_hdmi_de/user/last` 送适配器（`SYNC_DELAY` = RGB 滞后 `de` 的拍数，疑似 2，未证实），适配器 → [`view_mux`] → `osd_overlay` → `hdmi_tx`。这条路径相对 `S_hdmi_de` 的总延迟是 `SYNC_DELAY + 1 + (view_mux ? 1 : 0) + 3`；`hdmi_tx` 的 `vsync/hsync/de` 就用 `sync_delay` 把 `uivtc` 的 `O_vtc_vs/hs/de_valid` 延迟这个拍数（例如 2+1+1+3 = 7）。提供给 `video_out` 的读使能 `S_hdmi_window_rd_en` 仍用未延迟的 `S_hdmi_de`。这样不改 `hdmi_mixer`，该模块在新路径里不再使用。上板前须先验证 8.1 第 6 点。

## 4d. contest_vision_path（集成块，第 3 批后半，**已接入 `contest_work`，仅有仿真与综合 / 布线工具结果，无上板结果**）

[rtl_custom/contest_vision_path.v](../rtl_custom/contest_vision_path.v) 把前面所有模块接成一条路径，夹在基线的"帧缓存读出 / `uivtc` 时序"与 `hdmi_tx` 之间，并带一个旁路开关回到基线画面。`contest_work` 顶层只有三处改动：新增 `I_sw[3:0]` / `O_led[3:0]` 端口、实例化本块、`hdmi_tx` 的 `I_video_in_vs/de/data` 改接本块输出（其余全部与 lab1 相同，`tb_custom/verify_contest_work.py` 逐文件核对）。

```
uivtc de/user/last + 帧缓存 RGB ──► video_pos_adapter ──┬──► rgb_to_gray ────┐
                                                         │                    ├─► view_mux ─► osd_overlay ─► tx_data
                                                         ├──► color_segment ──┘      ▲(原图延迟 2 拍)
                                                         │        └─► frame_bbox ─► res_*（框、中心、像素数）
基线 hdmi_mixer 输出 (base_vs/de/data) ───────────────────────────────────────────── 旁路时直通
```

| 端口 | 说明 |
|---|---|
| `clk` / `rst_n_async` | 接 `S_hdmi_pixel_clk`（STA 报告约 75.0 MHz）/ `S_hdmi_rst_n`（PLL lock）；复位在块内同步释放（2 级）；`sw` 用 2 级触发器同步 |
| `vtc_vs/de/user/last` | `uivtc` 的输出，**不延迟** |
| `rd_rgb` | `S_video_rd_data`（帧缓存读出，24 位，基线顺序待实物核实） |
| `base_vs/de/data` | `hdmi_mixer` 的输出，旁路时原样送 `hdmi_tx` |
| `sw[0]` | 1 = 处理后画面，0 = **基线画面**（上电默认取决于拨码位置） |
| `sw[2:1]` | 显示模式：00 原图、01 灰度、10 颜色掩膜、11 原图 + 命中像素涂洋红 |
| `sw[3]` | 1 = 另画目标框、十字、计数线（x=640）；0 = 只画 Logo 与文字 |
| `led[0]` | 目标已找到（`res_valid`，红色像素数 ≥ `MIN_PIXELS`=400） |
| `led[1]`（板上 LED2） | 适配器 `geom_err` 的粘滞标志（`sw[0]=0` 时清除；亮 = 基线 `user/last` 与合约不符） |
| `led[2]`（板上 LED3） | `res_frame_id[4]`：每 16 帧翻转一次（约 1.9 Hz 闪烁表示统计在逐帧更新） |
| `led[3]` | 处理路径启用 |

参数：`SKEW=2`（RGB 比 `uivtc` 的 `de` 晚的拍数，**推断值，未证实**）、`R_MIN=80`、`DELTA=30`、`MIN_PIXELS=400`、`LINE_X=640`。

**延迟与时序**：`uivtc` 的 `de` 到 `tx_de` 的固定延迟 = `SKEW`（适配器内的 RGB 补偿）+ 1（适配器）+ 2（灰度 / 分割）+ 1（`view_mux`）+ 3（OSD）= `SKEW+7` = 9 拍；`tx_vs` / `tx_de` 都由 `sync_delay` 延迟同样的拍数。旁路时 `tx_*` = `hdmi_mixer` 输出，即基线延迟 3 拍。**`SKEW` 选错的后果**：画面（与 OSD 坐标）整体偏移 `|实际-SKEW|` 个像素，行首 / 行尾可能多出 1–2 个像素的无效列；帧结构、统计结果不受影响。

**切换行为**：`sw[0]` 异步拨动，2 级同步后直接切换多路器。在帧中间拨动会让那一帧上半部分是一种画面、下半部分是另一种；在 `vsync` 附近拨动可能使那一帧的 `vsync` 脉冲缩短几拍。这些都是一次性、可自行恢复的显示瞬态，设计上没有做帧边界锁存（如需要可作为后续改进）。视图模式 `sw[2:1]` 在 OSD 内部于帧首采样，所以只在帧边界生效。

**验证（仿真）**：[tb_custom/tb_vision_path.v](../tb_custom/tb_vision_path.v) 用**未修改的 `uivtc.v`** 作时序源，帧缓存 RGB 比 `de` 晚 2 拍（`ACT_SKEW`），位置相关的伪随机颜色图案，`DUT` 用默认参数（`SKEW=2`）。6 帧：原图、灰度、掩膜、涂色、原图 + `sw[3]`、旁路。逐拍检查 `tx_de/tx_vs` 等于 `uivtc` 输出延迟 9 拍；在 OSD 文字区以外每个像素的 `tx_data` 等于独立计算的期望色；`sw[3]` 帧里检查计数线像素；旁路帧里 `tx_*` 逐拍等于 `base_*`；`led` 检查。负对照：`SKEW` 覆盖为 1 或 3 时该测试必然失败（见 STATUS 的实际结果）。

## 4e. cross_counter（越线计数状态机，第 4 批，**纯 RTL + 仿真，尚未接入 `contest_work`，不在 `release` 的位流里**）

[rtl_custom/cross_counter.v](../rtl_custom/cross_counter.v)：每帧一个样本，判断目标中心 `cx` 是否越过竖线 `line_x`，计数。接口 `clk, rst_n, upd, valid, cx[11:0], line_x[11:0]` → `evt, evt_dir, cnt_lr, cnt_rl, cnt_total, side`；参数 `HYST=12, CONFIRM=2, LOST_MAX=5, CNT_W=16`。典型接法：`upd=frame_done, valid=res_valid, cx=res_cx`（`frame_bbox` 的结果与 `frame_done` 在同一个时钟沿更新）。`upd=0` 时 `valid/cx/line_x` 一律忽略；无 ready、无停顿；输出在 `upd` 之后 1 拍变化；复位低有效异步。

**每帧的区域**（13 位算术，不回绕）：`N` = `valid=0`；`L` = `cx + HYST < line_x`；`R` = `cx > line_x + HYST`；`M`（死区）= 其余。

**状态与规则**：`side` = 最近一次**确认**的一侧（未知 / 左 / 右），`cand/ccnt` = 换边候选及其连续帧数，`lcnt` = 连续丢目标帧数。

| 样本 | 动作 |
|---|---|
| `N`（丢目标） | `lcnt` 加 1；候选清零；`lcnt > LOST_MAX` 则忘记 `side`（再出现时只学习新一侧，**不计数**） |
| `M`（死区） | `lcnt` 清零，候选清零，`side` 不变 |
| `L` / `R` 且等于 `side` | 候选清零 |
| `L` / `R` 且不等于 `side` | 连续 `CONFIRM` 帧都在另一侧才算确认：`side` 改为新一侧；若旧 `side` 不是未知，则计一次越线（`L→R` 记 `cnt_lr`、`R→L` 记 `cnt_rl`，`evt` 一拍脉冲，`evt_dir` 保持最近一次方向） |

效果：死区内抖动、单帧毛刺、目标短暂丢失后回到原来一侧都不会计数；开机时目标已经在线的某一侧只学习，不计数；丢失超过 `LOST_MAX` 帧再出现在另一侧也只学习。三个计数器饱和于 `2^CNT_W-1`。`line_x` 每帧采样一次，应保持不变（移动线等于移动区域）。计数的是**包围框中心**（`frame_bbox` 给的不是质心），一个目标；多目标、遮挡、同时进出不在设计范围内。

**接入 `contest_vision_path` 的改动（设计，未实施、未构建）**：例化 `cross_counter`（`upd=frame_done`、`valid=res_valid`、`cx=res_cx`、`line_x=LINE_X_C`），把 `cnt_total` 接到 `osd_overlay.cross_cnt`（现在是常数 0，OSD 的 `CROSS:` 行即显示它），其余不变。`cnt_total` 在一帧结束后变化，比下一帧 SOF 早整个垂直消隐（远大于 OSD 要求的 43 拍），显示的是上一帧的结果，与目标框同样滞后一帧。该改动会改变 `contest_vision_path.v` 与位流，需要重新跑集成块仿真 / 变异测试、同步进 `contest_work`、重新构建；建议等第一次上板结果回来后再做，以免上板对象不停变化。

**验证**：[tb_custom/tb_cross_counter.v](../tb_custom/tb_cross_counter.v)：三个参数组不同的 DUT（默认；`HYST=0 CONFIRM=1 LOST_MAX=0 CNT_W=3`；`HYST=20 CONFIRM=3 LOST_MAX=2`）看同一激励。(1) 9 个手算期望的定向场景（正常左→右、死区抖动、单帧毛刺、往返、短丢失、长丢失、右侧开机、饱和、复位清候选），场景后核对三个 DUT 的 `cnt_lr/cnt_rl`（或复位后的 `side`），外加一个 `line_x`=0 / 4095 与 `cx`=0 / 4095 极值场景（只与参考模型比较）；(2) 在 testbench 里用普通整数另写的参考模型（不是 RTL 的结构），每个时钟逐位比较每个 DUT 的全部输出，包含 400,000 帧随机运行（随机游走越线、丢目标突发、随机 `line_x` 含 0 / 4095、帧间 0–3 个带垃圾数据的空闲拍、背靠背样本、随机复位）；结尾检查覆盖计数（事件、忘记、候选重置、死区、新一侧学习、饱和、丢失突发、短丢失后恢复）不低于阈值，避免空转通过。

## 5. 级联延迟汇总

| 路径 | 固定延迟（拍） | 备注 |
|---|---|---|
| `in_*` → `rgb_to_gray.out_*` | 2 | 全部输出同拍对齐 |
| `in_*` → `color_segment.out_*` | 2 | 全部输出同拍对齐 |
| `vid_de` → `video_pos_adapter.out_de` | `SYNC_DELAY`+1 | `vid_rgb` → `out_rgb` 为 1 拍 |
| 适配器 EOF 输出 → `frame_bbox.frame_done`（经 `color_segment`） | 2 + 1 = 3 | 完整链路的 testbench 逐拍验证 |
| `color_segment.out_*` → `frame_bbox.frame_done / res_*` | 1（相对 EOF 像素） | 结果之后一直保持 |
| 输入的 EOF 像素 → `frame_done`（`color_segment` 后接 `frame_bbox`） | 2 + 1 = 3 | 仅指模块内流水线周期，不是端到端时延 |

时钟 / 复位：单时钟域，无跨时钟。复位为低有效异步，释放须在集成时同步。

## 6. 文件清单

| 文件 | 用途 |
|---|---|
| [rtl_custom/rgb_to_gray.v](../rtl_custom/rgb_to_gray.v) | 灰度 |
| [rtl_custom/color_segment.v](../rtl_custom/color_segment.v) | 红色阈值 + ROI |
| [rtl_custom/frame_bbox.v](../rtl_custom/frame_bbox.v) | 帧统计 |
| [tb_custom/tb_rgb_to_gray.v](../tb_custom/tb_rgb_to_gray.v) | 灰度自检 |
| [tb_custom/tb_color_segment.v](../tb_custom/tb_color_segment.v) | 分割自检（7 组参数同时检查） |
| [tb_custom/tb_frame_bbox.v](../tb_custom/tb_frame_bbox.v) | 帧统计自检（4 组参数同时检查） |
| [rtl_custom/video_pos_adapter.v](../rtl_custom/video_pos_adapter.v) | 位置适配（`user/last` → `x/y/sof/eol/eof`），第 2 批 |
| [tb_custom/tb_video_pos_adapter.v](../tb_custom/tb_video_pos_adapter.v) | 适配器自检：Part A 用未修改的 `uivtc.v` 驱动 7 组几何；Part B 6 组协议测试（手写期望 + 参考模型 + 随机流 + 复位） |
| [tb_custom/tb_vtc_chk.v](../tb_custom/tb_vtc_chk.v) | 上面两个 testbench 共用：`uivtc` + 适配器 + 以 `uivtc` 自己的 `hcnt/vcnt` 为真值的检查模块 |
| [tb_custom/tb_pos_chain.v](../tb_custom/tb_pos_chain.v) | 完整链路：真实 1280×720 `uivtc` → 适配器 → `color_segment` → `frame_bbox`，4 帧不同的红色矩形 |
| [rtl_custom/osd_overlay.v](../rtl_custom/osd_overlay.v)、[osd_bin2bcd.v](../rtl_custom/osd_bin2bcd.v)、[view_mux.v](../rtl_custom/view_mux.v)、[sync_delay.v](../rtl_custom/sync_delay.v) | OSD 与显示辅助模块，第 3 批（§4c） |
| [rtl_custom/osd_font_rom.v](../rtl_custom/osd_font_rom.v)、[osd_logo_rom.v](../rtl_custom/osd_logo_rom.v) | **生成的** ROM（字体 / 安路 Logo），不要手改，由 `gen_osd_assets.py` 生成 |
| [tb_custom/gen_osd_assets.py](../tb_custom/gen_osd_assets.py) | 生成上面两个 ROM 与 `osd_assets/font.npy`、`logo.npy`，并在 `logs_custom/osd_preview/` 输出预览图 |
| [tb_custom/gen_osd_golden.py](../tb_custom/gen_osd_golden.py) | OSD 的**独立** Python 黄金模型：只读素材，按 §4c 的规格渲染整帧，生成稀疏黄金文件 `tb_custom/osd_assets/golden/`（`run_all.ps1` 会先运行它） |
| [tb_custom/tb_osd_overlay.v](../tb_custom/tb_osd_overlay.v) | OSD 逐像素自检：7 个整帧 1280×720 与黄金模型逐点比对，帧中途改控制量验证帧一致性 |
| [tb_custom/tb_osd_aux.v](../tb_custom/tb_osd_aux.v) | `osd_bin2bcd`（4096 个值穷举等）、`view_mux`、`sync_delay` 自检 |
| [tb_custom/tb_osd_chain.v](../tb_custom/tb_osd_chain.v) | 整机：真实 `uivtc` → 适配器 → {`color_segment` → `frame_bbox`, `osd_overlay`}，4 帧，OSD 的框与数字取自 `frame_bbox`，与黄金模型逐点比对 |
| [rtl_custom/contest_vision_path.v](../rtl_custom/contest_vision_path.v)、[tb_custom/tb_vision_path.v](../tb_custom/tb_vision_path.v) | 集成块（接入 `contest_work`）与它的整机测试（真实 `uivtc`、旁路、四种视图），§4d |
| [rtl_custom/cross_counter.v](../rtl_custom/cross_counter.v)、[tb_custom/tb_cross_counter.v](../tb_custom/tb_cross_counter.v) | 越线计数状态机与它的自检（第 4 批，§4e；未接入 `contest_work`） |
| [tb_custom/verify_contest_work.py](../tb_custom/verify_contest_work.py) | 来源核对：基线 368 项哈希、`contest_work` 与 lab1 只有预期的 3 处差别、自研源码与 `rtl_custom` 一致 |
| [contest_work/scripts/build_cli.ps1](../contest_work/scripts/build_cli.ps1)、[sync_custom.ps1](../contest_work/scripts/sync_custom.ps1) | TD 命令行完整构建；把 `rtl_custom` 同步进工程并核对 |
| [tb_custom/run_all.ps1](../tb_custom/run_all.ps1) | 找 iverilog，编译并运行全部 9 个 testbench，日志写入 logs_custom（`-SkipChain` 跳过三个 1280×720 长测试） |
| [tb_custom/td_check.ps1](../tb_custom/td_check.ps1) | 用已安装的 TD 做读入 / `optimize_rtl` / testbench `analyze` 检查，含负对照 |
| [tb_custom/contract_check.py](../tb_custom/contract_check.py) | Python 合约数字自检（不验证 RTL） |
| [tb_custom/mutation_test.py](../tb_custom/mutation_test.py)、[mutation_parallel.py](../tb_custom/mutation_parallel.py) | 变异测试：向 RTL 副本注入典型缺陷（前 4 个模块 79 个、OSD 组 61 个、集成块 16 个，实际结果见 STATUS），要求 testbench 报 FAIL；`rtl_custom` 本身不会被改动；后者并行运行并合并 |
| [tb_custom/run_modelsim.do](../tb_custom/run_modelsim.do) | ModelSim / Questa 运行脚本（已在 SE-64 2020.4 上跑通） |
| [tools/iverilog/](../tools/iverilog/README.txt) | 私有 Icarus Verilog 13.0（来源、SHA-256、卸载方法见 README.txt）；`run_all.ps1` 与 `mutation_test.py` 会自动找到它 |

### 自检设计要点

- 期望值与 DUT 实现分离：灰度用 32 位整数与 `/`（DUT 用位切片）；分割用 32 位**有符号**整数的 `R-G>=DELTA`（DUT 用 11 位无符号加法）；包围框用"列 / 行占用扫描"从边界向内找最小 / 最大（DUT 是增量 min/max），中心用整数 `/2`。
- 延迟用独立的、按同样方式复位的期望流水线逐拍比较，不靠"等一会儿"。`frame_done` 的期望时刻由 testbench 在送出 EOF 像素的同一拍给出选通，DUT 必须在下一拍出现；每一拍还要求所有 `res_*` 等于模型，因此同时检查"保持到下一次完成"。
- 覆盖：黑 / 白 / 红 / 绿 / 蓝、单通道扫描、灰阶 `(v,v,v)`、随机 RGB、有效空洞（消隐拍灌入任意 RGB / hit / sof / eol / eof）、连续帧、复位（含异步复位、小于一个时钟周期的复位脉冲）；分割：ROI 四边及刚越界点、相等阈值、差一阈值、`G+DELTA` 超 255 的回卷陷阱、R×G 平面 × 7 个 B 值、`R_MIN=0/DELTA=0` 与 `255/255` 极值、`X1/Y1=4096`；帧统计：空帧、单点、矩形、首 / 末像素、四角、满帧、1280×720 满帧和四角、相邻两帧目标完全不同、EOF 紧接 SOF、帧中复位、复位后无 SOF 的残帧（不得输出）、帧中 SOF 重启（`frame_abort`）、数量阈值 15 / 16 / 17、`CNT_W=4` 饱和、`MIN_PIXELS=0` 仍要求至少 1 个命中、1×1 / 1×N / N×1、80 个随机帧、65540 个单像素帧检验 `res_frame_id` 回卷。
- 结束时各 testbench 还检查覆盖量（比较的时钟数、命中数、完成帧数）是否达标，避免空转通过。
- 随机数种子写在 testbench 开头并在日志首行打印：灰度 `0x5EED0001`、分割 `0x5EED0002`、帧统计 `0x5EED0003`。失败时打印 testbench 名、时刻、字段、期望、实际及当拍输入（分割还打印 x/y，帧统计还打印 sof/eof），`TB_RESULT: FAIL` 并在 `run_all.ps1` 里返回非零。

## 7. 测试命令与实际结果

实际结果（以此为准，没有运行写"未运行"）：

| 检查 | 命令 | 结果 |
|---|---|---|
| 行为仿真（iverilog 13.0） | `powershell -ExecutionPolicy Bypass -File F:\fpga_s2\tb_custom\run_all.ps1` | **9/9 PASS**，退出码 0（总耗时约 1 小时，`-SkipChain` 跳过三个 1280×720 长测试）。灰度 208,618 拍、分割 771,433 拍（7 组参数）、帧统计 1,992,994 拍 / 65,664 帧、适配器 Part A 50,067 拍 + Part B 6 组、`osd_aux`、`osd_overlay` 6,454,259 拍（7 整帧逐点比对）、链路 6,137,591 拍、整机 OSD 3,686,400 像素、集成块 8,622,496 拍，均 0 错误；汇总 `logs_custom/run_all_console_v4.txt` |
| 穷举 2^24 色（`-DFULL_SWEEP`） | 手工编译，见下 | 灰度 PASS（16,985,838 拍，0 错误，`logs_custom/sim_full_rgb_to_gray.log`）；分割 PASS（8 个并行区间 `+SWEEP_LO/+SWEEP_HI` 连续覆盖 0..16,777,215，7 组参数全部 0 错误，`logs_custom/sim_full_color_segment_part0..7.log`） |
| 变异测试 | `python tb_custom\mutation_test.py`（前 4 个模块）；`python tb_custom\mutation_parallel.py <jobs> <tag> <模块子串...>`（OSD 组、集成块） | 前 4 个模块 78 个注入缺陷全部被抓到 + 1 个等价变异体（已论证）；OSD 组 61 个全部抓到；集成块 16 个全部抓到；越线计数器 32 个中 30 个抓到、2 个已论证等价（见 §4e 与 STATUS）；0 幸存。`logs_custom/mutation_report.txt`、`mutation_summary_osd2.txt`、`mutation_summary_vp.txt`。OSD 组第一轮曾有 2 个幸存变异体，修正 testbench / 黄金场景后重跑，经过见 STATUS |
| ModelSim SE-64 2020.4 编译 | `F:\medolsim\win64\vlog.exe -lint <tb> <rtl>` | 三组均 0 错误 0 警告（`logs_custom/modelsim_vlog.log`），仅编译 |
| ModelSim 仿真 | `vsim.exe -c -do "set TBDIR F:/fpga_s2/tb_custom; do F:/fpga_s2/tb_custom/run_modelsim.do"` | **9/9 PASS**，计数与 iverilog 一致（`logs_custom/modelsim_sim.log`）。`vsim -c` 脚本出错时仍返回退出码 0，务必看 `TB_RESULT` 行 |
| TD 读入 + `optimize_rtl` + testbench 语法 | `powershell -ExecutionPolicy Bypass -File F:\fpga_s2\tb_custom\td_check.ps1` | 见 [logs_custom/td_check/td_check_summary.txt](../logs_custom/td_check/td_check_summary.txt)（含 `contest_vision_path` 与 9 个 testbench） |
| **TD 命令行完整构建（`contest_work`）** | `powershell -ExecutionPolicy Bypass -File F:\fpga_s2\contest_work\scripts\build_cli.ps1 -EndStep bitgen -Tag full2` | **成功**：0 错误，Setup WNS +1.175 ns / Hold WNS +0.020 ns / 0 违例；LUT6 10878、寄存器 14127、ERAM 47、DSP 17（未改动基线重建：9836 / 13321 / 40 / 8）；位流 `release/contest_work_20261006_cli_full2.bit`。**没有下载 / 上板**。数字与说明见 STATUS 与 `CODEX_HANDOFF_BURN.md` |
| Python 合约数字 | `python F:\fpga_s2\tb_custom\contract_check.py` | 见 [logs_custom/contract_check.log](../logs_custom/contract_check.log) |

手工命令（等价于 `run_all.ps1`，在 `F:\fpga_s2\tb_custom` 下执行）：

```bash
iverilog -g2005 -Wall -o sim_gray.vvp tb_rgb_to_gray.v   ../rtl_custom/rgb_to_gray.v   && vvp sim_gray.vvp
iverilog -g2005 -Wall -o sim_seg.vvp  tb_color_segment.v ../rtl_custom/color_segment.v && vvp sim_seg.vvp
iverilog -g2005 -Wall -o sim_bbox.vvp tb_frame_bbox.v    ../rtl_custom/frame_bbox.v    && vvp sim_bbox.vvp
```

testbench 文件放在命令行最前面，是为了让它的 `` `timescale `` 同时作用于没有 `timescale` 的 RTL 文件，避免 iverilog 的 timescale 提示。

每个 testbench 最后一行为 `TB_RESULT: PASS <name>` 或 `TB_RESULT: FAIL <name> errors=N`。加 `-DFULL_SWEEP` 可对灰度和分割做全部 2^24 种颜色的穷举：灰度单进程约 7 分钟；分割单进程需 35 分钟以上，可按区间并行，例如 `vvp sim_seg_full.vvp +SWEEP_LO=0 +SWEEP_HI=2097152`，换不同区间同时开多个进程。

TD 的 RTL 级统计（`optimize_rtl` 后的 `report_area`，**不是综合 / 布局布线后的资源占用，也没有时序**；"—"= 未记录该列。布局布线后的真实资源见上面完整构建一行）：

| 模块 | DFF | 基本门 | MACRO_ADD | MACRO_MULT | MACRO_MUX | 锁存器 |
|---|---|---|---|---|---|---|
| rgb_to_gray | 107 | 110 | 2 | 3 | 32 | 0 |
| color_segment | 109 | 119 | 7 | 0 | 48 | 0 |
| frame_bbox（`CNT_W=20`） | 182 | 218 | 9 | 0 | 209 | 0 |
| video_pos_adapter（默认参数） | 76 | — | — | — | — | 0 |
| osd_overlay | 589 | — | — | — | — | 0 |
| contest_vision_path（含上面所有模块） | 889 | — | — | — | — | 0 |

## 8. 适配到基线 RGB 的建议（仅静态读码，**未经波形或仿真验证**）

以下事实来自对 lab1 源码的阅读，行号为交接时副本。结论标"推断"的必须由 Codex 用波形、ChipWatcher 或基线路径仿真证实后才能当真。

### 8.1 基线里已读到的事实

1. [uivtc.v:127-138](../lab1/user_source/hdl_source/vtc/uivtc.v) 的寄存器链：`O_vtc_de_valid = valid_r2`、`O_vtc_user = user_r2`、`O_vtc_last = last_r2`。按寄存器链推演，**`user` 与帧第一个有效像素同拍，`last` 与每行最后一个有效像素同拍**，都在 `de_valid` 为 1 的拍内；没有整帧结束标志。**这一点已在第 2 批用未修改的 `uivtc.v` 仿真证实**：7 组小几何和真实 1280×720 / 1650×750 下，以 `uivtc` 自己的 `hcnt/vcnt` 为坐标真值，`user` 都恰在帧首像素、`last` 都恰在行末像素、二者都不在 `de=0` 时出现（`tb_vtc_chk.v` 的检查）。注意这只说明 `uivtc` 的输出，不说明 `hdmi_mixer` 里 RGB 的相对拍数。
2. 因此整帧结束像素 = `last && 该行是最后一行`，行号要自己数；不能拿 `last` 当 EOF。
3. [hdmi_mixer.v:39](../lab1/user_source/hdl_source/hdmi_mixer.v) `O_video_rd_en = I_video_de`，在 [design_top_wrapper.v:723,828](../lab1/user_source/hdl_source/design_top_wrapper.v) 经 `S_hdmi_window_rd_en` 接到 `video_out` 的 `I_video_rd_en`。
4. [video_out.v:157-198](../lab1/user_source/hdl_source/video_out.v)：每 16 个像素用 3 个 128 位字，FIFO 读使能在 `rd_cnt==0/5/10` 拍；输出 `O_vdieo_data` 是寄存器输出。FIFO 参数 `SHOW_AHEAD_EN=0, OUTREG_EN="NOREG"`（[w128_d512_fifo.v:28-29](../lab1/user_source/ip_source/w128_d512_fifo/w128_d512_fifo.v)），即同步读，读数据在 `re` 后 1 拍出现。由此推演：**de 有效拍 c 对应的像素 RGB 在 `O_vdieo_data` 上出现于 c+2 拍**。
5. [hdmi_mixer.v:75-87,143](../lab1/user_source/hdl_source/hdmi_mixer.v)：`de/hsync/vsync` 与 RGB 各经 3 级寄存器到 `O_hdmi_*`。
6. **推断（待证实）**：de 链延迟 3、RGB 总延迟 2+3=5，即 `O_hdmi_data` 比 `O_hdmi_de` **晚 2 拍**：每行左侧 2 个像素为黑，右侧最后 2 个像素落入消隐。这对 HDMI 编码器而言可能只是画面右移 2 像素，肉眼难察觉；但叠加框的坐标必须以**数据**的位置为准。
7. **不要复用 `hdmi_mixer` 里的 `S_x/S_y`**：[hdmi_mixer.v:41-59](../lab1/user_source/hdl_source/hdmi_mixer.v) 的计数器在 `user` 那一拍才复位，所以每帧第一行 x 偏 1、第一个像素的 y 还是上一帧的残值；它只在 DEBUG 彩条里使用，从未被当作坐标源验证过。

### 8.2 建议的对齐关系与时序图

下图以 `t=0` 为一行第一个像素的 `S_hdmi_de` 上升拍（均为推演，不是波形）：

```
t                      : -1   0    1    2    3    4    5    6        W-1   W    W+1  W+2
S_hdmi_de (=rd_en)     :  0   1    1    1    1    1    1    1   ...   1    0    0    0
S_hdmi_user (行0, 1拍) :  0   1    0    0    0    0    0    0   ...
S_hdmi_last            :  0   0    0    0    0    0    0    0   ...   1    0    0    0
FIFO re                :  0   1    0    0    0    0    1    0   ...
O_vdieo_data (=S_video_rd_data): .  .  .   P0   P1   P2   P3   P4  ...  ...  P(W-1)
mixer.O_hdmi_de        :  .   .    .    .    1    1    1    1   ...   1    1    1    0  (de 链 3 级)
mixer.O_hdmi_data      :  .   .    .    .    .    .    P0   P1  ...        <- RGB 比 de 晚 2 拍 (推断)
```

### 8.3 推荐的集成顺序（每步都能回退）

1. **只观察的统计旁路**（阶段 B）：在 `S_video_rd_data` 处并联取数，另写一个小的位置适配模块，把 `S_hdmi_de / user / last` 延迟 2 拍与 RGB 对齐，再产生 `x/y/sof/eol/eof` 接 `color_segment → frame_bbox`。显示路径完全不动，先用 ChipWatcher 或 LED 看 `res_valid / res_cx`。位置适配的计数方式要避免 8.1 第 7 点的问题：

   ```
   x_cur = (de & user) ? 0 : x_nxt;          // 本拍像素的 x
   y_cur = (de & user) ? 0 : y_nxt;
   on de:  last ? (x_nxt<=0; y_nxt<=y_cur+1) : (x_nxt<=x_cur+1; y_nxt<=y_cur)
   sof = de & user;   eol = de & last;   eof = de & last & (y_cur == HEIGHT-1)
   ```

   这个适配模块就是第 2 批的 `video_pos_adapter`（§4b），已用**未修改的 `uivtc.v` 实例**（含真实 1650×750 总周期）验证了 `sof/eol/eof/x/y` 的对齐，并和 `color_segment`、`frame_bbox` 串成完整链路仿真。接入时：`vid_de/vid_user/vid_last` 接 `S_hdmi_de/S_hdmi_user/S_hdmi_last`，`vid_rgb` 接 `S_video_rd_data`；`SYNC_DELAY` 要等 8.1 第 6 点证实后再定（仿真 `uivtc + video_out + hdmi_mixer`，或实物抓 `O_hdmi_de` 与 `O_hdmi_data`）；注意 `geom_err` 只反映行列几何，**对 `SYNC_DELAY` 选错不敏感**，2 拍的偏差在包围框上只是 2 个像素，肉眼也很难看出来。
2. 证实 8.1 第 6 点：最小办法是用 testbench 把 `uivtc + video_out（含 soft FIFO 的行为模型）+ hdmi_mixer` 串起来仿真，看 `O_hdmi_de` 与 `O_hdmi_data` 的拍差；或者实物上用 ChipWatcher 抓 `O_hdmi_de` 和 `O_hdmi_data`。
3. 阶段 C 的叠加：在 `hdmi_mixer` 的输出（`O_hdmi_data` 与 `O_hdmi_de` 同一级）前后插入叠加级，并让 `vsync/hsync/de` 与叠加级总延迟一致。不要在不知道偏差的情况下直接改 mixer；需要的话在 `contest_work` 副本里改并留 diff。
4. 在 3 之前不要把 `rgb_to_gray` 的输出送进显示路径，否则 RGB 比同步晚的拍数会再增加，必须同步加延迟。

### 8.4 其它集成前必须确认的事项

- RGB 字节顺序：基线输出 24 位的 `[23:16]/[15:8]/[7:0]` 对应 R/G/B 还是别的，用红色物体或彩条确认；`color_segment` 假设 `[23:16]=R`。
- 板上复位 / 按键约束：原例程 `I_rst_n=R10`、`I_button=N2/J14`，板载 KEY 是 D5/A9/B9/C7，接入前按原理图确认（见 CLAUDE.md）。
- 新模块的 `rst_n` 必须来自已同步释放的复位（基线的 `S_hdmi_rst_n` 需读源码确认是否同步释放）。
- 屏幕是否接收 720p 仍未验收。
