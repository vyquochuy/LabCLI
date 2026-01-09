import os
import json
import time
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
    temp_dir = None
    snap_dir = None
    rollback_protector = None
    merkle_root = None
    
    try:
        # Tự động cleanup các snapshot không commit và temp directory trước khi backup
        cleaned = cleanup_incomplete_snapshots(store_path)
        if cleaned > 0:
            print(f"Cleaned up {cleaned} incomplete snapshot(s) and temp directory(ies)\n")
        
        # Kiểm tra source tồn tại
        if not os.path.exists(source_path):
            print(f"Source path not found: {source_path}")
            return STATUS_FAIL
        
        # Tạo snapshot ID từ timestamp + label
        timestamp = int(time.time() * 1000)
        snap_id = f"{timestamp}_{label}"
        
        # Tạo temp directory với prefix để dễ cleanup nếu bị kill
        temp_dir = os.path.join(store_path, f".tmp_{snap_id}")
        temp_chunks_dir = os.path.join(temp_dir, "chunks")
        
        # Snapshot directory cuối cùng (chỉ tạo sau khi commit)
        snap_dir = os.path.join(store_path, snap_id)
        
        # Khởi tạo WAL
        ensure_dir(store_path)
        wal = WAL(os.path.join(store_path, "wal.log"))
        wal.begin(snap_id)
        
        try:
            # Tạo temp directory để build snapshot
            ensure_dir(temp_chunks_dir)
            
            # Thu thập tất cả files
            files = list_files(source_path)
            
            if not files:
                print("No files to backup")
                remove_dir(temp_dir)
                return STATUS_FAIL
            
            # Chuẩn bị manifest và merkle tree
            manifest = {
                "snapshot_id": snap_id,
                "label": label,
                "timestamp": timestamp,
                "files": []
            }
            
            merkle = MerkleTree()
            
            # Xử lý từng file - ghi vào temp directory
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
                    temp_chunk_path = os.path.join(temp_chunks_dir, chunk_filename)
                    
                    # Ghi chunk vào temp directory (deduplicate trong cùng snapshot)
                    # Chỉ ghi nếu chưa tồn tại trong temp directory
                    if not os.path.exists(temp_chunk_path):
                        write_file(temp_chunk_path, chunk_data)
                    
                    file_info["chunks"].append(chunk_hash)
                    merkle.add_leaf(chunk_hash)
                    chunk_idx += 1
                
                manifest["files"].append(file_info)
            
            # Tính merkle root
            merkle_root = merkle.compute_root()
            manifest["merkle_root"] = merkle_root
            
            # Ghi manifest vào temp directory
            temp_manifest_path = os.path.join(temp_dir, "manifest.json")
            with open(temp_manifest_path, "w") as f:
                json.dump(manifest, f, indent=2)
            
            # QUAN TRỌNG: Chỉ ghi vào roots.log SAU KHI tất cả đã hoàn tất
            rollback_protector = RollbackProtector(os.path.join(store_path, "roots.log"))
            rollback_protector.append_root(merkle_root)
            
            # QUAN TRỌNG: Chỉ rename temp directory thành snapshot directory SAU KHI đã commit WAL
            # Nếu bị kill trước đây, temp directory sẽ không được rename và sẽ bị cleanup
            wal.commit(snap_id)
            
            # Chỉ sau khi commit WAL thành công, mới rename temp directory thành snapshot directory
            # Đây là atomic operation - nếu rename thành công, snapshot đã sẵn sàng
            # Nếu rename thất bại (ví dụ: disk full), temp directory vẫn còn và có thể retry sau
            if os.path.exists(temp_dir):
                try:
                    os.rename(temp_dir, snap_dir)
                except Exception as rename_error:
                    # Nếu rename thất bại, WAL đã commit nhưng snapshot directory chưa tồn tại
                    # Cleanup sẽ tự động retry rename khi chạy list-snapshots hoặc cleanup
                    print(f"Warning: Failed to rename temp directory to snapshot: {rename_error}")
                    print(f"Snapshot will be recovered automatically on next cleanup")
                    # Không raise exception, để cleanup có thể retry sau
                    return STATUS_FAIL
            
            print(f"Backup completed: {snap_id}")
            print(f"Merkle root: {merkle_root}")
            print(f"Files backed up: {len(files)}")
            
            return STATUS_OK
            
        except Exception as e:
            # Rollback nếu có lỗi
            print(f"Backup failed, rolling back: {e}")
            
            # Xóa temp directory
            if temp_dir and os.path.exists(temp_dir):
                remove_dir(temp_dir)
            
            # QUAN TRỌNG: Không commit WAL nếu failed
            # roots.log cũng không được ghi nếu exception xảy ra trước đó
            
            return STATUS_FAIL
            
    except Exception as e:
        print("Backup error:", e)
        
        # Cleanup nếu có exception ở outer level
        if temp_dir and os.path.exists(temp_dir):
            remove_dir(temp_dir)
        if snap_dir and os.path.exists(snap_dir):
            remove_dir(snap_dir)
        
        return STATUS_FAIL


