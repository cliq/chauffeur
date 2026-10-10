#define _GNU_SOURCE
#include "CChauffeurTLS.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
#include <openssl/err.h>
#include <openssl/ssl.h>

#define CTLS_MAX_PSK 64
#define CTLS_MAX_IDENTITY 128
// Upper bound on any single wait. shutdown() wakes waiters at once; this only bounds
// how long a missed wake-up could go unnoticed.
#define CTLS_WAIT_MS 250

struct ctls_key {
    uint8_t psk[CTLS_MAX_PSK];
    size_t psk_len;
    char identity[CTLS_MAX_IDENTITY];
};

struct ctls_server {
    int fd;
    atomic_int closed;
    atomic_int failure;
    SSL_CTX *ctx;
    struct ctls_key key;
};

struct ctls_conn {
    int fd;
    atomic_int closed;
    SSL *ssl;
    // OpenSSL objects are not safe for concurrent use; reads and writes come from
    // different threads, so every SSL call holds this lock. Waiting for socket
    // readiness happens outside it.
    pthread_mutex_t lock;
    // A copy, so a handshake in progress never reads a listener that was freed.
    struct ctls_key key;
    char peer[INET6_ADDRSTRLEN];
};

static void set_error(char *error, size_t error_len, const char *message) {
    if (!error || error_len == 0) return;
    unsigned long code = ERR_peek_last_error();
    if (code) {
        char detail[160];
        ERR_error_string_n(code, detail, sizeof detail);
        snprintf(error, error_len, "%s (%s)", message, detail);
    } else if (errno) {
        snprintf(error, error_len, "%s (%s)", message, strerror(errno));
    } else {
        snprintf(error, error_len, "%s", message);
    }
    ERR_clear_error();
}

static unsigned int psk_callback(SSL *ssl, const char *identity, unsigned char *psk, unsigned int max_psk_len) {
    ctls_conn *conn = SSL_get_app_data(ssl);
    if (!conn || !identity || strcmp(identity, conn->key.identity) != 0) return 0;
    if (conn->key.psk_len > max_psk_len) return 0;
    memcpy(psk, conn->key.psk, conn->key.psk_len);
    return (unsigned int)conn->key.psk_len;
}

ctls_server *ctls_server_new(int port, const uint8_t *psk, size_t psk_len, const char *identity, char *error, size_t error_len) {
    errno = 0;
    if (!psk || psk_len == 0 || psk_len > CTLS_MAX_PSK || !identity || strlen(identity) >= CTLS_MAX_IDENTITY) {
        set_error(error, error_len, "invalid key");
        return NULL;
    }
    ctls_server *server = calloc(1, sizeof *server);
    if (!server) { set_error(error, error_len, "out of memory"); return NULL; }
    memcpy(server->key.psk, psk, psk_len);
    server->key.psk_len = psk_len;
    strcpy(server->key.identity, identity);
    server->fd = -1;

    server->ctx = SSL_CTX_new(TLS_server_method());
    if (!server->ctx) { set_error(error, error_len, "SSL_CTX_new failed"); ctls_server_free(server); return NULL; }
    SSL_CTX_set_min_proto_version(server->ctx, TLS1_2_VERSION);
    SSL_CTX_set_max_proto_version(server->ctx, TLS1_2_VERSION);
    SSL_CTX_set_options(server->ctx, SSL_OP_NO_RENEGOTIATION | SSL_OP_NO_TICKET);
    SSL_CTX_set_mode(server->ctx, SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER | SSL_MODE_ENABLE_PARTIAL_WRITE);
    // The suite Network.framework negotiates; plain PSK needs security level 0.
    if (SSL_CTX_set_cipher_list(server->ctx, "PSK-AES128-GCM-SHA256:@SECLEVEL=0") != 1) {
        set_error(error, error_len, "PSK cipher unavailable");
        ctls_server_free(server);
        return NULL;
    }
    SSL_CTX_set_psk_server_callback(server->ctx, psk_callback);

    int fd = socket(AF_INET6, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) { set_error(error, error_len, "socket failed"); ctls_server_free(server); return NULL; }
    int on = 1, off = 0;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof on);
    setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &off, sizeof off);
    struct sockaddr_in6 address = {0};
    address.sin6_family = AF_INET6;
    address.sin6_addr = in6addr_any;
    address.sin6_port = htons((uint16_t)port);
    if (bind(fd, (struct sockaddr *)&address, sizeof address) != 0 || listen(fd, 16) != 0) {
        set_error(error, error_len, "cannot listen on port");
        close(fd);
        ctls_server_free(server);
        return NULL;
    }
    server->fd = fd;
    return server;
}

