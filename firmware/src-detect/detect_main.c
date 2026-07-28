// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Caleb Kemere, Reet Sinha, Allen Mikhailov, Rice University
//
// Minimal firmware for the IMU-DETECT bitstream. Brings up the network exactly
// like the acquisition firmware (PS7/MIO GEM, lwIP, static 192.168.18.10) and
// speaks the SAME 20-byte TCP command protocol + discovery beacon, so net.py
// connects unchanged. It handles only PING and DETECT_IMU and touches ONLY the
// detect peripheral (0x43D00000) -- never the acquisition PL, which does not
// exist in this bitstream and whose AXI addresses would hang the core.
//
// Deliberately self-contained (no src-core0 coupling): the acquisition main and
// network stack are wound through streaming/CDMA/aux state this image lacks.

#include "lwip/init.h"
#include "lwip/tcp.h"
#include "lwip/udp.h"
#include "lwip/timeouts.h"
#include "netif/xadapter.h"
#include "xparameters.h"
#include "xil_printf.h"
#include "xiltimer.h"   // XTime / XTime_GetTime (SDT flow), as in the acq firmware
#include "sleep.h"
#include <string.h>

#include "platform.h"
#include "pl_imu_detect.h"
// eth_link_detect() is declared by netif/xadapter.h (the lwIP EMAC adapter).

#define TCP_PORT         0x6900
#define UDP_PORT         0x6800
#define BEACON_PORT      0x6880
#define BEACON_MAGIC     0x4B4C4231   // "KLB1"
#define BEACON_VERSION   1
#define CMD_MAGIC        0xDEADBEEF
#define CMD_PACKET_SIZE  20
#define ACK_SUCCESS      0x06
#define ACK_ERROR        0x15

#define CMD_PING         0x60
#define CMD_DETECT_IMU   0xB0

struct netif server_netif;

// lwIP's timer subsystem needs a millisecond tick (same as the acquisition fw).
uint32_t sys_now(void) {
    XTime now;
    XTime_GetTime(&now);
    return (uint32_t)(now / (XPAR_CPU_CORE_CLOCK_FREQ_HZ / 1000U));
}

typedef struct __attribute__((packed)) {
    uint32_t magic, cmd_id, ack_id, param1, param2;
} cmd_packet_t;

// Matches net.py _BEACON_FMT '<II4sHHI6sH' (28 bytes).
typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint32_t version;
    uint8_t  ip[4];
    uint16_t tcp_port;
    uint16_t udp_port;
    uint32_t fw;
    uint8_t  mac[6];
    uint16_t reserved;
} device_beacon_t;
_Static_assert(sizeof(device_beacon_t) == 28, "beacon must be 28 bytes (net.py decode)");

static uint8_t recv_buffer[CMD_PACKET_SIZE] __attribute__((aligned(8)));
static uint16_t recv_pos = 0;

static const unsigned char board_mac[6] = { 0x00, 0x0a, 0x35, 0x00, 0x01, 0x02 };

// ---------------------------------------------------------------- responses --
static void send_ack(struct tcp_pcb *tpcb, uint32_t ack_id, uint8_t status) {
    uint8_t r[3] = { (ack_id >> 8) & 0xFF, ack_id & 0xFF, status };
    tcp_write(tpcb, r, 3, TCP_WRITE_FLAG_COPY);
    tcp_output(tpcb);
}
static void send_response(struct tcp_pcb *tpcb, uint32_t ack_id, uint8_t status,
                          const void *data, uint16_t len) {
    uint8_t h[5] = { (ack_id >> 8) & 0xFF, ack_id & 0xFF, status,
                     (len >> 8) & 0xFF, len & 0xFF };
    tcp_write(tpcb, h, 5, TCP_WRITE_FLAG_COPY);
    if (data && len) tcp_write(tpcb, data, len, TCP_WRITE_FLAG_COPY);
    tcp_output(tpcb);
}

static void process_command(struct tcp_pcb *tpcb, cmd_packet_t *cmd) {
    switch (cmd->cmd_id) {
        case CMD_PING:
            send_ack(tpcb, cmd->ack_id, ACK_SUCCESS);
            break;
        case CMD_DETECT_IMU: {
            imu_detect_response_t resp;
            int rc = pl_imu_detect_run(&resp);
            // Reply with the struct regardless (rc<0 => PL never reported done,
            // results zeroed); net.py flags the version mismatch / absence.
            (void)rc;
            send_response(tpcb, cmd->ack_id, ACK_SUCCESS, &resp, sizeof(resp));
            break;
        }
        default:
            // Everything else (incl. GET_STATUS) NAKs; net.py tolerates it and
            // proceeds to the command prompt.
            send_ack(tpcb, cmd->ack_id, ACK_ERROR);
            break;
    }
}

