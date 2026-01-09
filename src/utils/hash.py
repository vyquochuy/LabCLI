import hashlib

def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()

def sha256_str(s: str) -> str:
    return sha256_bytes(s.encode("utf-8"))
