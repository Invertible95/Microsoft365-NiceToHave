<#
.SYNOPSIS
    Retrieves Microsoft Entra ID application registrations and monitors client secret expiration dates.

.DESCRIPTION
    This script connects to Microsoft Graph API and retrieves all application registrations 
    from Microsoft Entra ID. It collects comprehensive information about client secrets, 
    including their creation dates, expiration dates, and calculates days until expiry.
    
    The script helps administrators proactively monitor and manage application credentials
    to prevent service disruptions caused by expired secrets. Results can be displayed
    in the console or exported to an Excel file for reporting and tracking purposes.

.PARAMETER ExportExcel
    Switch parameter to export results to an Excel file instead of console output.

.PARAMETER OutputFilePath
    Specifies the path for Excel export file. Default location is C:\Temp\AppRegistrationsInfo.xlsx

.NOTES
    File Name      : FindAppRegistrationsInformation.ps1
    Author         : Victor Uhrberg
    Version        : 2.0
    Date           : 2025-01-03
    Prerequisite   : Microsoft Graph PowerShell SDK modules:
                     - Microsoft.Graph.Authentication
                     - Microsoft.Graph.Applications
                     - ImportExcel (for Excel export functionality)
    
    Required Permissions: Application.Read.All

.EXAMPLE
    .\FindAppRegistrationsInformation.ps1
    
    Displays application registration information in the console, including a summary 
    of applications with secrets and warnings for secrets expiring within 30 days.

.EXAMPLE
    .\FindAppRegistrationsInformation.ps1 -ExportExcel
    
    Exports all application registration and secret information to an Excel file 
    at the default location (C:\Temp\AppRegistrationsInfo.xlsx).

.EXAMPLE
    .\FindAppRegistrationsInformation.ps1 -ExportExcel -OutputFilePath "C:\Reports\AppSecrets.xlsx"
    
    Exports the results to a custom Excel file location for reporting purposes.

.INPUTS
    None. This script does not accept pipeline input.

.OUTPUTS
    PSCustomObject with the following properties:
    - ApplicationName: Display name of the application registration
    - ApplicationId: Unique identifier of the application
    - SecretId: Key ID of the client secret
    - StartDate: When the secret was created
    - EndDate: When the secret expires
    - DaysUntilExpiry: Number of days until the secret expires

.LINK
    GitHub Repository:
    https://github.com/Invertible95/Microsoft365-NiceToHave
    
    Microsoft Graph Applications API:
    https://learn.microsoft.com/en-us/graph/api/resources/application
    
    Microsoft Graph PowerShell SDK:
    https://learn.microsoft.com/en-us/powershell/microsoftgraph/
#>


[CmdletBinding()]

param(

    [Parameter(Mandatory = $false)]
    [switch]
    $ExportExcel,

    [Parameter(Mandatory = $false)]
    [string]
    $OutputFilePath = "C:\Temp\AppRegistrationsInfo.xlsx"
)


# Required Modules
$requiredModules = @(
    "Microsoft.Graph.Authentication",
    "Microsoft.Graph.Applications",
    "ImportExcel"
)

foreach ($module in $requiredModules) {
    # Check if module is already imported
    if (-not (Get-Module -Name $module)) {
        # Check if module is available but not imported
        if (-not (Get-Module -Name $module -ListAvailable)) {
            Write-Host "Installing required module: $module" -ForegroundColor Yellow
            Install-Module -Name $module -Scope CurrentUser -Force -AllowClobber
        }
        
        try {
            Import-Module -Name $module -ErrorAction Stop
            Write-Host "Successfully imported $module" -ForegroundColor Green
        }
        catch {
            Write-Error "Failed to import $module. Error: $_"
            exit 1
        }
    }
}

# Connect to Microsoft Graph if not already connected
$graphConnection = Get-MgContext
if (-not $graphConnection) {
    Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Yellow
    Connect-MgGraph -Scopes "Application.Read.All" -NoWelcome
}
Write-Host "Connected to Microsoft Graph as $($graphConnection.Account)" -ForegroundColor Green


