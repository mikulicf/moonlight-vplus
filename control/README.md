# Moonlight managed access control

This directory contains a small management service and a host agent for explicitly authorized Moonlight connections. The service authenticates users, assigns machines to users, and issues short-lived client-certificate leases. Streaming remains a direct connection from the Moonlight client to the Apollo host; video, audio, input, and application traffic do not pass through this service.

## Deployment model

The supplied Compose deployment runs Caddy and `moonlight-control` in the same private network namespace. The backend listens only on `127.0.0.1:8080`. Caddy is the only process that accepts external traffic, on ports 80 and 443, and overwrites `X-Real-IP` with the actual peer address. Port 8080 is not published.

You must provide a DNS hostname. There is no built-in hostname, URL, account, password, enrollment token, or seeded administrator. The hostname must resolve to the deployment and ports 80 and 443 must reach it so Caddy can obtain and renew a publicly trusted certificate.

From `control/deploy`, validate and start the deployment with a hostname supplied for that invocation:

```sh
BACKEND_HOSTNAME='<management-hostname>' docker compose config
BACKEND_HOSTNAME='<management-hostname>' docker compose up -d --build
```

Running `docker compose config` without `BACKEND_HOSTNAME` fails. Keep the hostname in your deployment secret/configuration system rather than committing an environment file. The Compose project owns three persistent volumes: the backend SQLite database and Caddy's certificate data and runtime configuration. Back them up with access restricted to the operator.

Create the first administrator locally after the backend is healthy:

```sh
BACKEND_HOSTNAME='<management-hostname>' docker compose exec -it backend \
  moonlight-control create-admin --db=/data/control.db --username '<administrator-name>'
```

The command reads a password from the terminal and requires at least 15 characters. It does not accept or print a default password. Additional users, machines, grants, password resets, disabling, token rotation, and audit review are available through the HTTPS admin page. Each user sees only machines granted to that user.

The client starts with an empty managed-backend URL. Enter the deployment's final `https://` origin and the assigned username in the client. The client saves the URL and username for convenience; its bearer token remains in process memory and is cleared on sign-out or authentication failure. The backend does not use cookie authentication and does not enable cross-origin browser access.

## Host enrollment