static void describe_peer(const struct sockaddr_storage *peer, char *text, size_t text_len) {
    if (peer->ss_family == AF_INET6) {
        const struct sockaddr_in6 *six = (const struct sockaddr_in6 *)peer;
        if (IN6_IS_ADDR_V4MAPPED(&six->sin6_addr)) inet_ntop(AF_INET, &six->sin6_addr.s6_addr[12], text, (socklen_t)text_len);
        else inet_ntop(AF_INET6, &six->sin6_addr, text, (socklen_t)text_len);
    } else if (peer->ss_family == AF_INET) {
        inet_ntop(AF_INET, &((const struct sockaddr_in *)peer)->sin_addr, text, (socklen_t)text_len);
    }
}

static ctls_conn *new_conn(ctls_server *server, int fd, const struct sockaddr_storage *peer) {
    ctls_conn *conn = calloc(1, sizeof *conn);
    if (!conn) return NULL;
    conn->fd = fd;
    conn->key = server->key;
    if (pthread_mutex_init(&conn->lock, NULL) != 0) { free(conn); return NULL; }
    describe_peer(peer, conn->peer, sizeof conn->peer);
    conn->ssl = SSL_new(server->ctx);
    if (!conn->ssl || SSL_set_fd(conn->ssl, fd) != 1) {
        if (conn->ssl) SSL_free(conn->ssl);
        pthread_mutex_destroy(&conn->lock);
        free(conn);
        ERR_clear_error();
        return NULL;
    }
    SSL_set_app_data(conn->ssl, conn);
    SSL_set_accept_state(conn->ssl);
    return conn;
}

/// Sleeps regardless of the listener: while descriptors are exhausted it stays readable,
/// so waiting on it would return at once.
static void back_off(void) {
    struct timespec pause = { .tv_sec = 0, .tv_nsec = 100 * 1000000L };
    nanosleep(&pause, NULL);
}

ctls_conn *ctls_server_accept(ctls_server *server) {
    while (!atomic_load(&server->closed)) {
        struct pollfd item = { .fd = server->fd, .events = POLLIN };
        int ready = poll(&item, 1, CTLS_WAIT_MS);
        if (ready < 0 && errno != EINTR) { atomic_store(&server->failure, errno); return NULL; }
        if (ready <= 0) continue;
        struct sockaddr_storage peer = {0};
        socklen_t peer_len = sizeof peer;
        int fd = accept4(server->fd, (struct sockaddr *)&peer, &peer_len, SOCK_CLOEXEC | SOCK_NONBLOCK);
        if (fd < 0) {
            if (atomic_load(&server->closed)) return NULL;
            switch (errno) {
            case EINTR: case EAGAIN: case ECONNABORTED: case EPROTO:
                continue;
            case EMFILE: case ENFILE: case ENOBUFS: case ENOMEM:
                back_off();
                continue;
            default:
                atomic_store(&server->failure, errno);
                return NULL;
            }
        }
        int on = 1;
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, sizeof on);
        ctls_conn *conn = new_conn(server, fd, &peer);
        if (conn) return conn;
        close(fd);
        back_off();
    }
    return NULL;
}

int ctls_server_failure(ctls_server *server) { return atomic_load(&server->failure); }

void ctls_server_close(ctls_server *server) {
    if (atomic_exchange(&server->closed, 1)) return;
    if (server->fd >= 0) shutdown(server->fd, SHUT_RDWR);
}

void ctls_server_free(ctls_server *server) {
    if (!server) return;
    if (server->fd >= 0) close(server->fd);
    if (server->ctx) SSL_CTX_free(server->ctx);
    OPENSSL_cleanse(&server->key, sizeof server->key);
    free(server);
}

const char *ctls_conn_peer(ctls_conn *conn) { return conn->peer; }

static long now_ms(void) {
    struct timespec spec;
    clock_gettime(CLOCK_MONOTONIC, &spec);
    return spec.tv_sec * 1000L + spec.tv_nsec / 1000000L;
}

