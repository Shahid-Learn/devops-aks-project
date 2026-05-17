# Pre-ACR Build Checklist (OpenTelemetry Demo)

Use this checklist before running full image build and push to ACR.

## Goal

Validate the container workflow with a small representative subset locally, then rely on CI for the full fleet build.

## Important Reality Check

You do **not** need to build every service locally before ACR/AKS.

- Local environment issues (DNS, TLS trust, WSL2 mount permissions) can break builds even when Dockerfiles are correct.
- CI should be the source of truth for building all images.
- Local checks are still useful to build confidence and catch obvious Dockerfile/runtime mistakes.

## Recommended Local Validation Scope

Validate 3-4 services locally:

1. `frontend` (Node, multi-stage, distroless runtime)
2. `product-catalog` (Go, distroless static runtime)
3. `cart` (C#/.NET)
4. `recommendation` (Python)

If one service fails due to environment trust/proxy issues, continue with others and use CI for complete validation.

## Step 1: Preflight

From repo root:

```bash
docker version
docker compose version
```

Confirm Docker Desktop is running and WSL integration is enabled.

## Step 2: Local Build Test (Single Service)

Example with product-catalog:

```bash
cd /mnt/c/shahid-learn/opentelemetry-demo
docker compose build product-catalog
```

Verify image exists:

```bash
docker images | grep -E 'product-catalog|otel/demo'
```

Run with dependencies and check logs:

```bash
docker compose up -d otel-collector flagd astronomy-db product-catalog
docker compose logs -f product-catalog
```

Note: product-catalog is gRPC-first. `curl http://localhost:3550` is not a reliable health check.

## Step 3: Local Runtime Smoke Test (Frontend)

```bash
docker compose build frontend
```

For Docker Desktop/WSL2, use the documented stable command in `src/frontend/README.md`.

Expected outcome:

- Frontend loads at `http://localhost:8080`
- No startup crash in frontend logs

## Step 4: Local Go/No-Go Decision

Proceed to ACR build/push if all are true:

- At least 2 representative services build locally
- Frontend runs locally
- Compose workflow is understood (`build`, `run`, `up`, `logs`)

If one service fails due to TLS/proxy trust issues, do **not** block the whole phase. Continue to CI.

## Step 5: ACR Login

If you are on WSL with Zscaler/corporate TLS interception, do this first:

```bash
# Ensure WSL CA bundle is current.
sudo apt-get update
sudo apt-get install -y ca-certificates openssl curl
sudo update-ca-certificates

# Make Azure CLI/Python and curl use the WSL CA bundle.
export REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt

# Verify ACR endpoint TLS from WSL.
# Expected result is HTTP 401 (that means TLS/network path is healthy).
curl -Iv https://<acr-name>.azurecr.io/v2/
```

Real reason for the earlier failure:

- Zscaler intercepts TLS and re-signs certificates.
- WSL tools (Azure CLI/curl) and Docker build containers use different trust contexts.
- `REQUESTS_CA_BUNDLE`/`SSL_CERT_FILE` fix Azure CLI and curl in WSL, but they do not automatically fix TLS inside `docker build` steps.
- Once CA trust is correct, `az acr login` succeeds.

Then run login:

```bash
az account show
az acr login --name acrdevopsproject
```

Health check note:

- `az acr check-health` may end with `NOTARY_COMMAND_ERROR` if notary is not installed.
- This is not a blocker for normal Docker push/pull and can be ignored for this workflow.

## One-time local machine setup (Zscaler TLS fix for Docker builds)

### Root-cause explanation

Zscaler intercepts outbound HTTPS and re-signs certificates with its own CA chain:
- **Root CA**: `CN = SASPKI-SHA256` (in Windows cert store only)
- **Intermediate CA**: `CN = Zscaler.sas.local` (in `/usr/local/share/ca-certificates/zscaler-root.crt`)

The WSL system CA bundle is already updated — that fixes Azure CLI/curl in WSL
(Python reads Windows cert store, so the chain is available there). But every
`docker build` stage is an isolated container with only its base image's CA bundle.
Those containers have neither the root nor intermediate. OpenSSL requires the
**full chain** to validate a certificate — injecting only the intermediate fails
with "unable to get local issuer certificate".

### The implemented fix (already in this repo)

Every Dockerfile that makes HTTPS calls during build now has this pattern,
applied before the first network operation in each affected stage:

**Non-Java, non-Node runtimes** (Alpine, Debian/Ubuntu, Python, Ruby, PHP, Go, Rust, .NET, Elixir):

```dockerfile
ARG ZSCALER_CERT_B64=""
RUN if [ -n "$ZSCALER_CERT_B64" ]; then mkdir -p /etc/ssl/certs && echo "$ZSCALER_CERT_B64" | base64 -d >> /etc/ssl/certs/ca-certificates.crt; fi
```

**Node.js / npm** — Node.js **does NOT use the OS cert bundle** (`/etc/ssl/certs/ca-certificates.crt`).
Injecting the cert there has no effect on `npm install` or any Node process.
You must explicitly pass `NODE_EXTRA_CA_CERTS`:

```dockerfile
ARG ZSCALER_CERT_B64=""
RUN if [ -n "$ZSCALER_CERT_B64" ]; then \
        mkdir -p /etc/ssl/certs && \
        echo "$ZSCALER_CERT_B64" | base64 -d >> /etc/ssl/certs/ca-certificates.crt; \
    fi
RUN NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt npm ci
```

**Playwright (Chromium install)** — `playwright install --with-deps chromium` uses a
Node.js-based browser fetcher internally. It hits the same Node.js TLS problem.
This command runs in the **runner stage** (not the builder stage), so the cert must
be injected in the runner stage too — and `NODE_EXTRA_CA_CERTS` must be set:

```dockerfile
# In the runner/final stage — separate ARG declaration required per stage:
ARG ZSCALER_CERT_B64=""
RUN if [ -n "$ZSCALER_CERT_B64" ]; then \
        mkdir -p /etc/ssl/certs && \
        echo "$ZSCALER_CERT_B64" | base64 -d >> /etc/ssl/certs/ca-certificates.crt; \
    fi
RUN NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt playwright install --with-deps chromium
```

**Java/JVM runtimes** (`ad`, `fraud-detection`) — Java ignores the OS cert bundle
and uses its own truststore (`$JAVA_HOME/lib/security/cacerts`). The pattern is:

```dockerfile
ARG ZSCALER_CERT_B64=""
RUN if [ -n "$ZSCALER_CERT_B64" ]; then \
    echo "$ZSCALER_CERT_B64" | base64 -d > /tmp/zscaler-chain.pem && \
    sed -n '1,/-----END CERTIFICATE-----/p' /tmp/zscaler-chain.pem > /tmp/zscaler-root.pem && \
    keytool -import -noprompt -trustcacerts \
        -alias zscaler-root \
        -file /tmp/zscaler-root.pem \
        -keystore "$JAVA_HOME/lib/security/cacerts" \
        -storepass changeit && \
    rm -f /tmp/zscaler-root.pem /tmp/zscaler-chain.pem; \
fi
```

> **Why `sed` not `awk`?** The chain PEM contains two certs (root + intermediate).
> `keytool` only needs the **root CA** to anchor trust. The `sed` command extracts
> only the first cert block cleanly. The earlier `awk`-based approach that tried to
> split the chain into separate files was silently broken in POSIX `sh` (glob
> expansion `*` didn't match the files mid-pipe) — `keytool` received no input and
> exited 0, leaving the truststore unchanged. Symptom: Java SSL errors despite the
> `RUN` step appearing to succeed.

`keytool` is built into every JDK image.

The cert is base64-encoded (single line) to avoid multiline ARG truncation.
`/etc/ssl/certs/ca-certificates.crt` is the system CA bundle on both Alpine and
Debian (used by apk, apt-get, Go crypto/tls, Rust/cargo, Ruby/bundler, PHP/curl,
Elixir/Erlang ssl, etc.).

`docker-compose.override.yml` passes `ZSCALER_CERT_B64: "${ZSCALER_CERT_B64:-}"` to all
affected services via a shared YAML anchor.

**In CI/CD**: `ZSCALER_CERT_B64` is not set → the `RUN if [ -n ... ]` block is a
complete no-op → zero overhead, no behaviour change.

#### Gradle-specific timeout issues

Gradle has **two separate timeout settings** that both need increasing when
downloading through a slow/inspecting proxy.

**1. Gradle wrapper download timeout** (`gradle-wrapper.properties`)  
The wrapper downloads the Gradle distribution ZIP (~130 MB for Gradle 9). The
default is 10 seconds — far too short. Add to each `gradle/wrapper/gradle-wrapper.properties`:

```properties
networkTimeout=300000
```

**2. Gradle internal HTTP socket timeout** (build container `gradle.properties`)  
The internal Gradle HTTP client (for Maven/Gradle dependency downloads) also
has short defaults. Large JARs like `grpc-netty-shaded` can stall mid-download
through Zscaler and trigger socket timeouts. Add to the Dockerfile before any
`./gradlew` invocation:

```dockerfile
RUN mkdir -p /root/.gradle && printf \
    'systemProp.org.gradle.internal.http.socketTimeout=300000\nsystemProp.org.gradle.internal.http.connectionTimeout=60000\n' \
    >> /root/.gradle/gradle.properties
```

### Why the full chain is needed

The cert file at `/usr/local/share/ca-certificates/zscaler-root.crt` is the
**Zscaler intermediate CA** (`CN = Zscaler.sas.local`), signed by a corporate
root (`CN = SASPKI-SHA256`). OpenSSL requires the full chain — injecting only
the intermediate fails because the root is not in Docker build containers.
The root is in the Windows certificate store but NOT in the WSL system bundle.

Azure CLI (`az acr login`) works without this fix because Python's SSL library
reads the Windows cert store directly on WSL.

### One-time setup: build the chain file (run once per machine)

```bash
# 1. Export SASPKI-SHA256 root CA from Windows cert store
powershell.exe -c "\$cert = Get-ChildItem Cert:\LocalMachine\Root | Where-Object { \$_.Thumbprint -eq '0080E81D6FAA39238925BCFEE2220D226C08FA5E' }; [System.IO.File]::WriteAllBytes('C:\\Windows\\Temp\\saspki-root.der', \$cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert))"

# 2. Convert to PEM and create full chain (root + intermediate)
openssl x509 -inform der -in /mnt/c/Windows/Temp/saspki-root.der -out /tmp/saspki-root.pem
openssl x509 -in /usr/local/share/ca-certificates/zscaler-root.crt -out /tmp/zscaler-intermediate.pem
cat /tmp/saspki-root.pem /tmp/zscaler-intermediate.pem > ~/zscaler-chain.pem

# 3. Export as ZSCALER_CERT_B64 (used by docker compose build)
export ZSCALER_CERT_B64=$(base64 -w 0 ~/zscaler-chain.pem)

# 4. Make this permanent — add to ~/.zshrc (or ~/.bashrc):
cat >> ~/.zshrc << 'EOF'

# Zscaler TLS fix for Docker builds (full chain: SASPKI-SHA256 root + Zscaler.sas.local intermediate)
if [ -f "$HOME/zscaler-chain.pem" ]; then
  export ZSCALER_CERT_B64=$(base64 -w 0 "$HOME/zscaler-chain.pem")
fi
EOF
```

Verify before building:

```bash
echo "$ZSCALER_CERT_B64" | base64 -d | grep -c "BEGIN CERTIFICATE"
# Should print 2 (root + intermediate)
```

After this, `docker compose build` works for all services without any HTTP
downgrades or per-service hacks.

### Platform behaviour reference

| Environment | Does Zscaler intercept? | `docker pull` works? | `RUN pip/npm/gradle` works? | Fix needed? |
|---|---|---|---|---|
| **Windows + WSL** | Yes (Windows cert store, invisible to WSL) | Yes (Docker daemon) | ❌ SSL error | Yes — this setup |
| **macOS + Docker Desktop** | Yes (macOS Keychain) | Yes (daemon uses host) | ❌ SSL error — containers are isolated | Yes — same approach |
| **Linux bare metal** | Yes (if agent installed) | Yes | ❌ SSL error | Yes — same approach |
| **GitHub-hosted GHA runners** | **No** — runs inside GitHub's DC, no Zscaler | Yes | ✅ Works | **No** — `ZSCALER_CERT_B64` is unset, RUN is a no-op |
| **Self-hosted GHA runners (behind Zscaler)** | Yes | Depends | ❌ SSL error | Provision cert on runner machine via Ansible/Terraform, not Dockerfile |

**Key insight**: The container build boundary (not the OS) is the root cause.
Even if the host has the CA in its keychain, `RUN` commands run in an isolated
container filesystem that only knows what the base image ships with.

**GitHub Actions**: The Dockerfiles are already CI-safe. The `ARG` defaults to `""`
so the `RUN if [ -n ... ]` block is a silent no-op on every GitHub-hosted runner.

Optional verification:

```bash
docker info | grep -i -E 'Registry|Username'
```

## Step 6: Set Image Variables for Compose Build/Push

```bash
export IMAGE_NAME=acrdevopsproject.azurecr.io/otel-demo
export DEMO_VERSION=$(git rev-parse --short HEAD)
export IMAGE_VERSION=$DEMO_VERSION
```

## Step 7: Build and Push (Preferred: CI)

Standard deterministic tag command (recommended for one-service tests and CI):

```bash
export ACR_NAME=acrdevopsprojectd1e51ba4
export ACR_LOGIN_SERVER=${ACR_NAME}.azurecr.io
export SERVICE=cart
export TAG=$(git rev-parse --short HEAD)

# Build from repo root with explicit Dockerfile and explicit ACR tag.
docker build \
	-f ./src/cart/src/Dockerfile \
	-t ${ACR_LOGIN_SERVER}/otel-demo/${SERVICE}:${TAG} \
	.

docker push ${ACR_LOGIN_SERVER}/otel-demo/${SERVICE}:${TAG}
```

Why this is the standard form:

- Tag is deterministic (`<acr>/otel-demo/<service>:<git-sha>`).
- Works the same in local and CI.
- Avoids ambiguity from local Compose image names/tags.

Preferred path:

1. Run full multi-service build/push in GitHub Actions.
2. Treat CI result as authoritative.

If you still want local push for a subset first:

```bash
docker compose build frontend product-catalog cart recommendation
docker compose push frontend product-catalog cart recommendation
```

Then full set in CI.

## Step 8: AKS Readiness Check

Before deploy:

- Images are present in ACR with expected tags
- Kubernetes manifests reference ACR image names
- Pull permissions from AKS to ACR are configured

## Common Pitfalls

1. Build context wrong (must run compose from repo root).
2. Distroless images have no shell.
3. Port mismatch (`next dev -p 8080` vs published ports).
4. TLS trust failures in local Docker build network.
5. WSL2 file permission issues for `.next` with Turbopack.
6. **Node.js ignores OS cert bundle** — `NODE_EXTRA_CA_CERTS` is required for any
   Node/npm/Playwright step even if the cert was correctly injected into
   `/etc/ssl/certs/ca-certificates.crt`.
7. **Playwright cert injection must be in the runner stage** — multi-stage builds
   reset the filesystem; an `ARG` or `RUN` in the builder stage does not carry
   forward. Declare `ARG ZSCALER_CERT_B64` and inject in every stage that makes
   HTTPS calls.
8. **WSL 2 DNS broken without corporate VPN** — auto-generated `/etc/resolv.conf`
   may contain unreachable IPv6 addresses (`fec0:0:0:ffff::*`), causing all DNS
   resolution inside build containers to fail. Permanent fix:
   - Set `generateResolvConf = false` in `/etc/wsl.conf`
   - Write a static `/etc/resolv.conf` with `nameserver 192.168.0.1` (Windows host)
     and `nameserver 8.8.8.8` as fallback
   - Set `"dns": ["8.8.8.8", "8.8.4.4"]` in `/etc/docker/daemon.json`
9. **BuildKit snapshot corruption** — if a build fails mid-layer, subsequent builds
   may report `snapshot does not exist: not found`. `docker builder prune` does not
   fix this. Clear it with `sudo rm -rf /var/lib/docker/buildkit/`. Already-tagged
   images in `docker images` are preserved.
10. **`docker compose push` EOF errors** — pushing all services in parallel can
    trigger connection drops through Zscaler (too many concurrent HTTPS streams).
    Push sequentially instead:
    ```bash
    for tag in accounting ad cart checkout currency email flagd-ui fraud-detection \
               frontend frontend-proxy image-provider kafka llm load-generator \
               opensearch payment product-catalog product-reviews quote \
               recommendation shipping telemetry-docs; do
      docker push acrdevopsprojectd1e51ba4.azurecr.io/otel-demo:${DEMO_VERSION}-${tag}
    done
    ```
6. **Node.js ignores OS cert bundle** — `NODE_EXTRA_CA_CERTS` is required for any
   Node/npm/Playwright step even if the cert was correctly injected into
   `/etc/ssl/certs/ca-certificates.crt`.
7. **Playwright cert injection must be in the runner stage** — multi-stage builds
   reset the filesystem; an `ARG` or `RUN` in the builder stage does not carry
   forward. Declare `ARG ZSCALER_CERT_B64` and inject in every stage that makes
   HTTPS calls.
8. **WSL 2 DNS broken without corporate VPN** — auto-generated `/etc/resolv.conf`
   may contain unreachable IPv6 addresses (`fec0:0:0:ffff::*`), causing all DNS
   resolution inside build containers to fail. Permanent fix:
   - Set `generateResolvConf = false` in `/etc/wsl.conf`
   - Write a static `/etc/resolv.conf` with `nameserver 192.168.0.1` (Windows host)
     and `nameserver 8.8.8.8` as fallback
   - Set `"dns": ["8.8.8.8", "8.8.4.4"]` in `/etc/docker/daemon.json`
9. **BuildKit snapshot corruption** — if a build fails mid-layer, subsequent builds
   may report `snapshot does not exist: not found`. `docker builder prune` does not
   fix this. Clear it with `sudo rm -rf /var/lib/docker/buildkit/`. Already-tagged
   images in `docker images` are preserved.
10. **`docker compose push` EOF errors** — pushing all services in parallel can
    trigger connection drops through Zscaler (too many concurrent HTTPS streams).
    Push sequentially instead:
    ```bash
    for tag in accounting ad cart checkout currency email flagd-ui fraud-detection \
               frontend frontend-proxy image-provider kafka llm load-generator \
               opensearch payment product-catalog product-reviews quote \
               recommendation shipping telemetry-docs; do
      docker push acrdevopsprojectd1e51ba4.azurecr.io/otel-demo:${DEMO_VERSION}-${tag}
    done
    ```

## Minimal Success Criteria for This Phase

You are ready to move on when:

1. You can explain the multi-stage build pattern.
2. You can build and run at least one backend service and frontend locally.
3. You can log in to ACR.
4. You can tag/push at least one image.
5. You have a CI plan for full-fleet image build/push.
