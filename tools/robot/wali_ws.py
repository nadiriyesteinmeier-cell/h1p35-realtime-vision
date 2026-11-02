#!/usr/bin/env python3
"""wali_ws.py - minimal WebSocket client for the WALL-E robot's own control socket (ws://<robot>/ws, the "瓦力控制台" protocol)

Protocol (from the robot's web console js/control.js):
  move : {"type": "move", "dir": "forward|backward|left|right|spinleft|spinright|stop", "speed": 20..100}
  tools: {"type": "mcp", "payload": {"jsonrpc": "2.0", "id": n, "method": "tools/call", "params": {"name": "self.wali.<tool>", "arguments": {...}}}}
         The robot's own tool list (tools/list over this socket, saved in logs_custom/robot/tools_ws.json, firmware 2.4.2):
         self.wali.action {action: wave|arm_left|arm_right|dance|nod|shake_head|stop}   (blocks until done, then answers)
         self.wali.mood   {mood: 21 moods incl. neutral|happy|surprised|thinking|sad|...} (eyes + body motion together)
         self.wali.eye    {action: off|blink|double_blink|pulse(+pulse_times)|flash|wake|mood|color(+color "#RRGGBB")|brightness(+brightness)}
         self.wali.servo  {servo: left_arm|right_arm|head, angle: 0..180 physical; arms raised ~60 / natural ~120 / down ~170,
                           head level ~120 / up 180 / down 0}   (interrupts a running mood motion)
         self.wali.move   {direction: forward|backward|left|right|stop, speed, duration ms}   (timed; blocks until done)
  keep-alive: the text "ping" every 1.5 s (the console does the same). The robot has few sockets: keep ONE connection open, reconnect slowly.
No external packages (RFC 6455 client frames are masked text frames; incoming frames are read and dropped / logged).

    python tools/robot/wali_ws.py --host 192.168.137.238 eye_color "#FF0000"
    python tools/robot/wali_ws.py --host 192.168.137.238 action nod
"""
import argparse
import base64
import json
import os
import socket
import struct
import sys
import threading
import time


class WaliWS:
    def __init__(self, host, port=80, path='/ws', log=print):
        self.host, self.port, self.path, self.log = host, port, path, log
        self.sock = None
        self.lock = threading.Lock()
        self.next_id = 1
        self.alive = False
        self.rx_thread = None
        self.on_text = None                      # optional callback(full text of every incoming message except "pong")

    # ---------------------------------------------------------------- connection
    def connect(self, timeout=5.0):
        s = socket.create_connection((self.host, self.port), timeout=timeout)
        key = base64.b64encode(os.urandom(16)).decode()
        req = ('GET %s HTTP/1.1\r\nHost: %s:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
               'Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n' % (self.path, self.host, self.port, key))
        s.sendall(req.encode())
        resp = b''
        while b'\r\n\r\n' not in resp:
            chunk = s.recv(1024)
            if not chunk:
                raise ConnectionError('closed during handshake')
            resp += chunk
        status = resp.split(b'\r\n', 1)[0]
        if b' 101 ' not in status:
            raise ConnectionError('handshake refused: %r' % status)
        s.settimeout(None)
        self.sock = s
        self.alive = True
        self.rx_thread = threading.Thread(target=self._rx, daemon=True)
        self.rx_thread.start()
        threading.Thread(target=self._ping, daemon=True).start()
        self.log('wali: connected ws://%s:%d%s' % (self.host, self.port, self.path))

    def close(self):
        self.alive = False
        try:
            self._send_frame(0x8, b'')
            self.sock.close()
        except OSError:
            pass

    def _send_frame(self, opcode, data):
        mask = os.urandom(4)
        n = len(data)
        if n < 126:
            hdr = struct.pack('!BB', 0x80 | opcode, 0x80 | n)
        elif n < 65536:
            hdr = struct.pack('!BBH', 0x80 | opcode, 0x80 | 126, n)
        else:
            hdr = struct.pack('!BBQ', 0x80 | opcode, 0x80 | 127, n)
        body = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
        with self.lock:
            self.sock.sendall(hdr + mask + body)

    def _recv_exact(self, n):
        buf = b''
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise ConnectionError('closed')
            buf += chunk
        return buf

    def _rx(self):
        try:
            while self.alive:
                b0, b1 = self._recv_exact(2)
                op, n = b0 & 0x0F, b1 & 0x7F
                if n == 126:
                    n = struct.unpack('!H', self._recv_exact(2))[0]
                elif n == 127:
                    n = struct.unpack('!Q', self._recv_exact(8))[0]
                if b1 & 0x80:
                    self._recv_exact(4)
                data = self._recv_exact(n) if n else b''
                if op == 0x9:                                   # ping -> pong
                    self._send_frame(0xA, data)
                elif op == 0x8:
                    break
                elif op == 0x1:
                    txt = data.decode('utf-8', 'replace')
                    if txt != 'pong':
                        self.log('wali <- ' + txt[:200])
                        if self.on_text:
                            self.on_text(txt)
        except (OSError, ConnectionError, ValueError):
            pass
        self.alive = False
        self.log('wali: connection closed')

    def _ping(self):
        while self.alive:
            time.sleep(1.5)
            try:
                self._send_frame(0x1, b'ping')
            except OSError:
                self.alive = False

    # ---------------------------------------------------------------- commands
    def send_json(self, obj):
        self._send_frame(0x1, json.dumps(obj, ensure_ascii=False).encode('utf-8'))

    def tool(self, name, arguments):
        rid = self.next_id
        self.next_id += 1
        self.send_json({'type': 'mcp', 'payload': {'jsonrpc': '2.0', 'id': rid, 'method': 'tools/call',
                                                   'params': {'name': name, 'arguments': arguments}}})
        return rid

    def move(self, direction, speed=40):
        self.send_json({'type': 'move', 'dir': direction, 'speed': int(speed)})

    def action(self, name):
        self.tool('self.wali.action', {'action': name})

    def mood(self, name):
        self.tool('self.wali.mood', {'mood': name})

    def eye(self, action, **kw):
        a = {'action': action}
        a.update(kw)
        self.tool('self.wali.eye', a)

    def servo(self, which, angle):
        self.tool('self.wali.servo', {'servo': which, 'angle': int(angle)})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--host', default='192.168.137.238')
    ap.add_argument('cmd', choices=['eye_color', 'eye', 'action', 'mood', 'servo', 'move'])
    ap.add_argument('arg', nargs='*')
    a = ap.parse_args()
    w = WaliWS(a.host)
    w.connect()
    if a.cmd == 'eye_color':
        w.eye('color', color=a.arg[0])
    elif a.cmd == 'eye':
        w.eye(a.arg[0])
    elif a.cmd == 'action':
        w.action(a.arg[0])
    elif a.cmd == 'mood':
        w.mood(a.arg[0])
    elif a.cmd == 'servo':
        w.servo(a.arg[0], int(a.arg[1]))
    elif a.cmd == 'move':
        w.move(a.arg[0], int(a.arg[1]) if len(a.arg) > 1 else 40)
    time.sleep(2.0)                                          # let the robot answer before closing
    w.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