/// Waits for the socket after WANT_READ/WANT_WRITE. Returns -1 once closed or on error.
static int wait_for(ctls_conn *conn, int want, int timeout_ms) {
    if (atomic_load(&conn->closed)) return -1;
    struct pollfd item = { .fd = conn->fd, .events = (short)(want == SSL_ERROR_WANT_WRITE ? POLLOUT : POLLIN) };
    int ready = poll(&item, 1, timeout_ms);
    if (ready < 0 && errno != EINTR) return -1;
    if (atomic_load(&conn->closed)) return -1;
    return 0;
}

int ctls_conn_handshake(ctls_conn *conn, int timeout_ms, char *error, size_t error_len) {
    long deadline = now_ms() + timeout_ms;
    for (;;) {
        errno = 0;
        pthread_mutex_lock(&conn->lock);
        int result = SSL_do_handshake(conn->ssl);
        int code = result == 1 ? SSL_ERROR_NONE : SSL_get_error(conn->ssl, result);
        if (code != SSL_ERROR_NONE && code != SSL_ERROR_WANT_READ && code != SSL_ERROR_WANT_WRITE) set_error(error, error_len, "TLS handshake failed");
        else ERR_clear_error();
        pthread_mutex_unlock(&conn->lock);
        if (code == SSL_ERROR_NONE) return 0;
        if (code != SSL_ERROR_WANT_READ && code != SSL_ERROR_WANT_WRITE) return -1;
        long remaining = deadline - now_ms();
        if (remaining <= 0) { if (error && error_len) snprintf(error, error_len, "TLS handshake timed out"); return -1; }
        if (wait_for(conn, code, remaining > CTLS_WAIT_MS ? CTLS_WAIT_MS : (int)remaining) != 0) {
            if (error && error_len) snprintf(error, error_len, "connection closed");
            return -1;
        }
    }
}

long ctls_conn_read(ctls_conn *conn, uint8_t *buffer, size_t len) {
    int chunk = len > 0x7fffffff ? 0x7fffffff : (int)len;
    for (;;) {
        if (atomic_load(&conn->closed)) return -1;
        pthread_mutex_lock(&conn->lock);
        int result = SSL_read(conn->ssl, buffer, chunk);
        int code = result > 0 ? SSL_ERROR_NONE : SSL_get_error(conn->ssl, result);
        ERR_clear_error();
        pthread_mutex_unlock(&conn->lock);
        if (result > 0) return result;
        if (code == SSL_ERROR_ZERO_RETURN) return 0;
        // A peer that closes without close_notify, as Network.framework may.
        if (code == SSL_ERROR_SYSCALL && result == 0) return 0;
        if (code != SSL_ERROR_WANT_READ && code != SSL_ERROR_WANT_WRITE) return -1;
        if (wait_for(conn, code, CTLS_WAIT_MS) != 0) return -1;
    }
}

int ctls_conn_write(ctls_conn *conn, const uint8_t *buffer, size_t len) {
    size_t offset = 0;
    while (offset < len) {
        if (atomic_load(&conn->closed)) return -1;
        size_t chunk = len - offset;
        if (chunk > 0x7fffffff) chunk = 0x7fffffff;
        pthread_mutex_lock(&conn->lock);
        int result = SSL_write(conn->ssl, buffer + offset, (int)chunk);
        int code = result > 0 ? SSL_ERROR_NONE : SSL_get_error(conn->ssl, result);
        ERR_clear_error();
        pthread_mutex_unlock(&conn->lock);
        if (result > 0) { offset += (size_t)result; continue; }
        if (code != SSL_ERROR_WANT_READ && code != SSL_ERROR_WANT_WRITE) return -1;
        if (wait_for(conn, code, CTLS_WAIT_MS) != 0) return -1;
    }
    return 0;
}

void ctls_conn_close(ctls_conn *conn) {
    if (atomic_exchange(&conn->closed, 1)) return;
    shutdown(conn->fd, SHUT_RDWR);
}

void ctls_conn_free(ctls_conn *conn) {
    if (!conn) return;
    if (conn->ssl) SSL_free(conn->ssl);
    close(conn->fd);
    pthread_mutex_destroy(&conn->lock);
    OPENSSL_cleanse(&conn->key, sizeof conn->key);
    free(conn);
}
