#!/usr/bin/env python3
"""Disposable container only: actual TCP/UDP binds for all four inventory queries."""
from pathlib import Path
import socket
import time

sockets = []
for family, address in [(socket.AF_INET, '127.0.0.1'), (socket.AF_INET6, '::1')]:
    for kind, port in [(socket.SOCK_STREAM, 18443), (socket.SOCK_DGRAM, 51820)]:
        current = socket.socket(family, kind)
        if family == socket.AF_INET6:
            current.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        current.bind((address, port))
        if kind == socket.SOCK_STREAM:
            current.listen(1)
        sockets.append(current)
connected = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
connected.bind(('127.0.0.1', 51822))
connected.connect(('127.0.0.1', 51820))
sockets.append(connected)
Path('/fixture-data/sockets-ready').touch()
time.sleep(240)
