// sigmask-dedup.so — LD_PRELOAD shim that eliminates no-op pthread_sigmask
// syscalls on the Palworld Linux dedicated server.
//
// Problem (measured 2026-08-05): UE4SS's signal-based per-step crash-recovery
// trampoline flips the process signal mask around every Lua/UObject step on
// the game thread. Each flip is a real rt_sigprocmask syscall even when the
// resulting mask is unchanged (the trampoline blocks the same signal set,
// does work, restores — the intermediate states repeat). Measured cost:
// 289K syscalls/s on the populated test world (~18-20% of one core in
// kernel syscall + _copy_to_user), 144K/s on idle live, 36K/s after the
// mod-side cleanup (a497278/e150d63).
//
// Mechanism: intercept pthread_sigmask (and sigprocmask), maintain a
// THREAD-LOCAL mirror of the calling thread's current mask. If the requested
// operation would leave THAT THREAD's mask unchanged, return 0 without
// entering the kernel. Semantics preserved for all real changes
// (block/unblock/set). Query-only calls (oldset with how==SIG_SETMASK and
// set==NULL) pass through.
//
// Per-thread correctness: rt_sigprocmask affects only the calling thread
// (NPTL). The mirror is __thread, initialized from the real mask on that
// thread's first intercepted call, and updated after every real change.
// Threads created by pthread_create inherit the creator's mask — their
// first intercepted call re-queries the kernel, so the mirror never drifts
// into a state where we skip a real change. Skipping only happens when the
// mirror proves the result is identical, which is a pure no-op.
//
// Build: gcc -shared -fPIC -O2 -o sigmask-dedup.so sigmask-dedup.c -ldl
// Use: LD_PRELOAD="/palworld/.../sigmask-dedup.so:/palworld/.../libUE4SS.so"
//
// v1.0 (2026-08-05): initial shim, per-thread mirror, pthread_sigmask +
// sigprocmask wrappers.

#define _GNU_SOURCE
#include <pthread.h>
#include <signal.h>
#include <dlfcn.h>

typedef int (*sigmask_fn)(int how, const sigset_t *set, sigset_t *oldset);

static sigmask_fn real_pthread_sigmask = NULL;
static sigmask_fn real_sigprocmask = NULL;

// Thread-local mirror of this thread's current signal mask.
static __thread sigset_t t_current_mask;
static __thread int t_mask_initialized = 0;

static void ensure_init(void)
{
    if (!t_mask_initialized)
    {
        // Query the real kernel state for THIS thread so the mirror starts
        // accurate (covers pthread_create-inherited masks and any changes
        // made before our interception — e.g. by the dynamic loader).
        sigset_t probe;
        // Use the real function if resolved, else the syscall path; a
        // no-argument query never recurses into our wrapper because we
        // call the real function directly.
        sigmask_fn real = real_pthread_sigmask ? real_pthread_sigmask
                                               : (sigmask_fn)dlsym(RTLD_NEXT, "pthread_sigmask");
        if (real == NULL)
        {
            real = (sigmask_fn)dlsym(RTLD_NEXT, "sigprocmask");
        }
        if (real != NULL)
        {
            real(SIG_SETMASK, NULL, &probe);
        }
        else
        {
            sigemptyset(&probe);
        }
        t_current_mask = probe;
        t_mask_initialized = 1;
    }
}

// Compute the mask that WOULD result from `how` applied to `set`.
// Returns 1 if the result equals this thread's current mask (no-op),
// 0 otherwise.
static int mask_would_be_noop(int how, const sigset_t *set)
{
    sigset_t result = t_current_mask;
    switch (how)
    {
    case SIG_BLOCK:
        for (int i = 1; i < NSIG; i++)
        {
            if (sigismember(set, i))
            {
                sigaddset(&result, i);
            }
        }
        break;
    case SIG_UNBLOCK:
        for (int i = 1; i < NSIG; i++)
        {
            if (sigismember(set, i))
            {
                sigdelset(&result, i);
            }
        }
        break;
    case SIG_SETMASK:
        result = *set;
        break;
    default:
        return 0; // unknown how — pass through
    }

    for (int i = 1; i < NSIG; i++)
    {
        if (sigismember(&result, i) != sigismember(&t_current_mask, i))
        {
            return 0;
        }
    }
    return 1;
}

static void apply_to_mirror(int how, const sigset_t *set)
{
    if (how == SIG_SETMASK)
    {
        t_current_mask = *set;
        return;
    }
    for (int i = 1; i < NSIG; i++)
    {
        if (!sigismember(set, i))
        {
            continue;
        }
        if (how == SIG_BLOCK)
        {
            sigaddset(&t_current_mask, i);
        }
        else
        {
            sigdelset(&t_current_mask, i);
        }
    }
}

static int shim_sigmask(sigmask_fn real_fn,
                        int how, const sigset_t *set, sigset_t *oldset)
{
    if (real_fn == NULL)
    {
        real_fn = (sigmask_fn)dlsym(RTLD_NEXT, "pthread_sigmask");
        if (real_fn == NULL)
        {
            real_fn = (sigmask_fn)dlsym(RTLD_NEXT, "sigprocmask");
        }
        if (real_fn == NULL)
        {
            return -1; // fail closed — never hide a call we can't reason about
        }
    }

    ensure_init();

    // Query-only (set==NULL) or unknown how: pass through.
    if (set == NULL || (how != SIG_BLOCK && how != SIG_UNBLOCK && how != SIG_SETMASK))
    {
        return real_fn(how, set, oldset);
    }

    // Pure no-op for this thread: deliver the mirror as oldset, skip syscall.
    if (mask_would_be_noop(how, set))
    {
        if (oldset != NULL)
        {
            *oldset = t_current_mask;
        }
        return 0;
    }

    int result = real_fn(how, set, oldset);
    if (result == 0)
    {
        apply_to_mirror(how, set);
    }
    return result;
}

int pthread_sigmask(int how, const sigset_t *set, sigset_t *oldset)
{
    if (real_pthread_sigmask == NULL)
    {
        real_pthread_sigmask = (sigmask_fn)dlsym(RTLD_NEXT, "pthread_sigmask");
        if (real_pthread_sigmask == NULL)
        {
            real_pthread_sigmask = (sigmask_fn)dlsym(RTLD_NEXT, "sigprocmask");
        }
    }
    return shim_sigmask(real_pthread_sigmask, how, set, oldset);
}

int sigprocmask(int how, const sigset_t *set, sigset_t *oldset)
{
    if (real_sigprocmask == NULL)
    {
        real_sigprocmask = (sigmask_fn)dlsym(RTLD_NEXT, "sigprocmask");
    }
    return shim_sigmask(real_sigprocmask, how, set, oldset);
}
