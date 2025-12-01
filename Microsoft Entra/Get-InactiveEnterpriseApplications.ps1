<#
.SYNOPSIS
    Identifies and reports on inactive Microsoft Entra Enterprise Applications.

.DESCRIPTION
    This script connects to Microsoft Graph API and retrieves all Enterprise Applications
    in a Microsoft Entra tenant. It then collects information about each application,
    including when it was last accessed and what delegated permissions it has.
    
    The script helps identify potentially unused applications that may pose security risks.

.PARAMETER TenantId
    The Microsoft Entra tenant ID (required)

.PARAMETER ClientId
    The application (client) ID for authentication (required)

.PARAMETER OutputFilePath
    Path for Excel export file (default: C:\Temp\InactiveEnterpriseApps.xlsx)

.PARAMETER ExportExcel
    Switch to export results to Excel file instead of console output

.NOTES
    File Name      : Get-InactiveEnterpriseApplications.ps1
    Author         : Victor Uhrberg
    Date           : 2025-10-17
    Prerequisite   : Requires Powershell 7.x and the following modules:
                     Microsoft.Graph.Authentication
                     Microsoft.Graph.Applications
                     ImportExcel
                     Microsoft Graph API access with appropriate permissions
                     This script uses an app registration for authentication.
                     Environment variable CLIENT_SECRET_EAPPS must be set with the client secret
    Required Permissions: Application.Read.All, AuditLog.Read.All, Directory.Read.All

.EXAMPLE
    # Set environment variable first
    $env:CLIENT_SECRET_EAPPS = "your-client-secret"
    
    # Basic usage with console output
    .\Get-InactiveEnterpriseApplications.ps1 -TenantId "your-tenant-id" -ClientId "your-client-id"

.EXAMPLE
    # Export to Excel file
    .\Get-InactiveEnterpriseApplications.ps1 -TenantId "your-tenant-id" -ClientId "your-client-id" -ExportExcel

.OUTPUTS
    PSCustomObject with the following properties:
    - AppName: Display name of the enterprise application
    - AppId: Application ID
    - CreatedDate: When the application was created
    - LastSignInDate: When the application was last accessed
    - DaysSinceLastSignIn: Number of days since last sign-in or "Never Signed In"
    - DelegatedPermissions: Comma-separated list of delegated permissions

.LINK
    GitHub Repository:
    https://github.com/Invertible95/Microsoft365-NiceToHave
    
    ServicePrincipal resource:
    https://learn.microsoft.com/en-us/graph/api/resources/serviceprincipal
    
    SignInActivity API:
    https://learn.microsoft.com/en-us/graph/api/serviceprincipalsigninactivity-get?view=graph-rest-beta&tabs=http
#>

[CmdletBinding()]
param (

    [Parameter(Mandatory = $true)]
    [string]$TenantId,

    [Parameter(Mandatory = $true)]
    [string]$ClientId,

    [string]$ClientSecret = $env:CLIENT_SECRET_EAPPS,

    [Parameter(Mandatory = $false)]
    [string]$OutputFilePath = "C:\Temp\InactiveEnterpriseApps.xlsx",

    [Parameter(Mandatory = $false)]
    [switch]$ExportExcel
)

# Initialize global variables
$global:tokenResponse = $null
$global:headers = @{}

function Show-RestApiConnectionStatus {
    param(
        [string]$TenantId,
        [string]$ClientId
    )

    if ($global:headers -and $global:headers.Authorization) {
        Write-Host "Connected to Microsoft Graph REST API:" -ForegroundColor Green
        Write-Host "Tenant ID: $TenantId" -ForegroundColor Yellow
        Write-Host "Client ID: $ClientId" -ForegroundColor Yellow
        Write-Host "Auth Method: Client Credentials (App Registration)" -ForegroundColor Yellow
        Write-Host "Token Status: Active" -ForegroundColor Green
    }
    else {
        Write-Host "Not connected to Microsoft Graph REST API" -ForegroundColor Red
    }
}
function Connect-toGraph {
    [CmdletBinding()]
    param()
    
    try {
        Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Yellow
        
        $tokenBody = @{
            Grant_Type    = "client_credentials"
            Scope         = "https://graph.microsoft.com/.default"
            Client_Id     = $script:ClientId
            Client_Secret = $script:ClientSecret
        }
        
        $global:tokenResponse = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$script:TenantId/oauth2/v2.0/token" -Method POST -Body $tokenBody -ErrorAction Stop
        
        $global:headers = @{
            "Authorization" = "Bearer $($global:tokenResponse.access_token)"
            "Content-type"  = "application/json"
        }
        
        Write-Host "Successfully connected to Microsoft Graph" -ForegroundColor Green
        Show-RestApiConnectionStatus -TenantId $script:TenantId -ClientId $script:ClientId
    }
    catch {
        Write-Error "Failed to connect to Microsoft Graph: $_"
        exit 1
    }
}

