# Next agent session

## Required follow-up (previous session): real transport connectivity E2E tests

Done. Added `tests/e2e/scenarios/03-transport-connectivity.sh`, which starts
a real, compatible client for every configured transport and asserts on the
real response fetched through the tunnel from `https://example.com` (not a
stub, not just a listener/handshake check):

- VLESS WebSocket / gRPC / XHTTP through Nginx -- real xray-core client
  (the same binary 3x-ui installs), VLESS Encryption client key, TLS to the
  self-signed cert with `allowInsecure`.
- VLESS TCP+Reality direct (bypassing Nginx entirely) -- real xray-core
  client with the real Reality public key/short ID.
- Hysteria2 direct, including Salamander/`finalmask` -- real `hysteria`
  client binary (apernet/hysteria release).
- NaiveProxy direct HTTPS forward proxy -- plain `curl -x https://user:pass@...`
  (curl's native HTTPS-proxy support is itself a real client for this
  transport, no extra binary needed).
- mieru direct, username/password -- real `mieru` client binary
  (enfein/mieru client release, separate package from the `mita` server).

### Outstanding: needs confirmation on a native amd64 runner

Local validation on this session's arm64 (Apple Silicon) dev host hit a
QEMU user-mode emulation crash (SIGSEGV inside grpc-go's HTTP/2 transport,
during `mita apply config`) that reproduced even with
`GODEBUG=asyncpreemptoff=1` set. `run.sh` always forces `linux/amd64`
(NaiveProxy's binary is amd64-only), so every Go binary in scenario 3 runs
emulated on arm64 hosts -- this is very likely an emulator-level artifact,
not a real bug in `mita`/the script, but it was NOT possible to fully
confirm end-to-end locally in this session. **Next session (or CI, which is
natively amd64) should run `tests/e2e/run.sh 03-transport-connectivity.sh`
to completion and confirm all 7 transport assertions pass.** If it still
fails on native amd64, treat that as a real bug (start there, not with the
emulation theory).

One real bug WAS found and fixed via partial local runs before hitting the
emulation wall: the scenario originally set `REALITY_SUBDOMAIN`/
`HYSTERIA_SUBDOMAIN` before the first (`cdn`-mode) `install_3xui_and_inbounds`
call, tripping that function's own post-call validation (which checks "is
`REALITY_SUBDOMAIN` set" unconditionally, matching real usage where cdn/no-cdn
are mutually exclusive and would never see this combination). Fixed by
setting those two vars only right before the second (`no-cdn`-mode) call.

## Current implementation context

- Public selector is `CDN_MODE`, accepting true/false-compatible values.
- Internal `INSTALL_MODE` remains only as a normalized implementation branch
  (`cdn` / `no-cdn`).
- `CDN_MODE=false` renders no WS/gRPC/XHTTP locations in the generated Nginx
  site.
- Hysteria2 is direct UDP/QUIC and binds `0.0.0.0` (default UDP/443), while
  Nginx retains TCP/443.
- mieru (new this session) is a direct, no-TLS/SNI connection authenticated
  by username/password. Rather than one random ephemeral port, it listens on
  a fixed, curated "boring" port set (`53/UDP`, `853/TCP`, `993/TCP`,
  `8443/TCP`) -- deliberately not user-configurable, with automatic
  skip-on-collision per candidate. See `MIERU_CANDIDATE_PORTS`,
  `select_mieru_ports()`, `format_mieru_ports()` in `setup.sh`.
- Salamander/Gecko and HTTP/3 masquerade should not be combined: official
  Hysteria docs say obfuscation makes the server incompatible with standard
  QUIC/HTTP3.

## Validation already run

- Bash syntax, ShellCheck, and the full Bats suite (`tests/*.bats`) pass
  after the mieru feature and E2E scenario additions.
- Scenario 3's script logic was manually re-verified against upstream
  mieru/hysteria/xray-core config schemas and partially validated via real
  (if incomplete, due to the arm64/QEMU issue above) Docker E2E runs, which
  caught and fixed one real environment-ordering bug (see above).
- Full client connectivity E2E coverage is implemented but not yet
  confirmed passing end-to-end on a native amd64 host/CI.
