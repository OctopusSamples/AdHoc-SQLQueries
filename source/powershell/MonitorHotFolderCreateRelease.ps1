Param(
    [string]$OctopusServer, ## The Octopus Server where the release will be created on, example https://example.octopus.com
    [string]$OctopusAPIKey, ## The API Key to interact with the Octopus Server, https://octopus.com/docs/api-and-integration/api/how-to-create-an-api-key
    [string]$OctopusProject, ## The Octopus project the release will be created for
    [string]$FolderToMonitor, ## The hot folder which will be monitored
    [string]$VersionPrefix, ## The release number prefix.  If you provide 2018.8, the first release will be 2018.8.1, the second is 2018.8.2
    [string]$OctoExeLocation, ## The location where the utility octo.exe is installed on.  Octo.exe is required for this to work.  You can download it https://octopus.com/downloads
    [string]$PackageName ## The name of the package which will be created.
)

Write-Host "Octopus Server: $OctopusServer"
Write-Host "Octopus Project: $OctopusProject"
Write-Host "Folder To Monitor: $FolderToMonitor"
Write-Host "OctoExeFolder: $OctoExeLocation"
Write-Host "Version Prefix: $versionPrefix"

# Check if PowerShell-Yaml is installed.
Write-Host "Checking to see if powershell-yaml is installed"
$powershellModule = Get-Module -Name powershell-yaml	
if ($powershellModule -eq $null) { 	
	Write-Host "Powershell-yaml is not installed, installing now"
    install-module powershell-yaml -force
}

Write-Host "Importing powershell-yaml"
import-module powershell-yaml



$octoExe = "$octoExeLocation\Octo.exe"

$header = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
$header.Add("X-Octopus-ApiKey", $OctopusAPIKey)

$projectToQuery = $OctopusProject.Replace(" ", "-")
$projectUrl = "$OctopusServer/api/projects/$projectToQuery"
Write-Host "Querying to get project details: $projectUrl"

$response = Invoke-RestMethod $projectUrl -Headers $header 
Write-Host "ProjectResponse: $response"

$projectId = $response.Id
Write-Host "ProjectId: $projectId"

#Set the build number to zero in case no build is found
$buildNumber = 0
$skipCount = 0
$totalResults = 100

while ($skipCount -lt $totalResults -and $buildNumber -eq 0)
{
    $releaseUrl = "$OctopusServer/api/projects/$projectId/releases?skip=$skipCount"
    Write-Host "Querying to get release details: $releaseUrl"

    $response = Invoke-RestMethod $releaseUrl -Headers $header
    $releaseList = $response.Items
    $releaseCount = $releaseList.Count
    $totalResults = $response.TotalResults
    $skipCount = $skipCount + $releaseList.Count

    Write-Host "Found $releaseCount releases in current response, with a total result of $totalResults, looping through to find build number"

    foreach ($release in $releaseList)
    {
        $currentVersion = $release.Version
        Write-Host "Comparing $versionPrefix with $currentVersion"

        if ($currentVersion.StartsWith($versionPrefix))
        {
            Write-Host "The release version $currentVersion starts with $versionPrefix, pulling the build number"
            $versionSuffix = $currentVersion.Substring($versionPrefix.Length)

            # Remove all the non digit items from the suffix
            $buildNumber = $versionSuffix -replace '[^0-9]',''
            $buildNumber = [int]::Parse($buildNumber)
            Write-Host "Found the build number $buildNumber to use"
            break
        }
    }
}

$pendingFolder = "$FolderToMonitor\Pending"
$processedFolder = "$FolderToMonitor\Processed"
$directoriesToProcess = Get-ChildItem -Path $pendingFolder -Directory

foreach ($directory in $directoriesToProcess) {
    Write-Host "Processing the directory: $pendingFolder\$directory"

    $metaDataYamlFile = "$pendingFolder\$directory\MetaData.yaml"
    if ((Test-Path $metaDataYamlFile) -eq $false) {
        Throw "The MetaData.yaml file $metaDataYamlFile was not found"
    }

    Write-Host "Reading the contents of $metaDataYamlFile"
    [string[]]$fileContent = Get-Content $metaDataYamlFile

    $content = ''
    foreach ($line in $fileContent) { $content = $content + "`n" + $line }

    Write-Host "$content"
    $yaml = ConvertFrom-YAML $content

    $environment = $yaml.Environment
    Write-Host "Deployment Environment: $environment"
        
    $directoryNameForVersion = $directory.ToString().Replace(" ", "")
    Write-Host "Directory Name For release: $directoryNameForVersion"

    Write-Host "Adding one to the build number $buildNumber"
    $buildNumber = $buildNumber + 1
    Write-Host "New build number is $buildNumber"

    $versionToUse = "$VersionPrefix.$buildNumber"
    Write-Host "The version for this directory will be: $versionToUse"

    $releaseName = "$versionToUse-$directoryNameForVersion"
    Write-Host "The release name for this directory will be: $releaseName"

    Write-Host "Packaging the folder $pendingFolder\$directory"
    & $octoExe pack --id=$PackageName --version=$versionToUse --format="ZIP" --basePath="$pendingFolder\$directory" --outFolder="$processedFolder"

    Write-Host "Pushing the package $processedFolder\$versionToUse.zip to $OctopusServer"
    & $octoExe push --Package="$processedFolder\$PackageName.$versionToUse.zip" --server="$OctopusServer" --apiKey="$OctopusAPIKey" --replace-existing

    Write-Host "Creating The Release"
    & $octoExe create-release --project $OctopusProject --packageVersion="$versionToUse" --version="$releaseName" --deployTo="$environment" --Server="$OctopusServer" --apiKey="$OctopusAPIKey"

    $currentTimeStamp = Get-Date
    $currentTimeStamp = $currentTimeStamp.ToString("yyyyMMdd_HHmmss")
    $processedFolderToUse = "$processedFolder\$currentTimeStamp$directory"
    Write-Host "Finished processing $pendingFolder\$directory moving to $processedFolderToUse"
    Move-Item -Path "$pendingFolder\$directory" -Destination "$processedFolderToUse"
} 