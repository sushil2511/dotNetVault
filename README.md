# VaultSharpDemo — .NET + HashiCorp Vault via VaultSharp (AppRole → KV v2)

A minimal .NET 10 console app that:

1. Authenticates to Vault with **AppRole** (`role_id` + `secret_id`) using **VaultSharp 1.17.5.1**.
2. Receives a short-lived **client token** (VaultSharp manages it automatically).
3. Reads a secret from the **KV v2** secrets engine.
4. Prints every key/value in the secret.

This is a copy of `../VaultDemo` (which uses the official `HashiCorp.Vault` client) with
the implementation swapped to [`VaultSharp`](https://github.com/rajanadar/VaultSharp).

## Prerequisites

| Requirement | Status in this workspace |
|---|---|
| .NET 10 SDK | Installed at `%LOCALAPPDATA%\Microsoft\dotnet` (added to user `PATH`) |
| NuGet package | `VaultSharp` 1.17.5.1 — restored automatically |
| Vault server | Any reachable Vault with AppRole enabled and a KV v2 mount (default `secret`) |
| Vault CLI | Only needed for the local dev setup script; downloaded automatically |

Verify the SDK in a **new** terminal:

```powershell
dotnet --version   # 10.0.404
```

If `dotnet` is still not found, use the full path for the current session:

```powershell
$env:PATH = "$env:PATH;$env:LOCALAPPDATA\Microsoft\dotnet"
```

## Project layout

```
VaultSharpDemo/
├── Program.cs                     # AppRole login + KV v2 read + print (VaultSharp)
├── VaultSharpDemo.csproj          # net10.0 + VaultSharp 1.17.5.1
├── scripts/
│   └── setup-vault-dev.ps1        # Local dev Vault: download, start, configure
├── .gitignore                     # ignores bin/obj/.tools (credentials)
└── README.md
```

## Configuration (environment variables)

| Variable | Required | Default | Meaning |
|---|---|---|---|
| `VAULT_ADDR` | yes | — | Vault address, e.g. `http://127.0.0.1:8200` |
| `VAULT_ROLE_ID` | yes | — | AppRole role ID |
| `VAULT_SECRET_ID` | yes | — | AppRole secret ID |
| `VAULT_SECRET_MOUNT` | no | `secret` | KV v2 mount path |
| `VAULT_SECRET_PATH` | no | `myapp` | Path inside the mount (`myapp` → `secret/data/myapp`) |
| `VAULT_APPROLE_MOUNT` | no | `approle` | AppRole auth mount path |

Secrets are read from the environment so no credentials live in source control.

## Quick start (local dev Vault)

From the `VaultSharpDemo` folder:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\setup-vault-dev.ps1
```

It downloads Vault, starts a dev server on `http://127.0.0.1:8200`, enables AppRole,
writes a read-only policy, and seeds `secret/data/myapp`. Then set the printed
environment variables and run:

```powershell
$env:VAULT_ADDR      = "http://127.0.0.1:8200"
$env:VAULT_ROLE_ID   = "<printed role id>"
$env:VAULT_SECRET_ID = "<printed secret id>"

dotnet run
```

Expected output:

```
Authenticating to http://127.0.0.1:8200 with AppRole (mount: approle)...
Authentication successful. Token accessor: <accessor>
Reading secret at secret/myapp...

Secrets at secret/myapp:
  apikey = abc123
  db-pass = S3cr3t-P@ss
  db-user = app_user
```

Stop the dev server when done:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\setup-vault-dev.ps1 -Stop
```

> Dev mode keeps everything in memory and uses the well-known root token `root`.
> It is for local testing only — never use it in production.

## Manual Vault setup (existing server)

```bash
vault auth enable approle

# KV v2 policies must target the data/ path.
vault policy write myapp-policy - <<'EOF'
path "secret/data/myapp" {
  capabilities = ["read"]
}
EOF

vault write auth/approle/role/myapp \
  token_policies=myapp-policy token_ttl=1h token_max_ttl=4h

vault kv put secret/myapp db-user=app_user db-pass='S3cr3t-P@ss' apikey='abc123'

# Credentials for the .NET app
vault read -field=role_id   auth/approle/role/myapp/role-id
vault write -field=secret_id -f auth/approle/role/myapp/secret-id
```

Then export `VAULT_ADDR`, `VAULT_ROLE_ID`, and `VAULT_SECRET_ID` and run `dotnet run`.

## How the code works (VaultSharp 1.17.5.1)

```csharp
IAuthMethodInfo authMethod = new AppRoleAuthMethodInfo(
    mountPoint: "approle", roleId: roleId, secretId: secretId);

var settings = new VaultClientSettings(address, authMethod);
IVaultClient vaultClient = new VaultClient(settings);

// First call performs the AppRole login; VaultSharp reuses the client token.
Secret<CallingTokenInfo> tokenInfo = await vaultClient.V1.Auth.Token.LookupSelfAsync();

Secret<SecretData> secret = await vaultClient.V1.Secrets.KeyValue.V2.ReadSecretAsync(
    path: "myapp", mountPoint: "secret");

IDictionary<string, object> data = secret.Data.Data;
```

Notes:

- VaultSharp authenticates **lazily** on the first API request and attaches the
  returned token to later requests, so there is no manual `SetToken` step.
- `LookupSelfAsync()` is used here to trigger the login and verify the token.
  It prints the token **accessor** (safe to log), not the token itself.
- `SecretData.Data` is an `IDictionary<string, object>`.
- VaultSharp 1.17.5.1 uses `System.Text.Json` internally (no Newtonsoft.Json reference needed).

## Differences from `../VaultDemo`

| | `VaultSharpDemo` (this project) | `../VaultDemo` |
|---|---|---|
| Package | `VaultSharp` 1.17.5.1 | `HashiCorp.Vault` 0.3.0 |
| Maintainer | Community (rajanadar) | HashiCorp (official) |
| Namespaces | `VaultSharp.*` | `Vault.*` |
| AppRole setup | `AppRoleAuthMethodInfo` in `VaultClientSettings` | `Auth.AppRoleLogin(...)` + `SetToken(...)` |
| KV v2 read | `V1.Secrets.KeyValue.V2.ReadSecretAsync(...)` | `Secrets.KvV2Read(...)` |
| Secret data type | `IDictionary<string, object>` | `object` / `JObject` |

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `Missing required environment variable` | Set the variable in the same shell, or restart the terminal. |
| HTTP 403 `permission denied` | Policy path must be `secret/data/<name>` for KV v2; confirm the role's `token_policies`. |
| HTTP 404 | Wrong mount/path, or the engine is KV v1 (this app calls KV v2). |
| `invalid role or secret ID` | Regenerate the `secret_id`; confirm the AppRole mount (`VAULT_APPROLE_MOUNT`). |
| TLS / self-signed certificate error | Configure a custom HTTP handler via `VaultClientSettings.PostProcessHttpClientHandlerAction`, or use a trusted certificate. |
| `dotnet` not recognized | Open a new terminal, or prepend `%LOCALAPPDATA%\Microsoft\dotnet` to `PATH`. |
| NuGet restore fails | Check network/proxy access to `https://api.nuget.org`; run `dotnet restore`. |
| `Application Control policy has blocked this file` (0x800711C7) | Windows Smart App Control / WDAC blocked the built binary. Run `dotnet run` (Debug), or publish to an allowed location, or adjust the policy. |

## Production notes

- The AppRole token is short-lived. For long-running apps, configure token renewal
  (`RenewSelfAsync`) or re-authenticate when it expires.
- Printing secrets is for demo purposes only; avoid logging secret values in production.
- Protect `secret_id` (ideally use response wrapping / short TTLs) and always use TLS.