// ------------------------------------------------------------------ TCP recv --
static err_t tcp_recv_cb(void *arg, struct tcp_pcb *tpcb, struct pbuf *p, err_t err) {
    (void)arg; (void)err;
    if (!p) { tcp_close(tpcb); recv_pos = 0; return ERR_OK; }

    for (struct pbuf *q = p; q; q = q->next) {
        uint8_t *d = (uint8_t *)q->payload;
        for (uint16_t i = 0; i < q->len; i++) {
            recv_buffer[recv_pos++] = d[i];
            if (recv_pos == CMD_PACKET_SIZE) {
                recv_pos = 0;
                cmd_packet_t *cmd = (cmd_packet_t *)recv_buffer;
                if (cmd->magic == CMD_MAGIC) process_command(tpcb, cmd);
            }
        }
    }
    tcp_recved(tpcb, p->tot_len);
    pbuf_free(p);
    return ERR_OK;
}

static err_t tcp_accept_cb(void *arg, struct tcp_pcb *newpcb, err_t err) {
    (void)arg; (void)err;
    recv_pos = 0;
    tcp_recv(newpcb, tcp_recv_cb);
    return ERR_OK;
}

static void start_tcp_server(void) {
    struct tcp_pcb *pcb = tcp_new();
    if (!pcb) return;
    tcp_bind(pcb, IP_ADDR_ANY, TCP_PORT);
    pcb = tcp_listen(pcb);
    tcp_accept(pcb, tcp_accept_cb);
}

// -------------------------------------------------------------------- beacon --
static struct udp_pcb *beacon_pcb = NULL;
static ip_addr_t beacon_bcast;

static void beacon_init(void) {
    beacon_bcast.addr = IPADDR_BROADCAST;   // limited broadcast (SOF_BROADCAST off)
    beacon_pcb = udp_new();
}
static void beacon_send(void) {
    if (!beacon_pcb) return;
    static device_beacon_t b;   // static: PBUF_REF references it until TX drains
    b.magic = BEACON_MAGIC; b.version = BEACON_VERSION;
    memcpy(b.ip, &server_netif.ip_addr.addr, 4);
    b.tcp_port = TCP_PORT; b.udp_port = UDP_PORT;
    b.fw = 0; memcpy(b.mac, board_mac, 6); b.reserved = 0;
    struct pbuf *p = pbuf_alloc(PBUF_TRANSPORT, sizeof(b), PBUF_REF);
    if (!p) return;
    p->payload = &b;
    udp_sendto(beacon_pcb, p, &beacon_bcast, BEACON_PORT);
    pbuf_free(p);
}

// ---------------------------------------------------------------------- main --
int main(void) {
    ip_addr_t ipaddr, netmask, gw;

    init_platform();
    xil_printf("\r\nGLANCE IMU-DETECT firmware (probe both ports for BNO055)\r\n");

    IP4_ADDR(&ipaddr,  192, 168, 18, 10);
    IP4_ADDR(&netmask, 255, 255, 255, 0);
    IP4_ADDR(&gw,      192, 168, 18, 1);

    lwip_init();
    netif_add(&server_netif, &ipaddr, &netmask, &gw, NULL, NULL, NULL);
    netif_set_default(&server_netif);
    xemac_add(&server_netif, &ipaddr, &netmask, &gw,
              (unsigned char *)board_mac, XPAR_XEMACPS_0_BASEADDR);
    netif_set_up(&server_netif);

    // wait for PHY link
    eth_link_detect(&server_netif);
    while (!netif_is_link_up(&server_netif)) {
        xemacif_input(&server_netif);
        sys_check_timeouts();
        eth_link_detect(&server_netif);
    }
    xil_printf("Network link UP. IP 192.168.18.10, TCP port 0x%04X\r\n", TCP_PORT);

    start_tcp_server();
    beacon_init();

    // service loop: drain RX, beacon ~1 Hz (no acquisition, no time budget)
    unsigned beat = 0;
    while (1) {
        xemacif_input(&server_netif);
        sys_check_timeouts();
        if (++beat >= 200000) { beat = 0; beacon_send(); }
        usleep(5);
    }

    cleanup_platform();
    return 0;
}
