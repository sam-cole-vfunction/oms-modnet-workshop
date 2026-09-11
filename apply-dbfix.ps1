$ErrorActionPreference = "Stop"
$out = "c:\vFunctionLab\OMSNET\apply-dbfix.out.txt"
"" | Set-Content $out

$SqlInstance  = "localhost\SQLEXPRESS"
$DatabaseName = "OMS"
$appPoolLogin = "NT AUTHORITY\SYSTEM"
$webConfig    = "C:\vFunctionLab\win-oms\oms-net\OMS.NET\Web.config"
$AppPoolName  = "OMSAppPool"

function Log($m) { $m | Add-Content $out }

# 1) Create DB + grant app pool login db_owner (ADO.NET, current admin identity)
$sqlBatches = @(
"IF DB_ID(N'$DatabaseName') IS NULL CREATE DATABASE [$DatabaseName];",
"IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'$appPoolLogin') CREATE LOGIN [$appPoolLogin] FROM WINDOWS;",
"USE [$DatabaseName]; IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$appPoolLogin') CREATE USER [$appPoolLogin] FOR LOGIN [$appPoolLogin];",
"USE [$DatabaseName]; ALTER ROLE [db_owner] ADD MEMBER [$appPoolLogin];"
)
try {
    $conn = New-Object System.Data.SqlClient.SqlConnection "Server=$SqlInstance;Database=master;Trusted_Connection=True;"
    $conn.Open()
    foreach ($b in $sqlBatches) {
        $cmd = $conn.CreateCommand(); $cmd.CommandText = $b; $null = $cmd.ExecuteNonQuery()
    }
    $conn.Close()
    Log "DB '$DatabaseName' created/verified and '$appPoolLogin' granted db_owner."
}
catch {
    Log "DB SETUP FAILED: $_"
    throw
}

# 2) Update the live Web.config connection string to point at OMS
$xml = [xml](Get-Content $webConfig)
$c = $xml.configuration.connectionStrings.add | Where-Object { $_.name -eq "SqlExpress" }
if ($c) {
    $c.connectionString = "Server=$SqlInstance;Database=$DatabaseName;Trusted_Connection=True;"
    $xml.Save($webConfig)
    Log "Web.config connection string set to: $($c.connectionString)"
} else {
    Log "WARN: SqlExpress connection string not found in Web.config"
}

# 3) Recycle the app pool so it picks up the new config
Import-Module WebAdministration -ErrorAction SilentlyContinue
try { Restart-WebAppPool -Name $AppPoolName; Log "Recycled app pool '$AppPoolName'." } catch { Log "WARN: could not recycle pool: $_" }

# 4) Re-test the API (this triggers EF auto-migration into OMS)
Start-Sleep -Seconds 3
foreach ($u in @("http://localhost:8080/api/product/all", "http://localhost:8080/api/inventory")) {
    $method = if ($u -like "*inventory") { "POST" } else { "GET" }
    try {
        $p = @{ Uri = $u; Method = $method; UseBasicParsing = $true; TimeoutSec = 60 }
        if ($method -eq "POST") { $p["Body"] = '{"skuId":"DIAG-1","storeId":"10","quantity":1}'; $p["ContentType"] = "application/json" }
        $r = Invoke-WebRequest @p
        Log ("{0} {1} -> {2}" -f $method, $u, [int]$r.StatusCode)
    }
    catch {
        $resp = $_.Exception.Response
        if ($resp) {
            $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
            $body = $reader.ReadToEnd()
            $short = if ($body.Length -gt 300) { $body.Substring(0,300) } else { $body }
            Log ("{0} {1} -> {2}  BODY: {3}" -f $method, $u, [int]$resp.StatusCode, $short)
        } else {
            Log ("{0} {1} -> ERROR: {2}" -f $method, $u, $_.Exception.Message)
        }
    }
}
Log "DONE"
