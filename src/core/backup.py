from utils.constants import STATUS_OK, STATUS_FAIL

def backup(source_path, store_path, label):
    try:
        # TODO:
        # 1. chunk files
        # 2. write manifest
        # 3. compute merkle root
        # 4. WAL begin / commit
        return STATUS_OK
    except Exception as e:
        print("Backup error:", e)
        return STATUS_FAIL
