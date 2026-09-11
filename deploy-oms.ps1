#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Deploys the OMS.NET application on IIS with SQL Server Express, installs dev tooling,
    and (optionally) installs and configures the vFunction .NET agent.

.DESCRIPTION
    This script performs a full deployment of the OMS.NET application:
    1. Installs IIS with required features
    2. Installs SQL Server Express (silent install)
    3. Installs .NET Framework 4.7.2 Developer Pack and MSBuild tooling
    4. Restores NuGet packages and builds the solution
    5. Creates the database and runs EF migrations
    6. Configures IIS site and application pool
    7. Installs the Kiro IDE (via winget, with an auto-resolved direct-installer fallback)
    8. Installs the official .NET 10 SDK (via winget, with a dotnet-install.ps1 fallback)
    9. Installs uv/uvx (Astral) as a prerequisite for Kiro power MCP servers
    10. Installs and configures the vFunction .NET agent (dynamic + viper/static) and
        hooks it into the IIS App Pool. This phase runs last (it needs the App Pool from
        step 6) and is skipped unless -VFServerHost is provided or -SkipVFunction is off.

.NOTES
    Must be run as Administrator.
    Tested on Windows Server 2016/2019/2022 and Windows 10/11.

    The vFunction phase is skipped automatically when no -VFServerHost is supplied, so the
    script can be used for a plain OMS.NET deployment. Pass -VFServerHost (and optionally
    the vFunction credentials/UUIDs) to also install the agent, or -SkipVFunction to force
    it off.
#>

param(
    [string]$RepoPath = "C:\vFunctionLab\win-oms\oms-net",
    [string]$RepoUrl = "https://bitbucket.org/vfunction/oms-net.git",
    [string]$RepoBranch = "master",
    [string]$SiteName = "OMS.NET",
    [string]$AppPoolName = "OMSAppPool",
    [int]$Port = 80,
    [string]$HostHeader = "dev.oms.net",
    [string]$SqlInstance = "localhost\SQLEXPRESS",
    [string]$DatabaseName = "OMS",

    # Kiro IDE install (Step 9b). Prefers winget (package id Amazon.Kiro); if winget
    # is unavailable, the installer URL is resolved AUTOMATICALLY from Kiro's official
    # update metadata (no download URL needs to be supplied). -KiroInstallerUrl remains
    # as an optional manual override for air-gapped/mirrored setups. Use -SkipKiro to
    # skip the IDE install entirely (e.g. on headless servers).
    [switch]$SkipKiro,
    [string]$KiroWingetId = "Amazon.Kiro",
    [string]$KiroInstallerUrl = "",

    # Base host for Kiro's official desktop download metadata. The per-platform manifest
    # (metadata-windows-x64-stable.json) is fetched from here to discover the current
    # installer URL automatically. Override only if you mirror Kiro internally.
    [string]$KiroMetadataBaseUrl = "https://prod.download.desktop.kiro.dev/stable",

    # .NET 10 SDK install (Step 9c). Installs the official .NET 10 SDK so it's ready for
    # workshop use. Prefers winget (package id Microsoft.DotNet.SDK.10); if winget is
    # unavailable, falls back to Microsoft's official dotnet-install.ps1 (-Channel 10.0).
    # Use -SkipDotNet10 to skip this step.
    [switch]$SkipDotNet10,
    [string]$DotNet10WingetId = "Microsoft.DotNet.SDK.10",
    [string]$DotNet10Channel = "10.0",

    # uv / uvx install (Step 9d). Installs Astral's uv (which provides uvx), a common
    # prerequisite for launching MCP servers used by Kiro powers. Users add powers
    # themselves via the Kiro UI; this step just ensures uv/uvx is available machine-wide.
    # Prefers winget (package id astral-sh.uv); if winget is unavailable, falls back to
    # Astral's official standalone installer (install.ps1). Use -SkipUv to skip.
    [switch]$SkipUv,
    [string]$UvWingetId = "astral-sh.uv",
    [string]$UvInstallDir = "$env:ProgramFiles\uv",

    # -----------------------------------------------------------------------
    # vFunction .NET agent (Step 10). This phase runs LAST because it hooks into
    # the IIS App Pool created earlier. It is skipped automatically unless a
    # -VFServerHost is provided; pass -SkipVFunction to force it off even when a
    # host is given. VFServerHost is intentionally NOT mandatory so the script can
    # be used for a plain OMS.NET deployment without vFunction.
    # -----------------------------------------------------------------------
    [switch]$SkipVFunction,
    [string]$VFServerHost = "",
    [string]$VFEmail = "admin@vfun.com",
    # Supply the vFunction login password at runtime (-VFPassword) rather than hardcoding
    # it here, so no credential is committed to source control.
    [string]$VFPassword = "",
    [string]$ControllerName = "oms-controller",
    # vFunction application display name (distinct from the IIS $SiteName above).
    [string]$VFAppName = "OMS-NET",
    [string]$IncludeClasses = "OMS.",

    # Runtime/language of the application in vFunction. If this is not sent when
    # creating the app, the server defaults it to Java. For OMS.NET it must be the
    # .NET runtime literal ".net" (lowercase, leading dot), verified against a
    # manually-created .NET app on the server.
    [string]$Runtime = ".net",

    [string]$VFBaseDir = "C:\vfunction",
    # Path to the OMS.NET application binaries the viper/static agent analyzes.
    # Defaults below to the built project's bin folder ($projectPath\bin).
    [string]$AssembliesPath = "",

    [string]$PackageUrl = "",

    [string]$OrgId = "",
    [string]$AppId = "",
    [string]$ClientId = "",
    [string]$ClientSecret = "",

    [switch]$SkipDynamic,
    [switch]$SkipViper
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"  # Speed up Invoke-WebRequest

$projectPath = Join-Path $RepoPath "OMS.NET"
$solutionFile = Join-Path $RepoPath "OMS.NET.sln"
$webConfig = Join-Path $projectPath "Web.config"
$packagesDir = Join-Path $RepoPath "packages"
$downloadsDir = Join-Path $RepoPath ".deploy-downloads"

# vFunction agent derived defaults.
# If no -AssembliesPath was supplied, use the built project's bin folder.
if (-not $AssembliesPath) {
    $AssembliesPath = Join-Path $projectPath "bin"
}
$dynamicInstance = "default-dotnet"
$viperInstance = "default-dotnet-viper"

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "=====================================================" -ForegroundColor Cyan
    Write-Host " $Message" -ForegroundColor Cyan
    Write-Host "=====================================================" -ForegroundColor Cyan
    Write-Host ""
}

function Fail {
    param([string]$Message)
    Write-Host ""
    Write-Host "FATAL: $Message" -ForegroundColor Red
    Write-Host ""
    exit 1
}

function Test-CommandExists {
    param([string]$Command)
    $null = Get-Command $Command -ErrorAction SilentlyContinue
    return $?
}

function Resolve-KiroInstallerUrl {
    <#
    .SYNOPSIS
        Discovers the current Kiro Windows x64 installer URL from Kiro's official
        update metadata, so no download URL has to be supplied manually.
    .DESCRIPTION
        Kiro's desktop auto-updater publishes a per-platform metadata manifest at
        <base>/metadata-<platform>-<arch>-stable.json. Each manifest exposes the
        current installer under .releases[].updateTo.url (same shape used by the
        Linux updater). We fetch the Windows x64 manifest and return the release
        URL that ends in .exe. Returns $null if it can't be resolved.
    #>
    param(
        [string]$BaseUrl = "https://prod.download.desktop.kiro.dev/stable"
    )

    # Try known platform tokens for the Windows x64 manifest (Kiro has used both).
    $manifestNames = @(
        "metadata-windows-x64-stable.json",
        "metadata-win32-x64-stable.json"
    )

    foreach ($name in $manifestNames) {
        $metaUrl = "$($BaseUrl.TrimEnd('/'))/$name"
        try {
            Write-Host "  Resolving Kiro installer from metadata: $metaUrl"
            $resp = Invoke-WebRequest -Uri $metaUrl -UseBasicParsing -TimeoutSec 30
            $meta = $resp.Content | ConvertFrom-Json

            # Collect candidate URLs from releases[].updateTo.url
            $urls = @()
            if ($meta.releases) {
                foreach ($rel in $meta.releases) {
                    if ($rel.updateTo -and $rel.updateTo.url) {
                        $urls += $rel.updateTo.url
                    }
                }
            }
            # Some manifests also expose a top-level url.
            if ($meta.url) { $urls += $meta.url }

            # Prefer a Windows installer executable.
            $exe = $urls | Where-Object { $_ -match '\.exe(\?|$)' } | Select-Object -First 1
            if ($exe) {
                $version = if ($meta.currentRelease) { $meta.currentRelease } else { "unknown" }
                Write-Host "  Found Kiro $version installer: $exe" -ForegroundColor Green
                return $exe
            }
        }
        catch {
            Write-Host "  Metadata not available at $metaUrl ($($_.Exception.Message))." -ForegroundColor DarkYellow
        }
    }

    return $null
}

# ---------------------------------------------------------------------------
# STEP 0: Clone (or update) the OMS.NET repository
# ---------------------------------------------------------------------------
Write-Step "Step 0: Cloning OMS.NET Repository"

# Ensure git is available; install it via winget if missing.
if (-not (Test-CommandExists "git")) {
    Write-Host "git not found. Attempting to install Git for Windows..." -ForegroundColor Yellow
    if (Test-CommandExists "winget") {
        winget install --id Git.Git -e --source winget --accept-package-agreements --accept-source-agreements
    }
    else {
        Write-Error "git is not installed and winget is unavailable. Please install Git for Windows from https://git-scm.com/download/win and re-run this script."
        exit 1
    }

    # Refresh PATH for the current session so git is picked up without a restart.
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path", "User")

    if (-not (Test-CommandExists "git")) {
        # Fall back to the default install location.
        $gitCmd = "${env:ProgramFiles}\Git\cmd"
        if (Test-Path (Join-Path $gitCmd "git.exe")) {
            $env:Path += ";$gitCmd"
        }
    }

    if (-not (Test-CommandExists "git")) {
        Write-Error "git still not found after installation. Open a new terminal (to refresh PATH) and re-run this script."
        exit 1
    }
}

Write-Host "Using git: $((Get-Command git).Source)" -ForegroundColor Green

