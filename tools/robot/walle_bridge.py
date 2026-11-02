#!/usr/bin/env python3
"""walle_bridge.py - FPGA camera detections -> WALL-E robot (over the robot's own WebSocket, no change to the robot's settings)

  FPGA board UART (COM3, 115200, rtl_custom/uart_report.v line every 0.2 s)
      -> robot_rules.Rules (events: colour target appears / target left-centre-right / line crossing / target lost; rules.json)
      -> wali_ws.WaliWS (ws://<robot>/ws: "move" messages and self.wali.* MCP tool calls)
The robot keeps its cloud connection (voice assistant still works). One WebSocket is kept open (the robot has few sockets);
it is re-opened with a growing back-off if it drops. Every command and every event is logged to logs_custom/robot/bridge.log.

    F:/yolo_env/Scripts/python.exe tools/robot/walle_bridge.py --robot 192.168.137.238 --fpga COM3 [--dry-run] [--min-area 300]
(pyserial is installed in F:/yolo_env, not in the system Python.)
"""
import argparse
import json
import os
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..', '..'))
LOG = os.path.join(ROOT, 'logs_custom', 'robot', 'bridge.log')
sys.path.insert(0, HERE)
import robot_rules                   # noqa: E402
from wali_ws import WaliWS           # noqa: E402


def log(*a):
    line = time.strftime('%H:%M:%S ') + ' '.join(str(x) for x in a)
    print(line, flush=True)
    os.makedirs(os.path.dirname(LOG), exist_ok=True)
    with open(LOG, 'a', encoding='utf-8') as f:
        f.write(line + '\n')


MOTION = ('self.wali.action', 'self.wali.mood', 'self.wali.servo', 'self.wali.move', 'move')
BUSY_MAX = 8.0                     # s: give up waiting for the answer of a motion after this


class Robot:
    """One WebSocket to the robot. Motion commands (action / mood / servo / move) interrupt each other on the robot, and an action
    answers only when it is finished: so a motion is sent only after the previous one has answered (or BUSY_MAX passed); while one
    runs, only the newest waiting motion is kept (older ones are stale). Eye commands go out at once."""

    def __init__(self, host, dry):
        self.host, self.dry = host, dry
        self.ws = None
        self.next_try = 0.0
        self.backoff = 1.0
        self.lock = threading.Lock()
        self.busy_id = None
        self.busy_until = 0.0
        self.pending = None

    def ensure(self):
        if self.dry or (self.ws and self.ws.alive):
            return True
        if time.time() < self.next_try:
            return False
        try:
            self.ws = WaliWS(self.host, log=log)
            self.ws.on_text = self._on_text
            self.ws.connect()
            self.backoff = 1.0
            with self.lock:
                self.busy_id = None
            return True
        except OSError as e:
            log('robot connect failed:', repr(e), '- retry in %.0f s' % self.backoff)
            self.next_try = time.time() + self.backoff
            self.backoff = min(self.backoff * 2, 15.0)
            return False

    def _on_text(self, txt):
        try:
            rid = json.loads(txt).get('id')
        except (ValueError, AttributeError):
            return
        with self.lock:
            if rid is not None and rid == self.busy_id:
                self.busy_id = None
        self.poll()

    def _send(self, name, args):
        if name == 'move':
            self.ws.move(args['move'], args.get('speed', 40))
            return None
        return self.ws.tool(name, args)

    def poll(self):
        """send the waiting motion once the robot is free"""
        with self.lock:
            if self.busy_id is not None and time.time() < self.busy_until:
                return
            self.busy_id = None
            job, self.pending = self.pending, None
        if job and self.ensure():
            self._motion(*job)

    def _motion(self, name, args):
        rid = self._send(name, args)
        with self.lock:
            self.busy_id = rid
            self.busy_until = time.time() + BUSY_MAX
        log('->', name, args)

    def do(self, name, args):
        if self.dry:
            log('[dry] ->', name, args)
            return
        if not self.ensure():
            log('robot offline, dropped:', name, args)
            return
        if name == 'move' and args.get('move') == 'stop':          # stop goes out at once and cancels a waiting motion
            with self.lock:
                self.pending = None
            self._send(name, args)
            log('->', name, args)
            return
        if name in MOTION:
            with self.lock:
                if self.busy_id is not None and time.time() < self.busy_until:
                    if self.pending:
                        log('   (dropped stale', self.pending[0], self.pending[1], ')')
                    self.pending = (name, args)
                    log('   (queued', name, args, ')')
                    return
            self._motion(name, args)
        else:
            self._send(name, args)
            log('->', name, args)


def has_move(node):
    """True if a rules table contains a driving command"""
    if isinstance(node, dict):
        if node.get('name') in ('move', 'self.wali.move'):
            return True
        return any(has_move(v) for k, v in node.items() if k != '_comment')
    if isinstance(node, list):
        return any(has_move(v) for v in node)
    return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--robot', default='192.168.137.238')
    ap.add_argument('--fpga', default='COM3')
    ap.add_argument('--dry-run', action='store_true', help='print the commands, do not send them')
    ap.add_argument('--min-area', type=int, default=robot_rules.MIN_AREA, help='smaller targets are ignored (noise)')
    ap.add_argument('--rules', default=robot_rules.RULES_FILE, help='rules file (rules.json: gestures only; rules_drive.json: driving)')
    ap.add_argument('--drive', action='store_true', help='allow move commands (needed for a rules file that drives the robot)')
    a = ap.parse_args()
    import serial
    robot_rules.MIN_AREA = a.min_area
    robot_rules.RULES_FILE = os.path.abspath(a.rules)
    rules = robot_rules.Rules()
    drives = has_move(robot_rules.ACTIONS)
    if drives and not a.drive:
        log('%s contains move commands: start with --drive to allow driving' % a.rules)
        return 1
    robot = Robot(a.robot, a.dry_run)
    robot.ensure()
    log('bridge: FPGA %s -> robot %s, rules %s%s%s' % (a.fpga, a.robot, os.path.basename(a.rules), ' (driving)' if drives else '',
                                                    ' (dry run)' if a.dry_run else ''))
    last_det_log = 0.0
    while True:
        try:
            with serial.Serial(a.fpga, 115200, timeout=1) as sp:
                log('fpga uart open:', a.fpga)
                while True:
                    raw = sp.readline()
                    robot.poll()
                    if not raw:
                        robot.ensure()
                        continue
                    det = rules.parse(raw.decode('ascii', 'replace').strip())
                    if det is None:
                        continue
                    now = time.time()
                    if now - last_det_log > 5:
                        last_det_log = now
                        log('fpga:', ' '.join('%s=%s' % (c, ('x%d,a%d' % (det[c]['x'], det[c]['area'])) if det[c]['valid'] else '-') for c in 'RGB'))
                    for name, args in rules.decide(det, now):
                        robot.do(name, args)
        except KeyboardInterrupt:
            if drives and not a.dry_run and robot.ensure():
                robot.do('move', {'move': 'stop'})
                time.sleep(0.3)
            break
        except Exception as e:                           # noqa: BLE001 - the board may be unplugged; retry
            log('fpga uart error:', repr(e))
            time.sleep(2)
    return 0


if __name__ == '__main__':
    sys.exit(main())
