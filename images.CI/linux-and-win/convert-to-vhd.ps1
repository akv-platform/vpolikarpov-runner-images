param (
  [String] [Parameter (Mandatory = $true)] $SubscriptionId,
  [String] [Parameter (Mandatory = $true)] $Location,
  [String] [Parameter (Mandatory = $true)] $ResourceGroupName,
  
  [String] [Parameter (Mandatory = $true)] $ManagedImageName,
  
  [String] [Parameter (Mandatory = $true)] $GalleryName,
  [String] [Parameter (Mandatory = $true)] $GalleryImageSku,
  [String] [Parameter (Mandatory = $true)] $GalleryImageVersion,
  
  [String] [Parameter (Mandatory = $true)] $StorageAccountName,
  [String] [Parameter (Mandatory = $true)] $StorageAccountContainerName,
  [String] [Parameter (Mandatory = $true)] $VhdName,
  
  [String] [Parameter (Mandatory = $true)] $ClientId,
  [String] [Parameter (Mandatory = $true)] $ClientSecret,
  [String] [Parameter (Mandatory = $true)] $TenantId
)

function Get-DestinationBlobUri {
  param (
    [string] [Parameter(Mandatory = $true)] $SubscriptionId,

    [string] [Parameter(Mandatory = $true)] $ResourceGroupName,
    [string] [Parameter(Mandatory = $true)] $StorageAccountName,
    [string] [Parameter(Mandatory = $true)] $ContainerName,
    [string] [Parameter(Mandatory = $true)] $ImageBlobName,
    
    [string] [Parameter(Mandatory = $true)] $TenantId
  )

  Write-Host "List the access keys or Kerberos keys for a $StorageAccountName storage account."
  $targetKey = az storage account keys list --resource-group $ResourceGroupName --account-name $StorageAccountName --query "[0].value" -o tsv
  Test-LastExitCode
  $isHasKey = -not [System.String]::IsNullOrEmpty($targetKey)
  Write-Host "Successfully got Target Key? $isHasKey"

  Write-Host "Creating SAS Token for destination storage account $StorageAccountName in subscription $SubscriptionId."
  $expirySasTime = (Get-Date).AddDays(2).ToString("yyyy-MM-dTH:mZ")
  $targetSasToken = az storage account generate-sas --account-key $targetKey --account-name $StorageAccountName --expiry $expirySasTime --services b --resource-types co --permissions rwdlac -o tsv
  Test-LastExitCode

  $targetBlobUri = 'https://{0}.blob.core.windows.net/{1}/{2}?{3}' -f $StorageAccountName, $ContainerName, $ImageBlobName, $targetSasToken
  return $targetBlobUri
}

$ErrorActionPreference = "Stop"

if (-not $env:AZCOPYPATH) {
  Write-Error "AZCOPYPATH is not set"
  exit 1
}
Write-Host "azcopy path is set"

# Login to Azure
az login --service-principal --username $ClientId --password $ClientSecret --tenant $TenantId | Out-Null

# Create Compute Image Gallery if it doesn't exist
$galleryExists = az sig list --resource-group $ResourceGroupName --query "[?name=='$GalleryName']" -o tsv
if ($null -eq $galleryExists) {
  az sig create --resource-group $ResourceGroupName --gallery-name $GalleryName --location $Location
}

# Create Image Definition if it doesn't exist
$imageDefinitionName = "RunnerImage-$GalleryImageSku"
if ($ImageName -like "*windows*") {
  $imageOsType = "Windows"
} elseif ($ImageName -like "*ubuntu*") {
  $imageOsType = "Linux"
} else {
  throw "Unknown OS type for image '$ImageName'"
}

$galleryImageExists = az sig image-definition list --resource-group $ResourceGroupName --gallery-name $GalleryName --query "[?name=='$imageDefinitionName']" -o tsv
if ($null -eq $galleryImageExists) {
  az sig image-definition create `
    --resource-group $ResourceGroupName `
    --gallery-name $GalleryName `
    --gallery-image-definition $imageDefinitionName `
    --publisher "GuthubImagesGeneration" `
    --offer "RunnerImage" `
    --sku $GalleryImageSku `
    --os-type $imageOsType `
    --location $Location
}

# Create Image Version from existing Managed Image
az sig image-version create `
  --resource-group $ResourceGroupName `
  --gallery-name $GalleryName `
  --gallery-image-definition $imageDefinitionName `
  --gallery-image-version "1.0.0" `
  --managed-image "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Compute/images/$ImageName" `
  --target-regions $Location `
  --replica-count 1 `
  --location $Location

# Create Azure Managed Disk from Shared Image Gallery
az disk create `
  --resource-group $ResourceGroupName `
  --name $ImageName `
  --location $Location `
  --gallery-image-reference "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Compute/galleries/$GalleryName/images/$imageDefinitionName/versions/1.0.0"

# Generate SAS URL for the Managed Disk
$sourceDiskUri = az disk grant-access `
  --resource-group $ResourceGroupName `
  --name $ImageName `
  --duration-in-seconds 86400 `
  --access-level Read `
  --query [accessSas] -o tsv

$destinationVHDBlobUri = Get-DestinationBlobUri `
  -ContainerName "vhds" `
  -SubscriptionId $SubscriptionId `
  -ResourceGroupName $ResourceGroupName `
  -StorageAccountName $StorageAccountName `
  -TenantId $TenantId `
  -ImageBlobName $VhdName

Write-Host "Copying VHD blob from '$($sourceDiskUri.Split('?')[0])' to '$($destinationVHDBlobUri.Split('?')[0])'..."

$jobLog = New-Object 'System.Collections.Generic.List[PSCustomObject]'
Write-Host 'Starting azcopy'

& $env:AZCOPYPATH copy $sourceDiskUri $DestinationVHDBlobUri --s2s-preserve-access-tier=false --output-type json | Foreach-Object {
  # Parse Json
  $json = ConvertFrom-Json -InputObject $_
  if ($json.MessageContent.StartsWith('{')) {
    $json.MessageContent = ConvertFrom-Json -InputObject $json.MessageContent
  }
  $jobLog.Add($json)

  # Output current status
  if ($json.MessageType -in @('Progress', 'EndOfJob')) {
    $mc = $json.MessageContent
    $status = $mc.JobStatus
    $bytesCopied = [int]($mc.TotalBytesTransferred / 1MB)
    $totalBytes = [int]($mc.TotalBytesExpected / 1MB)
    $percentComplete = [Math]::Round($mc.PercentComplete, 2)
    # Write-Host "$env:imageBlobName -> $targetAccountName : $status [$percentComplete %]: $bytesCopied/$totalBytes MB Copied..."
    Write-Host " $status [$percentComplete %]: $bytesCopied/$totalBytes MB Copied..."
  }
}

Write-Host 'azcopy finished'

# Check last exit code
if ($LASTEXITCODE) {
  Write-Host $LASTEXITCODE

  $failedJob = $jobLog | Where-Object { $_.MessageType -eq 'EndOfJob' -and $_.MessageContent.JobStatus -eq 'Failed' }

  if ($failedJob) {
    $errorContent = $failedJob.MessageContent.FailedTransfers.ErrorCode
  } else {
    $errorContent = ($jobLog | Where-Object MessageType -eq 'Error').MessageContent
  }
  #throw "Copy [$env:imageBlobName] failed with error: $errorContent"
  throw "Blob Copy failed with error: $errorContent"
}
