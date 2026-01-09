import time
import os
from utils.hash import sha256_str
from utils.constants import ZERO_HASH

class AuditLogger:
    def __init__(self, path):
        self.path = path
        # Tạo thư mục parent nếu chưa tồn tại
        os.makedirs(os.path.dirname(path), exist_ok=True)
        # File lưu audit root hashes để phát hiện truncation
        self.roots_path = os.path.join(os.path.dirname(path), "audit_roots.log")

    def _last_hash(self):
        try:
            with open(self.path, "r") as f:
                lines = f.readlines()
            if not lines:
                return ZERO_HASH
            return lines[-1].split()[0]
        except FileNotFoundError:
            return ZERO_HASH
    
    def _save_audit_root(self, entry_hash, count):
        """Lưu audit root hash để phát hiện truncation"""
        with open(self.roots_path, "a") as f:
            f.write(f"{count} {entry_hash}\n")

    def log(self, user, command, args_str, status):
        prev = self._last_hash()
        ts = int(time.time() * 1000)
        args_hash = sha256_str(args_str)
        raw = f"{prev} {ts} {user} {command} {args_hash} {status}"
        entry_hash = sha256_str(raw)
        line = f"{entry_hash} {raw}\n"

        with open(self.path, "a") as f:
            f.write(line)
        
        # Đếm số entries và lưu root
        try:
            with open(self.path, "r") as f:
                count = len(f.readlines())
            self._save_audit_root(entry_hash, count)
        except:
            pass
