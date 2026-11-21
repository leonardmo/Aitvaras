#ifndef AITVARAS_GATEWAY_PTY_H
#define AITVARAS_GATEWAY_PTY_H
#include <sys/types.h>

// Runs only in the single launcher process. A child exits with its normal
// status or 128 + signal. -1 reports a system error via errno.
int aitvaras_supervise(const char *path, char *const argv[], char *const envp[], int interactive, int input, int output, int test_timeout_ms);

// Returns an owned child PID and a nonblocking PTY master. The caller drains
// and closes the master, signals the process group and reaps the child.
pid_t aitvaras_spawn_pty(const char *path, char *const argv[], char *const envp[],
                         const char *directory, unsigned short columns, int *master);

#endif
