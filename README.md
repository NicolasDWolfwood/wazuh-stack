# Wazuh + syslog-ng on Unraid behind Nginx Proxy Manager

This bundle is opinionated for your environment:

- `creanet` is the Docker-internal network spanning `10.18.0.0/16`
- the Wazuh containers use fixed addresses inside that network, currently `10.18.1.x`
- `br0` is your external LAN-backed Docker network on `192.168.1.0/24`
- `syslog-ng` gets its own `br0` IP so it can bind `514/tcp` and `514/udp` without conflicting with the host
- the rest of the stack stays on `creanet`
- external systems reach the dashboard and manager through published ports on the Unraid host IP
- appdata is rooted under `/mnt/user/appdata/wazuh`
- public hostname: `wazuh.creative-it.nl`
- Nginx Proxy Manager handles public TLS
- minimal hand work: bootstrap appdata, generate the dashboard keystore, generate certs, bring the stack up

## What this stack does

- `syslog-ng` receives syslog on UDP/TCP 514
- raw logs are retained under `/mnt/user/appdata/wazuh/syslog-ng/logs`
- logs are forwarded internally to `wazuh.manager` over TCP 514
- `syslog-ng` is dual-homed: `br0` for syslog ingress and `creanet` for forwarding into Wazuh
- the Wazuh containers use fixed `10.18.1.x` addresses inside `creanet`
- the dashboard is exposed on the Unraid host at `http://<unraid-lan-ip>:5601`
- NPM proxies `https://wazuh.creative-it.nl` to `http://<unraid-lan-ip>:5601`

## Recommended exposure model

Best practice is to keep `wazuh.creative-it.nl` internal-only or protected behind VPN / identity-aware access.
Do not expose the dashboard directly to the public internet unless you understand the risk and have a strong access-control layer.

## File placement

Run the bootstrap script and it creates the required tree automatically under `${APPDATA_ROOT}`:

- `syslog-ng/config/syslog-ng.conf`
- `syslog-ng/logs/`
- `manager/api-configuration/`
- `manager/etc/ossec.conf`
- `manager/logs/`, `manager/queue/`, `manager/var/multigroups/`, `manager/integrations/`
- `manager/active-response/bin/`, `manager/agentless/`, `manager/wodles/`
- `manager/filebeat-etc/`, `manager/filebeat-var/`
- `indexer/config/opensearch.yml`
- `indexer/config/opensearch-security/internal_users.yml`
- `indexer/data/`
- `dashboard/config/opensearch_dashboards.yml`
- `dashboard/config/opensearch_dashboards.keystore`
- `dashboard/custom-assets/`
- `certs/certs.yml`

## Required edits before startup

1. Copy `.env.example` to `.env`
2. Set `APPDATA_ROOT` if you want a different appdata location
3. Set the host/IP values in `.env` if you do not want the defaults
4. Replace all `CHANGE_ME_...` values in `.env` with plaintext passwords
5. If a password contains `$`, escape it as `$$` in `.env`
6. Set `WAZUH_CLUSTER_KEY` to exactly 32 alphanumeric characters
7. Ensure the external Docker networks `br0` and `creanet` already exist on Unraid
8. In Unraid `Settings -> Docker`, set `Docker custom network type` to `ipvlan` for the `br0` custom IP setup
9. Keep the `10.18.1.x` addresses reserved inside `creanet` for this stack

## Bootstrap appdata

```bash
./scripts/bootstrap-appdata.sh
```

The bootstrap script:

- creates the appdata directory tree
- copies the static config files into place
- renders `manager/etc/ossec.conf` with the cluster key from `.env`
- renders `dashboard/config/opensearch_dashboards.yml` without persisting indexer credentials
- generates `internal_users.yml` from the passwords in `.env`
- generates `certs.yml` from the fixed IPs in `.env`

## Generate the dashboard keystore

```bash
./scripts/generate-dashboard-keystore.sh
```

## Generate Wazuh certificates

```bash
./scripts/generate-certs.sh
```

## Recommended Unraid operator workflow

For the supported Unraid path, use the wrapper scripts instead of running each step by hand:

```bash
./scripts/deploy-unraid.sh
```

This script:

- validates the required `.env` values
- checks that the external Docker networks already exist
- bootstraps appdata
- generates the dashboard keystore
- generates certs
- recreates the stack
- runs a health check at the end

To run the health check later without redeploying:

```bash
./scripts/check-unraid.sh
```

For a host-originated syslog end-to-end smoke test:

```bash
./scripts/check-unraid.sh --smoke-syslog
```

To prune old raw syslog files based on `SYSLOG_RETENTION_DAYS`:

```bash
./scripts/prune-syslog-logs.sh
```

## Start the stack

```bash
./scripts/docker-compose-host.sh up -d
```

## Nginx Proxy Manager settings

Create a Proxy Host with:

- Domain Names: `wazuh.creative-it.nl`
- Scheme: `http`
- Forward Hostname / IP: your Unraid server LAN IP on `192.168.1.0/24`
- Forward Port: `5601`
- Cache Assets: off
- Block Common Exploits: on
- Websockets Support: on

### SSL tab

- Request a new SSL certificate for `wazuh.creative-it.nl`
- Force SSL: on
- HTTP/2 Support: on
- HSTS Enabled: on

### Advanced NPM config

```nginx
proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;

proxy_http_version 1.1;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection "upgrade";

proxy_read_timeout 3600;
proxy_send_timeout 3600;
```

## Notes

- `WAZUH_API_BIND_IP` defaults to `127.0.0.1` so the API is not exposed on the LAN by default.
- `DASHBOARD_BIND_IP`, `WAZUH_AGENT_BIND_IP`, and `WAZUH_AUTH_BIND_IP` are separate on purpose so you can tighten exposure service by service.
- If you want Unraid itself to send syslog to the `syslog-ng` `br0` IP, keep Unraid `Host access to custom networks` enabled.
- Schedule `./scripts/prune-syslog-logs.sh` from Unraid User Scripts or cron if you want automatic retention enforcement.

## UniFi / Ubiquiti logging target

- IP: `192.168.1.200` or whatever you set as `SYSLOG_BR0_IP`
- Port: `514`
- Protocol: UDP initially, TCP if your controller/build supports and behaves correctly

## Addressing model

- `192.168.1.200`: `syslog-ng` on `br0`
- `10.18.1.2`: `syslog-ng` on `creanet`
- `10.18.1.3`: `wazuh.manager`
- `10.18.1.4`: `wazuh.indexer`
- `10.18.1.5`: `wazuh.dashboard`

Only `192.168.1.200` or your configured `SYSLOG_BR0_IP` is intended for direct LAN syslog ingress. The `10.18.1.x` addresses are for Docker-side communication on `creanet`. External clients should use the Unraid host IP and the published ports for the dashboard and manager.
