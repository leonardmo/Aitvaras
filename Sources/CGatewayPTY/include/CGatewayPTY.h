#ifndef AITVARAS_GATEWAY_PTY_H
#define AITVARAS_GATEWAY_PTY_H

// Runs only in the single launcher process. A child exits with its normal
// status or 128 + signal. -1 reports a system error via errno.
int aitvaras_supervise(const char *path, char *const argv[], char *const envp[], int interactive, int input, int output, int test_timeout_ms);

#endif
