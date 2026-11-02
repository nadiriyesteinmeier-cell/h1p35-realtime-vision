#!/usr/bin/env python3
"""net_mutants.py - mutation test of the engine around the cores (rtl_custom/yolo_net_engine.v, yolo_bank_ram.v) against the end-to-end mini-network test (run_net_tests.py)

Every mutant is the unchanged RTL with ONE deliberately injected bug in the sequencer, the descriptor decoding, the bank multiplexers or the RAM. A mutant is
KILLED when at least one case fails, it SURVIVED when everything still passes. The control run (unmodified RTL) must pass.
Equivalent mutants are argued in docs/YOLO_FEASIBILITY_2026-10-16.md (the aux core is started during convolution layers in `ne_aux_start_always`; its writes are not
connected then, so that change cannot be seen at the banks).
Usage: python net_mutants.py [jobs [name ...]]      -> logs_custom/yolo_vec/net_mutation_summary.txt   (names: run only these mutants)
"""
import concurrent.futures as cf
import os
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..', '..'))
RTLDIR = os.path.join(ROOT, 'rtl_custom')
WORK = os.path.join(ROOT, 'logs_custom', 'yolo_mut_net')
FILES = ['yolo_net_engine.v', 'yolo_conv_core.v', 'yolo_aux_core.v', 'yolo_bank_ram.v']