$gitDir = Join-Path $RepoPath ".git"
if (Test-Path $gitDir) {
    Write-Host "Repository already present at $RepoPath. Fetching latest changes..." -ForegroundColor Yellow
    Push-Location $RepoPath
    try {
        git fetch origin
        git checkout $RepoBranch
        git pull origin $RepoBranch
    }
    finally {
        Pop-Location
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "git pull returned exit code $LASTEXITCODE. Continuing with the existing checkout."
    }
}
else {
    # Make sure the parent directory exists, and that the target dir is empty (or absent).
    $parentDir = Split-Path -Parent $RepoPath
    if (-not (Test-Path $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    }

    # The target may already contain deploy scratch (e.g. .deploy-downloads) from a
    # previous run. git can't clone into a non-empty directory, so detect any content
    # that isn't the known scratch folder and refuse; otherwise clone into a temp dir
    # and move the sources in, preserving the scratch folder.
    $allowedExisting = @(".deploy-downloads")
    $unexpected = @()
    if (Test-Path $RepoPath) {
        $unexpected = Get-ChildItem -Path $RepoPath -Force |
            Where-Object { $allowedExisting -notcontains $_.Name }
    }

    if ($unexpected.Count -gt 0) {
        Write-Error "Target path '$RepoPath' exists and contains unexpected content ($($unexpected.Name -join ', ')), but is not a git repository. Please remove it or choose a different -RepoPath, then re-run."
        exit 1
    }

    if (-not (Test-Path $RepoPath)) {
        New-Item -ItemType Directory -Path $RepoPath -Force | Out-Null
    }

    $emptyTarget = -not (Get-ChildItem -Path $RepoPath -Force | Select-Object -First 1)

    if ($emptyTarget) {
        Write-Host "Cloning $RepoUrl (branch: $RepoBranch) into $RepoPath..."
        git clone --branch $RepoBranch $RepoUrl $RepoPath
        if ($LASTEXITCODE -ne 0) {
            Write-Error "git clone failed with exit code $LASTEXITCODE. Verify the repository URL and your network/credentials."
            exit 1
        }
    }
    else {
        # Directory only holds allowed scratch content; clone to temp then merge in.
        $tempClone = Join-Path ([System.IO.Path]::GetTempPath()) ("oms-net-" + [System.Guid]::NewGuid().ToString("N"))
        Write-Host "Target contains deploy scratch only. Cloning $RepoUrl (branch: $RepoBranch) into a temp dir, then merging..." -ForegroundColor Yellow
        git clone --branch $RepoBranch $RepoUrl $tempClone
        if ($LASTEXITCODE -ne 0) {
            Write-Error "git clone failed with exit code $LASTEXITCODE. Verify the repository URL and your network/credentials."
            exit 1
        }
        # Move all cloned content (including the .git folder) into the target.
        Get-ChildItem -Path $tempClone -Force | ForEach-Object {
            Move-Item -Path $_.FullName -Destination $RepoPath -Force
        }
        Remove-Item -Path $tempClone -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host "Repository cloned successfully." -ForegroundColor Green
}

# Sanity check: the solution file we build later must now exist.
if (-not (Test-Path $solutionFile)) {
    Write-Warning "Expected solution file not found at '$solutionFile' after clone."
    Write-Warning "The repository layout may differ. Searching for a .sln file under $RepoPath..."
    $foundSln = Get-ChildItem -Path $RepoPath -Filter "*.sln" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($foundSln) {
        Write-Warning "Found solution at: $($foundSln.FullName)"
        Write-Warning "If this differs from the expected path, adjust the script's `\$RepoPath`/layout accordingly."
    }
}

# ---------------------------------------------------------------------------
# STEP 1: Install IIS and required Windows features
# ---------------------------------------------------------------------------
Write-Step "Step 1: Installing IIS and Windows Features"

$iisFeatures = @(
    "IIS-WebServerRole",
    "IIS-WebServer",
    "IIS-CommonHttpFeatures",
    "IIS-StaticContent",
    "IIS-DefaultDocument",
    "IIS-DirectoryBrowsing",
    "IIS-HttpErrors",
    "IIS-ApplicationDevelopment",
    "IIS-ASPNET45",
    "IIS-NetFxExtensibility45",
    "IIS-ISAPIExtensions",
    "IIS-ISAPIFilter",
    "IIS-HealthAndDiagnostics",
    "IIS-HttpLogging",
    "IIS-RequestMonitor",
    "IIS-Security",
    "IIS-RequestFiltering",
    "IIS-Performance",
    "IIS-HttpCompressionStatic",
    "IIS-HttpCompressionDynamic",
    "IIS-WebServerManagementTools",
    "IIS-ManagementConsole",
    "IIS-ManagementService",
    "NetFx4Extended-ASPNET45",
    "WAS-WindowsActivationService",
    "WAS-ProcessModel",
    "WAS-ConfigurationAPI"
)

# Detect if this is Windows Server or desktop Windows
$osInfo = Get-CimInstance Win32_OperatingSystem
$isServer = $osInfo.ProductType -ne 1

if ($isServer) {
    Write-Host "Detected Windows Server - using Install-WindowsFeature" -ForegroundColor Yellow
    $serverFeatures = @(
        "Web-Server",
        "Web-Common-Http",
        "Web-Static-Content",
        "Web-Default-Doc",
        "Web-Dir-Browsing",
        "Web-Http-Errors",
        "Web-App-Dev",
        "Web-Asp-Net45",
        "Web-Net-Ext45",
        "Web-ISAPI-Ext",
        "Web-ISAPI-Filter",
        "Web-Health",
        "Web-Http-Logging",
        "Web-Request-Monitor",
        "Web-Security",
        "Web-Filtering",
        "Web-Performance",
        "Web-Stat-Compression",
        "Web-Dyn-Compression",
        "Web-Mgmt-Tools",
        "Web-Mgmt-Console",
        "Web-Mgmt-Service",
        "NET-Framework-45-ASPNET",
        "WAS",
        "WAS-Process-Model",
        "WAS-Config-APIs"
    )
    Install-WindowsFeature -Name $serverFeatures -IncludeManagementTools | Out-Null
    Write-Host "IIS features installed via Install-WindowsFeature." -ForegroundColor Green
}
else {
    Write-Host "Detected Windows Desktop - using DISM" -ForegroundColor Yellow
    foreach ($feature in $iisFeatures) {
        $state = (Get-WindowsOptionalFeature -Online -FeatureName $feature -ErrorAction SilentlyContinue)
        if ($state -and $state.State -ne "Enabled") {
            Write-Host "  Enabling: $feature"
            Enable-WindowsOptionalFeature -Online -FeatureName $feature -All -NoRestart | Out-Null
        }
    }
    Write-Host "IIS features enabled." -ForegroundColor Green
}

# Ensure ASP.NET 4.x is registered with IIS
$aspnetRegIis = Join-Path $env:windir "Microsoft.NET\Framework64\v4.0.30319\aspnet_regiis.exe"
if (Test-Path $aspnetRegIis) {
    Write-Host "Registering ASP.NET 4.x with IIS..."
    & $aspnetRegIis -i 2>&1 | Out-Null
}

# ---------------------------------------------------------------------------
# STEP 2: Install SQL Server Express
# ---------------------------------------------------------------------------
Write-Step "Step 2: Installing SQL Server Express"

# Check if SQLEXPRESS instance already exists
$sqlService = Get-Service -Name "MSSQL`$SQLEXPRESS" -ErrorAction SilentlyContinue
if ($sqlService) {
    Write-Host "SQL Server Express (SQLEXPRESS) is already installed." -ForegroundColor Green
    if ($sqlService.Status -ne "Running") {
        Write-Host "Starting SQL Server Express service..."
        Start-Service -Name "MSSQL`$SQLEXPRESS"
    }
}
else {
    Write-Host "SQL Server Express not found. Downloading and installing..."

    if (-not (Test-Path $downloadsDir)) {
        New-Item -ItemType Directory -Path $downloadsDir -Force | Out-Null
    }

    $sqlExpressInstallerUrl = "https://go.microsoft.com/fwlink/?linkid=866658"
    $sqlExpressBootstrapper = Join-Path $downloadsDir "SQL2022-SSEI-Expr.exe"

    if (-not (Test-Path $sqlExpressBootstrapper)) {
        Write-Host "Downloading SQL Server Express installer..."
        Invoke-WebRequest -Uri $sqlExpressInstallerUrl -OutFile $sqlExpressBootstrapper -UseBasicParsing
    }

    # Run the bootstrapper to download and install silently
    Write-Host "Running SQL Server Express setup (this may take several minutes)..."
    $sqlArgs = @(
        "/Action=Install",
        "/MEDIATYPE=Advanced",
        "/QUIET",
        "/IACCEPTSQLSERVERLICENSETERMS",
        "/ENU",
        "/INSTANCENAME=SQLEXPRESS",
        "/SECURITYMODE=SQL",
        "/SAPWD=OmsP@ss2024!",
        "/TCPENABLED=1",
        "/ADDCURRENTUSERASSQLADMIN"
    )

    $sqlProcess = Start-Process -FilePath $sqlExpressBootstrapper -ArgumentList $sqlArgs -Wait -PassThru -NoNewWindow
    
    if ($sqlProcess.ExitCode -ne 0) {
        Write-Host "SQL Express bootstrapper returned exit code: $($sqlProcess.ExitCode)" -ForegroundColor Yellow
        Write-Host "The bootstrapper may download files first. Checking for extracted setup..."
        
        # The bootstrapper often downloads the full installer to a temp location
        # Try alternative: use /MediaPath to download media, then run setup.exe directly
        $mediaPath = Join-Path $downloadsDir "SQLMedia"
        if (-not (Test-Path $mediaPath)) {
            New-Item -ItemType Directory -Path $mediaPath -Force | Out-Null
        }

        Write-Host "Downloading SQL Express media..."
        $dlArgs = @("/Action=Download", "/MEDIAPATH=$mediaPath", "/MEDIATYPE=Advanced", "/QUIET")
        $dlProcess = Start-Process -FilePath $sqlExpressBootstrapper -ArgumentList $dlArgs -Wait -PassThru -NoNewWindow
        
        # Find the downloaded setup file
        $setupExe = Get-ChildItem -Path $mediaPath -Filter "SQLEXPR*.exe" -Recurse | Select-Object -First 1
        if (-not $setupExe) {
            $setupExe = Get-ChildItem -Path $mediaPath -Filter "setup.exe" -Recurse | Select-Object -First 1
        }

        if ($setupExe) {
            Write-Host "Found setup at: $($setupExe.FullName)"
            # Extract and run
            $extractPath = Join-Path $downloadsDir "SQLExtract"
            & $setupExe.FullName /q /x:$extractPath 2>&1 | Out-Null
            Start-Sleep -Seconds 5

            $finalSetup = Join-Path $extractPath "setup.exe"
            if (-not (Test-Path $finalSetup)) {
                $finalSetup = Get-ChildItem -Path $extractPath -Filter "setup.exe" -Recurse | Select-Object -First 1
                if ($finalSetup) { $finalSetup = $finalSetup.FullName }
            }

            if ($finalSetup -and (Test-Path $finalSetup)) {
                $setupArgs = @(
                    "/Q",
                    "/IACCEPTSQLSERVERLICENSETERMS",
                    "/ACTION=Install",
                    "/FEATURES=SQLENGINE",
                    "/INSTANCENAME=SQLEXPRESS",
                    "/SECURITYMODE=SQL",
                    "/SAPWD=OmsP@ss2024!",
                    "/TCPENABLED=1",
                    "/ADDCURRENTUSERASSQLADMIN",
                    "/SQLSVCSTARTUPTYPE=Automatic",
                    "/BROWSERSVCSTARTUPTYPE=Automatic"
                )
                Write-Host "Running SQL Server Express setup.exe..."
                $setupProcess = Start-Process -FilePath $finalSetup -ArgumentList $setupArgs -Wait -PassThru -NoNewWindow
                Write-Host "Setup completed with exit code: $($setupProcess.ExitCode)"
            }
        }
    }

    # Verify installation
    Start-Sleep -Seconds 10
    $sqlService = Get-Service -Name "MSSQL`$SQLEXPRESS" -ErrorAction SilentlyContinue
    if ($sqlService) {
        Write-Host "SQL Server Express installed successfully." -ForegroundColor Green
        if ($sqlService.Status -ne "Running") {
            Start-Service -Name "MSSQL`$SQLEXPRESS"
        }
    }
    else {
        Write-Warning "SQL Server Express service not detected. You may need to install it manually."
        Write-Warning "Download from: https://go.microsoft.com/fwlink/?linkid=866658"
        Write-Warning "After installing, re-run this script."
        Read-Host "Press Enter to continue anyway, or Ctrl+C to abort"
    }
}

# Start SQL Server Browser (needed for named instance connections)
$browserService = Get-Service -Name "SQLBrowser" -ErrorAction SilentlyContinue
if ($browserService) {
    Set-Service -Name "SQLBrowser" -StartupType Automatic -ErrorAction SilentlyContinue
    if ($browserService.Status -ne "Running") {
        Start-Service -Name "SQLBrowser" -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# STEP 3: Install Build Tools (MSBuild, NuGet, .NET 4.7.2 targeting pack)
# ---------------------------------------------------------------------------
Write-Step "Step 3: Installing Build Tools"

if (-not (Test-Path $downloadsDir)) {
    New-Item -ItemType Directory -Path $downloadsDir -Force | Out-Null
}

# Install NuGet CLI
$nugetExe = Join-Path $downloadsDir "nuget.exe"
if (-not (Test-Path $nugetExe)) {
    Write-Host "Downloading nuget.exe..."
    Invoke-WebRequest -Uri "https://dist.nuget.org/win-x86-commandline/latest/nuget.exe" -OutFile $nugetExe -UseBasicParsing
}

# Find MSBuild
$msbuildPath = $null
$msbuildLocations = @(
    "${env:ProgramFiles}\Microsoft Visual Studio\2022\*\MSBuild\Current\Bin\MSBuild.exe",
    "${env:ProgramFiles}\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\MSBuild.exe",
    "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\*\MSBuild\Current\Bin\MSBuild.exe",
    "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\MSBuild.exe",
    "${env:ProgramFiles}\Microsoft Visual Studio\2019\*\MSBuild\Current\Bin\MSBuild.exe",
    "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2019\*\MSBuild\Current\Bin\MSBuild.exe",
    "${env:ProgramFiles(x86)}\MSBuild\14.0\Bin\MSBuild.exe"
)

foreach ($loc in $msbuildLocations) {
    $found = Resolve-Path $loc -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) {
        $msbuildPath = $found.Path
        break
    }
}

if (-not $msbuildPath) {
    Write-Host "MSBuild not found. Installing Visual Studio Build Tools 2022..." -ForegroundColor Yellow

    $vsInstallerUrl = "https://aka.ms/vs/17/release/vs_buildtools.exe"
    $vsInstaller = Join-Path $downloadsDir "vs_buildtools.exe"

    if (-not (Test-Path $vsInstaller)) {
        Write-Host "Downloading Visual Studio Build Tools..."
        Invoke-WebRequest -Uri $vsInstallerUrl -OutFile $vsInstaller -UseBasicParsing
    }

    Write-Host "Installing Build Tools (this may take 10-15 minutes)..."
    $vsArgs = @(
        "--quiet",
        "--wait",
        "--norestart",
        "--nocache",
        "--add", "Microsoft.VisualStudio.Workload.WebBuildTools",
        "--add", "Microsoft.Net.Component.4.7.2.TargetingPack",
        "--add", "Microsoft.Net.Component.4.7.2.SDK",
        "--add", "Microsoft.VisualStudio.Component.WebDeploy",
        "--add", "Microsoft.VisualStudio.Component.NuGet.BuildTools",
        "--includeRecommended"
    )
    $vsProcess = Start-Process -FilePath $vsInstaller -ArgumentList $vsArgs -Wait -PassThru -NoNewWindow
    Write-Host "Build Tools installer exited with code: $($vsProcess.ExitCode)"

    # Re-search for MSBuild
    Start-Sleep -Seconds 5
    foreach ($loc in $msbuildLocations) {
        $found = Resolve-Path $loc -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) {
            $msbuildPath = $found.Path
            break
        }
    }
}

if ($msbuildPath) {
    Write-Host "MSBuild found at: $msbuildPath" -ForegroundColor Green
}
else {
    Write-Error "MSBuild not found after installation. Please install Visual Studio 2022 Build Tools manually and re-run."
    exit 1
}

# ---------------------------------------------------------------------------
# STEP 4: Restore NuGet Packages and Build the Solution
# ---------------------------------------------------------------------------
Write-Step "Step 4: Restoring NuGet Packages and Building"

Write-Host "Restoring NuGet packages..."
& $nugetExe restore $solutionFile -PackagesDirectory $packagesDir -NonInteractive
if ($LASTEXITCODE -ne 0) {
    Write-Warning "NuGet restore returned exit code $LASTEXITCODE. Retrying with explicit source..."
    & $nugetExe restore $solutionFile -PackagesDirectory $packagesDir -NonInteractive -Source "https://api.nuget.org/v3/index.json"
}

# Build only the OMS.NET web project (pulls in APTCA and Common via ProjectReference).
# The solution also references WpfApp1 which may not exist in the repo checkout.
$omsProject = Join-Path $projectPath "OMS.NET.csproj"
Write-Host "Building OMS.NET project in Release configuration..."
& $msbuildPath $omsProject /p:Configuration=Release /p:Platform="AnyCPU" /p:DeployOnBuild=false /t:Rebuild /v:minimal
if ($LASTEXITCODE -ne 0) {
    Write-Error "Build failed with exit code $LASTEXITCODE"
    exit 1
}
Write-Host "Build successful." -ForegroundColor Green

# ---------------------------------------------------------------------------
# STEP 5: Configure Web.config Connection String for SQLEXPRESS
# ---------------------------------------------------------------------------
Write-Step "Step 5: Configuring Connection String"

$xml = [xml](Get-Content $webConfig)
$connStrings = $xml.configuration.connectionStrings
$sqlExpressConn = $connStrings.add | Where-Object { $_.name -eq "SqlExpress" }

if ($sqlExpressConn) {
    $newConnStr = "Server=$SqlInstance;Database=$DatabaseName;Trusted_Connection=True;"
    $sqlExpressConn.connectionString = $newConnStr
    $xml.Save($webConfig)
    Write-Host "Connection string updated to: $newConnStr" -ForegroundColor Green
}
else {
    Write-Warning "Could not find 'SqlExpress' connection string in Web.config. Please verify manually."
}

# ---------------------------------------------------------------------------
# STEP 5b: Create the application database and grant the App Pool identity access
# ---------------------------------------------------------------------------
# Why this step exists:
#   EF has AutomaticMigrationsEnabled=true, so on the first request it tries to
#   CREATE its tables in the database named by the connection string. Previously
#   that database was 'master' (a system DB) and the IIS App Pool identity had no
#   rights there, producing: "CREATE TABLE permission denied in database 'master'."
#   We now target a dedicated DB ($DatabaseName, default 'OMS'), create it, and make
#   the App Pool login a db_owner so migrations can create the schema.
Write-Step "Step 5b: Creating database '$DatabaseName' and granting App Pool access"

# The App Pool runs as LocalSystem (see Step 7), which authenticates to SQL Server
# as the machine's SYSTEM account: NT AUTHORITY\SYSTEM.
$appPoolLogin = "NT AUTHORITY\SYSTEM"

# Guard against creating the app schema inside a system database.
if ($DatabaseName -in @("master", "model", "msdb", "tempdb")) {
    Write-Warning "DatabaseName '$DatabaseName' is a SQL Server system database. Refusing to run app migrations there."
    Write-Warning "Re-run with -DatabaseName OMS (or another dedicated name)."
}
else {
    $sql = @"
IF DB_ID(N'$DatabaseName') IS NULL
BEGIN
    CREATE DATABASE [$DatabaseName];
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'$appPoolLogin')
BEGIN
    CREATE LOGIN [$appPoolLogin] FROM WINDOWS;
END
GO
USE [$DatabaseName];
GO
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$appPoolLogin')
BEGIN
    CREATE USER [$appPoolLogin] FOR LOGIN [$appPoolLogin];
END
ALTER ROLE [db_owner] ADD MEMBER [$appPoolLogin];
GO
"@

    $sqlFile = Join-Path $downloadsDir "setup-db.sql"
    Set-Content -Path $sqlFile -Value $sql -Encoding ASCII

    $ranSql = $false
    if (Test-CommandExists "sqlcmd") {
        Write-Host "Running database setup via sqlcmd (trusted connection as current admin)..."
        & sqlcmd -S $SqlInstance -E -b -i $sqlFile
        if ($LASTEXITCODE -eq 0) {
            $ranSql = $true
            Write-Host "Database '$DatabaseName' ready; '$appPoolLogin' granted db_owner." -ForegroundColor Green
        }
        else {
            Write-Warning "sqlcmd returned exit code $LASTEXITCODE. Falling back to .NET SqlConnection..."
        }
    }

    if (-not $ranSql) {
        # Fallback: execute via ADO.NET using the current (admin) Windows identity.
        try {
            $connString = "Server=$SqlInstance;Database=master;Trusted_Connection=True;"
            $conn = New-Object System.Data.SqlClient.SqlConnection $connString
            $conn.Open()
            # Split on GO batch separators (sqlcmd-style) since ADO.NET can't run GO.
            $batches = ($sql -split "(?m)^\s*GO\s*$") | Where-Object { $_.Trim() -ne "" }
            foreach ($batch in $batches) {
                $cmd = $conn.CreateCommand()
                $cmd.CommandText = $batch
                $null = $cmd.ExecuteNonQuery()
            }
            $conn.Close()
            Write-Host "Database '$DatabaseName' ready; '$appPoolLogin' granted db_owner (via ADO.NET)." -ForegroundColor Green
        }
        catch {
            Write-Warning "Failed to create/configure database '$DatabaseName': $_"
            Write-Warning "Create it manually and grant '$appPoolLogin' db_owner, then re-run."
        }
    }
}

# ---------------------------------------------------------------------------
# STEP 6: Run Entity Framework Migrations
# ---------------------------------------------------------------------------
Write-Step "Step 6: Running Entity Framework Migrations"

$migrateExe = Join-Path $packagesDir "EntityFramework.6.4.4\tools\migrate.exe"
$omsAssembly = Join-Path $projectPath "bin\OMS.NET.dll"

if (Test-Path $migrateExe) {
    if (Test-Path $omsAssembly) {
        Write-Host "Running EF migrations using migrate.exe..."
        & $migrateExe "OMS.NET.dll" /startupConfigurationFile="$webConfig" /startupDirectory=(Join-Path $projectPath "bin") /connectionString="Server=$SqlInstance;Database=$DatabaseName;Trusted_Connection=True;" /connectionProviderName="System.Data.SqlClient"
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "migrate.exe returned exit code $LASTEXITCODE"
            Write-Host "The database will be auto-migrated on first request (AutomaticMigrationsEnabled=true)." -ForegroundColor Yellow
        }
        else {
            Write-Host "Migrations applied successfully." -ForegroundColor Green
        }
    }
    else {
        Write-Warning "OMS.NET.dll not found at $omsAssembly. Migrations will run on first request."
    }
}
else {
    Write-Host "migrate.exe not found. Migrations will run automatically on first application request." -ForegroundColor Yellow
    Write-Host "(AutomaticMigrationsEnabled is set to true in the Configuration class)"
}

