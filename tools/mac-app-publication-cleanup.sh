#!/usr/bin/env bash

# Sourced by build-mac-app.sh. The caller owns transaction_root and messages.

transaction_layout_safe() {
  python3 -c '
import os, stat, sys
root = sys.argv[1]
root_info = os.lstat(root)
if (not stat.S_ISDIR(root_info.st_mode) or root_info.st_uid != os.geteuid()
        or stat.S_IMODE(root_info.st_mode) != 0o700):
    raise RuntimeError("unsafe transaction root")
regular = {"format", "owner-pid", "owner-instance", "state", ".state.next",
           "candidate-id", ".candidate-id.next", "output-id", ".output-id.next"}
directories = {"candidate.app", "icon-work", "swift-scratch"}
names = set(os.listdir(root))
if not {"format", "owner-pid", "owner-instance", "state"}.issubset(names):
    raise RuntimeError("missing ownership markers")
for name in names:
    info = os.lstat(os.path.join(root, name))
    if name in regular:
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_nlink != 1:
            raise RuntimeError("unsafe transaction marker")
    elif name in directories:
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid():
            raise RuntimeError("unsafe transaction directory")
    else:
        raise RuntimeError("unexpected transaction node")
with open(os.path.join(root, "format"), "r", encoding="ascii") as source:
    if source.read() != "droidmatch-app-publication-v2\n":
        raise RuntimeError("invalid ownership marker")
' "${transaction_root}" >/dev/null 2>&1
}

remove_transaction_tree() {
  if ! transaction_layout_safe; then
    printf 'Refusing to clean an unsafe App publication transaction.\n' >&2
    printf '中文：拒绝清理布局不安全的 App 发布事务。\n' >&2
    return 1
  fi
  if ! python3 -c '
import os, stat, sys
root = sys.argv[1]
root_info = os.lstat(root)
flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
def remove_contents(directory_fd):
    for name in os.listdir(directory_fd):
        info = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        if stat.S_ISDIR(info.st_mode):
            child_fd = os.open(name, flags, dir_fd=directory_fd)
            try:
                opened = os.fstat(child_fd)
                if (opened.st_dev, opened.st_ino) != (info.st_dev, info.st_ino):
                    raise RuntimeError("transaction directory changed")
                remove_contents(child_fd)
            finally:
                os.close(child_fd)
            os.rmdir(name, dir_fd=directory_fd)
        else:
            os.unlink(name, dir_fd=directory_fd)
root_fd = os.open(root, flags)
try:
    opened = os.fstat(root_fd)
    if (opened.st_dev, opened.st_ino) != (root_info.st_dev, root_info.st_ino):
        raise RuntimeError("transaction root changed")
    remove_contents(root_fd)
finally:
    os.close(root_fd)
os.rmdir(root)
' "${transaction_root}" >/dev/null 2>&1; then
    printf 'App publication transaction cleanup failed.\n' >&2
    printf '中文：App 发布事务清理失败。\n' >&2
    return 1
  fi
}