E = 'yolo_net_engine.v'
R = 'yolo_bank_ram.v'
MUT = [
    ("ne_latch_early", E, "if (state == S_LATCH) begin\n            c_op", "if (state == S_FETCH) begin\n            c_op"),
    ("ne_op_field", E, "c_op <= desc_data[2:0];", "c_op <= desc_data[3:1];"),
    ("ne_src_field", E, "c_src <= desc_data[4:3];", "c_src <= desc_data[5:4];"),
    ("ne_dst_field", E, "c_dst <= desc_data[6:5];", "c_dst <= desc_data[4:3];"),
    ("ne_h_field", E, "c_h <= desc_data[18:7];", "c_h <= desc_data[17:6];"),
    ("ne_w_field", E, "c_w <= desc_data[30:19];", "c_w <= desc_data[29:18];"),
    ("ne_cin_field", E, "c_cin <= desc_data[41:31];", "c_cin <= desc_data[40:30];"),
    ("ne_cout_field", E, "c_cout <= desc_data[52:42];", "c_cout <= desc_data[51:41];"),
    ("ne_k3_field", E, "c_k3 <= desc_data[53];", "c_k3 <= desc_data[54];"),
    ("ne_act_field", E, "c_act <= desc_data[54];", "c_act <= desc_data[55];"),
    ("ne_pool_field", E, "c_pool <= desc_data[55];", "c_pool <= desc_data[54];"),
    ("ne_in_base_field", E, "c_in_base <= desc_data[75:56];", "c_in_base <= desc_data[74:55];"),
    ("ne_in_row_field", E, "c_in_row <= desc_data[95:76];", "c_in_row <= desc_data[94:75];"),
    ("ne_in_pix_field", E, "c_in_pix <= desc_data[115:96];", "c_in_pix <= desc_data[114:95];"),
    ("ne_out_base_field", E, "c_out_base <= desc_data[135:116];", "c_out_base <= desc_data[134:115];"),
    ("ne_out_row_field", E, "c_out_row <= desc_data[155:136];", "c_out_row <= desc_data[154:135];"),
    ("ne_out_pix_field", E, "c_out_pix <= desc_data[175:156];", "c_out_pix <= desc_data[174:155];"),
    ("ne_wt_base_field", E, "c_wt_base <= desc_data[189:176];", "c_wt_base <= desc_data[188:175];"),
    ("ne_pm_base_field", E, "c_pm_base <= desc_data[200:190];", "c_pm_base <= desc_data[199:189];"),
    ("ne_wt_base_dropped", E, "assign wt_addr = c_wt_base + core_wt_addr;", "assign wt_addr = core_wt_addr;"),
    ("ne_pm_base_dropped", E, "assign pm_addr = c_pm_base + core_pm_addr;", "assign pm_addr = core_pm_addr;"),
    ("ne_aux_mode", E, ".cfg_mode(c_op - 3'd1)", ".cfg_mode(c_op)"),
    ("ne_conv_pool_off", E, ".cfg_pool(c_pool)", ".cfg_pool(1'b0)"),
    ("ne_conv_act_on", E, ".cfg_act(c_act)", ".cfg_act(1'b1)"),
    ("ne_conv_k3_on", E, ".cfg_k3(c_k3)", ".cfg_k3(1'b1)"),
    ("ne_layer_last", E, "if (layer == cfg_nlayers - 1'b1) begin", "if (layer == cfg_nlayers) begin"),
    ("ne_layer_step", E, "layer <= layer + 1'b1;\n                            state <= S_FETCH;", "layer <= layer + 2'd2;\n                            state <= S_FETCH;"),
    ("ne_start_layer0", E, "layer <= {NLW{1'b0}};\n                        state <= S_FETCH;", "state <= S_FETCH;"),
    ("ne_net_done_missing", E, "net_done <= 1'b1;\n                            state <= S_IDLE;", "state <= S_IDLE;"),
    ("ne_layer_done_missing", E, "layer_done <= 1'b1;\n                        if (layer", "if (layer"),
    ("ne_wait_conv_done_for_aux", E, "if (cv ? conv_done : aux_done) begin", "if (conv_done) begin"),
    ("ne_wait_aux_done_for_conv", E, "if (cv ? conv_done : aux_done) begin", "if (aux_done) begin"),
    ("ne_conv_start", E, "conv_start <= cv;", "conv_start <= 1'b0;"),
    ("ne_aux_start", E, "aux_start  <= !cv;", "aux_start  <= 1'b0;"),
    ("ne_wr_mux_src", E, "wire [AW-1:0] w_addr = cv ? conv_out_addr : aux_out_addr;", "wire [AW-1:0] w_addr = cv ? aux_out_addr : conv_out_addr;"),
    ("ne_wdata_mux", E, "wire [7:0]    w_data = cv ? conv_out_data : aux_out_data;", "wire [7:0]    w_data = cv ? aux_out_data : conv_out_data;"),
    ("ne_we_mux", E, "wire          w_we   = cv ? conv_we : aux_we;", "wire          w_we   = cv ? aux_we : conv_we;"),
    ("ne_we_bank1", E, "wire we1 = busy ? (w_we && c_dst == 2'd1)", "wire we1 = busy ? (w_we && c_dst == 2'd0)"),
    ("ne_we_bank2", E, "wire we2 = busy ? (w_we && c_dst == 2'd2)", "wire we2 = busy ? (w_we && c_dst == 2'd3)"),
    ("ne_we_bank3", E, "wire we3 = busy ? (w_we && c_dst == 2'd3)", "wire we3 = busy ? (w_we && c_dst == 2'd2)"),
    ("ne_host_we_bank", E, "(host_we && host_bank == 2'd0)", "(host_we && host_bank == 2'd1)"),
    ("ne_host_wa", E, "wire [AW-1:0] wa = busy ? w_addr : host_addr;", "wire [AW-1:0] wa = busy ? w_addr : host_addr + 1'b1;"),
    ("ne_ra_src_act", E, "else if (b == src_i) ra_sel = cv_i ? a_act : a_aux;", "else if (b == src_i) ra_sel = cv_i ? a_aux : a_act;"),
    ("ne_ra_merge_zero", E, "else if (b == dst_i) ra_sel = cv_i ? a_merge : {AW{1'b0}};", "else if (b == dst_i) ra_sel = {AW{1'b0}};"),
    ("ne_ra_merge_src", E, "else if (b == dst_i) ra_sel = cv_i ? a_merge : {AW{1'b0}};", "else if (b == dst_i) ra_sel = cv_i ? a_act : {AW{1'b0}};"),
    ("ne_act_data_dst", E, "assign act_data    = src_rdata;", "assign act_data    = rd_sel(c_dst, rd0, rd1, rd2, rd3);"),
    ("ne_aux_data_dst", E, "assign aux_rd_data = src_rdata;", "assign aux_rd_data = rd_sel(c_dst, rd0, rd1, rd2, rd3);"),
    ("ne_merge_data_src", E, "assign out_rd_data = rd_sel(c_dst, rd0, rd1, rd2, rd3);", "assign out_rd_data = rd_sel(c_src, rd0, rd1, rd2, rd3);"),
    ("ne_host_rdata_bank", E, "hrb <= host_rbank;", "hrb <= 2'd0;"),
    ("ne_busy_host_mux", E, "wire [7:0]    wd = busy ? w_data : host_wdata;", "wire [7:0]    wd = w_data;"),
    ("rb_read_addr", R, "rdata <= mem[raddr[ABITS-1:0]];", "rdata <= mem[raddr[ABITS-1:0] + 1'b1];"),
    ("rb_write_gate", R, "if (we) mem[waddr[ABITS-1:0]] <= wdata;", "mem[waddr[ABITS-1:0]] <= wdata;"),
    ("rb_write_addr", R, "if (we) mem[waddr[ABITS-1:0]] <= wdata;", "if (we) mem[waddr[ABITS-1:0] + 1'b1] <= wdata;"),
    ("ne_aux_start_always", E, "aux_start  <= !cv;", "aux_start  <= 1'b1;"),
]