function Get-EnterpriseApps {
    [CmdletBinding()]
    param()
    
    try {
        Write-Host "Retrieving Enterprise Applications..." -ForegroundColor Yellow
        
        # Define the initial URL for fetching Enterprise Apps
        $URLGetApplications = "https://graph.microsoft.com/beta/servicePrincipals?" +
        "`$top=300&" +
        "`$filter=servicePrincipalType eq 'Application' and (tags/any(tag: tag eq 'WindowsAzureActiveDirectoryIntegratedApp'))&" +
        "`$select=appid,id,displayName,createdDateTime"

        # Initialize an array to store all Enterprise Apps
        $allApplications = @()
        
        # Retrieve the first page of Enterprise Apps
        $Applications = Invoke-RestMethod -Method GET -Uri $URLGetApplications -Headers $global:headers -ErrorAction Stop

        # Add the Enterprise Apps from the first page to the result array
        $allApplications += $Applications.value

        # Handle pagination
        while ($Applications.'@odata.nextLink') {
            
            $Applications = Invoke-RestMethod -Method GET -Uri $Applications.'@odata.nextLink' -Headers $global:headers -ErrorAction Stop
            
            # Add applications to result array
            $allApplications += $Applications.value
        }

        Write-Host "Found $($allApplications.Count) Enterprise Applications" -ForegroundColor Green
        return $allApplications
    }
    catch {
        Write-Error "Failed to retrieve Enterprise Applications: $_"
        return @()
    }
}

function Get-SignInActivity {
    param (
        [Parameter(Mandatory = $true)]
        [string]$appId
    )

    try {
        # Get the last sign-in date for the application
        $lastSignInUrl = "https://graph.microsoft.com/beta/reports/servicePrincipalSignInActivities?`$filter=appId eq '$($appId)'"
        $lastSignInResponse = Invoke-RestMethod -Method GET -Uri $lastSignInUrl -Headers $headers

        # Extract the actual date from the response properly
        # Reason: beta/reports/servicePrincipalSignInActivities is a new API endpoint and returns an array of sign-in activities
        $lastSignInDateTime = $null
        if ($lastSignInResponse.value -and $lastSignInResponse.value.Count -gt 0) {
            $signInActivity = $lastSignInResponse.value[0].lastSignInActivity
            if ($signInActivity -and $signInActivity.lastSignInDateTime) {
                $lastSignInDateTime = $signInActivity.lastSignInDateTime
            }
        }
    }
    catch {
        # Some apps may not have sign-in logs available
        Write-Verbose "No sign-in data available for app $AppId"
        return $null
    }

    return $lastSignInDateTime
}

function Get-DelegatedPermissions {
    param (
        [Parameter(Mandatory = $true)]
        [string]$appId
    )
    $delegatedPermissionsUrl = "https://graph.microsoft.com/beta/servicePrincipals/$($appId)/oauth2PermissionGrants"
    $delegatedPermissions = Invoke-RestMethod -Method GET -Uri $delegatedPermissionsUrl -Headers $headers
    
    # Collect ALL scopes from ALL permission grants
    $allDelegatedScopes = @()
    foreach ($grant in $delegatedPermissions.value) {
        if ($grant.scope) {
            # Split the scope string and add individual permissions
            $scopeArray = $grant.scope.Trim().Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries)
            $allDelegatedScopes += $scopeArray
        }
    }
    return $allDelegatedScopes
}

Connect-toGraph

$results = @()

$applications = Get-EnterpriseApps

foreach ($app in $applications) {
    $appId = $app.appid
    $appName = $app.displayName
    $appCreatedDate = $app.createdDateTime

    # Get the last sign-in date for the application
    $lastSignInDateTime = Get-SignInActivity -appId $appId

    # Calculate the number of days since the last sign-in
    $daysSinceLastSignIn = if ($lastSignInDateTime) { 
        (New-TimeSpan -Start (Get-Date $lastSignInDateTime) -End (Get-Date)).Days 
    }
    else { 
        "Never Signed In" 
    }

    # Get delegated permissions
    $allDelegatedScopes = Get-DelegatedPermissions -appId $app.Id

    # Output the application details
    $Output = [PSCustomObject]@{
        AppName              = $appName
        AppId                = $appId
        CreatedDate          = $appCreatedDate
        LastSignInDate       = $lastSignInDateTime
        DaysSinceLastSignIn  = $daysSinceLastSignIn
        DelegatedPermissions = $allDelegatedScopes -join ', '
    }

    $results += $Output
}

# Export results to Excel or display in console
if ($ExportExcel) {
    $results | Export-Excel -Path $OutputFilePath -WorksheetName "InactiveEnterpriseApps" -TableStyle Light1 -AutoSize -Title "Inactive Enterprise Applications" -Show
}
else {
    $results | Format-Table -AutoSize

    Write-Host "Seeing alot of apps in your console? Use -ExportExcel switch to export results to an Excel file. `nExporting to Excel also shows additional details and is easier to analyze." -ForegroundColor Yellow
}