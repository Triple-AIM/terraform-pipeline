"""Run a command so that it can only reach the paths it is given.

    sandbox.py [--ro PATH]... [--rx PATH]... [--rw PATH]... -- COMMAND [ARG]...

Everything else is denied, including /proc. So the command cannot read its
own environment through the filesystem. Every process the command starts is
restricted the same way.

The system files that any process needs are also granted, where they exist.

The command is not run at all if a path it is given is missing, or if the
kernel does not support Landlock.
"""
import argparse
import ctypes
import os
import sys

# These numbers are the same on every architecture that Landlock supports.
SYS_LANDLOCK_CREATE_RULESET = 444
SYS_LANDLOCK_ADD_RULE = 445
SYS_LANDLOCK_RESTRICT_SELF = 446
LANDLOCK_CREATE_RULESET_VERSION = 1 << 0
LANDLOCK_RULE_PATH_BENEATH = 1
PR_SET_NO_NEW_PRIVS = 38

EXECUTE = 1 << 0
WRITE_FILE = 1 << 1
READ_FILE = 1 << 2
READ_DIR = 1 << 3
REMOVE_DIR = 1 << 4
REMOVE_FILE = 1 << 5
MAKE_DIR = 1 << 7
MAKE_REG = 1 << 8
MAKE_SOCK = 1 << 9
MAKE_FIFO = 1 << 10
MAKE_SYM = 1 << 12
REFER = 1 << 13  # ABI 2
TRUNCATE = 1 << 14  # ABI 3
IOCTL_DEV = 1 << 15  # ABI 5

SCOPE_ABSTRACT_UNIX_SOCKET = 1 << 0  # ABI 6
SCOPE_SIGNAL = 1 << 1  # ABI 6

# A rule for a file, not a directory, may only grant these rights.
FILE_RIGHTS = EXECUTE | WRITE_FILE | READ_FILE | TRUNCATE | IOCTL_DEV

READ = READ_FILE | READ_DIR
WRITE = (
    WRITE_FILE | REMOVE_DIR | REMOVE_FILE | MAKE_DIR | MAKE_REG | MAKE_SOCK
    | MAKE_FIFO | MAKE_SYM | REFER | TRUNCATE
)

# What any process may need. That means libraries and programs, plus the
# files that name lookups, TLS and git read.
SYSTEM = (
    [(p, READ | EXECUTE) for p in ("/usr", "/lib", "/lib32", "/lib64", "/bin", "/sbin")]
    + [(p, READ) for p in (
        "/etc/ssl", "/etc/ca-certificates", "/etc/pki", "/etc/resolv.conf",
        "/run/systemd/resolve", "/etc/hosts", "/etc/nsswitch.conf",
        "/etc/host.conf", "/etc/gai.conf", "/etc/localtime", "/etc/services",
        "/etc/protocols", "/etc/gitconfig", "/dev/urandom", "/dev/random",
        "/dev/zero",
    )]
    + [("/dev/null", READ | WRITE_FILE)]
)


class RulesetAttr(ctypes.Structure):
    _fields_ = [
        ("handled_access_fs", ctypes.c_uint64),
        ("handled_access_net", ctypes.c_uint64),
        ("scoped", ctypes.c_uint64),
    ]


class PathBeneathAttr(ctypes.Structure):
    _pack_ = 1
    _fields_ = [("allowed_access", ctypes.c_uint64), ("parent_fd", ctypes.c_int32)]


libc = ctypes.CDLL(None, use_errno=True)
libc.syscall.restype = ctypes.c_long


def fail(message):
    print(f"sandbox: {message}", file=sys.stderr)
    sys.exit(125)


def check(result, what):
    if result < 0:
        fail(f"{what}: {os.strerror(ctypes.get_errno())}")
    return result


def handled(abi):
    """Every filesystem right this kernel can restrict."""
    rights = (1 << 13) - 1
    if abi >= 2:
        rights |= REFER
    if abi >= 3:
        rights |= TRUNCATE
    if abi >= 5:
        rights |= IOCTL_DEV
    return rights


def grant(ruleset, fs, path, rights):
    fd = os.open(path, os.O_PATH | os.O_CLOEXEC)
    if not os.path.isdir(path):
        rights &= FILE_RIGHTS
    rule = PathBeneathAttr(allowed_access=rights & fs, parent_fd=fd)
    check(
        libc.syscall(SYS_LANDLOCK_ADD_RULE, ruleset, LANDLOCK_RULE_PATH_BENEATH, ctypes.byref(rule), ctypes.c_uint32(0)),
        f"grant {path}",
    )
    os.close(fd)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ro", action="append", default=[])
    parser.add_argument("--rx", action="append", default=[])
    parser.add_argument("--rw", action="append", default=[])
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        fail("no command")

    granted = (
        [(p, READ) for p in args.ro]
        + [(p, READ | EXECUTE) for p in args.rx]
        + [(p, READ | EXECUTE | WRITE) for p in args.rw]
    )
    for path, _ in granted:
        if not os.path.exists(path):
            fail(f"{path} does not exist, so the command was not run")

    abi = libc.syscall(
        SYS_LANDLOCK_CREATE_RULESET, None, ctypes.c_size_t(0),
        ctypes.c_uint32(LANDLOCK_CREATE_RULESET_VERSION),
    )
    if abi < 1:
        fail("Landlock is not available on this kernel, so the command was not run")

    fs = handled(abi)
    attr = RulesetAttr(handled_access_fs=fs, handled_access_net=0)
    if abi >= 6:
        # Processes inside cannot signal processes outside. They also cannot
        # use abstract sockets to reach them.
        attr.scoped = SCOPE_ABSTRACT_UNIX_SOCKET | SCOPE_SIGNAL
    size = 8 if abi < 4 else 16 if abi < 6 else 24
    ruleset = check(
        libc.syscall(SYS_LANDLOCK_CREATE_RULESET, ctypes.byref(attr), ctypes.c_size_t(size), ctypes.c_uint32(0)),
        "create ruleset",
    )
    for path, rights in SYSTEM:
        if os.path.exists(path):
            grant(ruleset, fs, path, rights)
    for path, rights in granted:
        grant(ruleset, fs, path, rights)

    check(libc.prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0), "set no_new_privs")
    check(libc.syscall(SYS_LANDLOCK_RESTRICT_SELF, ruleset, ctypes.c_uint32(0)), "restrict self")
    os.close(ruleset)
    os.execvp(command[0], command)


if __name__ == "__main__":
    main()
