# Network Layer — boss-12 (192.168.215.12)

## Interface

| Interface | IP | Netmask | Gateway |
|-----------|----|---------|---------|
| eth0 | 192.168.215.12/24 | 255.255.255.0 | 192.168.215.1 |
| lo | 127.0.0.1/8 | — | — |

## DNS

| Field | Value |
|-------|-------|
| Nameserver | 0.250.250.200 (Docker Engine DNS) |
| Resolv managed by | Docker Engine |

## Listening Services

| Port | Protocol | Service |
|------|----------|---------|
| 22 | TCP | SSH (OpenSSH) |

Only SSH is exposed. No other services listen on any port.

## Network Details

- OSI layer 2: eth0 (veth pair, index 1913 on host)
- MAC: e2:c2:c9:85:13:17
- MTU: 1500
- Docker bridge network (192.168.215.0/24)

## Proxy

| Variable | Value |
|----------|-------|
| http_proxy | (unset) |
| https_proxy | (unset) |
| no_proxy | (unset) |

No proxy configured.

## Adjacent Hosts

| IP | Role |
|----|------|
| 192.168.215.1 | Gateway / Docker host |
| 192.168.215.5 | kyb dev container (this session) |
