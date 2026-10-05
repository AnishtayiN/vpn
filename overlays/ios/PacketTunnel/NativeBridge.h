#include <stdint.h>
#include <stddef.h>
int32_t voidrau_core_start(const char *environment_json);
void voidrau_core_stop(void);
char *voidrau_core_error(void);
void voidrau_core_string_free(char *string);
int hev_socks5_tunnel_main_from_str(const unsigned char *config, unsigned int length, int fd);
void hev_socks5_tunnel_quit(void);
void hev_socks5_tunnel_stats(size_t *tx_packets, size_t *tx_bytes, size_t *rx_packets, size_t *rx_bytes);
