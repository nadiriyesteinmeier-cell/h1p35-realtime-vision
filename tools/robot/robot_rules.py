#!/usr/bin/env python3
"""robot_rules.py - turns the FPGA board's recognition report into WALL-E actions (used by walle_server.py)

FPGA UART line (rtl_custom/uart_report.v, every 0.2 s):
  R:RECT,X0640,Y0360,A012345,N00012;G:CIRC,X0320,Y0100,A009876,N00003;B:----,X----,Y----,A000000,N00000;CAM060,DSP060
  per colour: shape (RECT CIRC TRIA OVAL "OBJ " or ----), centre X / Y ('-' while no valid target), hit pixels A, line crossings N.
The rules work on events, not on single lines (one line every 0.2 s would flood the robot):
  * appear   : the DOMINANT colour (largest valid target) changes to c and stays for APPEAR lines -> ACTIONS['appear'][c]
               (a green part also shows small red / blue hits at its edges: only the largest colour counts; a new colour has to be
               DOM_RATIO times larger than the current one while that one is still there)
  * follow   : while the largest target stays, its x position decides left / centre / right with hysteresis; a change of side
               -> ACTIONS['left'] / ['right'] / ['centre']
  * cross    : the line-crossing counter of the dominant colour increased                 -> ACTIONS['cross'][colour]
  * lost     : no target in LOST consecutive lines after one was seen                     -> ACTIONS['lost']
  * drive    : (only if the rules have a 'drive' table) every DRIVE_PERIOD while colour c dominates -> ACTIONS['drive'][c][side]
               (rules_drive.json: green = go and steer by the target's side, blue = back, red = stop)
Each event kind (appear / cross / side / lost) fires at most once per MIN_GAP seconds; a held-back side change is retried with the
next line, the others are one-shot. rules.json next to this file overrides ACTIONS (walle_bridge.py serialises the robot's motions).
"""
import json
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
LINE = re.compile(r'([RGB]):(RECT|CIRC|TRIA|OVAL|OBJ |----),X([0-9-]{4}),Y([0-9-]{4}),A(\d{6}),N(\d{5})')

APPEAR, LOST, MIN_GAP = 2, 10, 1.5
DOM_RATIO = 1.5
MIN_AREA = 300                 # pixels: smaller targets are ignored (noise)
LEFT_X, RIGHT_X, HYST = 520, 760, 30

# default actions (placeholders until the robot's tool schemas are known; see rules.json)
ACTIONS = {
    'appear': {'R': [], 'G': [], 'B': []},
    'left': [], 'right': [], 'centre': [],
    'cross': {'R': [], 'G': [], 'B': []},
    'lost': [],
    'drive': {},                   # optional: {colour: {'left'|'centre'|'right': [actions]}} repeated every DRIVE_PERIOD while that colour dominates
}
DRIVE_PERIOD = 0.6


RULES_FILE = os.path.join(HERE, 'rules.json')


def load_actions(path=None):
    p = path or RULES_FILE
    if os.path.exists(p):
        with open(p, encoding='utf-8') as f:
            user = json.load(f)
        for k, v in user.items():
            ACTIONS[k] = v
    return ACTIONS


class Rules:
    def __init__(self):
        load_actions()
        self.dom = None                                # dominant colour
        self.cand, self.cand_n = None, 0
        self.cross = {'R': None, 'G': None, 'B': None}
        self.none_lines = 0
        self.any_seen = False
        self.side = None
        self.last_call = {}

    @staticmethod
    def parse(line):
        """one report line -> {'R': {...}, 'G': {...}, 'B': {...}} or None"""
        m = LINE.findall(line)
        if len(m) != 3:
            return None
        det = {}
        for c, shape, x, y, a, n in m:
            valid = shape != '----' and x.isdigit() and int(a) >= MIN_AREA
            det[c] = {'shape': shape.strip(), 'x': int(x) if x.isdigit() else None, 'y': int(y) if y.isdigit() else None,
                      'area': int(a), 'cross': int(n), 'valid': valid}
        return det

    def _gap_ok(self, key, now):
        t = self.last_call.get(key, float('-inf'))
        if now - t < MIN_GAP:
            return False
        self.last_call[key] = now
        return True

    def _emit(self, key, actions, now, out):
        """queue the actions of one event unless that event kind fired less than MIN_GAP ago; False if held back"""
        if not self._gap_ok(key, now):
            return False
        out.extend((act['name'], act.get('arguments', {})) for act in actions)
        return True

    def decide(self, det, now):
        out = []
        valid = [c for c in 'RGB' if det[c]['valid']]
        best = max(valid, key=lambda c: det[c]['area'], default=None)
        # dominant colour
        if best is not None and best != self.dom:
            if self.dom in valid and det[best]['area'] < DOM_RATIO * det[self.dom]['area']:
                self.cand, self.cand_n = None, 0
            else:
                self.cand_n = self.cand_n + 1 if self.cand == best else 1
                self.cand = best
                if self.cand_n >= APPEAR:
                    self.dom, self.cand, self.cand_n = best, None, 0
                    self._emit('appear', ACTIONS['appear'].get(best, []), now, out)
        elif best == self.dom:
            self.cand, self.cand_n = None, 0
        # line crossings of the dominant colour (the counters of all colours are tracked so a change of colour is not a crossing)
        for c in 'RGB':
            if c == self.dom and self.cross[c] is not None and det[c]['cross'] > self.cross[c]:
                self._emit('cross', ACTIONS['cross'].get(c, []), now, out)
            self.cross[c] = det[c]['cross']
        # follow the dominant target
        d = det[self.dom] if self.dom in valid else None
        if d is not None and d['x'] is not None:
            x = d['x']
            side = self.side
            if x < LEFT_X - (HYST if self.side == 'left' else 0):
                side = 'left'
            elif x > RIGHT_X + (HYST if self.side == 'right' else 0):
                side = 'right'
            elif LEFT_X + HYST <= x <= RIGHT_X - HYST or self.side is None:
                side = 'centre'
            if side != self.side and self._emit('side', ACTIONS[side], now, out):
                self.side = side                                # a held-back side change is tried again with the next line
            drv = ACTIONS.get('drive', {}).get(self.dom, {}).get(self.side or 'centre', [])
            if drv and now - self.last_call.get('drive', float('-inf')) >= DRIVE_PERIOD:
                self.last_call['drive'] = now
                out.extend((act['name'], act.get('arguments', {})) for act in drv)
        if valid:
            self.none_lines = 0
            self.any_seen = True
        else:
            self.none_lines += 1
            if self.any_seen and self.none_lines == LOST:
                self.any_seen = False
                self.side = None
                self.dom, self.cand, self.cand_n = None, None, 0
                self._emit('lost', ACTIONS['lost'], now, out)
        return out