# argued equivalent: no bank, address or handshake can observe the change
EQUIVALENT = {'ne_aux_start_always'}


def run_one(item):
    name, fname, old, new = item
    d = os.path.join(WORK, name)
    if os.path.isdir(d):
        shutil.rmtree(d, ignore_errors=True)
    os.makedirs(os.path.join(d, 'rtl'))
    for f in FILES:
        shutil.copy(os.path.join(RTLDIR, f), os.path.join(d, 'rtl', f))
    if name != 'control':
        p = os.path.join(d, 'rtl', fname)
        t = open(p, encoding='utf-8').read()
        assert t.count(old) == 1, (name, 'old text occurs %d times' % t.count(old))
        open(p, 'w', encoding='utf-8', newline='').write(t.replace(old, new))
    try:
        r = subprocess.run([sys.executable, os.path.join(HERE, 'run_net_tests.py'), '--rtl-dir', os.path.join(d, 'rtl'), '--work', os.path.join(d, 'w'), '--lanes', '8',
                            '--quiet', '--stop-first'], capture_output=True, text=True, timeout=1500)
    except subprocess.TimeoutExpired:                       # a mutant that hangs the whole simulation is detected as well (counted as killed)
        return name, 1, 'wall-clock timeout'
    return name, r.returncode, (r.stdout + r.stderr)[-400:]


def main():
    jobs = int(sys.argv[1]) if len(sys.argv) > 1 else 6
    only = set(sys.argv[2:])
    src = {f: open(os.path.join(RTLDIR, f), encoding='utf-8').read() for f in FILES}
    bad = [m[0] for m in MUT if src[m[1]].count(m[2]) != 1]
    if bad:                                                    # fail fast: a mutant whose text no longer matches the RTL would otherwise abort the run at the very end
        print('mutants whose old text does not occur exactly once:', bad)
        return 2
    muts = [m for m in MUT if not only or m[0] in only]
    items = [('control', None, None, None)] + muts
    t0 = time.time()
    res = {}
    with cf.ThreadPoolExecutor(max_workers=jobs) as ex:
        for name, rc, tail in ex.map(run_one, items):
            res[name] = (rc, tail)
    killed = survived = 0
    lines = ['net_mutants %s  wall %.0f s' % (time.strftime('%Y-%m-%d %H:%M:%S'), time.time() - t0), '']
    lines.append('control (unmodified RTL): %s' % ('PASS' if res['control'][0] == 0 else 'FAIL  ' + res['control'][1]))
    for name, fname, old, new in muts:
        rc = res[name][0]
        if res['control'][0] != 0:
            lines.append('%-26s INVALID (the control run failed)' % name)
            survived += 1
        elif rc == 0 and name in EQUIVALENT:
            killed += 1
            lines.append('%-26s EQUIVALENT (argued: the outputs of the aux core are not connected during convolution layers)' % name)
        elif rc == 0:
            survived += 1
            lines.append('%-26s SURVIVED' % name)
        elif rc == 2:
            survived += 1
            lines.append('%-26s INVALID (compile error: %s)' % (name, res[name][1].strip().replace('\n', ' ')[-150:]))
        else:
            killed += 1
            lines.append('%-26s KILLED' % name)
    lines += ['', 'mutants=%d killed_or_equivalent=%d survived=%d' % (len(muts), killed, survived)]
    out = '\n'.join(lines)
    os.makedirs(os.path.join(ROOT, 'logs_custom', 'yolo_vec'), exist_ok=True)
    open(os.path.join(ROOT, 'logs_custom', 'yolo_vec', 'net_mutation_summary.txt'), 'w', encoding='utf-8').write(out)
    print(out)
    return 0 if survived == 0 and res['control'][0] == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