Managed hosts require the patched [`mikulicf/apollo-managed`](https://github.com/mikulicf/apollo-managed) source. Build and operate that host package according to its repository instructions, and configure Apollo's `managed_policy_file` to the same local file named by the agent's `policy_file`. An unpatched Apollo build does not consume this authorization policy and is not a managed host.

Create the machine in the admin page with the address and Apollo HTTP/HTTPS ports that clients can reach directly. The page displays its host enrollment token once. Copy it immediately into a root/administrator-readable agent configuration; the backend stores only its hash. Rotation invalidates the previous token and active leases for that machine.

The agent JSON accepts these exact fields:

```json
{
  "backend_url": "https://<management-hostname>",
  "host_token": "<host-enrollment-token>",
  "policy_file": "<absolute-managed-policy-path>",
  "server_certificate_file": "<absolute-apollo-server-certificate-path>",
  "http_port": 47989
}
```

`ca_file` is an optional sixth field for an operator-managed private CA. The backend URL must be an HTTPS origin without a path, credentials, query, or fragment. The agent requires a valid TLS chain and does not follow redirects. Decide DNS, certificate issuance, renewal, and any private-CA installation for each host environment before enrollment; do not disable certificate verification.

`server_certificate_file` must contain exactly Apollo's single PEM server certificate. `policy_file` must be writable by the agent and readable by Apollo, with permissions limited to those services and administrators. Run `moonlight-agent -config <absolute-agent-config-path>` under the host service manager. On Windows it supports the service name `MoonlightManagedHostAgent`; service installation, account choice, and filesystem ACLs remain operator-specific.

The agent reads Apollo's loopback `/serverinfo`, requires `ManagedAccessProtocol` 1 and a host UUID, then polls the backend every second. Leases last 90 seconds and the client attempts renewal every 25 seconds. Grant revocation, user disabling, logout, or explicit release is normally reflected in the host policy by the next one-second poll plus the atomic file replacement time (allow roughly another 500 ms). During a backend or network outage, an already written authorization can remain usable only until its lease expires, no more than 90 seconds from its last successful renewal.

### Windows host installer

Build `moonlight-agent.exe` locally from this repository and install the patched Apollo binary before running the host installer. The installer is offline: it does not download software or change routing, port forwarding, or firewall rules. Run it from an elevated Windows PowerShell session. Omit `HostToken` from the command so PowerShell prompts for the required `SecureString`; do not put the enrollment token in command history or a script:

```powershell
.\install-host.ps1 `
  -BackendUrl 'https://<management-hostname>' `
  -AgentExecutable '<absolute-path-to-moonlight-agent.exe>' `
  -ApolloConfig '<absolute-path-to-apollo-config>' `
  -ServerCertificate '<absolute-path-to-apollo-server-certificate>' `
  -ApolloReadAccount '<account-running-apollo-service>'
```

`HttpPort` defaults to Apollo's protocol default, 47989. Override it only when Apollo uses a different base HTTP port. `ApolloServiceName` defaults to `ApolloService` and can be supplied when the installed service has another name.

`ApolloReadAccount` must match the account that actually runs `ApolloService`. LocalSystem is supported and is Apollo's normal Windows architecture: its service wrapper duplicates its SYSTEM token into the interactive console session before launching Apollo. Do not reconfigure that service merely to create a separate policy reader. An operator-specific dedicated non-administrator account is also accepted when the Apollo service already runs under it. LocalService, NetworkService, the Administrators identity, and direct local Administrators members are rejected.

The installer creates `%ProgramData%\MoonlightManagedAccess` with inheritance disabled and ownership assigned to SYSTEM. SYSTEM and Administrators receive full control. When Apollo uses a distinct non-administrator account, that account receives traversal on the root and read/execute access only on the policy directory. When Apollo uses LocalSystem, no duplicate read-only ACL is added: Apollo and the agent are both trusted SYSTEM daemons and necessarily retain full access. The agent service runs as LocalSystem, starts automatically, and has bounded restart recovery actions. The installer rejects reparse points, copies and hash-checks the agent, writes the enrollment token only into the protected agent JSON, and never prints it.

This host design trusts the Apollo daemon, managed-access agent, and local administrators. The Windows account exposed in an interactive streamed session must remain a non-administrator; an interactive administrator can edit SYSTEM-protected policy and secrets and therefore bypass this local boundary.

Apollo is stopped before its configuration changes. The installer backs up the configuration inside the protected root and updates only the `managed_policy_file` directive, preserving every other line. It restarts Apollo and requires `/serverinfo` to report `ManagedAccessProtocol` 1 before registering and starting the agent. If that check or agent startup fails, it removes a partial agent service, restores the exact backup, and restarts Apollo with its old configuration.

To revoke local managed access immediately, run the fail-closed helper as administrator:

```powershell
.\disable-host.ps1
```

It stops and disables `MoonlightManagedHostAgent` and removes the current policy file. It deliberately retains the protected agent configuration, Apollo directive, binary, and backup for investigation or controlled recovery. Rotate the machine's host token in the admin UI as well when retiring or reprovisioning a host.

## Direct streaming network

The management deployment opens only HTTP/HTTPS for its own UI and API. Clients must separately reach each Apollo host's GameStream ports. With the default base port, Moonlight documents TCP 47984, 47989, and 48010, plus UDP 47998, 47999, 48000, 48002, and 48010. Apollo can offset this family when its base `port` changes, so use the host's configured values. See Moonlight's [setup guide](https://github.com/moonlight-stream/moonlight-docs/wiki/Setup-Guide) and the canonical [port indexes in moonlight-common-c](https://github.com/moonlight-stream/moonlight-common-c/blob/master/src/Limelight.h).

Expose only the streaming ports required by the chosen topology. Apollo's administration UI on 47990 and Windows Remote Management ports are not part of streaming or managed authorization and must never be published to the Internet for this design. The management service is not a tunnel, NAT traversal service, or relay; address routing and firewall policy are deployment responsibilities.

Do not deploy upstream Apollo 0.4.6 as an Internet-exposed managed host. Sunshine's critical [GHSA-ph75-mgxh-mv57 / CVE-2026-32253](https://github.com/LizardByte/Sunshine/security/advisories/GHSA-ph75-mgxh-mv57) documents a client-certificate authentication bypass in the inherited verification path. Apollo 0.4.6 contains the same permissive error handling in its [`src/crypto.cpp`](https://github.com/ClassicOldSong/Apollo/blob/v0.4.6/src/crypto.cpp#L27-L40). The managed Apollo source must include the certificate-validation repair as well as the policy patch before use.

## Security and operations

This layout assumes the Docker host, Compose control, persistent volumes, DNS, and TLS account are under one trusted operator; Caddy is the only public path to the management API; and host and user devices protect their local credentials. It also assumes direct host addresses and streaming ports are restricted to the intended users and networks. A compromise of the Docker host, Apollo host, client device, DNS, TLS keys, or operator account is outside the isolation this service provides.

Use one database and one public URL per backend. Separate backend deployments do not federate users, machines, grants, sessions, audit records, or host credentials. A host belongs to the backend whose enrollment token its agent holds.

Before admitting users, verify all of the following:

- The public hostname presents a valid certificate and redirects HTTP to HTTPS.
- Only 80 and 443 are published for the management deployment; 8080 is absent from host bindings.
- The first administrator was created interactively and there are no unintended accounts or grants.
- Database and Caddy volumes are backed up and restricted to the operator.
- Every host reports managed protocol 1, uses the patched Apollo source, and has matching policy paths.
- Revoking a test grant removes the client certificate from that host's policy within the expected window.
- Apollo administration and operating-system management ports are unreachable from untrusted networks.

The Go packages have automated authentication, authorization, policy, protocol, request-boundary, and agent file-handling tests. Those tests support regression checking; they are not a penetration test, production-readiness certification, or substitute for reviewing the actual DNS, TLS, firewall, host hardening, backups, monitoring, and incident-response setup.
