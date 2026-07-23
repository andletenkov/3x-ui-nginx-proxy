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

### Local (arm64) run hit a QEMU emulation crash -- confirmed NOT a real bug

`tests/e2e/run.sh` always forces `--platform linux/amd64` (NaiveProxy's real
binary is amd64-only), so on this session's Apple Silicon/arm64 dev host
every Go binary in scenario 3 (xray-core, `mita`, `mieru`, `hysteria`) ran
under QEMU user-mode emulation. That triggered a SIGSEGV inside grpc-go's
HTTP/2 transport during `mita apply config`, reproducing even with
`GODEBUG=asyncpreemptoff=1` set.

This was root-caused and confirmed as a pure emulator artifact within this
session, not left as an open question: the exact same
`mita apply config` -> `mita start` -> real `mieru` client -> real SOCKS5
tunnel -> `curl https://example.com` chain, run in a systemd/cgroups
container built natively for `linux/arm64` (no QEMU involved), completed
with zero crashes and returned the real `Example Domain` page through the
tunnel end-to-end -- proving both that the crash is emulation-specific and
that the actual config-generation logic (`portBindings`, `users`, `mtu` on
the server side; `profiles`/`servers`/`portBindings`/`user`/`socks5Port` on
the client side) is correct.

GitHub Actions' `ubuntu-latest` runners are natively amd64, so this
scenario is not expected to hit the same emulator crash there. Still worth
a first CI run to confirm the full 7-transport pass end-to-end (this
session validated mieru's data path natively in isolation, but not the
xray-core/hysteria paths natively, for time reasons -- those go through the
same `run.sh` amd64-forced path and were not independently re-verified
outside QEMU).

One real bug WAS found and fixed via partial local (QEMU) runs before
reaching the crash: the scenario originally set `REALITY_SUBDOMAIN`/
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
- Scenario 3's logic was verified against upstream mieru/hysteria/xray-core
  config schemas, and mieru's full server+client data path was independently
  confirmed working end-to-end on native arm64 (see above).
- The full 7-transport scenario has not yet completed a clean run through
  `tests/e2e/run.sh` (amd64/QEMU-forced locally); next session should run it
  on CI or a native amd64 host to get a real pass/fail signal.
