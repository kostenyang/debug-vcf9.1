#!/usr/bin/env python3
"""在 SDDC Manager 上以 root 執行一條指令。
vcf 不在 sudoers、su 需要 TTY → 用 pty.fork() 開虛擬終端,看到 'assword' 就送密碼。
用法: ROOTPW=... python3 asroot.py '<command>'"""
import os, pty, sys, time
cmd = sys.argv[1]
pw = os.environ["ROOTPW"].encode() + b"\n"
pid, fd = pty.fork()
if pid == 0:
    os.execvp("su", ["su", "-", "root", "-c", cmd])
sent = False
buf = b""
while True:
    try:
        data = os.read(fd, 4096)
    except OSError:
        break
    if not data:
        break
    buf += data
    if not sent and b"assword" in buf:
        time.sleep(0.2)
        os.write(fd, pw)
        sent = True
        buf = b""
        continue
    sys.stdout.write(data.decode("utf-8", "replace"))
    sys.stdout.flush()
_, status = os.waitpid(pid, 0)
sys.exit(os.waitstatus_to_exitcode(status))
