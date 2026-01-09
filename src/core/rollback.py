import os
from utils.constants import STATUS_OK, STATUS_FAIL

class RollbackProtector:
    def __init__(self, path):
        self.path = path

    def append_root(self, root_hash: str):
        """Ghi root mới (chỉ append)"""
        index = 1
        if os.path.exists(self.path):
            with open(self.path, "r") as f:
                lines = f.readlines()
            index = len(lines) + 1

        with open(self.path, "a") as f:
            f.write(f"{index} {root_hash}\n")

    def load_roots(self):
        """Đọc toàn bộ root chain"""
        roots = []
        if not os.path.exists(self.path):
            return roots

        with open(self.path, "r") as f:
            for line in f:
                parts = line.strip().split()
                if len(parts) != 2:
                    raise ValueError("Invalid roots.log format")
                idx, root = parts
                roots.append((int(idx), root))
        return roots

    def verify_root(self, root_hash: str):
        """
        Kiểm tra root có hợp lệ không:
        - root phải tồn tại
        - root phải là root cuối cùng (chống rollback)
        """
        roots = self.load_roots()

        if not roots:
            return STATUS_FAIL

        last_idx, last_root = roots[-1]

        if root_hash != last_root:
            print("Rollback detected!")
            return STATUS_FAIL

        return STATUS_OK
