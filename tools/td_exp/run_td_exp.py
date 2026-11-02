#!/usr/bin/env python3
"""run_td_exp.py - build a small stand-alone design with the installed TD (command line, DefaultFlow) and print the resource / timing summary

Usage: python run_td_exp.py <name> <top-module> <clock-port> <period-ns> <file.v> [<file.v> ...] [--end opt_route|bitgen] [--pins port=PIN ...]
Writes logs_custom/td_exp/<name>/ (prj, sdc, adc, run/ with TD's reports). Never touches any project of the repository, never programs a board.
Every top-level port gets a LOCATION (from a built-in list of PH1P35MDG324 board pins, or from --pins) only so that place & route can run;
the design is not meant to be downloaded. The constraint is a single clock with the given period on <clock-port>.
"""
import os
import re
import subprocess
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
TD = r'F:\TD\bin\td_commands_prompt.exe'
FLOW = 'F:/TD/scripts/DefaultFlow.tcl'
BOARD_PINS = ['C4', 'R10', 'D10', 'E10', 'C6', 'D6', 'C9', 'C11', 'B11', 'E7', 'E6', 'B6', 'B7', 'E5', 'G15', 'G14', 'A17', 'A18', 'B16', 'A15', 'B15', 'A14',
              'H1', 'J1', 'C12', 'D5', 'A9', 'B9', 'C7', 'A4', 'B4', 'E11', 'D11']


