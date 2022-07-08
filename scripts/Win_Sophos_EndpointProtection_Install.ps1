<#
.SYNOPSIS
    Installs Sophos Endpoint via the Sophos API https://developer.sophos.com/apis

.REQUIREMENTS
    You will need API credentials to use this script.  The instructions are slightly different depending who you are. 
    (Only Step 1 Required For API Credentials)
    For Partners : https://developer.sophos.com/getting-started 
    For Organizations: https://developer.sophos.com/getting-started-organization 
    For Tenants	: https://developer.sophos.com/getting-started-tenant 

.INSTRUCTIONS
    1. Get your API Credentials (Client Id, Client Secret) using the steps in the Requirements section
    2. In SCS RMM, Go to Settings >> Global Settings >> Custom Fields and under Clients, create the following custom fields:
        a) SophosTenantName as type text
        b) SophosClientId as type text
        c) SophosClientSecret as type text
    3. In SCS RMM, Right-click on each client and select Edit.  Fill in the SophosTenantName, SophosClientId, and SophosClientSecret.
       Make sure the SophosTenantName is EXACTLY how it is displayed in your Sophos Partner / Central Dashboard.  A partner can find the list of tenants on the left menu under Sophos Central Customers
    4. Create the follow script arguments
        a) -ClientId {{client.SophosClientId}}
        b) -ClientSecret {{client.SophosClientSecret}}
        c) -TenantName {{client.SophosTenantName}}
        d) -Products (Optional Parameter) - A list of products to install, comma-separated.  Available options are: antivirus, intercept, mdr, deviceEncryption or all.  Example - To install Antivirus, Intercept, and Device encryption you would pass "antivirus,intercept,deviceEncryption".  
		
.NOTES
	V1.0 Initial Release by https://github.com/bc24fl/tacticalrmm-scripts/
	V1.1 Added error handling for each Invoke-Rest Call for easier troubleshooting and graceful exit.
	V1.2 Added support for more than 100 tenants.
    V1.3 Removed Chocolately dependency
	
#>

param(
    $ClientId,
    $ClientSecret,
    $TenantName,
    $Products
)

if ([string]::IsNullOrEmpty($ClientId)) {
    throw "ClientId must be defined. Use -ClientId <value> to pass it."
}

if ([string]::IsNullOrEmpty($ClientSecret)) {
    throw "ClientSecret must be defined. Use -ClientSecret <value> to pass it."
}

if ([string]::IsNullOrEmpty($TenantName)) {
    throw "TenantName must be defined. Use -TenantName <value> to pass it."
}

if ([string]::IsNullOrEmpty($Products)) {
    Write-Output "No product options specified installing default antivirus and intercept."
    $Products = "antivirus,intercept"
}

Write-Output "Running Sophos Endpoint Installation Script On: $env:COMPUTERNAME"

# Set TLS Version for web requests
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Find if workstation or server.  osInfo.ProductType returns 1 = workstation, 2 = domain controller, 3 = server
$osInfo = Get-CimInstance -ClassName Win32_OperatingSystem

$urlAuth = "https://id.sophos.com/api/v2/oauth2/token"
$urlWhoami = "https://api.central.sophos.com/whoami/v1"
$urlTenant = "https://api.central.sophos.com/partner/v1/tenants?pageTotal=true"

$authBody = @{
    "grant_type"    = "client_credentials"
    "client_id"     = $ClientId
    "client_secret" = $ClientSecret
    "scope"         = "token"
}

$authResponse = (Invoke-RestMethod -Method 'post' -Uri $urlAuth -Body $authBody)
$authToken = $authResponse.access_token
$authHeaders = @{Authorization = "Bearer $authToken" }

if ($authToken.length -eq 0) {
    throw "Error, no authentication token received.  Please check your api credentials.  Exiting script."
}

$whoAmIResponse = (Invoke-RestMethod -Method 'Get' -headers $authHeaders -Uri $urlWhoami)
$myId = $whoAmIResponse.Id
$myIdType = $whoAmIResponse.idType

if ($myIdType.length -eq 0) {
    throw "Error, no Whoami Id Type received.  Please check your api credentials or network connections.  Exiting script."
}

