#Requires -Version 5.1
<#
.SYNOPSIS
    Starts a local Vault dev server configured for this demo (AppRole + KV v2 secret).

.DESCRIPTION
    - Downloads the Vault CLI into .tools if it is not already there.
    - Starts a dev-mode Vault server on http://127.0.0.1:8200 (root token: root).
    - Enables the AppRole auth method, creates a read-only policy, and seeds
      secret/data/myapp with demo values.
    - Prints the role_id / secret_id to use with the .NET app.

    Dev mode stores everything in memory and uses a well-known root token.
    NEVER use this setup in production.

.PARAMETER Stop
    Stops the Vault dev server started by this script.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\setup-vault-dev.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\setup-vault-dev.ps1 -Stop
#>
[CmdletBinding()]
param(
    [switch]$Stop
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$tools = Join-Path $root ".tools"
$vaultExe = Join-Path $tools "vault.exe"
$pidFile = Join-Path $tools "vault.pid"
$logFile = Join-Path $tools "vault.log"
$errFile = Join-Path $tools "vault.err.log"
$vaultVersion = "2.2.1"
$vaultAddress = "http://127.0.0.1:8200"

New-Item -ItemType Directory -Force -Path $tools | Out-Null

if ($Stop) {
    if (Test-Path $pidFile) {
        $vaultPid = [int](Get-Content $pidFile)
        Stop-Process -Id $vaultPid -Force -ErrorAction SilentlyContinue
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
        Write-Host "Stopped Vault dev server (PID $vaultPid)."
    }
    else {
        Write-Host "No .tools\vault.pid found; nothing to stop."
    }
    return
}

# 1. Download the Vault CLI if needed.
if (-not (Test-Path $vaultExe)) {
    Write-Host "Downloading Vault $vaultVersion..."
    $zip = Join-Path $tools "vault.zip"
    $url = "https://releases.hashicorp.com/vault/$vaultVersion/vault_${vaultVersion}_windows_amd64.zip"
    Invoke-WebRequest -UseBasicParsing $url -OutFile $zip
    Expand-Archive -Path $zip -DestinationPath $tools -Force
    Remove-Item $zip
}

# 2. Start the dev server if it is not already answering.
$running = $false
try {
    Invoke-RestMethod "$vaultAddress/v1/sys/health" -TimeoutSec 2 | Out-Null
    $running = $true
}
catch {
    $running = $false
}

if (-not $running) {
    Write-Host "Starting Vault dev server at $vaultAddress..."
    $process = Start-Process -FilePath $vaultExe `
        -ArgumentList @("server", "-dev", "-dev-root-token-id=root", "-dev-listen-address", "127.0.0.1:8200") `
        -RedirectStandardOutput $logFile `
        -RedirectStandardError $errFile `
        -WindowStyle Hidden `
        -PassThru
    $process.Id | Set-Content $pidFile

    $ready = $false
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 500
        try {
            Invoke-RestMethod "$vaultAddress/v1/sys/health" -TimeoutSec 2 | Out-Null
            $ready = $true
            break
        }
        catch {
            # Keep waiting.
        }
    }
    if (-not $ready) {
        throw "Vault did not become ready. See $logFile and $errFile."
    }
}
else {
    Write-Host "Vault dev server is already running at $vaultAddress."
}

# 3. Configure AppRole, policy, and the demo secret.
$env:VAULT_ADDR = $vaultAddress
$env:VAULT_TOKEN = "root"

$policyFile = Join-Path $tools "myapp-policy.hcl"
@'
# Read-only access to the demo secret at secret/data/myapp (KV v2)
path "secret/data/myapp" {
  capabilities = ["read"]
}
'@ | Set-Content -Path $policyFile -Encoding ASCII

# Enable AppRole only if it is not already enabled (the script is re-runnable).
$authList = (& $vaultExe auth list -format=json | ConvertFrom-Json)
if (-not ($authList.PSObject.Properties.Name -contains "approle/")) {
    & $vaultExe auth enable approle | Out-Null
}
& $vaultExe policy write myapp-policy $policyFile | Out-Null
& $vaultExe write auth/approle/role/myapp token_policies=myapp-policy token_ttl=1h token_max_ttl=4h | Out-Null
& $vaultExe kv put secret/myapp db-user=app_user db-pass='S3cr3t-P@ss' apikey='abc123' | Out-Null

$roleId = (& $vaultExe read -field=role_id auth/approle/role/myapp/role-id).Trim()
$secretId = (& $vaultExe write -field=secret_id -f auth/approle/role/myapp/secret-id).Trim()

$envFile = Join-Path $tools "vault-dev.env"
"VAULT_ADDR=$vaultAddress`nVAULT_ROLE_ID=$roleId`nVAULT_SECRET_ID=$secretId" |
    Set-Content -Path $envFile -Encoding ASCII

Write-Host ""
Write-Host "Vault dev environment is ready."
Write-Host "Set these in your shell (also saved to .tools\vault-dev.env):"
Write-Host ""
Write-Host "  `$env:VAULT_ADDR      = `"$vaultAddress`""
Write-Host "  `$env:VAULT_ROLE_ID   = `"$roleId`""
Write-Host "  `$env:VAULT_SECRET_ID = `"$secretId`""
Write-Host ""
Write-Host "Run the app from the project folder:  dotnet run"
Write-Host "Stop Vault with:  powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Stop"
