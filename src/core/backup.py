# from utils.constants import STATUS_OK, STATUS_FAIL

# def backup(source_path, store_path, label):
#     try:
#         # TODO:
#         # 1. chunk files
#         # 2. write manifest
#         # 3. compute merkle root
#         # 4. WAL begin / commit
#         return STATUS_OK
#     except Exception as e:
#         print("Backup error:", e)
#         return STATUS_FAIL

import os
import json
from utils.constants import STATUS_OK, STATUS_FAIL, CHUNK_SIZE
from utils.fs import ensure_dir, list_files, read_chunks, write_file, remove_dir
from utils.hash import sha256_bytes, sha256_str
from core.wal import WAL
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

def backup(source_path, store_path, label):
    try:
        # Kiểm tra source tồn tại
        if not os.path.exists(source_path):
            print(f"Source path not found: {source_path}")
            return STATUS_FAIL
        
        # Tạo snapshot ID từ timestamp + label
        import time
        timestamp = int(time.time() * 1000)
        snap_id = f"{timestamp}_{label}"
        
        snap_dir = os.path.join(store_path, snap_id)
        chunks_dir = os.path.join(snap_dir, "chunks")
        
        # Khởi tạo WAL
        ensure_dir(store_path)
        wal = WAL(os.path.join(store_path, "wal.log"))
        wal.begin(snap_id)
        
        try:
            # Tạo thư mục snapshot
            ensure_dir(chunks_dir)
            
            # Thu thập tất cả files
            files = list_files(source_path)
            
            if not files:
                print("No files to backup")
                remove_dir(snap_dir)
                return STATUS_FAIL
            
            # Chuẩn bị manifest và merkle tree
            manifest = {
                "snapshot_id": snap_id,
                "label": label,
                "timestamp": timestamp,
                "files": []
            }
            
            merkle = MerkleTree()
            
            # Xử lý từng file
            for rel_path, abs_path in files:
                file_info = {
                    "path": rel_path,
                    "chunks": []
                }
                
                # Chia file thành chunks
                chunk_idx = 0
                for chunk_data in read_chunks(abs_path, CHUNK_SIZE):
                    chunk_hash = sha256_bytes(chunk_data)
                    chunk_filename = f"{chunk_hash}.chunk"
                    chunk_path = os.path.join(chunks_dir, chunk_filename)
                    
                    # Ghi chunk (deduplicate tự động)
                    if not os.path.exists(chunk_path):
                        write_file(chunk_path, chunk_data)
                    
                    file_info["chunks"].append(chunk_hash)
                    merkle.add_leaf(chunk_hash)
                    chunk_idx += 1
                
                manifest["files"].append(file_info)
            
            # Tính merkle root
            merkle_root = merkle.compute_root()
            manifest["merkle_root"] = merkle_root
            
            # Ghi manifest
            manifest_path = os.path.join(snap_dir, "manifest.json")
            with open(manifest_path, "w") as f:
                json.dump(manifest, f, indent=2)
            
            # Ghi merkle root vào rollback protector
            rollback = RollbackProtector(os.path.join(store_path, "roots.log"))
            rollback.append_root(merkle_root)
            
            # Commit WAL
            wal.commit(snap_id)
            
            print(f"Backup completed: {snap_id}")
            print(f"Merkle root: {merkle_root}")
            print(f"Files backed up: {len(files)}")
            
            return STATUS_OK
            
        except Exception as e:
            # Rollback nếu có lỗi
            print(f"Backup failed, rolling back: {e}")
            remove_dir(snap_dir)
            return STATUS_FAIL
            
    except Exception as e:
        print("Backup error:", e)
        return STATUS_FAIL