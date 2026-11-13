using VaultSharp;
using VaultSharp.Core;
using VaultSharp.V1.AuthMethods;
using VaultSharp.V1.AuthMethods.AppRole;
using VaultSharp.V1.AuthMethods.Token.Models;
using VaultSharp.V1.Commons;

try
{
    // Configuration comes from environment variables so no secrets live in source control.
    string address = RequireEnv("VAULT_ADDR");
    string roleId = RequireEnv("VAULT_ROLE_ID");
    string secretId = RequireEnv("VAULT_SECRET_ID");

    string secretMountPath = EnvOrDefault("VAULT_SECRET_MOUNT", "secret");
    string secretPath = EnvOrDefault("VAULT_SECRET_PATH", "myapp");
    string appRoleMountPath = EnvOrDefault("VAULT_APPROLE_MOUNT", "approle");

    // VaultSharp authenticates lazily: the first API call performs the AppRole
    // login and attaches the returned client token to every later request.
    IAuthMethodInfo authMethod = new AppRoleAuthMethodInfo(
        mountPoint: appRoleMountPath,
        roleId: roleId,
        secretId: secretId);

    var settings = new VaultClientSettings(address, authMethod);
    IVaultClient vaultClient = new VaultClient(settings);

    // 1. Trigger the AppRole login and confirm the client token is valid.
    Console.WriteLine($"Authenticating to {address} with AppRole (mount: {appRoleMountPath})...");
    Secret<CallingTokenInfo> tokenInfo = await vaultClient.V1.Auth.Token.LookupSelfAsync();
    Console.WriteLine($"Authentication successful. Token accessor: {tokenInfo.Data.Accessor}");

    // 2. Read the secret from the KV v2 secrets engine.
    //    The path is relative to the mount, so "myapp" means secret/data/myapp.
    Console.WriteLine($"Reading secret at {secretMountPath}/{secretPath}...");
    Secret<SecretData> secret = await vaultClient.V1.Secrets.KeyValue.V2.ReadSecretAsync(
        path: secretPath,
        mountPoint: secretMountPath);

    IDictionary<string, object> data = secret.Data.Data;
    if (data is null || data.Count == 0)
    {
        Console.Error.WriteLine($"No secret data found at {secretMountPath}/{secretPath}.");
        return 1;
    }

    // 3. Print the secrets.
    Console.WriteLine();
    Console.WriteLine($"Secrets at {secretMountPath}/{secretPath}:");
    foreach (KeyValuePair<string, object> item in data)
    {
        Console.WriteLine($"  {item.Key} = {item.Value}");
    }

    return 0;
}
catch (VaultApiException ex)
{
    Console.Error.WriteLine($"Vault API error (HTTP {ex.StatusCode}):");
    List<string> errors = ex.ApiErrors?.ToList() ?? new List<string>();
    if (errors.Count > 0)
    {
        foreach (string error in errors)
        {
            Console.Error.WriteLine($"  - {error}");
        }
    }
    else
    {
        Console.Error.WriteLine($"  {ex.Message}");
    }
    return 1;
}
catch (Exception ex)
{
    Console.Error.WriteLine($"Error: {ex.Message}");
    return 1;
}

static string RequireEnv(string name)
{
    string? value = Environment.GetEnvironmentVariable(name);
    if (string.IsNullOrWhiteSpace(value))
    {
        throw new InvalidOperationException(
            $"Missing required environment variable '{name}'. See README.md for setup.");
    }
    return value;
}

static string EnvOrDefault(string name, string fallback)
{
    string? value = Environment.GetEnvironmentVariable(name);
    return string.IsNullOrWhiteSpace(value) ? fallback : value;
}
