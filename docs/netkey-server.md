# Netkey server: serving a ZFS pool key over mutual TLS

The server side of `omarchy-zfs-netkey-setup`. This runs on a machine you
control — **not** on the Omarchy box being unlocked, and not on third-party
infrastructure: the payload is the key to your pool, so it must not transit a
provider that terminates TLS on your behalf (no CDN, no tunnel service that
re-signs). Point-to-point, pinned CA, client certificate required.

Nothing here is packaged. It's a recipe, because where it runs is your call.

## What gets served

Exactly the bytes of the pool keyfile — the same file
`keylocation=file://…` points at on the client (`/etc/zfs/keys/…` on a stock
`omarchy-bootstrap-zfs` install). The ZBM hook writes the response to a tmpfs
file and hands it to `zfs load-key -L file://…`, so any transformation (base64,
trailing newline) breaks the unlock.

```bash
# On the Omarchy box, as root — this is the file to publish:
zfs get -H -o value keylocation "$(zfs list -H -o name / | cut -d/ -f1)"
```

Copy it to the server over SSH. Never through anything that might log or cache.

## 1. A private CA

One CA, used to sign the server certificate and each client. `openssl` only —
no need for step-ca or Vault at this scale.

```bash
mkdir -p ~/netkey-ca && cd ~/netkey-ca
chmod 700 .

# CA (keep netkey-ca.key offline once the certs below exist)
openssl req -x509 -newkey ed25519 -nodes -days 3650 \
  -keyout netkey-ca.key -out netkey-ca.crt \
  -subj "/CN=omarchy netkey CA"

# Server cert — CN/SAN must match exactly what the client will request.
# Prefer an IP SAN: DNS in early boot means the ZBM image also needs a resolver.
openssl req -newkey ed25519 -nodes \
  -keyout server.key -out server.csr \
  -subj "/CN=keys.home.arpa"
openssl x509 -req -in server.csr -days 825 \
  -CA netkey-ca.crt -CAkey netkey-ca.key -CAcreateserial \
  -extfile <(printf 'subjectAltName=DNS:keys.home.arpa,IP:192.168.1.10\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n') \
  -out server.crt

# One client cert per host that may unlock. The CN is how you identify — and
# revoke — a specific machine.
openssl req -newkey ed25519 -nodes \
  -keyout colo01-client.key -out colo01-client.csr \
  -subj "/CN=colo01"
openssl x509 -req -in colo01-client.csr -days 825 \
  -CA netkey-ca.crt -CAkey netkey-ca.key -CAcreateserial \
  -extfile <(printf 'keyUsage=digitalSignature\nextendedKeyUsage=clientAuth\n') \
  -out colo01-client.crt
```

Give the client three files: `netkey-ca.crt`, `colo01-client.crt`,
`colo01-client.key` → the `--ca`, `--cert`, `--key` arguments of
`omarchy-zfs-netkey-setup`.

## 2. Serve it

Caddy, because mutual TLS is four lines. nginx equivalent is in the note below.

```caddyfile
# /etc/caddy/Caddyfile
https://keys.home.arpa:8443 {
    tls /etc/caddy/netkey/server.crt /etc/caddy/netkey/server.key {
        client_auth {
            mode                 require_and_verify
            trust_pool file /etc/caddy/netkey/netkey-ca.crt
        }
    }

    # One path per host, named for the client CN it belongs to. Serving a single
    # shared path to every client removes your ability to revoke one machine.
    @colo01 {
        path /colo01/key
        client_cert_cn colo01
    }
    handle @colo01 {
        rewrite * /colo01.key
        root * /etc/caddy/netkey/keys
        file_server
    }

    respond 404
}
```

```bash
sudo install -d -m 700 /etc/caddy/netkey/keys
sudo install -m 600 colo01.key /etc/caddy/netkey/keys/colo01.key   # the pool key
sudo chown -R caddy:caddy /etc/caddy/netkey
sudo systemctl enable --now caddy
```

The client URL is then `https://keys.home.arpa:8443/colo01/key`.

The `client_cert_cn` matcher is what makes per-host revocation work: without it,
any certificate your CA ever signed can fetch any key.

> **nginx**: `ssl_client_certificate /etc/nginx/netkey/netkey-ca.crt;`
> `ssl_verify_client on;` and gate on
> `if ($ssl_client_s_dn !~ "CN=colo01") { return 403; }` inside the
> `location /colo01/key` block.

## 3. Reachability from the colo

The keyserver has to be reachable from the colo box at boot, which means exposing
it. Keep the exposure narrow:

- **Firewalla (home LAN)**: port-forward `8443` to the keyserver, with an
  allow-rule restricted to the colo provider's address range. The colo IP is
  static; there's no reason for the rest of the internet to reach this port.
- Prefer an **IP SAN** and an IP-based URL so the ZBM image needs no DNS. If you
  use a hostname, `omarchy-zfs-remote-unlock-setup --static` must have been given
  a DNS server, and that resolver becomes a boot dependency.
- The keyserver must survive the same power event as the box it unlocks. If both
  are on the same UPS-less circuit, a shared outage means the colo box falls
  through to the SSH prompt — which is the designed fallback, not a failure, but
  worth knowing before you rely on unattended reboots.

## 4. Test before you trust it

From a host presenting the client cert:

```bash
curl --cacert netkey-ca.crt --cert colo01-client.crt --key colo01-client.key \
     https://keys.home.arpa:8443/colo01/key | cmp - /path/to/local/copy/of/pool.key

# And confirm it fails closed:
curl --cacert netkey-ca.crt https://keys.home.arpa:8443/colo01/key   # expect a TLS error
```

Then run the three reboot tests listed by `omarchy-zfs-netkey-setup`.

## 5. Revocation

There is no CRL here, deliberately — at this scale revocation is deletion:

| To revoke | Do |
|---|---|
| One host | Delete its key file on the server, or drop its `client_cert_cn` block |
| Every host | Stop the service, or pull the firewall rule |
| A stolen disk | Both of the above, then rotate the pool passphrase (`zfs change-key`) and re-publish |

A stolen ZBM image contains a valid client certificate. It is only useful while
the server answers it, so the response to lost hardware is to stop answering —
immediately, then rotate at leisure.
