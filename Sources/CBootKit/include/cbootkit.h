#ifndef CBOOTKIT_H
#define CBOOTKIT_H

#include <stddef.h>

/// Open `path` through Apple's /usr/libexec/authopen and receive the descriptor over a socket.
/// authopen holds the entitlements needed to open raw disk devices, which plain processes (even
/// root) cannot do since macOS 10.15 without Full Disk Access.
///
/// - extauth: optional 32 byte AuthorizationExternalForm (pre-authorized rights, so no prompt);
///            NULL lets authopen show its own authorization dialog.
/// Returns the file descriptor, or -1 with a message in `err`.
int cbk_authopen(const char *path, int oflags, const void *extauth, size_t extauth_len, char *err, size_t errlen);

#endif
