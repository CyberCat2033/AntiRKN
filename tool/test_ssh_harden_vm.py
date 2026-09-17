#!/usr/bin/env python3
"""Current SSH hardening acceptance suite; requires its own disposable VM.

See test_ssh_harden_recovery_vm.py for fixture setup. The original v18 test
predated provisional confirmation and is retained in git history.
"""
from test_ssh_harden_recovery_vm import main

if __name__ == '__main__':
    main()
