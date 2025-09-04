<#
.DESCRIPTION
    This script retrieves all application registrations from Microsoft Entra ID.
    and collects information about their client secrets, including expiration dates.
    The output can be used to monitor secret expiration and manage app credentials.

    The information can also be exported to an Excel file.

.NOTES
    Author: Victor Uhrberg
    Date: 2025-09-03

.EXAMPLE
    For raw output
    .\FindAppRegistrationsInformation.ps1

    For Excel export
    .\FindAppRegistrationsInformation.ps1 -ExportExcel

.LINK
    https://github.com/Invertible95/Microsoft365-NiceToHave
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
$AppsWithSecrets = @()

foreach ($App in $Applications) {
    $AppName = $App.DisplayName
    $AppId = $App.Id

    $AppCredentials = Get-MgApplication -ApplicationId $AppId | Select-Object PasswordCredentials

    $Secrets = $AppCredentials.PasswordCredentials

    if ($Secrets.Count -gt 0) {
        $AppsWithSecrets += $AppName
    }

    foreach ($Secret in $Secrets) {
        $SecretId = $Secret.KeyId
        $StartDate = $Secret.StartDateTime
        $EndDate = $Secret.EndDateTime

        $Intel += [PSCustomObject]@{
            ApplicationName = $AppName
            ApplicationId   = $AppId
            SecretId        = $SecretId
            StartDate       = $StartDate
            EndDate         = $EndDate
            DaysUntilExpiry = ($EndDate - $Today).Days
        }
    }
}

Write-Host "Found $($AppsWithSecrets.Count) applications with secrets present." -ForegroundColor Green
Start-Sleep 3

if ($ExportExcel) {
    try {
        Write-Host "`nExporting data to Excel file at $OutputFilePath" -ForegroundColor Yellow

        $Intel | Sort-Object ApplicationName | Export-Excel -Path $OutputFilePath -AutoSize -FreezeTopRow
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
    # Display expiration warnings after the main output
    Write-Host "`nChecking for secrets expiring within 30 days..." -ForegroundColor Yellow
    $ExpiringSecrets = $Intel | Where-Object { $_.DaysUntilExpiry -le 30 -and $_.DaysUntilExpiry -ge 0 }

    if ($ExpiringSecrets) {
        Write-Host "`nWARNING: The following secrets are expiring within 30 days:" -ForegroundColor Red
        foreach ($Secret in $ExpiringSecrets) {
            Write-Host "  - $($Secret.ApplicationName): Secret expires on $($Secret.EndDate) ($($Secret.DaysUntilExpiry) days)" -ForegroundColor Red
        }
    }
    else {
        Write-Host "`nGood news! No secrets are expiring within the next 30 days." -ForegroundColor Green
    }
}

