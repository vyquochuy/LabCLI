import os
import shutil

def ensure_dir(path: str):
    """Tạo thư mục nếu chưa tồn tại"""
    os.makedirs(path, exist_ok=True)


def list_files(root_dir: str):
    """
    Duyệt tất cả file trong root_dir
    Trả về list (relative_path, absolute_path)
    Đã SORT theo relative_path
    """
    result = []
    root_dir = os.path.abspath(root_dir)

    for base, _, files in os.walk(root_dir):
        for name in files:
            abs_path = os.path.join(base, name)
            rel_path = os.path.relpath(abs_path, root_dir)
            result.append((rel_path.replace("\\", "/"), abs_path))

    result.sort(key=lambda x: x[0])
    return result


def read_chunks(file_path: str, chunk_size: int):
    """Đọc file theo từng chunk"""
    with open(file_path, "rb") as f:
        while True:
            chunk = f.read(chunk_size)
            if not chunk:
                break
            yield chunk


def write_file(path: str, data: bytes):
    """Ghi file binary, tự tạo thư mục cha"""
    parent = os.path.dirname(path)
    if parent:
        ensure_dir(parent)

    with open(path, "wb") as f:
        f.write(data)


def remove_dir(path: str):
    """Xoá thư mục (dùng khi rollback/crash)"""
    if os.path.exists(path):
        shutil.rmtree(path)


def file_exists(path: str) -> bool:
    return os.path.isfile(path)


def dir_exists(path: str) -> bool:
    return os.path.isdir(path)