if ($myIdType -eq 'partner') {
    $requestHeaders = @{
        'Authorization' = "Bearer $authToken"
        'X-Partner-ID'  = $myId
    }
}
elseif ($myIdType -eq 'organization') {
    $requestHeaders = @{
        'Authorization'     = "Bearer $authToken"
        'X-Organization-ID' = $myId
    }
}
elseif ($myIdType -eq 'tenant') {
    $requestHeaders = @{
        'Authorization' = "Bearer $authToken"
        'X-Tenant-ID'   = $myId
    }
}
else {
    throw "Error finding id type.  This script only supports Partner, Organization, and Tenant API's."
}

# Cycle through all tenants until a tenant match, or all pages have exhausted.  
$currentPage = 1
do {
    Write-Output "Looking for tenant on page $currentPage.  Please wait..."
	
    if ($currentPage -ge 2) {
        Start-Sleep -s 5
        $urlTenant = "https://api.central.sophos.com/partner/v1/tenants?page=$currentPage"
    }
	
    $tenantResponse = (Invoke-RestMethod -Method 'Get' -headers $requestHeaders -Uri $urlTenant)
    $tenants = $tenantResponse.items
    $totalPages	= [int]$tenantResponse.pages.total
	
    foreach ($tenant in $tenants) {
        if ($tenant.name -eq $TenantName) {
            $tenantRegion = $tenant.dataRegion
            $tenantId = $tenant.id
        }
    }
    $currentPage += 1
} until( $currentPage -gt $totalPages -Or ($tenantId.length -gt 1 ) )

if ($tenantId.length -eq 0) {
    throw "Error, no tenant found with the provided name.  Please check the name and try again.  Exiting script."
}

$requestHeaders = @{
    'Authorization' = "Bearer $authToken"
    'X-Tenant-ID'   = $tenantId 
}

$urlEndpoint = "https://api-$tenantRegion.central.sophos.com/endpoint/v1/downloads"
$endpointDownloadResponse = (Invoke-RestMethod -Method 'Get' -headers $requestHeaders -Uri $urlEndpoint)
$endpointInstallers = $endpointDownloadResponse.installers

if ($endpointInstallers.length -eq 0) {
    throw "Error, no installers received.  Please check your api credentials or network connections.  Exiting script."
}

foreach ($installer in $endpointInstallers) {
    
    if ( ($installer.platform -eq "windows") -And ($installer.productName = "Sophos Endpoint Protection") ) {
        
        if ( ($osInfo.ProductType -eq 1) -And ($installer.type = "computer") ) {
            # Workstation Install
            $installUrl = $installer.downloadUrl
        }
        elseif ( ( ($osInfo.ProductType -eq 2) -Or ($osInfo.ProductType -eq 3) ) -And ($installer.type = "server") ) {
            # Server Install
            $installUrl = $installer.downloadUrl
        }
        else {
            throw "Error, this script only supports producttype of 1) Work Station, 2) Domain Controller, or 3) Server."
        }
    }
}

try {
    Write-Output "Checking if Sophos Endpoint installed. Please wait..."

    $software = "Sophos Endpoint Agent";
    $installed = ((Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*).DisplayName -Match $software).Length -gt 0

    if (-Not $installed) {
        Write-Output "Sophos Endpoint is NOT installed. Installing now..."

        Write-Output "Downloading Sophos from $installUrl. Please wait..." 
        $tmpDir = [System.IO.Path]::GetTempPath()
    
        $outpath = "$tmpDir\SophosSetup.exe"
        
        Write-Output "Saving file to $outpath"
        
        Invoke-WebRequest -Uri $installUrl -OutFile $outpath

        Write-Output "Running Sophos Setup... Please wait up to 20 minutes for install to complete." 
        $appArgs = @("--products=" + ($Products -join ","), "--quiet")
        Start-Process -Filepath $outpath -ArgumentList $appArgs

    }
    else {
        Write-Output "Sophos Endpoint is installed.  Skipping installation."
    }
}
catch {
    throw "Installation failed with error message: $($PSItem.ToString())"
}
