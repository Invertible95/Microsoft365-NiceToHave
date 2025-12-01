<#
.SYNOPSIS
    Identifies and reports on inactive Microsoft Entra Enterprise Applications.

.DESCRIPTION
    Connects to Microsoft Graph API using app registration credentials to retrieve
    Enterprise Applications and their sign-in activity. Helps identify unused
    applications that may pose security risks.

.PARAMETER TenantId
    Microsoft Entra tenant ID (required)

.PARAMETER ClientId
    Application (client) ID for authentication (required)

.PARAMETER ClientSecret
    Client secret (defaults to $env:CLIENT_SECRET_EAPPS)

.PARAMETER OutputFilePath
    Path for Excel export (default: C:\Temp\Enterprise Application sign-in activity.xlsx)

.PARAMETER ExportExcel
    Export results to Excel instead of console output

.NOTES
    Author         : Victor Uhrberg
    Date           : 2025-10-17
    Prerequisites  : PowerShell 7.x, ImportExcel module
    Permissions    : Application.Read.All, AuditLog.Read.All, Directory.Read.All

.EXAMPLE
    $env:CLIENT_SECRET_EAPPS = "your-secret"
    .\Get-InactiveEnterpriseApplications.ps1 -TenantId "tenant-id" -ClientId "client-id" -ExportExcel

.LINK
    https://github.com/Invertible95/Microsoft365-NiceToHave
#>

[CmdletBinding()]
param (

    [Parameter(Mandatory = $true)]
    [string]$TenantId,

    [Parameter(Mandatory = $true)]
    [string]$ClientId,

    [string]$ClientSecret = $env:CLIENT_SECRET_EAPPS,

    [Parameter(Mandatory = $false)]
    [string]$OutputFilePath = "C:\Temp\Enterprise Application sign-in activity.xlsx",

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
        "`$top=999&" +
        "`$filter=servicePrincipalType eq 'Application' and (tags/any(tag: tag eq 'WindowsAzureActiveDirectoryIntegratedApp'))&" +
        "`$select=appid,id,displayName,createdDateTime,signInActivity"

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
function Get-SignInActivityBulk {
    [CmdletBinding()]
    param()
    
    try {
        Write-Host "Retrieving sign-in activity data..." -ForegroundColor Yellow
        
        # Use REST API with your existing authentication
        $signInActivityUrl = "https://graph.microsoft.com/beta/reports/servicePrincipalSignInActivities?`$top=999"
        
        $allSignInActivity = @()
        
        # Get first page
        $response = Invoke-RestMethod -Method GET -Uri $signInActivityUrl -Headers $global:headers -ErrorAction Stop
        $allSignInActivity += $response.value
        
        # Handle pagination
        while ($response.'@odata.nextLink') {
            $response = Invoke-RestMethod -Method GET -Uri $response.'@odata.nextLink' -Headers $global:headers -ErrorAction Stop
            $allSignInActivity += $response.value
        }
        
        # Build a hashtable for quick lookups by appId
        $activityLookup = @{}
        foreach ($activity in $allSignInActivity) {
            if ($activity.appId) {
                $activityLookup[$activity.appId] = $activity
            }
        }
        
        Write-Host "Found sign-in activity for $($activityLookup.Count) applications" -ForegroundColor Green
        return $activityLookup
    }
    catch {
        Write-Warning "Failed to retrieve sign-in activity: $_"
        return @{}
    }
}

function Get-DelegatedPermissions {
    param (
        [Parameter(Mandatory = $true)]
        [string]$appId
    )
    
    try {
        $delegatedPermissionsUrl = "https://graph.Microsoft.com/v1.0/servicePrincipals/$appId/oauth2PermissionGrants"
        $delegatedPermissions = Invoke-RestMethod -Method GET -Uri $delegatedPermissionsUrl -Headers $global:headers 
        
        $allDelegatedScopes = @()
        foreach ($grant in $delegatedPermissions.value) {
            if ($grant.scope) {
                $scopeArray = $grant.scope.Trim().Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries)
                $allDelegatedScopes += $scopeArray
            }
        }
        return $allDelegatedScopes
    }
    catch {
        Write-Warning "Failed to get permissions for app $appId':' $_"
        return @()
    }
}

Connect-toGraph

$results = @()

$applications = Get-EnterpriseApps
$signInActivityLookup = Get-SignInActivityBulk

Write-Host "Processing $($applications.Count) applications..." -ForegroundColor Cyan
$counter = 0

foreach ($app in $applications) {
    $counter++
    $percentComplete = [math]::Round(($counter / $applications.Count) * 100, 1)
    
    Write-Progress -Activity "Analyzing Enterprise Applications" `
        -Status "Processing: $($app.DisplayName) ($counter of $($applications.Count))" `
        -PercentComplete $percentComplete

    # Look up sign-in activity
    $lastSignInDateTime = $null
    if ($signInActivityLookup.ContainsKey($app.AppId)) {
        $signInActivity = $signInActivityLookup[$app.AppId]
        
        # Get the most recent sign-in from various activity types
        $lastSignInDateTime = $signInActivity.LastSignInActivity.LastSignInDateTime ?? 
        $signInActivity.DelegatedClientSignInActivity.LastSignInDateTime ??
        $signInActivity.DelegatedResourceSignInActivity.LastSignInDateTime ??
        $signInActivity.ApplicationAuthenticationClientSignInActivity.LastSignInDateTime ??
        $null
    }

    # Calculate days since last sign-in
    $daysSinceLastSignIn = if ($lastSignInDateTime) { 
        [math]::Round((New-TimeSpan -Start $lastSignInDateTime -End (Get-Date)).TotalDays)
    }
    else { 
        "Never Signed In" 
    }

    # Get delegated permissions
    $allDelegatedScopes = Get-DelegatedPermissions -appId $app.Id

    # Output the application details
    $Output = [PSCustomObject]@{
        AppName              = $app.DisplayName
        AppId                = $app.AppId
        CreatedDate          = $app.CreatedDateTime
        LastSignInDate       = $lastSignInDateTime
        DaysSinceLastSignIn  = $daysSinceLastSignIn
        DelegatedPermissions = $allDelegatedScopes -join ', '
    }

    $results += $Output
}

# Export results to Excel or display in console
if ($ExportExcel) {
    $results | Export-Excel -Path $OutputFilePath -WorksheetName "InactiveEnterpriseApps" -TableStyle Light1 -AutoSize -Title "Enterprise Application Sign-In Activity" -Show
}
else {
    $results | Format-Table -AutoSize

    Write-Host "Seeing alot of apps in your console? Use -ExportExcel switch to export results to an Excel file. `nExporting to Excel also shows additional details and is easier to analyze." -ForegroundColor Yellow
}