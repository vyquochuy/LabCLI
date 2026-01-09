# from utils.constants import STATUS_OK, STATUS_FAIL

# def restore(snapshot_id, store_path, target_path):
#     try:
#         # TODO: call verify first, then restore
#         return STATUS_OK
#     except Exception as e:
#         print("Restore error:", e)
#         return STATUS_FAIL

import os
import json
from utils.constants import STATUS_OK, STATUS_FAIL
from utils.fs import ensure_dir, write_file
from core.verify import verify

def restore(snapshot_id, store_path, target_path):
    try:
        # Bước 1: Verify trước khi restore
        print("Verifying snapshot before restore...")
        verify_status = verify(snapshot_id, store_path)
        
        if verify_status == STATUS_FAIL:
            print("Snapshot verification failed. Restore aborted.")
            return STATUS_FAIL
        
        print("Snapshot verified successfully. Starting restore...")
        
        # Bước 2: Đọc manifest
        snap_dir = os.path.join(store_path, snapshot_id)
        manifest_path = os.path.join(snap_dir, "manifest.json")
        
        with open(manifest_path, "r") as f:
            manifest = json.load(f)
        
        # Bước 3: Tạo target directory
        ensure_dir(target_path)
        
        # Bước 4: Restore từng file
        chunks_dir = os.path.join(snap_dir, "chunks")
        
        for file_info in manifest["files"]:
            rel_path = file_info["path"]
            target_file_path = os.path.join(target_path, rel_path)
            
            # Tạo thư mục cha nếu cần
            target_file_dir = os.path.dirname(target_file_path)
            if target_file_dir:
                ensure_dir(target_file_dir)
            
            # Ghép các chunks lại thành file
            file_data = b""
            for chunk_hash in file_info["chunks"]:
                chunk_path = os.path.join(chunks_dir, f"{chunk_hash}.chunk")
                
                with open(chunk_path, "rb") as f:
                    file_data += f.read()
            
            # Ghi file
            with open(target_file_path, "wb") as f:
                f.write(file_data)
            
            print(f"Restored: {rel_path}")
        
        print(f"\nRestore completed to: {target_path}")
        print(f"Files restored: {len(manifest['files'])}")
        
        return STATUS_OK
        
    except Exception as e:
        print("Restore error:", e)
        return STATUS_FAIL