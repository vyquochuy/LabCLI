# chống crash bằng write-ahead logging
class WAL:
    def __init__(self, path):
        self.path = path

    def begin(self, snap_id):
        self._append(f"BEGIN {snap_id}")

    def commit(self, snap_id):
        self._append(f"COMMIT {snap_id}")

    def _append(self, line):
        with open(self.path, "a") as f:
            f.write(line + "\n")
