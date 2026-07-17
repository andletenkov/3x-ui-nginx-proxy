# Tests

Bats unit tests for `setup.sh`, `setup-3x-ui.sh`, and `harden-host.sh`.
System-mutating commands are replaced by executables in `tests/stubs/`; tests
need neither root access nor a real Cloudflare zone.

## Run

```bash
brew install bats-core   # or: apt install bats
chmod +x tests/stubs/*
bats tests/install.bats tests/anonymize.bats
```

## Coverage

`tests/install.bats` covers:

- port/path validation, including XHTTP API-style paths and collision checks;
- generated Nginx WS, gRPC, XHTTP, fallback, and panel proxy locations;
- XHTTP packet-up prefix routing for session/sequence subpaths;
- fallback-page installation and 404 behavior;
- Cloudflare real-IP generation and Cloudflare-only TCP/443 UFW rules;
- panel port validation, generated client links, and explicit enabled-client
  payloads;
- setup-helper invocation, subscription forwarding, uninstall cleanup, and
  idempotent configuration behavior.

`tests/anonymize.bats` covers DNS, NTP, sysctl, ICMP, TTL, banner, BBR, and
uninstall behavior in `harden-host.sh`.

## Stubs

| Stub | Purpose |
|---|---|
| `nginx` | Simulates config validation failures with `NGINX_T_SHOULD_FAIL=1` |
| `curl` | Supplies configurable Cloudflare IP ranges and HTTP responses |
| `ufw` | Records commands to `UFW_LOG` |
| `ss` | Simulates listeners via `SS_LISTENING_PORTS` |
| `iptables`, `sysctl`, `timedatectl`, `systemctl` | Isolate host-hardening behavior |
| `certbot`, `apt`, `apt-get`, `netfilter-persistent` | No-op external/system operations |
