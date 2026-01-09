# from utils.constants import STATUS_OK, STATUS_FAIL

# def verify(snapshot_id, store_path):
#     try:
#         # TODO: recompute merkle, check chunks, rollback
#         return STATUS_OK
#     except Exception as e:
#         print("Verify error:", e)
#         return STATUS_FAIL

import os
import json
from utils.constants import STATUS_OK, STATUS_FAIL
from utils.hash import sha256_bytes, sha256_str
from core.rollback import RollbackProtector

class MerkleTree:
    def __init__(self):
        self.leaves = []
    
    def add_leaf(self, data_hash: str):
        self.leaves.append(data_hash)
    
    def compute_root(self) -> str:
        if not self.leaves:
            return "0" * 64
        
        level = self.leaves[:]
        
        while len(level) > 1:
            next_level = []
            for i in range(0, len(level), 2):
                left = level[i]
                right = level[i + 1] if i + 1 < len(level) else left
                parent = sha256_str(left + right)
                next_level.append(parent)
            level = next_level
        
        return level[0]

def verify(snapshot_id, store_path):
    try:
        snap_dir = os.path.join(store_path, snapshot_id)
        
        # Kiểm tra snapshot tồn tại
        if not os.path.exists(snap_dir):
            print(f"Snapshot not found: {snapshot_id}")
            return STATUS_FAIL
        
        # Đọc manifest
        manifest_path = os.path.join(snap_dir, "manifest.json")
        if not os.path.exists(manifest_path):
            print("Manifest not found")
            return STATUS_FAIL
        
        with open(manifest_path, "r") as f:
            manifest = json.load(f)
        
        stored_root = manifest.get("merkle_root")
        if not stored_root:
            print("No merkle root in manifest")
            return STATUS_FAIL
        
        # Kiểm tra rollback
        rollback = RollbackProtector(os.path.join(store_path, "roots.log"))
        rollback_status = rollback.verify_root(stored_root)
        
        if rollback_status == STATUS_FAIL:
            print("Rollback attack detected! This snapshot is not the latest.")
            return STATUS_FAIL
        
        # Tính lại merkle root từ chunks
        chunks_dir = os.path.join(snap_dir, "chunks")
        merkle = MerkleTree()
        
        missing_chunks = []
        corrupted_chunks = []
        
        for file_info in manifest["files"]:
            for chunk_hash in file_info["chunks"]:
                chunk_path = os.path.join(chunks_dir, f"{chunk_hash}.chunk")
                
                # Kiểm tra chunk tồn tại
                if not os.path.exists(chunk_path):
                    missing_chunks.append(chunk_hash)
                    continue
                
                # Kiểm tra hash của chunk
                with open(chunk_path, "rb") as f:
                    chunk_data = f.read()
                    computed_hash = sha256_bytes(chunk_data)
                
                if computed_hash != chunk_hash:
                    corrupted_chunks.append(chunk_hash)
                
                merkle.add_leaf(chunk_hash)
        
        # Báo lỗi nếu có chunks bị thiếu hoặc sai
        if missing_chunks:
            print(f"Missing chunks: {len(missing_chunks)}")
            for h in missing_chunks[:5]:
                print(f"  - {h}")
            return STATUS_FAIL
        
        if corrupted_chunks:
            print(f"Corrupted chunks: {len(corrupted_chunks)}")
            for h in corrupted_chunks[:5]:
                print(f"  - {h}")
            return STATUS_FAIL
        
        # So sánh merkle root
        computed_root = merkle.compute_root()
        
        if computed_root != stored_root:
            print("Merkle root mismatch!")
            print(f"  Expected: {stored_root}")
            print(f"  Computed: {computed_root}")
            return STATUS_FAIL
        
        print(f"Verification passed for snapshot: {snapshot_id}")
        print(f"Merkle root: {computed_root}")
        print(f"Files: {len(manifest['files'])}")
        
        return STATUS_OK
        
    except Exception as e:
        print("Verify error:", e)
        return STATUS_FAIL