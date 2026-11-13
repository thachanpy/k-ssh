# Integration testing against a local OpenSSH server

SSH integration tests (`SSHIntegrationTests`) are skipped unless `SSH_IT=1`.

## Start the server (Docker)

From the repo root:

```bash
docker run -d --name ssh-it -p 2222:2222 \
  -e PUID=1000 -e PGID=1000 -e TZ=Etc/UTC \
  -e USER_NAME=test -e USER_PASSWORD=testpass -e PASSWORD_ACCESS=true \
  -e PUBLIC_KEY_DIR=/pubkeys \
  -v "$PWD/docs/integration/pubkeys:/pubkeys:ro" \
  lscr.io/linuxserver/openssh-server:latest
```

- User `test` / password `testpass`, port `2222`.
- `docs/integration/pubkeys/` holds the public halves of the **throwaway** fixture keys in
  `Packages/SSHCore/Tests/SSHCoreTests/KeyFixtures.swift` (Ed25519, RSA 2048, Ed25519 encrypted with
  passphrase `secret`). Never reuse these keys anywhere real.
- Wait a few seconds until `docker logs ssh-it` shows the server is ready.

## Run

```bash
cd Packages/SSHCore
SSH_IT=1 swift test --filter SSHIntegrationTests
```

## Stop

```bash
docker rm -f ssh-it
```

Each test uses its own temporary known-hosts store, so recreating the container (new host keys) does
not affect results.

## Manual check: jump host (T21)

No automated two-hop test exists yet. To verify by hand:

1. Start a second container on port `2223` (same command as above, different `--name`/port) and make
   it reachable only from the first container's network if you want a real bastion setup.
2. In the app, add host **A** (`localhost:2222`, user `test`) and host **B** (`localhost:2223`,
   user `test`) and, in B's editor, set *Connect through* = A.
3. Connect to B: you should be asked to trust both host keys (A first, then B), and a shell opens on B.
4. Make A point to B as its jump host: saving must be rejected ("loops back").
5. Close the tab: both connections end (check with `docker exec ssh-it ss -tn`).