if __name__ == '__main__':
    # self-test with recorded / synthetic lines
    r = Rules()
    ACTIONS.update({'appear': {'R': [{'name': 'red'}], 'G': [], 'B': []}, 'left': [{'name': 'left'}], 'right': [{'name': 'right'}],
                    'centre': [{'name': 'centre'}], 'lost': [{'name': 'lost'}], 'cross': {'R': [{'name': 'cross'}], 'G': [], 'B': []}})
    seq = (['R:OBJ ,X0300,Y0358,A001970,N00001;G:----,X----,Y----,A000134,N00000;B:----,X----,Y----,A000000,N00000;CAM060,DSP060'] * 3 +
           ['R:OBJ ,X0900,Y0358,A001970,N00002;G:----,X----,Y----,A000134,N00000;B:----,X----,Y----,A000000,N00000;CAM060,DSP060'] * 2 +
           ['R:----,X----,Y----,A000010,N00002;G:----,X----,Y----,A000134,N00000;B:----,X----,Y----,A000000,N00000;CAM060,DSP060'] * 12)
    t = 0.0
    got = []
    for line in seq:
        d = Rules.parse(line)
        assert d is not None, line
        for name, a in r.decide(d, t):
            got.append((round(t, 1), name))
        t += 2.0
    print(got)
    assert [n for _, n in got] == ['red', 'left', 'cross', 'right', 'lost'], got
    # a green part with small red / blue hits at its edges: only green counts; then a red part 3x larger takes over
    r2 = Rules()                                   # (loads rules.json: set the test actions after it)
    ACTIONS['appear'] = {'R': [{'name': 'red'}], 'G': [{'name': 'green'}], 'B': [{'name': 'blue'}]}
    mk = lambda ra, ga, ba: Rules.parse('R:OBJ ,X0620,Y0300,A%06d,N00000;G:RECT,X0640,Y0300,A%06d,N00000;B:OBJ ,X0600,Y0300,A%06d,N00000;CAM060,DSP060' % (ra, ga, ba))
    got2 = []
    t = 100.0
    for det in [mk(20197, 147484, 11737)] * 4 + [mk(30000, 40000, 9000)] * 3 + [mk(150000, 40000, 9000)] * 3:
        got2 += [n for n, _ in r2.decide(det, t) if n in ('red', 'green', 'blue')]
        t += 2.0
    print(got2)
    assert got2 == ['green', 'red'], got2
    # driving table: green on the left -> 'L' repeated every DRIVE_PERIOD, then green in the centre -> 'F'; red -> no drive
    r3 = Rules()
    ACTIONS.update({'appear': {'R': [{'name': 'stop'}], 'G': [], 'B': []}, 'left': [], 'right': [], 'centre': [], 'lost': [{'name': 'stop'}],
                    'cross': {'R': [], 'G': [], 'B': []},
                    'drive': {'G': {'left': [{'name': 'L'}], 'centre': [{'name': 'F'}], 'right': [{'name': 'R'}]}}})
    got3 = []
    t = 200.0
    for det in [mk(0, 50000, 0)] * 6 + [Rules.parse(l) for l in [
            'R:----,X----,Y----,A000000,N00000;G:RECT,X0300,Y0300,A050000,N00000;B:----,X----,Y----,A000000,N00000;CAM060,DSP060'] * 6] +             [mk(90000, 0, 0)] * 4:
        got3 += [n for n, _ in r3.decide(det, t)]
        t += 0.25                                  # exact in binary: no rounding at the DRIVE_PERIOD / MIN_GAP borders
    print(got3)
    assert got3 == ['F', 'F', 'L', 'L', 'stop'], got3
    print('robot_rules self-test PASS')