Write-Host "Retrieving application registrations..." -ForegroundColor Yellow
$Applications = Get-MgApplication -All
Write-Host "Found $($Applications.Count) applications." -ForegroundColor Green

$Intel = @()
$Today = (Get-Date).Date
$AppsWithCredentials = @()

foreach ($App in $Applications) {
    $AppName = $App.DisplayName
    $AppId = $App.Id

    $AppCredentials = Get-MgApplication -ApplicationId $AppId | Select-Object PasswordCredentials, KeyCredentials

    $Secrets = $AppCredentials.PasswordCredentials
    $Certs = $AppCredentials.KeyCredentials

    if ($Secrets.Count -gt 0) {
        $AppsWithCredentials += $AppName
    }
    if ($Certs.Count -gt 0) {
        $AppsWithCredentials += $AppName
    }


    foreach ($Secret in $Secrets) {
        $StartDate = $Secret.StartDateTime
        $EndDate = $Secret.EndDateTime
        $SecretName = $Secret.DisplayName

        $Intel += [PSCustomObject]@{
            ApplicationName                 = $AppName
            ApplicationId                   = $AppId
            'Secret Name'                   = $SecretName
            'Secret Start Date'             = $StartDate
            'Secret End Date'               = $EndDate
            'Secret Days Until Expiry'      = ($EndDate - $Today).Days
            'Certificate Name'              = $Null
            'Certificate Start Date'        = $Null
            'Certificate End Date'          = $Null
            'Certificate Days Until Expiry' = $Null
        }
    }

    foreach ($Cert in $Certs) {
        $StartDate = $Cert.StartDateTime
        $EndDate = $Cert.EndDateTime
        $CertName = $Cert.DisplayName

        $Intel += [PSCustomObject]@{
            ApplicationName                 = $AppName
            ApplicationId                   = $AppId
            'Secret Name'                   = $Null
            'Secret Start Date'             = $Null
            'Secret End Date'               = $Null
            'Secret Days Until Expiry'      = $Null
            'Certificate Name'              = $CertName
            'Certificate Start Date'        = $StartDate
            'Certificate End Date'          = $EndDate
            'Certificate Days Until Expiry' = ($EndDate - $Today).Days
        }
    }

}



Write-Host "Found $($AppsWithCredentials.Count) applications with credentials present." -ForegroundColor Green
Start-Sleep 2

if ($ExportExcel) {
    try {
        Write-Host "`nExporting data to Excel file at $OutputFilePath" -ForegroundColor Yellow

        $Intel | Sort-Object ApplicationName | Export-Excel -Path $OutputFilePath -AutoSize -FreezeTopRow -TableStyle Light13 -Title "App Registrations Credential Information" -Show
        Start-Sleep 3
        
        Write-Host "Export completed successfully!" -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to export to Excel: $_"
    }
}
else {
    Write-Host "`nApp Registrations Credential Information:" -ForegroundColor Cyan
    $Intel | Sort-Object ApplicationName | Format-Table -AutoSize
    
    # Display expiration warnings for both secrets and certificates
    Write-Host "`nChecking for credentials expiring within 30 days..." -ForegroundColor Yellow
    $ExpiringCredentials = $Intel | Where-Object { $_.DaysUntilExpiry -le 30 -and $_.DaysUntilExpiry -ge 0 }

    if ($ExpiringCredentials) {
        Write-Host "`nWARNING: The following credentials are expiring within 30 days:" -ForegroundColor Red
        foreach ($Credential in $ExpiringCredentials) {
            if ($Credential.'Secret Name') {
                Write-Host "  - $($Credential.ApplicationName): Secret '$($Credential.'Secret Name')' expires on $($Credential.'Secret End Date') ($($Credential.DaysUntilExpiry) days)" -ForegroundColor Red
            }
            elseif ($Credential.'Certificate Name') {
                Write-Host "  - $($Credential.ApplicationName): Certificate '$($Credential.'Certificate Name')' expires on $($Credential.'Certificate End Date') ($($Credential.DaysUntilExpiry) days)" -ForegroundColor Red
            }
        }
    }
    else {
        Write-Host "`nGood news! No secrets or certificates are expiring within the next 30 days." -ForegroundColor Green
    }
}