# ---------------------------------------------------------------------------
# STEP 7: Configure IIS Application Pool and Site
# ---------------------------------------------------------------------------
Write-Step "Step 7: Configuring IIS"

Import-Module WebAdministration -ErrorAction Stop

# Create Application Pool
if (-not (Test-Path "IIS:\AppPools\$AppPoolName")) {
    Write-Host "Creating Application Pool: $AppPoolName"
    New-WebAppPool -Name $AppPoolName | Out-Null
}

# Configure the App Pool
Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name "managedRuntimeVersion" -Value "v4.0"
Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name "managedPipelineMode" -Value "Integrated"
Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name "processModel.identityType" -Value "LocalSystem"
Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name "startMode" -Value "AlwaysRunning"

Write-Host "Application Pool '$AppPoolName' configured." -ForegroundColor Green

# Create or update the IIS Site
$existingSite = Get-Website -Name $SiteName -ErrorAction SilentlyContinue
if ($existingSite) {
    Write-Host "Site '$SiteName' already exists. Updating configuration..."
    Set-ItemProperty "IIS:\Sites\$SiteName" -Name "physicalPath" -Value $projectPath
    Set-ItemProperty "IIS:\Sites\$SiteName" -Name "applicationPool" -Value $AppPoolName
}
else {
    Write-Host "Creating IIS Site: $SiteName"
    New-Website -Name $SiteName -PhysicalPath $projectPath -ApplicationPool $AppPoolName -Port $Port -HostHeader $HostHeader | Out-Null
}

