from utils.constants import STATUS_OK, STATUS_FAIL

def verify(snapshot_id, store_path):
    try:
        # TODO: recompute merkle, check chunks, rollback
        return STATUS_OK
    except Exception as e:
        print("Verify error:", e)
        return STATUS_FAIL
