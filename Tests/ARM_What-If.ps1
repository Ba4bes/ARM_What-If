<#
.SYNOPSIS
    script that collects all ARM templates and tests in a repository and tests them with WhatIf
.DESCRIPTION
    The scripts collects all ARM templates, apart of exclusions.
    It looks for parameter files based on the defaults naming convention.
    After that, it will search the environment parameters to find parameters matching the template parameters.
    With those parameters, the ARM template is tested with WhatIf.
    The script throws if any whatif deployment comes back unsuccessful
.EXAMPLE
    .\ArmWhatIfTest.ps1 -SubscriptionID "8" -TestResourceGroupName "testresourcegroup" -Exclusions @("poli","cog","test")

    Tests all ARM templates that do not have policy, config or test in the name against the resourcegroup testresourcegroup.
.PARAMETER SubscriptionID
    The ID of the subscription where the TestResourceGroup is found
.PARAMETER TestResourceGroupName
    The name of a resourcegroup that is used for the tests. Best option is to have a dedicated, empty resourcegroup
.PARAMETER Templates
    If you want to
.PARAMETER Exclusions
    An array of strings that can be in a filepath. If the string is found, the json file is not tested.
.NOTES
    This script is meant to run in a Azure DevOps CICD pipeline
#>
param(
    [parameter(Mandatory = $true)]
    [string]$TestResourceGroupName,
    [parameter()]
    [string]$SubscriptionID,
    [parameter()]
    [hashTable]$Templates,
    [parameter()]
    [array]$Exclusions
)

if ($SubscriptionID) {
    Set-AzContext $SubscriptionID
}
# Check if Resourcegroup exists
try {
    $null = Get-AzResourceGroup $TestResourceGroupName
}
Catch {
    Throw "resourcegroup $TestResourceGroupName not found"
}

if ($null -eq $Templates) {
    # Collect al JSON files in the repository that do not contain a string in the exclusions
    $JSONS = Get-ChildItem .\ -Recurse -Include *.json
    if ($Exclusions) {
        $Regex = "(?i).*(" + ($Exclusions -join "|") + ").*"
        $JSONs = $JSONS | Where-Object { $_.FullName -notmatch $Regex }
    }
    # Create hashtable with Paths to all template files and parameter files.
    $Templates = [ordered]@{}
    foreach ($JSON in $JSONs) {
        # Check if the JSON contains a Resources property, which means it is a ARM template
        if ((Get-Content $JSON | convertfrom-json).Resources) {
            $TemplateFile = $JSON.FullName
            # Check if a parameter file exists (based on default naming convention)
            $ParameterName = $Json.FullName -replace '.json', '.parameters.json'
            if (Test-Path $ParameterName) {
                $Parameterfile = $ParameterName
                $Templates.add($TemplateFile, $ParameterFile)
            }
            else {
                $Templates.add($TemplateFile, "")
            }
        }
    }
}

# Collect the environment variables that are created in the pipeline
$EnvironmentVariables = Get-ChildItem Env:

$FailedResources = @()
Foreach ($Template in $Templates.GetEnumerator()) {
    $TemplateFile = $Template.Name
    $TemplateParameterFile = $Template.Value
    Write-Host "##[debug]######## $templateFile - $TemplateParameterFile ########"

    # Collect the parameters that are used in the template
    $TemplateContent = (Get-Content $TemplateFile | ConvertFrom-Json)
    $TemplateParameters = ($TemplateContent.Parameters | Get-Member -MemberType NoteProperty).Name

    $DeploymentParameters = [ordered]@{
        ResourceGroupName = $TestResourceGroupName
        TemplateFile      = $TemplateFile
        ErrorAction       = "Stop"
    }
    if (-not [string]::IsNullOrEmpty($TemplateParameterFile)) {
        $DeploymentParameters.add('TemplateParameterFile', $TemplateParameterFile)
    }

    #Check if the environmentvariables match the parameters of the template, add to the deployment parameters if they do.
    foreach ($EnvironmentVariable in $EnvironmentVariables) {
        if ($TemplateParameters -contains $EnvironmentVariable.Name) {
            if ($EnvironmentVariable.Name -eq "resourcegroupname") {
                $DeploymentParameters.add("resourcegroupNameFromTemplate", $EnvironmentVariable.Value)
            }
            if ($null -eq $DeploymentParameters.$($EnvironmentVariable.Name)) {
                $DeploymentParameters.add($EnvironmentVariable.Name, $EnvironmentVariable.Value)
            }
        }
    }

    try {
        # Perform the Whatif Action
        New-AzResourceGroupDeployment @DeploymentParameters -WhatIf -WhatIfResultFormat ResourceIdOnly
        Write-Host "no errors found"
    }
    Catch {
        Write-Host "##[error]======== ERROR ================================================"
        $FailureObject = @{
            "TemplateFile" = $TemplateFile
            "Parameters"   = $DeploymentParameters
            "ErrorMessage" = $_.Exception.InnerException.Message
        }
        $FailedResources += $FailureObject
    }
}

if ($FailedResources.count -gt 0) {
    Write-Host "FAILED RESOURCES:" -ForegroundColor Red

    $FailedResources | ForEach-Object {
        Write-Host " "
        Write-Host "TemplateFile: $($_.TemplateFile)"
        Write-Host "ErrorMessage: $($_.ErrorMessage)"
        "Used Parameters:"
        $_.Parameters
    }
    Throw "not all resources can be deployed"
}
