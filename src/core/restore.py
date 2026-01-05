from utils.constants import STATUS_OK, STATUS_FAIL

def restore(snapshot_id, store_path, target_path):
    try:
        # TODO: call verify first, then restore
        return STATUS_OK
    except Exception as e:
        print("Restore error:", e)
        return STATUS_FAIL