# Add binding without host header for direct port access (if port is not 80 or host header is set)
$bindings = Get-WebBinding -Name $SiteName
$hasPortBinding = $bindings | Where-Object { $_.bindingInformation -eq "*:${Port}:" }
if (-not $hasPortBinding -and $HostHeader) {
    # Also add a binding without host header on a different port for easy access
    New-WebBinding -Name $SiteName -Protocol "http" -Port 8080 -IPAddress "*" -ErrorAction SilentlyContinue
    Write-Host "Added additional binding on port 8080 (no host header required)" -ForegroundColor Yellow
}

Write-Host "IIS Site '$SiteName' configured." -ForegroundColor Green

# Ensure the site is started
Start-Website -Name $SiteName -ErrorAction SilentlyContinue

# Stop Default Web Site to avoid port conflicts on port 80
$defaultSite = Get-Website -Name "Default Web Site" -ErrorAction SilentlyContinue
if ($defaultSite -and $Port -eq 80 -and -not $HostHeader) {
    Stop-Website -Name "Default Web Site" -ErrorAction SilentlyContinue
    Write-Host "Stopped 'Default Web Site' to avoid port 80 conflict." -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# STEP 8: Add hosts file entry
# ---------------------------------------------------------------------------
Write-Step "Step 8: Configuring hosts file"

$hostsFile = Join-Path $env:windir "System32\drivers\etc\hosts"
$hostsEntry = "127.0.0.1    $HostHeader"

$hostsContent = Get-Content $hostsFile -Raw -ErrorAction SilentlyContinue
if ($hostsContent -notmatch [regex]::Escape($HostHeader)) {
    Add-Content -Path $hostsFile -Value "`n$hostsEntry" -Encoding ASCII
    Write-Host "Added '$hostsEntry' to hosts file." -ForegroundColor Green
}
else {
    Write-Host "Hosts entry for '$HostHeader' already exists." -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# STEP 9: Grant file system permissions
# ---------------------------------------------------------------------------
Write-Step "Step 9: Setting file system permissions"

$acl = Get-Acl $projectPath
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    "IIS_IUSRS", "ReadAndExecute", "ContainerInherit,ObjectInherit", "None", "Allow"
)
$acl.AddAccessRule($rule)

$ruleSystem = New-Object System.Security.AccessControl.FileSystemAccessRule(
    "SYSTEM", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow"
)
$acl.AddAccessRule($ruleSystem)

Set-Acl -Path $projectPath -AclObject $acl
Write-Host "File system permissions set for IIS_IUSRS and SYSTEM." -ForegroundColor Green

# ---------------------------------------------------------------------------
# STEP 9b: Install the Kiro IDE
# ---------------------------------------------------------------------------
# Installs the Kiro desktop IDE so the machine is ready for development work on
# OMS.NET. Preferred path is winget (matches how git is installed in Step 0);
# falls back to downloading the official installer if winget is unavailable. The
# installer URL is resolved automatically from Kiro's published update metadata,
# so no download URL needs to be supplied. This step is best-effort and never
# aborts the deployment.
if (-not $SkipKiro) {
    Write-Step "Step 9b: Installing Kiro IDE"

    # Detect an existing Kiro install (winget package or the default per-user path).
    $kiroInstalled = $false
    if (Test-CommandExists "winget") {
        $listed = winget list --id $KiroWingetId --exact --accept-source-agreements 2>$null
        if ($LASTEXITCODE -eq 0 -and ($listed -match [regex]::Escape($KiroWingetId))) {
            $kiroInstalled = $true
        }
    }
    $kiroExeDefault = Join-Path $env:LOCALAPPDATA "Programs\Kiro\Kiro.exe"
    if (Test-Path $kiroExeDefault) { $kiroInstalled = $true }

    if ($kiroInstalled) {
        Write-Host "Kiro IDE is already installed. Skipping." -ForegroundColor Green
    }
    else {
        $kiroOk = $false

        # Preferred: winget (silent, keeps Kiro auto-updatable).
        if (Test-CommandExists "winget") {
            Write-Host "Installing Kiro via winget (id: $KiroWingetId)..."
            winget install --id $KiroWingetId -e --source winget `
                --accept-package-agreements --accept-source-agreements --silent
            if ($LASTEXITCODE -eq 0) {
                $kiroOk = $true
                Write-Host "Kiro installed via winget." -ForegroundColor Green
            }
            else {
                Write-Warning "winget install of Kiro returned exit code $LASTEXITCODE. Falling back to direct installer."
            }
        }
        else {
            Write-Host "winget not available. Falling back to direct installer download." -ForegroundColor Yellow
        }

        # Fallback: download the official Windows x64 installer.
        # The installer URL is resolved AUTOMATICALLY from Kiro's official update
        # metadata, so no download URL needs to be supplied. -KiroInstallerUrl can
        # still be passed to override the auto-resolved URL (e.g. an internal mirror).
        if (-not $kiroOk) {
            try {
                if (-not (Test-Path $downloadsDir)) {
                    New-Item -ItemType Directory -Path $downloadsDir -Force | Out-Null
                }
                $kiroInstaller = Join-Path $downloadsDir "KiroSetup.exe"

                # Determine the installer URL: explicit override wins, otherwise
                # auto-resolve it from the published metadata manifest.
                $installerUrl = $KiroInstallerUrl
                if ($installerUrl) {
                    Write-Host "Using provided Kiro installer URL override."
                }
                else {
                    Write-Host "Auto-resolving the Kiro installer URL from official metadata..."
                    $installerUrl = Resolve-KiroInstallerUrl -BaseUrl $KiroMetadataBaseUrl
                }

                if (-not $installerUrl) {
                    Write-Warning "Could not resolve a Kiro installer URL automatically and none was provided."
                    Write-Warning "Kiro's metadata layout may have changed. Install manually from https://kiro.dev/downloads/ (Windows x64),"
                    Write-Warning "or re-run with -KiroInstallerUrl <url> pointing at the Windows x64 installer."
                }
                else {
                    Write-Host "Downloading Kiro installer from: $installerUrl"
                    Invoke-WebRequest -Uri $installerUrl -OutFile $kiroInstaller -UseBasicParsing
                    if (Test-Path $kiroInstaller) {
                        # Kiro uses an NSIS-based installer; /S runs it silently.
                        Write-Host "Running Kiro installer silently..."
                        $kiroProc = Start-Process -FilePath $kiroInstaller -ArgumentList "/S" -Wait -PassThru
                        if ($kiroProc.ExitCode -eq 0) {
                            $kiroOk = $true
                            Write-Host "Kiro installed via direct installer." -ForegroundColor Green
                        }
                        else {
                            Write-Warning "Kiro installer exited with code $($kiroProc.ExitCode)."
                        }
                    }
                    else {
                        Write-Warning "Kiro installer failed to download."
                    }
                }
            }
            catch {
                Write-Warning "Kiro installation failed (non-fatal): $_"
                Write-Warning "Install it manually from https://kiro.dev/downloads/."
            }
        }
    }
}
else {
    Write-Step "Step 9b: Skipping Kiro IDE installation (SkipKiro flag set)"
}

# ---------------------------------------------------------------------------
# STEP 9c: Install the official .NET 10 SDK
# ---------------------------------------------------------------------------
# Installs the official .NET 10 SDK (LTS) so it's available for workshop work.
# Preferred path is winget (id Microsoft.DotNet.SDK.10); if winget is unavailable
# it falls back to Microsoft's official dotnet-install.ps1 script pinned to the
# 10.0 channel. This step is best-effort and never aborts the deployment.
if (-not $SkipDotNet10) {
    Write-Step "Step 9c: Installing .NET 10 SDK"

    # Detect an existing .NET 10 SDK (any 10.x.x SDK counts as installed).
    $dotnet10Installed = $false
    if (Test-CommandExists "dotnet") {
        $sdks = & dotnet --list-sdks 2>$null
        if ($LASTEXITCODE -eq 0 -and ($sdks | Where-Object { $_ -match '^\s*10\.' })) {
            $dotnet10Installed = $true
        }
    }

    if ($dotnet10Installed) {
        Write-Host ".NET 10 SDK is already installed. Skipping." -ForegroundColor Green
    }
    else {
        $dotnetOk = $false

        # Preferred: winget (silent, keeps the SDK updatable).
        if (Test-CommandExists "winget") {
            Write-Host "Installing .NET 10 SDK via winget (id: $DotNet10WingetId)..."
            winget install --id $DotNet10WingetId -e --source winget `
                --accept-package-agreements --accept-source-agreements --silent
            if ($LASTEXITCODE -eq 0) {
                $dotnetOk = $true
                Write-Host ".NET 10 SDK installed via winget." -ForegroundColor Green
            }
            else {
                Write-Warning "winget install of .NET 10 SDK returned exit code $LASTEXITCODE. Falling back to dotnet-install.ps1."
            }
        }
        else {
            Write-Host "winget not available. Falling back to dotnet-install.ps1." -ForegroundColor Yellow
        }

        # Fallback: Microsoft's official install script, pinned to the 10.0 channel.
        # This is a machine-wide install into Program Files so IIS/all users can use it.
        if (-not $dotnetOk) {
            try {
                if (-not (Test-Path $downloadsDir)) {
                    New-Item -ItemType Directory -Path $downloadsDir -Force | Out-Null
                }
                $dotnetInstallScript = Join-Path $downloadsDir "dotnet-install.ps1"
                $dotnetInstallUrl = "https://dot.net/v1/dotnet-install.ps1"
                $dotnetInstallDir = Join-Path $env:ProgramFiles "dotnet"

                Write-Host "Downloading official dotnet-install.ps1 from: $dotnetInstallUrl"
                Invoke-WebRequest -Uri $dotnetInstallUrl -OutFile $dotnetInstallScript -UseBasicParsing

                if (Test-Path $dotnetInstallScript) {
                    Write-Host "Installing .NET 10 SDK (channel $DotNet10Channel) into $dotnetInstallDir ..."
                    & $dotnetInstallScript -Channel $DotNet10Channel -InstallDir $dotnetInstallDir -Architecture x64
                    if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq $null) {
                        # Ensure the install dir is on the machine PATH for future sessions.
                        $machinePath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
                        if ($machinePath -notmatch [regex]::Escape($dotnetInstallDir)) {
                            [System.Environment]::SetEnvironmentVariable("Path", "$machinePath;$dotnetInstallDir", "Machine")
                            Write-Host "Added $dotnetInstallDir to the machine PATH." -ForegroundColor Green
                        }
                        # Refresh PATH for the current session so dotnet is usable now.
                        $env:Path = "$env:Path;$dotnetInstallDir"
                        $dotnetOk = $true
                        Write-Host ".NET 10 SDK installed via dotnet-install.ps1." -ForegroundColor Green
                    }
                    else {
                        Write-Warning "dotnet-install.ps1 returned exit code $LASTEXITCODE."
                    }
                }
                else {
                    Write-Warning "dotnet-install.ps1 failed to download."
                }
            }
            catch {
                Write-Warning ".NET 10 SDK installation failed (non-fatal): $_"
                Write-Warning "Install it manually from https://dotnet.microsoft.com/download/dotnet/10.0 (Windows x64)."
            }
        }
    }
}
else {
    Write-Step "Step 9c: Skipping .NET 10 SDK installation (SkipDotNet10 flag set)"
}

