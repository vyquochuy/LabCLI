import time
from utils.hash import sha256_str
from utils.constants import ZERO_HASH

class AuditLogger:
    def __init__(self, path):
        self.path = path

    def _last_hash(self):
        try:
            with open(self.path, "r") as f:
                lines = f.readlines()
            if not lines:
                return ZERO_HASH
            return lines[-1].split()[0]
        except FileNotFoundError:
            return ZERO_HASH

    def log(self, user, command, args_str, status):
        prev = self._last_hash()
        ts = int(time.time() * 1000)
        args_hash = sha256_str(args_str)
        raw = f"{prev} {ts} {user} {command} {args_hash} {status}"
        entry_hash = sha256_str(raw)
        line = f"{entry_hash} {raw}\n"

        with open(self.path, "a") as f:
            f.write(line)
