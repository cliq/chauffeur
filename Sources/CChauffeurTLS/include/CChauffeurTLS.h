#pragma once
#include <stddef.h>
#include <stdint.h>

// Linux only. TLS 1.2 with TLS_PSK_WITH_AES_128_GCM_SHA256 over the system OpenSSL, the
// suite the iOS and macOS clients negotiate through Network.framework. BoringSSL, which
// swift-nio-ssl bundles, doesn't implement it. Calls block; callers give each its thread.

typedef struct ctls_server ctls_server;
typedef struct ctls_conn ctls_conn;

/// Binds a dual-stack TCP listener on `port` with the given pre-shared key (at most 64
/// bytes) and identity. Returns NULL and fills `error` (if given) on failure.
ctls_server *ctls_server_new(int port, const uint8_t *psk, size_t psk_len, const char *identity, char *error, size_t error_len);
/// Blocks until a client connects. Returns NULL once the server was closed, or after a
/// fatal listener error, which `ctls_server_failure` then reports.
ctls_conn *ctls_server_accept(ctls_server *server);
/// The errno that stopped `ctls_server_accept`, or 0.
int ctls_server_failure(ctls_server *server);
/// Unblocks a pending accept and stops accepting. Safe to call repeatedly.
void ctls_server_close(ctls_server *server);
/// Releases the server; call only once no thread is inside `ctls_server_accept`.
/// Connections it accepted stay valid: each holds its own copy of the key.
void ctls_server_free(ctls_server *server);

/// Numeric peer address, without a scope or IPv4-mapped prefix.
const char *ctls_conn_peer(ctls_conn *conn);
/// Runs the server handshake. Returns 0 on success, -1 on failure or timeout.
int ctls_conn_handshake(ctls_conn *conn, int timeout_ms, char *error, size_t error_len);
/// Reads up to `len` bytes. Returns the count, 0 at end of stream, or -1 on error/close.
long ctls_conn_read(ctls_conn *conn, uint8_t *buffer, size_t len);
/// Writes all bytes. Returns 0 on success, -1 on error/close. Concurrent writers may
/// interleave; callers serialize whole messages.
int ctls_conn_write(ctls_conn *conn, const uint8_t *buffer, size_t len);
/// Shuts the socket down so blocked reads and writes return. Safe to call repeatedly.
void ctls_conn_close(ctls_conn *conn);
/// Releases the connection; call only once no thread is inside read or write.
void ctls_conn_free(ctls_conn *conn);
