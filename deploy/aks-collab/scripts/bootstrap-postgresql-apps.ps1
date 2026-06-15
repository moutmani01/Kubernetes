param(
    [string]$Namespace = "collab-platform",
    [string]$ReleaseName = "collab-postgresql"
)

$ErrorActionPreference = "Stop"

function New-RandomPassword {
    param([int]$Length = 32)

    $chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#%^*-_"
    $bytes = New-Object byte[] ($Length)
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
}

function Invoke-External {
    param([scriptblock]$Script)

    & $Script
    if ($LASTEXITCODE -ne 0) {
        throw "External command failed with exit code $LASTEXITCODE"
    }
}

$kubectl = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Packages\Kubernetes.kubectl_Microsoft.Winget.Source_8wekyb3d8bbwe\kubectl.exe"
$serviceHost = "collab-postgresql.$Namespace.svc.cluster.local"
$apps = @("openproject", "docmost", "passbolt")

$postgresPassword = & $kubectl -n $Namespace get secret collab-postgresql-auth -o jsonpath="{.data.postgres-password}"
if (-not $postgresPassword) {
    throw "collab-postgresql-auth secret not found in namespace $Namespace"
}
$postgresPassword = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($postgresPassword))

$pod = & $kubectl -n $Namespace get pod -l app.kubernetes.io/instance=$ReleaseName,app.kubernetes.io/component=primary -o jsonpath="{.items[0].metadata.name}"
if (-not $pod) {
    throw "Could not find PostgreSQL primary pod for release $ReleaseName"
}

$credentialMap = @{}
foreach ($app in $apps) {
    $secretName = "$app-db"
    $existingPassword = $null
    try {
        $existingPassword = & $kubectl -n $Namespace get secret $secretName -o jsonpath="{.data.password}" 2>$null
    } catch {}

    if ($existingPassword) {
        $password = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($existingPassword))
    } else {
        $password = New-RandomPassword
    }

    $credentialMap[$app] = @{
        Username = $app
        Database = $app
        Password = $password
        SecretName = $secretName
    }
}

$sqlBlocks = foreach ($app in $apps) {
    $username = $credentialMap[$app].Username
    $database = $credentialMap[$app].Database
    $password = $credentialMap[$app].Password.Replace("'", "''")
@"
DO `$$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '$username') THEN
        EXECUTE format('CREATE ROLE %I LOGIN PASSWORD ''%s''', '$username', '$password');
    ELSE
        EXECUTE format('ALTER ROLE %I WITH LOGIN PASSWORD ''%s''', '$username', '$password');
    END IF;
END
`$$;
SELECT format('CREATE DATABASE %I OWNER %I', '$database', '$username')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = '$database')\gexec
GRANT ALL PRIVILEGES ON DATABASE "$database" TO "$username";
"@
}

$sql = ($sqlBlocks -join "`n")
$tempSql = [System.IO.Path]::GetTempFileName()
[System.IO.File]::WriteAllText($tempSql, $sql)

Invoke-External { Get-Content $tempSql | & $kubectl -n $Namespace exec -i $pod -- env PGPASSWORD=$postgresPassword psql -v ON_ERROR_STOP=1 -U postgres -d postgres -f - }
Remove-Item $tempSql -Force

foreach ($app in $apps) {
    $secretName = $credentialMap[$app].SecretName
    $username = $credentialMap[$app].Username
    $database = $credentialMap[$app].Database
    $password = $credentialMap[$app].Password

    Invoke-External { & $kubectl -n $Namespace create secret generic $secretName `
        --from-literal=host=$serviceHost `
        --from-literal=port=5432 `
        --from-literal=database=$database `
        --from-literal=username=$username `
        --from-literal=password=$password `
        --dry-run=client -o yaml | & $kubectl apply -f - }
}

Invoke-External { & $kubectl -n $Namespace get secrets openproject-db docmost-db passbolt-db }
Write-Host "PostgreSQL app users/databases are ready on $serviceHost"
