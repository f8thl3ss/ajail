use std::io;

/// Install a seccomp BPF filter that blocks `socket(AF_UNIX, ...)` with EACCES.
///
/// The filter checks the architecture is x86_64 or aarch64, then blocks
/// `socket()` calls where the first argument (domain) is `AF_UNIX`. All other
/// syscalls and socket domains pass through. Operations on inherited/pre-existing
/// unix socket FDs are not affected.
pub fn block_unix_sockets() -> io::Result<()> {
    const AUDIT_ARCH_X86_64: u32 = 0xC000_003E;
    const AUDIT_ARCH_AARCH64: u32 = 0xC000_00B7;
    const NR_SOCKET_X86_64: u32 = 41; // __NR_socket on x86_64
    const NR_SOCKET_AARCH64: u32 = 198; // __NR_socket on aarch64
    const AF_UNIX: u32 = 1;
    const SECCOMP_RET_ALLOW: u32 = 0x7FFF_0000;
    const SECCOMP_RET_ERRNO: u32 = 0x0005_0000;
    const EACCES: u32 = 13;

    // BPF instruction constants (pre-combined)
    const BPF_LD_W_ABS: u16 = 0x20; // BPF_LD | BPF_W | BPF_ABS
    const BPF_JMP_JEQ_K: u16 = 0x15; // BPF_JMP | BPF_JEQ | BPF_K
    const BPF_RET_K: u16 = 0x06; // BPF_RET | BPF_K

    // seccomp_data field offsets
    const OFF_NR: u32 = 0; // offsetof(seccomp_data, nr)
    const OFF_ARCH: u32 = 4; // offsetof(seccomp_data, arch)
    const OFF_ARGS0: u32 = 16; // offsetof(seccomp_data, args[0])

    #[rustfmt::skip]
    let mut filter: [libc::sock_filter; 11] = [
        // [0] Load arch
        libc::sock_filter { code: BPF_LD_W_ABS, jt: 0, jf: 0, k: OFF_ARCH },
        // [1] If arch == x86_64, jump to x86_64 handler at [3]
        libc::sock_filter { code: BPF_JMP_JEQ_K, jt: 1, jf: 0, k: AUDIT_ARCH_X86_64 },
        // [2] If arch == aarch64, jump to aarch64 handler at [5]; else ALLOW at [10]
        libc::sock_filter { code: BPF_JMP_JEQ_K, jt: 2, jf: 7, k: AUDIT_ARCH_AARCH64 },
        // --- x86_64 path ---
        // [3] Load syscall number
        libc::sock_filter { code: BPF_LD_W_ABS, jt: 0, jf: 0, k: OFF_NR },
        // [4] If nr == __NR_socket (x86_64), jump to domain check at [7]; else ALLOW at [10]
        libc::sock_filter { code: BPF_JMP_JEQ_K, jt: 2, jf: 5, k: NR_SOCKET_X86_64 },
        // --- aarch64 path ---
        // [5] Load syscall number
        libc::sock_filter { code: BPF_LD_W_ABS, jt: 0, jf: 0, k: OFF_NR },
        // [6] If nr == __NR_socket (aarch64), continue to domain check; else ALLOW at [10]
        libc::sock_filter { code: BPF_JMP_JEQ_K, jt: 0, jf: 3, k: NR_SOCKET_AARCH64 },
        // --- common domain check ---
        // [7] Load socket domain (args[0])
        libc::sock_filter { code: BPF_LD_W_ABS, jt: 0, jf: 0, k: OFF_ARGS0 },
        // [8] If domain == AF_UNIX, block; else ALLOW at [10]
        libc::sock_filter { code: BPF_JMP_JEQ_K, jt: 0, jf: 1, k: AF_UNIX },
        // [9] Return SECCOMP_RET_ERRNO | EACCES
        libc::sock_filter { code: BPF_RET_K, jt: 0, jf: 0, k: SECCOMP_RET_ERRNO | EACCES },
        // [10] Return SECCOMP_RET_ALLOW
        libc::sock_filter { code: BPF_RET_K, jt: 0, jf: 0, k: SECCOMP_RET_ALLOW },
    ];

    let prog = libc::sock_fprog {
        len: filter.len() as u16,
        filter: filter.as_mut_ptr(),
    };

    // PR_SET_NO_NEW_PRIVS is required before installing a seccomp filter
    // as an unprivileged user.
    let ret = unsafe { libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) };
    if ret != 0 {
        return Err(io::Error::last_os_error());
    }

    let ret = unsafe {
        libc::prctl(
            libc::PR_SET_SECCOMP,
            libc::SECCOMP_MODE_FILTER,
            &prog as *const libc::sock_fprog,
        )
    };
    if ret != 0 {
        return Err(io::Error::last_os_error());
    }

    Ok(())
}