# ---------------------------------------------------------------------------
# STEP 9d: Install uv / uvx (Astral)
# ---------------------------------------------------------------------------
# Installs uv (which ships uvx), a common launcher for the MCP servers used by
# Kiro powers. This does NOT install any power - users add powers themselves via
# the Kiro UI. This step just makes the uv/uvx prerequisite available machine-wide.
# Preferred path is winget (id astral-sh.uv); if winget is unavailable it falls
# back to Astral's official standalone installer. Best-effort; never aborts.
if (-not $SkipUv) {
    Write-Step "Step 9d: Installing uv / uvx (prerequisite for Kiro power MCP servers)"

    # Detect an existing uv install (on PATH or in the target install dir).
    $uvInstalled = $false
    if (Test-CommandExists "uv") {
        $uvInstalled = $true
    }
    elseif (Test-Path (Join-Path $UvInstallDir "uv.exe")) {
        $uvInstalled = $true
    }

    if ($uvInstalled) {
        Write-Host "uv is already installed. Skipping." -ForegroundColor Green
    }
    else {
        $uvOk = $false

        # Preferred: winget (silent, keeps uv updatable).
        if (Test-CommandExists "winget") {
            Write-Host "Installing uv via winget (id: $UvWingetId)..."
            winget install --id $UvWingetId -e --source winget `
                --accept-package-agreements --accept-source-agreements --silent
            if ($LASTEXITCODE -eq 0) {
                $uvOk = $true
                Write-Host "uv installed via winget." -ForegroundColor Green
            }
            else {
                Write-Warning "winget install of uv returned exit code $LASTEXITCODE. Falling back to the standalone installer."
            }
        }
        else {
            Write-Host "winget not available. Falling back to Astral's standalone installer." -ForegroundColor Yellow
        }

        # Fallback: Astral's official standalone installer. By default uv installs
        # into a per-user dir; we set UV_INSTALL_DIR to a machine-wide location so
        # uv/uvx is available to all users, then add it to the machine PATH.
        if (-not $uvOk) {
            try {
                if (-not (Test-Path $UvInstallDir)) {
                    New-Item -ItemType Directory -Path $UvInstallDir -Force | Out-Null
                }

                Write-Host "Installing uv into $UvInstallDir via Astral's standalone installer..."
                # UV_NO_MODIFY_PATH: we manage the machine PATH ourselves below rather
                # than let the installer edit the current user's PATH.
                $env:UV_INSTALL_DIR = $UvInstallDir
                $env:UV_NO_MODIFY_PATH = "1"
                $uvInstallScript = (Invoke-WebRequest -Uri "https://astral.sh/uv/install.ps1" -UseBasicParsing).Content
                Invoke-Expression $uvInstallScript

                $uvExe = Join-Path $UvInstallDir "uv.exe"
                if (Test-Path $uvExe) {
                    # Ensure the install dir is on the machine PATH for future sessions.
                    $machinePath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
                    if ($machinePath -notmatch [regex]::Escape($UvInstallDir)) {
                        [System.Environment]::SetEnvironmentVariable("Path", "$machinePath;$UvInstallDir", "Machine")
                        Write-Host "Added $UvInstallDir to the machine PATH." -ForegroundColor Green
                    }
                    # Refresh PATH for the current session so uv/uvx is usable now.
                    $env:Path = "$env:Path;$UvInstallDir"
                    $uvOk = $true
                    Write-Host "uv installed via standalone installer." -ForegroundColor Green
                }
                else {
                    Write-Warning "uv.exe not found in $UvInstallDir after running the standalone installer."
                }
            }
            catch {
                Write-Warning "uv installation failed (non-fatal): $_"
                Write-Warning "Install it manually from https://docs.astral.sh/uv/getting-started/installation/."
            }
            finally {
                Remove-Item Env:\UV_INSTALL_DIR -ErrorAction SilentlyContinue
                Remove-Item Env:\UV_NO_MODIFY_PATH -ErrorAction SilentlyContinue
            }
        }
    }

    Write-Host ""
    Write-Host "Note: uv/uvx is a prerequisite only. Add Kiro powers (e.g. AWS Transform)" -ForegroundColor Yellow
    Write-Host "manually from the Kiro IDE Powers panel - powers are a per-user setting." -ForegroundColor Yellow
}
else {
    Write-Step "Step 9d: Skipping uv / uvx installation (SkipUv flag set)"
}

# ---------------------------------------------------------------------------
# STEP 10: Final verification
# ---------------------------------------------------------------------------
Write-Step "Step 10: Verification"

Write-Host "Verifying services..." -ForegroundColor Yellow

# Check IIS
$w3svc = Get-Service -Name "W3SVC" -ErrorAction SilentlyContinue
if ($w3svc -and $w3svc.Status -eq "Running") {
    Write-Host "  [OK] IIS (W3SVC) is running" -ForegroundColor Green
}
else {
    Write-Host "  [!!] IIS (W3SVC) is NOT running" -ForegroundColor Red
    Start-Service -Name "W3SVC" -ErrorAction SilentlyContinue
}

# Check SQL Express
$sqlSvc = Get-Service -Name "MSSQL`$SQLEXPRESS" -ErrorAction SilentlyContinue
if ($sqlSvc -and $sqlSvc.Status -eq "Running") {
    Write-Host "  [OK] SQL Server Express is running" -ForegroundColor Green
}
else {
    Write-Host "  [!!] SQL Server Express is NOT running" -ForegroundColor Red
}

# Check site status
$siteState = (Get-Website -Name $SiteName -ErrorAction SilentlyContinue).State
if ($siteState -eq "Started") {
    Write-Host "  [OK] IIS Site '$SiteName' is started" -ForegroundColor Green
}
else {
    Write-Host "  [!!] IIS Site '$SiteName' state: $siteState" -ForegroundColor Red
}

# Try a quick HTTP request
Write-Host ""
Write-Host "Attempting to reach the application..." -ForegroundColor Yellow
try {
    $response = Invoke-WebRequest -Uri "http://${HostHeader}:${Port}/" -UseBasicParsing -TimeoutSec 30
    Write-Host "  [OK] HTTP $($response.StatusCode) - Application is responding!" -ForegroundColor Green
}
catch {
    Write-Host "  [INFO] Could not reach http://${HostHeader}:${Port}/ - this is normal if first request triggers migrations." -ForegroundColor Yellow
    Write-Host "  Try opening the URL in a browser. The first request may take a moment." -ForegroundColor Yellow
}

# Also try port 8080 if configured
try {
    $response2 = Invoke-WebRequest -Uri "http://localhost:8080/" -UseBasicParsing -TimeoutSec 10 -ErrorAction SilentlyContinue
    if ($response2) {
        Write-Host "  [OK] Also accessible at http://localhost:8080/" -ForegroundColor Green
    }
}
catch { }

# ---------------------------------------------------------------------------
# Summary (deployment + tooling phase)
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=====================================================" -ForegroundColor Green
Write-Host " OMS.NET DEPLOYMENT + TOOLING COMPLETE" -ForegroundColor Green
Write-Host "=====================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Application URL:  http://$HostHeader/" -ForegroundColor White
Write-Host "Alternate URL:    http://localhost:8080/" -ForegroundColor White
Write-Host "API Help Page:    http://$HostHeader/Help" -ForegroundColor White
Write-Host "SQL Instance:     $SqlInstance" -ForegroundColor White
Write-Host "Database:         $DatabaseName" -ForegroundColor White
Write-Host "IIS Site:         $SiteName" -ForegroundColor White
Write-Host "App Pool:         $AppPoolName" -ForegroundColor White
Write-Host "Physical Path:    $projectPath" -ForegroundColor White

# Report Kiro IDE install state
if ($SkipKiro) {
    Write-Host "Kiro IDE:         skipped (-SkipKiro)" -ForegroundColor White
}
else {
    $kiroExeDefault = Join-Path $env:LOCALAPPDATA "Programs\Kiro\Kiro.exe"
    $kiroPresent = Test-Path $kiroExeDefault
    if (-not $kiroPresent -and (Test-CommandExists "winget")) {
        $listed = winget list --id $KiroWingetId --exact 2>$null
        if ($LASTEXITCODE -eq 0 -and ($listed -match [regex]::Escape($KiroWingetId))) { $kiroPresent = $true }
    }
    if ($kiroPresent) {
        Write-Host "Kiro IDE:         installed" -ForegroundColor White
    }
    else {
        Write-Host "Kiro IDE:         not detected (install from https://kiro.dev/downloads/)" -ForegroundColor Yellow
    }
}

# Report .NET 10 SDK install state
if ($SkipDotNet10) {
    Write-Host ".NET 10 SDK:      skipped (-SkipDotNet10)" -ForegroundColor White
}
else {
    $dotnet10Version = $null
    if (Test-CommandExists "dotnet") {
        $sdks = & dotnet --list-sdks 2>$null
        if ($LASTEXITCODE -eq 0) {
            $dotnet10Version = ($sdks | Where-Object { $_ -match '^\s*10\.' } | Select-Object -First 1)
        }
    }
    if ($dotnet10Version) {
        $verOnly = ($dotnet10Version -split '\s+')[0]
        Write-Host ".NET 10 SDK:      installed ($verOnly)" -ForegroundColor White
    }
    else {
        Write-Host ".NET 10 SDK:      not detected (install from https://dotnet.microsoft.com/download/dotnet/10.0)" -ForegroundColor Yellow
    }
}

# Report uv / uvx install state
if ($SkipUv) {
    Write-Host "uv / uvx:         skipped (-SkipUv)" -ForegroundColor White
}
else {
    $uvPresent = (Test-CommandExists "uv") -or (Test-Path (Join-Path $UvInstallDir "uv.exe"))
    if ($uvPresent) {
        Write-Host "uv / uvx:         installed (add Kiro powers manually via the IDE)" -ForegroundColor White
    }
    else {
        Write-Host "uv / uvx:         not detected (install from https://docs.astral.sh/uv/)" -ForegroundColor Yellow
    }
}
Write-Host ""
Write-Host "If the application does not load immediately, the first" -ForegroundColor Yellow
Write-Host "request triggers EF database migrations. Allow 30-60s." -ForegroundColor Yellow
Write-Host ""

# ===========================================================================
# STEP 10: vFunction .NET agent (dynamic + viper/static)
# ===========================================================================
# This phase installs and configures the vFunction .NET agent and hooks it into
# the IIS App Pool created in Step 7. It runs LAST because it depends on that App
# Pool. It is skipped when -SkipVFunction is set, or when no -VFServerHost was
# provided (so the script doubles as a plain OMS.NET deploy tool).
$runVFunction = (-not $SkipVFunction) -and $VFServerHost
if ($SkipVFunction) {
    Write-Step "Step 10: Skipping vFunction agent installation (SkipVFunction flag set)"
}
elseif (-not $VFServerHost) {
    Write-Step "Step 10: Skipping vFunction agent installation (no -VFServerHost provided)"
    Write-Host "Pass -VFServerHost <url> (and optionally vFunction credentials/UUIDs) to" -ForegroundColor Yellow
    Write-Host "install and configure the vFunction .NET agent as part of this run." -ForegroundColor Yellow
}

if ($runVFunction) {

    # -----------------------------------------------------------------------
    # STEP 10a: Download and extract vFunction Controller package
    # -----------------------------------------------------------------------
    Write-Step "Step 10a: Downloading and extracting vFunction Controller package"

    if (-not (Test-Path $VFBaseDir)) {
        New-Item -ItemType Directory -Path $VFBaseDir -Force | Out-Null
    }

    # Try to locate install.ps1 - either flat or nested inside a subfolder
    $controllerInstallScript = $null
    $flatPath = Join-Path $VFBaseDir "controller-installation\install.ps1"
    if (Test-Path $flatPath) {
        $controllerInstallScript = $flatPath
    }
    else {
        $nestedSearch = Get-ChildItem -Path $VFBaseDir -Filter "install.ps1" -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.DirectoryName -like "*controller-installation*" } |
            Select-Object -First 1
        if ($nestedSearch) {
            $VFBaseDir = Split-Path (Split-Path $nestedSearch.FullName -Parent) -Parent
            $controllerInstallScript = $nestedSearch.FullName
        }
    }

    if ($controllerInstallScript) {
        Write-Host "vFunction controller package already extracted at $VFBaseDir" -ForegroundColor Green
    }
    else {
        # Need to download and extract
        if (-not $PackageUrl) {
            Write-Host ""
            Write-Host "The vFunction Controller Windows Installation ZIP is required." -ForegroundColor Yellow
            Write-Host "You can download it from the vFunction server or from the vFunction release packages." -ForegroundColor Yellow
            Write-Host ""
            $PackageUrl = Read-Host "Enter the path or URL to vfunction-controller-windows-installation*.zip"
        }

        if (-not $PackageUrl) {
            Fail "No vFunction package URL or path provided."
        }

        $zipPath = ""
        if ($PackageUrl -match "^https?://") {
            $zipPath = Join-Path $env:TEMP "vfunction-controller-windows-installation.zip"
            Write-Host "Downloading vFunction package from: $PackageUrl"

            $headers = @{}
            if ($env:VFUNCTION_REPO_USERNAME -and $env:VFUNCTION_REPO_PASSWORD) {
                $pair = "$($env:VFUNCTION_REPO_USERNAME):$($env:VFUNCTION_REPO_PASSWORD)"
                $bytes = [System.Text.Encoding]::ASCII.GetBytes($pair)
                $base64 = [System.Convert]::ToBase64String($bytes)
                $headers["Authorization"] = "Basic $base64"
            }

            Invoke-WebRequest -Uri $PackageUrl -OutFile $zipPath -UseBasicParsing -Headers $headers
            if (-not (Test-Path $zipPath)) {
                Fail "Failed to download vFunction package."
            }
        }
        else {
            $zipPath = $PackageUrl
            if (-not (Test-Path $zipPath)) {
                Fail "vFunction package file not found at: $zipPath"
            }
        }

        Write-Host "Extracting to $VFBaseDir..."
        Expand-Archive -Path $zipPath -DestinationPath $VFBaseDir -Force

        # The ZIP may extract with a nested folder (e.g., vfunction\controller-installation\...)
        $controllerInstallScript = Join-Path $VFBaseDir "controller-installation\install.ps1"
        if (-not (Test-Path $controllerInstallScript)) {
            $found = Get-ChildItem -Path $VFBaseDir -Filter "install.ps1" -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.DirectoryName -like "*controller-installation*" } |
                Select-Object -First 1
            if ($found) {
                $VFBaseDir = Split-Path (Split-Path $found.FullName -Parent) -Parent
                $controllerInstallScript = $found.FullName
                Write-Host "  Detected nested extraction. Adjusted VFBaseDir to: $VFBaseDir" -ForegroundColor Yellow
            }
            else {
                Fail "Extraction completed but install.ps1 not found under $VFBaseDir"
            }
        }
        Write-Host "vFunction package extracted successfully." -ForegroundColor Green
    }

    # Unblock all files (required for downloaded packages)
    Write-Host "Unblocking files..."
    Get-ChildItem -Path $VFBaseDir -Recurse | Unblock-File

    # Set permissions for current user
    $currentUser = "$env:USERDOMAIN\$env:USERNAME"
    Write-Host "Granting full permissions to $currentUser on $VFBaseDir"
    icacls $VFBaseDir /grant:r "${currentUser}:(OI)(CI)F" /T /Q 2>&1 | Out-Null

    # -----------------------------------------------------------------------
    # STEP 10b: Get or create application on vFunction server (get UUIDs)
    # -----------------------------------------------------------------------
    Write-Step "Step 10b: Obtaining vFunction application credentials"

    if ($OrgId -and $AppId -and $ClientId -and $ClientSecret) {
        Write-Host "Using provided UUIDs:" -ForegroundColor Green
        Write-Host "  OrgId:        $OrgId"
        Write-Host "  AppId:        $AppId"
        Write-Host "  ClientId:     $ClientId"
        Write-Host "  ClientSecret: $($ClientSecret.Substring(0,8))..."
    }
    else {
        Write-Host "No UUIDs provided. Creating application on vFunction server via API..." -ForegroundColor Yellow

        # The API path authenticates with the vFunction login. The password is not
        # hardcoded (so it isn't committed), so require it here. Alternatively pass the
        # -OrgId/-AppId/-ClientId/-ClientSecret UUIDs to skip API auth entirely.
        if (-not $VFPassword) {
            Fail "vFunction login password is required to create the app via API. Re-run with -VFPassword <password> (and -VFEmail if not the default), or pass -OrgId/-AppId/-ClientId/-ClientSecret to skip API auth."
        }

        # Get server client credentials from config.js
        Write-Host "Fetching server client credentials..."
        try {
            $configJs = (Invoke-WebRequest -Uri "$VFServerHost/config.js" -UseBasicParsing).Content
            $serverClientId = ($configJs | Select-String -Pattern "CLIENT_ID.*?'([^']+)'" | ForEach-Object { $_.Matches[0].Groups[1].Value })
            $serverClientSecret = ($configJs | Select-String -Pattern "CLIENT_SECRET.*?'([^']+)'" | ForEach-Object { $_.Matches[0].Groups[1].Value })

            if (-not $serverClientId -or -not $serverClientSecret) {
                Fail "Could not parse CLIENT_ID/CLIENT_SECRET from $VFServerHost/config.js"
            }
            Write-Host "  Server Client ID: $serverClientId"
        }
        catch {
            Fail "Failed to reach vFunction server at $VFServerHost/config.js - $_"
        }

        # Get access token
        Write-Host "Authenticating..."
        $tokenBody = @{
            client_id     = $serverClientId
            client_secret = $serverClientSecret
            username      = $VFEmail
            password      = $VFPassword
            grant_type    = "password"
            realm         = "users"
        }
        try {
            $tokenResponse = Invoke-RestMethod -Uri "$VFServerHost/token" -Method Post -Body $tokenBody -ContentType "application/x-www-form-urlencoded"
            $accessToken = $tokenResponse.access_token
            if (-not $accessToken) {
                Fail "Authentication succeeded but no access_token in response."
            }
            Write-Host "  Authenticated successfully." -ForegroundColor Green
        }
        catch {
            Fail "Authentication failed: $_"
        }

        $authHeaders = @{
            "Authorization" = "Bearer $accessToken"
            "Content-Type"  = "application/json"
        }

        # ---- Resolve the organization UUID automatically ------------------
        if (-not $OrgId) {
            Write-Host "Resolving organization id from $VFServerHost/api/v1/organizations/all ..."
            try {
                $orgsResponse = Invoke-RestMethod -Uri "$VFServerHost/api/v1/organizations/all" `
                    -Method Get -Headers $authHeaders -ErrorAction Stop

                # orgsResp wraps the list under "organizations"; tolerate a bare array too.
                $orgList = $null
                if ($orgsResponse.organizations) { $orgList = $orgsResponse.organizations }
                elseif ($orgsResponse -is [System.Array]) { $orgList = $orgsResponse }
                else { $orgList = @($orgsResponse) }
                $orgList = @($orgList | Where-Object { $_ })

                if ($orgList.Count -eq 0) {
                    Write-Warning "orgList returned no organizations for this account."
                }
                elseif ($orgList.Count -eq 1) {
                    $OrgId = $orgList[0].uuid
                    Write-Host "  Using the account's only organization: '$($orgList[0].name)' ($OrgId)" -ForegroundColor Green
                }
                else {
                    # Multiple orgs: try to disambiguate by name, else take the first.
                    $preferred = $orgList | Where-Object { $_.name -and ($_.name -ieq $VFAppName -or $_.name -like '*OMS*') } | Select-Object -First 1
                    if (-not $preferred) { $preferred = $orgList | Select-Object -First 1 }
                    $OrgId = $preferred.uuid
                    Write-Host "  Multiple organizations found; selected '$($preferred.name)' ($OrgId)." -ForegroundColor Green
                    Write-Host "  (Pass -OrgId to choose a different one.)" -ForegroundColor Yellow
                }
            }
            catch {
                Write-Warning "Could not resolve organization id automatically from orgList: $_"
            }
        }
        else {
            Write-Host "Using organization id supplied via -OrgId: $OrgId" -ForegroundColor Green
        }

        if (-not $OrgId) {
            Fail "Could not determine an organization id. The account '$VFEmail' may not administer any organization. Verify the login, or pass -OrgId explicitly."
        }

        # ---- Create application -------------------------------------------
        # runtime lives INSIDE data (data.runtime); the server defaults to Java
        # if it is not set at creation time.
        Write-Host "Creating application '$VFAppName' with runtime '$Runtime'..."
        $createBody = @{
            data = @{
                name              = $VFAppName
                runtime           = $Runtime
                clustering_params = @{
                    min_func_merge_thresh         = 0
                    min_var_merge_thresh          = 0
                    min_runtime                   = 0
                    max_runtime                   = 0
                    classes_inclusions            = @($IncludeClasses)
                    classes_exclusions            = @()
                    common_library                = $true
                    max_method_n_nodes            = 0
                    min_pure_static_tree_size     = 0
                    enable_auto_refactor          = $true
                    ignore_read_only_transactions = $true
                    ignore_db_connection_string   = $false
                    skip_undetectable_packages    = $false
                    pause_static                  = $false
                    experimental_features_data    = ""
                }
            }
            organization = $OrgId
        } | ConvertTo-Json -Depth 6 -Compress

        try {
            $createResponse = Invoke-RestMethod -Uri "$VFServerHost/api/v1/organizations/applications/create" `
                -Method Post -Body $createBody -Headers $authHeaders

            $createdApp = $createResponse
            if ($createResponse.app) { $createdApp = $createResponse.app }

            $AppId    = $createdApp.uuid
            $ClientId = $createdApp.client_id

            if (-not $AppId) {
                Fail "Application create call returned no app uuid. Response: $($createResponse | ConvertTo-Json -Depth 5 -Compress)"
            }

            Write-Host "  Application created:" -ForegroundColor Green
            Write-Host "    OrgId:        $OrgId"
            Write-Host "    AppId:        $AppId"
            if ($ClientId) { Write-Host "    ClientId:     $ClientId" }
        }
        catch {
            Write-Warning "Failed to create application: $_"
            Write-Host ""
            Write-Host "Please provide the UUIDs manually from the vFunction UI:" -ForegroundColor Yellow
            $AppId = Read-Host "  Enter app_id (uuid)"
            $ClientId = Read-Host "  Enter client_id"
            $ClientSecret = Read-Host "  Enter client_secret"
        }

        # Retrieve the controller install params (CLIENT_SECRET etc.)
        if ($AppId -and (-not $ClientId -or -not $ClientSecret)) {
            Write-Host "Retrieving controller install params (client credentials)..."
            $confReqBody = @{ uuid = $AppId; organization = $OrgId } | ConvertTo-Json -Compress
            try {
                $confResp = Invoke-RestMethod -Uri "$VFServerHost/api/v1/organizations/applications/controllerconf" `
                    -Method Post -Body $confReqBody -Headers $authHeaders -ErrorAction Stop
                if (-not $ClientId)     { $ClientId     = $confResp.CLIENT_ID;     if (-not $ClientId)     { $ClientId     = $confResp.client_id } }
                if (-not $ClientSecret) { $ClientSecret = $confResp.CLIENT_SECRET; if (-not $ClientSecret) { $ClientSecret = $confResp.client_secret } }
                if ($ClientSecret) {
                    Write-Host "  Retrieved client credentials from controllerconf." -ForegroundColor Green
                }
            }
            catch {
                Write-Host "  (Could not auto-retrieve controller conf: $_)" -ForegroundColor Yellow
            }
            if (-not $ClientId)     { $ClientId     = Read-Host "  Enter client_id" }
            if (-not $ClientSecret) { $ClientSecret = Read-Host "  Enter client_secret" }
        }

        if (-not $OrgId -or -not $AppId -or -not $ClientId -or -not $ClientSecret) {
            Fail "Missing required vFunction UUIDs. Cannot proceed."
        }

        # Verify the application was created with the .NET runtime (not Java default).
        try {
            $appCheck = Invoke-RestMethod -Uri "$VFServerHost/api/v1/organizations/applications/$AppId" `
                -Method Get -Headers $authHeaders
            $actualRuntime = $appCheck.data.runtime
            if (-not $actualRuntime -and $appCheck.app) { $actualRuntime = $appCheck.app.data.runtime }
            if ($actualRuntime) {
                if ("$actualRuntime".ToLower() -eq $Runtime.ToLower() -or "$actualRuntime".ToLower() -like "*net*") {
                    Write-Host "  Verified application runtime: $actualRuntime" -ForegroundColor Green
                }
                else {
                    Write-Warning "Application runtime is '$actualRuntime', not the .NET runtime you requested ('$Runtime')."
                    Write-Warning "In the vFunction UI, delete this app and re-run with the correct value, e.g. -Runtime '.NET' or -Runtime 'dotnet_framework'."
                }
            }
            else {
                Write-Host "  (Could not read back runtime to verify; continuing.)" -ForegroundColor Yellow
            }
        }
        catch {
            Write-Host "  (Runtime verification call failed; continuing.) $_" -ForegroundColor Yellow
        }

        # Set clustering params for the OMS application
        Write-Host "Configuring clustering parameters..."
        $clusteringBody = @{
            organization = $OrgId
            uuid         = $AppId
            data         = @{
                clustering_params = @{
                    min_var_merge_thresh          = 15
                    min_func_merge_thresh         = 15
                    min_runtime                   = 0.1
                    max_runtime                   = 15
                    granularity                   = 0.5
                    shared_service_extraction     = 0.5
                    inter_service_communication   = 0.5
                    domain_based_merging          = 0.5
                    min_service_size              = -1
                    max_method_n_nodes            = 6
                    classes_inclusions            = @($IncludeClasses)
                    classes_exclusions            = @()
                    excluded_jars                 = @()
                    common_library                = $true
                    min_pure_static_tree_size     = -1
                    enable_auto_refactor          = $false
                    enable_flow_mixer             = $false
                    pause_static                  = $false
                    infra_package_threshold       = 85
                    experimental_features_data    = ""
                    enable_infra_nominator_gnn    = $true
                    ignore_read_only_transactions = $true
                    ignore_db_connection_string   = $false
                    pep_nomination                = $null
                    skip_undetectable_packages    = $false
                }
            }
        } | ConvertTo-Json -Depth 5 -Compress

        try {
            Invoke-RestMethod -Uri "$VFServerHost/api/v1/organizations/applications/clusteringparams" `
                -Method Post -Body $clusteringBody -Headers $authHeaders | Out-Null
            Write-Host "  Clustering parameters configured." -ForegroundColor Green
        }
        catch {
            Write-Warning "Failed to set clustering params (non-fatal): $_"
        }
    }

    # -----------------------------------------------------------------------
    # STEP 10c: Install Dynamic Agent (Runtime/.NET Profiler)
    # -----------------------------------------------------------------------
    if (-not $SkipDynamic) {
        Write-Step "Step 10c: Installing vFunction Dynamic Agent (instance: $dynamicInstance)"

        $createInstanceScript = Join-Path $VFBaseDir "controller-installation\create-instance.ps1"
        $instanceDir = Join-Path $VFBaseDir "config\installation\instances\$dynamicInstance"

        if (-not (Test-Path $instanceDir)) {
            if (Test-Path $createInstanceScript) {
                Write-Host "Creating dynamic agent instance: $dynamicInstance"
                & $createInstanceScript -instance $dynamicInstance -type dotnet
            }
        }

        $dynamicYaml = Join-Path $instanceDir "installation.yaml"

        $yamlContent = @"
controller:
  name: $ControllerName
  host: $VFServerHost
  org_id: $OrgId
  app_id: $AppId
  client_id: $ClientId
  client_secret: $ClientSecret
  type: dotnet
  instrconf_additions:
    inclusions:
      - $IncludeClasses
    exclusions: []
  tags:
    - oms-net

agent:
  version: framework
  environment: iis
"@

        Write-Host "Writing dynamic agent installation.yaml..."
        if (-not (Test-Path $instanceDir)) {
            New-Item -ItemType Directory -Path $instanceDir -Force | Out-Null
        }
        Set-Content -Path $dynamicYaml -Value $yamlContent -Encoding UTF8
        Write-Host "  Written to: $dynamicYaml" -ForegroundColor Green

        Write-Host "Running vFunction dynamic agent install script..."
        $installScript = Join-Path $VFBaseDir "controller-installation\install.ps1"
        & powershell -NoProfile -ExecutionPolicy Unrestricted -Command "& '$installScript' -instance $dynamicInstance"

        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Dynamic agent install script returned exit code: $LASTEXITCODE"
        }
        else {
            Write-Host "Dynamic agent installed successfully." -ForegroundColor Green
        }
    }
    else {
        Write-Step "Step 10c: Skipping Dynamic Agent installation (SkipDynamic flag set)"
    }

    # -----------------------------------------------------------------------
    # STEP 10d: Install Viper (Static Analysis) Agent
    # -----------------------------------------------------------------------
    if (-not $SkipViper) {
        Write-Step "Step 10d: Installing vFunction Viper/Static Agent (instance: $viperInstance)"

        $createInstanceScript = Join-Path $VFBaseDir "controller-installation\create-instance.ps1"
        $viperInstanceDir = Join-Path $VFBaseDir "config\installation\instances\$viperInstance"

        if (Test-Path $createInstanceScript) {
            Write-Host "Creating viper instance: $viperInstance"
            & $createInstanceScript -instance $viperInstance -viperMode true -type dotnet
        }

        $viperYaml = Join-Path $viperInstanceDir "installation.yaml"

        $viperYamlContent = @"
controller:
  name: $ControllerName-viper
  host: $VFServerHost
  org_id: $OrgId
  app_id: $AppId
  client_id: $ClientId
  client_secret: $ClientSecret
  type: dotnet
  tags:
    - oms-net

server_application:
  name: $VFAppName
  include_classes: '$IncludeClasses'

viper:
  assemblies:
    - $($AssembliesPath -replace '\\', '/')
  stored_procedure:
    db_provider: sqlserver
    db_connection_string: 'Server=$SqlInstance;Database=$DatabaseName;Trusted_Connection=True;'
"@

        Write-Host "Writing viper installation.yaml..."
        if (-not (Test-Path $viperInstanceDir)) {
            New-Item -ItemType Directory -Path $viperInstanceDir -Force | Out-Null
        }
        Set-Content -Path $viperYaml -Value $viperYamlContent -Encoding UTF8
        Write-Host "  Written to: $viperYaml" -ForegroundColor Green

        Write-Host "Running vFunction viper install script..."
        $installScript = Join-Path $VFBaseDir "controller-installation\install.ps1"
        & powershell -NoProfile -ExecutionPolicy Unrestricted -Command "& '$installScript' -instance $viperInstance"

        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Viper install script returned exit code: $LASTEXITCODE"
        }
        else {
            Write-Host "Viper agent installed successfully." -ForegroundColor Green
        }
    }
    else {
        Write-Step "Step 10d: Skipping Viper/Static Agent installation (SkipViper flag set)"
    }

    # -----------------------------------------------------------------------
    # STEP 10e: Hook the Dynamic Agent into the IIS Application Pool
    # -----------------------------------------------------------------------
    if (-not $SkipDynamic) {
        Write-Step "Step 10e: Hooking vFunction agent into IIS Application Pool '$AppPoolName'"

        Import-Module WebAdministration -ErrorAction Stop

        if (-not (Test-Path "IIS:\AppPools\$AppPoolName")) {
            Fail "Application Pool '$AppPoolName' does not exist. The deployment phase should have created it."
        }

        $confJsonPath = Join-Path $VFBaseDir "config\agent\instances\$dynamicInstance\conf.json"
        $agentDll64 = Join-Path $VFBaseDir "agent\vfagent.net.dll"
        $agentDll32 = Join-Path $VFBaseDir "agent\vfagent.net.x86.dll"

        $envVars = @{
            "VF_AGENT_CONF_LOCATION" = $confJsonPath
            "COR_PROFILER_PATH_64"   = $agentDll64
            "COR_PROFILER_PATH_32"   = $agentDll32
            "COR_ENABLE_PROFILING"   = "1"
            "COR_PROFILER"           = "{cd7d4b53-96c8-4552-9c11-6e41df8eab8a}"
            "COMPlus_TailCallOpt"    = "0"
        }

        $filter = "system.applicationHost/applicationPools/add[@name='$AppPoolName']/environmentVariables"

        Write-Host "Clearing any existing vFunction environment variables from the App Pool..."
        foreach ($varName in $envVars.Keys) {
            try {
                Remove-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST' `
                    -filter $filter -name "." `
                    -AtElement @{name = $varName} -ErrorAction SilentlyContinue
            }
            catch { }
        }

        Write-Host "Adding vFunction profiler environment variables to App Pool..."
        foreach ($entry in $envVars.GetEnumerator()) {
            Write-Host "  $($entry.Key) = $($entry.Value)"
            Add-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST' `
                -filter $filter -name "." `
                -value @{ name = $entry.Key; value = $entry.Value }
        }

        Write-Host ""
        Write-Host "Environment variables set." -ForegroundColor Green

        Write-Host "Restarting Application Pool '$AppPoolName'..."
        Restart-WebAppPool -Name $AppPoolName
        Write-Host "Application Pool restarted." -ForegroundColor Green
    }
    else {
        Write-Step "Step 10e: Skipping IIS hook (SkipDynamic flag set)"
    }

    # -----------------------------------------------------------------------
    # STEP 10f: Verify vFunction agent and warm up
    # -----------------------------------------------------------------------
    Write-Step "Step 10f: vFunction Verification"

    Write-Host "Checking installed components..." -ForegroundColor Yellow

    $confJson = Join-Path $VFBaseDir "config\agent\instances\$dynamicInstance\conf.json"
    if (Test-Path $confJson) {
        Write-Host "  [OK] Dynamic agent conf.json exists: $confJson" -ForegroundColor Green
    }
    else {
        Write-Host "  [!!] Dynamic agent conf.json NOT found at: $confJson" -ForegroundColor Red
    }

    $viperService = Get-Service -Name "*viper*" -ErrorAction SilentlyContinue
    if ($viperService) {
        Write-Host "  [OK] Viper service found: $($viperService.Name) (Status: $($viperService.Status))" -ForegroundColor Green
    }
    else {
        $viperProcess = Get-Process -Name "*viper*" -ErrorAction SilentlyContinue
        if ($viperProcess) {
            Write-Host "  [OK] Viper process running (PID: $($viperProcess.Id))" -ForegroundColor Green
        }
        else {
            Write-Host "  [INFO] Viper service/process not detected (it may start on next controller check-in)" -ForegroundColor Yellow
        }
    }

    $agentDllPath = Join-Path $VFBaseDir "agent\vfagent.net.dll"
    if (Test-Path $agentDllPath) {
        Write-Host "  [OK] Agent DLL exists: $agentDllPath" -ForegroundColor Green
    }
    else {
        Write-Host "  [!!] Agent DLL NOT found at: $agentDllPath" -ForegroundColor Red
    }

    if (-not $SkipDynamic) {
        Import-Module WebAdministration -ErrorAction SilentlyContinue
        $profiling = Get-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST' `
            -filter "system.applicationHost/applicationPools/add[@name='$AppPoolName']/environmentVariables" `
            -name "." -ErrorAction SilentlyContinue
        if ($profiling) {
            Write-Host "  [OK] App Pool '$AppPoolName' has environment variables configured" -ForegroundColor Green
        }
    }

    # Warm up the application to trigger profiling
    Write-Host ""
    Write-Host "Warming up the application to initialize the agent..." -ForegroundColor Yellow
    try {
        Invoke-WebRequest -Uri "http://${HostHeader}:${Port}/" -UseBasicParsing -TimeoutSec 30 | Out-Null
        Write-Host "  Application responded - agent should begin collecting data." -ForegroundColor Green
    }
    catch {
        try {
            Invoke-WebRequest -Uri "http://localhost:8080/" -UseBasicParsing -TimeoutSec 30 | Out-Null
            Write-Host "  Application responded on port 8080 - agent should begin collecting data." -ForegroundColor Green
        }
        catch {
            Write-Host "  Could not reach the application. Browse to it manually to trigger the agent." -ForegroundColor Yellow
        }
    }

    # -----------------------------------------------------------------------
    # vFunction Summary
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=====================================================" -ForegroundColor Green
    Write-Host " vFUNCTION AGENT INSTALLATION COMPLETE" -ForegroundColor Green
    Write-Host "=====================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "vFunction Server:    $VFServerHost" -ForegroundColor White
    Write-Host "Application:         $VFAppName" -ForegroundColor White
    Write-Host "Controller Name:     $ControllerName" -ForegroundColor White
    Write-Host "Base Directory:      $VFBaseDir" -ForegroundColor White
    Write-Host ""
    if (-not $SkipDynamic) {
        Write-Host "Dynamic Agent:" -ForegroundColor White
        Write-Host "  Instance:          $dynamicInstance" -ForegroundColor White
        Write-Host "  App Pool:          $AppPoolName" -ForegroundColor White
        Write-Host "  Conf:              $confJson" -ForegroundColor White
    }
    if (-not $SkipViper) {
        Write-Host "Viper (Static):" -ForegroundColor White
        Write-Host "  Instance:          $viperInstance" -ForegroundColor White
        Write-Host "  Assemblies Path:   $AssembliesPath" -ForegroundColor White
    }
    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor Yellow
    Write-Host "  1. Open the vFunction Server UI at $VFServerHost" -ForegroundColor Yellow
    Write-Host "  2. Navigate to the '$VFAppName' application" -ForegroundColor Yellow
    Write-Host "  3. Go to Learning > Select Controllers and verify the controller appears" -ForegroundColor Yellow
    Write-Host "  4. Start Learning and exercise the application (use script\use-apis-net.sh)" -ForegroundColor Yellow
    Write-Host "  5. After collecting enough data, stop Learning and run Analysis" -ForegroundColor Yellow
    Write-Host ""
}