def main():
    args = sys.argv[1:]
    name, top, clkport, period = args[0], args[1], args[2], args[3]
    files = []
    pins = {}
    end = 'opt_route'
    i = 4
    while i < len(args):
        if args[i] == '--pins':
            i += 1
            while i < len(args) and '=' in args[i] and not args[i].startswith('--'):
                p, loc = args[i].split('=')
                pins[p] = loc
                i += 1
            continue
        if args[i] == '--end':
            end = args[i + 1]
            i += 2
            continue
        files.append(os.path.abspath(args[i]).replace('\\', '/'))
        i += 1
    base = os.path.join(ROOT, 'logs_custom', 'td_exp', name)
    run = os.path.join(base, 'run')
    os.makedirs(run, exist_ok=True)
    topfile = [f for f in files if re.search(r'module\s+' + top + r'\b', open(f, encoding='utf-8', errors='replace').read())][0]
    src = open(topfile, encoding='utf-8', errors='replace').read()
    m = re.search(r'module\s+' + top + r'\s*(#\s*\(.*?\))?\s*\((.*?)\);', src, re.S)
    ports = []
    for line in m.group(2).split(','):
        pm = re.search(r'(input|output|inout)\s+(?:wire|reg)?\s*(\[[^\]]+\])?\s*(\w+)', line.replace('\n', ' '))
        if pm:
            ports.append((pm.group(3), pm.group(2)))
    free = [p for p in BOARD_PINS if p not in set(pins.values())]
    adc = []
    for pname, rng in ports:
        if rng:
            hi, lo = (int(x) for x in re.findall(r'\d+', rng)[:2])
            for b in range(lo, hi + 1):
                key = '%s[%d]' % (pname, b)
                loc = pins.get(key) or free.pop(0)
                adc.append('set_pin_assignment { %s } { LOCATION = %s; IOSTANDARD = LVCMOS33; }' % (key, loc))
        else:
            loc = pins.get(pname) or free.pop(0)
            adc.append('set_pin_assignment { %s } { LOCATION = %s; IOSTANDARD = LVCMOS33; }' % (pname, loc))
    open(os.path.join(base, 'exp.adc'), 'w').write('\n'.join(adc) + '\n')
    open(os.path.join(base, 'exp.sdc'), 'w').write('create_clock -name {clk} -period %s -waveform {0.000 %.3f} [get_ports {%s}]\n' % (period, float(period) / 2, clkport))
    prj = ['<?xml version="1.0" encoding="UTF-8"?>', '<Project Version="3" Minor="2">', '    <Project_Created_Time></Project_Created_Time>', '    <TD_Encoding>UTF-8</TD_Encoding>',
           '    <TD_Version>6.2.178840</TD_Version>', '    <Name>exp</Name>', '    <HardWare>', '        <Family>PH1</Family>',
           '        <Device>PH1P35MDG324</Device>', '        <Speed>-3</Speed>', '    </HardWare>', '    <Source_Files>', '        <Verilog>']
    for n, f in enumerate(files, 1):
        prj += ['            <File Path="%s">' % os.path.relpath(f, run).replace(chr(92), '/'), '                <FileInfo>', '                    <Attr Name="UsedInSyn" Val="true"/>',
                '                    <Attr Name="UsedInP&R" Val="true"/>', '                    <Attr Name="BelongTo" Val="design_1"/>',
                '                    <Attr Name="CompileOrder" Val="%d"/>' % n, '                </FileInfo>', '            </File>']
    adc_rel = os.path.relpath(os.path.join(base, 'exp.adc'), run).replace(chr(92), '/')
    sdc_rel = os.path.relpath(os.path.join(base, 'exp.sdc'), run).replace(chr(92), '/')
    for tag, rel, order in (('ADC_FILE', adc_rel, 1), ('SDC_FILE', sdc_rel, 2)):
        prj += ['        </Verilog>' if tag == 'ADC_FILE' else '', '        <%s>' % tag, '            <File Path="%s">' % rel, '                <FileInfo>',
                '                    <Attr Name="UsedInSyn" Val="true"/>', '                    <Attr Name="UsedInP&R" Val="true"/>',
                '                    <Attr Name="BelongTo" Val="constraint_1"/>', '                    <Attr Name="CompileOrder" Val="%d"/>' % order,
                '                </FileInfo>', '            </File>', '        </%s>' % tag]
    prj = [x for x in prj if x != '']
    prj += ['    </Source_Files>', '    <FileSets>', '        <FileSet Name="design_1" Type="DesignFiles">', '        </FileSet>',
            '        <FileSet Name="constraint_1" Type="ConstrainFiles">', '        </FileSet>', '    </FileSets>', '    <TOP_MODULE>', '        <LABEL>%s</LABEL>' % top, '        <MODULE>%s</MODULE>' % top,
            '        <CREATEINDEX>user</CREATEINDEX>', '    </TOP_MODULE>', '    <Property>', '    </Property>', '    <Device_Settings>', '    </Device_Settings>',
            '    <Configurations>', '        <Control0>', '            <mclk_freq>33MHz</mclk_freq>', '        </Control0>', '        <FeatureRow>',
            '            <boot_mode>mspix4</boot_mode>', '        </FeatureRow>', '    </Configurations>', '</Project>']
    open(os.path.join(run, 'exp.prj'), 'w', encoding='utf-8', newline='').write('\r\n'.join(prj) + '\r\n')
    cfg = ('set ADCList {"%s"}\nset IpADCList { }\nset IpSDCList { }\nset SDCList {"%s"}\nset area_option -packarea\nset device_name ph1_35p.db\n'
           'set end_step %s\nset package_name PH1P35MDG324\nset prj_name {exp}\nset run_type syn\nset speed 3\nset start_step read_design\n'
           'set top_model_name {%s}\nset arr_filter off\nset drHoldFix off\n') % (
        os.path.relpath(os.path.join(base, 'exp.adc'), run).replace(chr(92), '/'), os.path.relpath(os.path.join(base, 'exp.sdc'), run).replace(chr(92), '/'), end, top)
    open(os.path.join(run, 'settings.cfg'), 'w').write(cfg)
    open(os.path.join(run, 'run_flow.tcl'), 'w').write('source %s\nexit\n' % FLOW)
    r = subprocess.run('"%s" run_flow.tcl > run_console.log 2>&1' % TD, shell=True, cwd=run, stdin=subprocess.DEVNULL, timeout=3000)
    log = open(os.path.join(run, 'run_console.log'), 'rb').read().decode('utf-8', 'replace')
    errs = [l for l in log.splitlines() if 'ERROR' in l]
    print('TD exit %s, %d ERROR lines' % (r.returncode, len(errs)))
    for e in errs[:8]:
        print(' ', e[:200])
    for f in sorted(os.listdir(run)):
        if f.endswith('_phy.area'):
            txt = open(os.path.join(run, f), encoding='utf-8', errors='replace').read()
            for key in ('#lut6', '#reg', '#slice', '#eram', '#dsp'):
                for ln in txt.splitlines():
                    if ln.strip().startswith(key):
                        print(ln.rstrip())
                        break
        if f == 'final_timing.rpt':
            t = open(os.path.join(run, f), encoding='utf-8', errors='replace').read()
            for ln in t.splitlines():
                if 'SWNS' in ln or 'HWNS' in ln or 'STA coverage' in ln or ln.strip().startswith('clk0') or ln.strip().startswith('Name'):
                    print(ln.strip()[:210])
    print('run directory:', run)


if __name__ == '__main__':
    main()
