import os

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
    
    def is_committed(self, snap_id):
        """
        Kiểm tra xem snapshot đã được commit chưa
        Trả về True nếu có COMMIT, False nếu chỉ có BEGIN hoặc không có
        """
        if not os.path.exists(self.path):
            return False
        
        with open(self.path, "r") as f:
            lines = f.readlines()
        
        has_begin = False
        for line in lines:
            line = line.strip()
            if line == f"BEGIN {snap_id}":
                has_begin = True
            elif line == f"COMMIT {snap_id}":
                return True  # Có COMMIT thì hợp lệ
        
        # Nếu có BEGIN nhưng không có COMMIT -> snapshot chưa hoàn tất
        return False
    
    def get_committed_snapshots(self):
        """
        Lấy danh sách tất cả snapshot đã được commit
        Trả về set các snapshot_id
        """
        committed = set()
        if not os.path.exists(self.path):
            return committed
        
        with open(self.path, "r") as f:
            for line in f:
                line = line.strip()
                if line.startswith("COMMIT "):
                    snap_id = line[7:].strip()  # Bỏ "COMMIT "
                    committed.add(snap_id)
        
        return committed