def cleanup_incomplete_snapshots(store_path):
    """
    Xóa các snapshot không được commit (incomplete/corrupted)
    Chỉ giữ lại các snapshot có COMMIT trong WAL
    Cũng xóa các temp directory (.tmp_*) còn sót lại
    Nếu WAL có COMMIT nhưng snapshot directory không tồn tại và có temp directory tương ứng,
    sẽ thử retry rename (trường hợp rename thất bại do crash)
    """
    try:
        if not os.path.exists(store_path):
            return 0
        
        wal = WAL(os.path.join(store_path, "wal.log"))
        committed_snapshots = wal.get_committed_snapshots()
        
        # Kiểm tra các snapshot đã commit nhưng directory chưa tồn tại
        # (có thể do rename thất bại sau khi commit WAL)
        for snap_id in committed_snapshots:
            snap_dir = os.path.join(store_path, snap_id)
            temp_dir = os.path.join(store_path, f".tmp_{snap_id}")
            
            # Nếu snapshot directory không tồn tại nhưng có temp directory
            if not os.path.exists(snap_dir) and os.path.exists(temp_dir):
                try:
                    print(f"Retrying rename for committed snapshot: {snap_id}")
                    os.rename(temp_dir, snap_dir)
                    print(f"Successfully recovered snapshot: {snap_id}")
                except Exception as e:
                    print(f"Failed to recover snapshot {snap_id}: {e}")
                    # Nếu không thể recover, xóa temp directory
                    remove_dir(temp_dir)
        
        # Tìm tất cả thư mục snapshot trong store
        cleaned_count = 0
        for item in os.listdir(store_path):
            # Bỏ qua các file log
            if item.endswith('.log'):
                continue
            
            item_path = os.path.join(store_path, item)
            # Chỉ xử lý thư mục
            if os.path.isdir(item_path):
                # Xóa temp directories (bắt đầu bằng .tmp_) còn sót lại
                if item.startswith('.tmp_'):
                    print(f"Cleaning up temp directory: {item}")
                    remove_dir(item_path)
                    cleaned_count += 1
                # Nếu snapshot này không có trong danh sách committed -> xóa
                elif item not in committed_snapshots:
                    print(f"Cleaning up incomplete snapshot: {item}")
                    remove_dir(item_path)
                    cleaned_count += 1
        
        return cleaned_count
    except Exception as e:
        print(f"Error during cleanup: {e}")
        return 0


def list_snapshots(store_path):
    """
    Liệt kê tất cả snapshot đã được commit (hợp lệ)
    Chỉ hiển thị snapshot có COMMIT trong WAL
    Tự động cleanup các snapshot không commit trước khi list
    """
    try:
        if not os.path.exists(store_path):
            print("Store directory not found")
            return []
        
        # Tự động cleanup các snapshot không commit
        cleaned = cleanup_incomplete_snapshots(store_path)
        if cleaned > 0:
            print(f"Cleaned up {cleaned} incomplete snapshot(s)\n")
        
        # Lấy danh sách snapshot đã commit từ WAL
        wal = WAL(os.path.join(store_path, "wal.log"))
        committed_snapshots = wal.get_committed_snapshots()
        
        if not committed_snapshots:
            print("No valid snapshots found")
            return []
        
        # Lấy thông tin chi tiết từ manifest của mỗi snapshot
        snapshot_list = []
        for snap_id in sorted(committed_snapshots):
            snap_dir = os.path.join(store_path, snap_id)
            manifest_path = os.path.join(snap_dir, "manifest.json")
            
            if os.path.exists(manifest_path):
                try:
                    with open(manifest_path, "r") as f:
                        manifest = json.load(f)
                    
                    snapshot_list.append({
                        "id": snap_id,
                        "label": manifest.get("label", "unknown"),
                        "timestamp": manifest.get("timestamp", 0),
                        "files": len(manifest.get("files", [])),
                        "merkle_root": manifest.get("merkle_root", "unknown")
                    })
                except Exception as e:
                    # Nếu không đọc được manifest, bỏ qua snapshot này
                    print(f"Warning: Cannot read manifest for {snap_id}: {e}")
                    continue
        
        return snapshot_list
        
    except Exception as e:
        print(f"Error listing snapshots: {e}")
        return []