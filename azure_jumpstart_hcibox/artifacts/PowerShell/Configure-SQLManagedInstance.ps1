$WarningPreference = "SilentlyContinue"
$ErrorActionPreference = "Stop"
$ProgressPreference = 'SilentlyContinue'

# Installing Azure CLI extensions
# Making extension install dynamic
Write-Header "Installing Azure CLI extensions"
az config set extension.use_dynamic_install=yes_without_prompt

az extension add --name connectedk8s --version 1.9.3
az extension add --name arcdata
az extension add --name k8s-extension
az extension add --name customlocation
az -v

# Import Configuration Module
# Ensure the module is imported
if (-not (Get-Module -ListAvailable -Name 'PowerShellGet')) {
    Import-Module PowerShellGet
}

# Validate the file path
$configFile = "$Env:HCIBoxDir\LocalBox-Config.psd1"
if (-not (Test-Path -Path $configFile)) {
    Write-Error "Configuration file not found at $configFile. Please check the path."
    Exit 1
}

$HCIBoxConfig = Import-PowerShellDataFile -Path $configFile
if ($null -eq $HCIBoxConfig) {
    Write-Error "Failed to load configuration file. Please check the file format."
    Exit 1
}

if (-not $HCIBoxConfig.Paths.LogsDir) {
    Write-Error "Logs directory path is not defined in the configuration file."
    Exit 1
}
Start-Transcript -Path "$($HCIBoxConfig.Paths.LogsDir)\Configure-SQLManagedInstance.log"

if (-not $HCIBoxConfig.AKSworkloadClusterName) {
    Write-Error "AKS workload cluster name is not defined in the configuration file."
    Exit 1
}
$aksClusterName = ($HCIBoxConfig.AKSworkloadClusterName).toLower()


$cliDirPath = "$Env:HCIBoxDir\.cli\.sqlmi"
if (-not (Test-Path -Path $cliDirPath)) {
  $cliDir = New-Item -Path $cliDirPath -ItemType Directory
  if (-not $($cliDir.Parent.Attributes.HasFlag([System.IO.FileAttributes]::Hidden))) {
    $folder = Get-Item $cliDir.Parent.FullName -ErrorAction SilentlyContinue
    $folder.Attributes += [System.IO.FileAttributes]::Hidden
  }
}

Write-Header "Az CLI Login"
az login --service-principal --username $Env:spnClientID --password=$Env:spnClientSecret --tenant $Env:spnTenantId
az account set -s $env:subscriptionId

# Login to Azure PowerShell with service principal provided by user
$spnpassword = ConvertTo-SecureString $env:spnClientSecret -AsPlainText -Force
$spncredential = New-Object System.Management.Automation.PSCredential ($env:spnClientId, $spnpassword)
Connect-AzAccount -ServicePrincipal -Credential $spncredential -Tenant $env:spntenantId -Subscription $env:subscriptionId

# Install k8s extensions
# OPTION 1
#az extension add -n k8s-runtime --upgrade
#az k8s-runtime load-balancer enable --resource-uri subscriptions/$env:subscriptionId/resourceGroups/$Env:resourceGroup/providers/Microsoft.Kubernetes/connectedClusters/localbox-aks
#az k8s-runtime load-balancer enable --resource-uri subscriptions/$env:subscriptionId/resourceGroups/$Env:resourceGroup/providers/Microsoft.Kubernetes/connectedClusters/$aksClusterName

# OPTION 2
# az provider register -n Microsoft.KubernetesRuntime
#$spnObjectId = "0fdc6fe2-8e7f-4cc5-a85f-32f4d205db88"
# az k8s-extension create --cluster-name "localbox-aks" -g $Env:resourceGroup --cluster-type connectedClusters --extension-type microsoft.arcnetworking --config k8sRuntimeFpaObjectId=$spnObjectId -n arcnetworking
# Check if the k8s extension already exists

$extensionName = "arcnetworking"
$existingExtension = az k8s-extension list --cluster-name $aksClusterName --resource-group $Env:resourceGroup --cluster-type connectedClusters --query "[?name=='$extensionName']" -o tsv

if (-not $existingExtension) {
  Write-Host "The k8s extension '$extensionName' does not exist. Creating it now..."
  az k8s-extension create --cluster-name $aksClusterName -g $Env:resourceGroup --cluster-type connectedClusters --extension-type microsoft.arcnetworking --config k8sRuntimeFpaObjectId=$spnObjectId -n $extensionName
} else {
  Write-Host "The k8s extension '$extensionName' already exists. Skipping creation."
}

# Create Load Balancer
Write-Header "Creating Load Balancer"
az k8s-runtime load-balancer create --load-balancer-name "metal-lb" --resource-uri "/subscriptions/$env:subscriptionId/resourceGroups/$Env:resourceGroup/providers/Microsoft.Kubernetes/connectedClusters/$aksClusterName" --addresses "10.10.0.0/30" --advertise-mode Both

# Use SDNAdminPassword from HCIBox configuration
$AZDATA_USERNAME = $Env:adminUsername
$AZDATA_PASSWORD = $HCIBoxConfig.SDNAdminPassword

# Getting AKS clusters' credentials
Write-Host "Getting AKS credentials"
az aksarc get-credentials --name $aksClusterName --resource-group $Env:resourceGroup --admin
$rgName = $Env:resourceGroup
$proxyProcess = Start-Process powershell -ArgumentList "-NoExit", "-Command az connectedk8s proxy -n $using:aksClusterName -g $using:rgName" -PassThru

Write-Host "Checking K8s Nodes"
kubectl get nodes
Write-Host "`n"

# Get Log Analytics workspace details
Write-Host "Getting Log Analytics workspace details"
$workspaceId = $(az resource show --resource-group $Env:resourceGroup --name $Env:workspaceName --resource-type "Microsoft.OperationalInsights/workspaces" --query properties.customerId -o tsv)
$workspaceKey = $(az monitor log-analytics workspace get-shared-keys --resource-group $Env:resourceGroup --workspace-name $Env:workspaceName --query primarySharedKey -o tsv)
$workspaceResourceId = $(az resource show --resource-group $Env:resourceGroup --name $Env:workspaceName --resource-type "Microsoft.OperationalInsights/workspaces" --query id -o tsv)
Write-Host "Worrkspace resource id: $workspaceResourceId"

# Enabling Container Insights and Azure Policy cluster extension on Arc-enabled cluster
if (!$workspaceResourceId) {
    Write-Error "Failed to retrieve workspace resource ID. Please check the workspace name and resource group."
    Exit 1
}

Write-Host "`n"
Write-Host "Enabling Container Insights cluster extension"

# Check if the Azure Monitor extension already exists
$monitorExtensionName = "Microsoft.AzureMonitor.Containers"
$existingMonitorExtension = az k8s-extension list --cluster-name $aksClusterName --resource-group $Env:resourceGroup --cluster-type connectedClusters --query "[?extensionType=='$monitorExtensionName']" -o tsv

if (-not $existingMonitorExtension) {
  Write-Host "The Azure Monitor extension '$monitorExtensionName' does not exist. Creating it now..."
  az k8s-extension create --name $monitorExtensionName --cluster-name $aksClusterName --resource-group $Env:resourceGroup --cluster-type connectedClusters --extension-type $monitorExtensionName --configuration-settings logAnalyticsWorkspaceResourceID=$workspaceResourceId --no-wait
} else {
  Write-Host "The Azure Monitor extension '$monitorExtensionName' already exists. Skipping creation."
}

Write-Host "`n"

$aksCustomLocation = "$aksClusterName-cl"
$dataController = "$aksClusterName-dc"

# Check if the arc data services extension already exists
Write-Host "Deploying arc data services extension on $aksClusterName"
Write-Host "`n"

$arcDataServicesExtensionName = "arc-data-services"
$existingArcDataServicesExtension = az k8s-extension list --cluster-name $aksClusterName --resource-group $Env:resourceGroup --cluster-type connectedClusters --query "[?name=='$arcDataServicesExtensionName']" -o tsv

if (-not $existingArcDataServicesExtension) {
  Write-Host "The arc data services extension '$arcDataServicesExtensionName' does not exist. Creating it now..."
  az k8s-extension create --name $arcDataServicesExtensionName `
    --extension-type microsoft.arcdataservices `
    --cluster-type connectedClusters `
    --cluster-name $aksClusterName `
    --resource-group $Env:resourceGroup `
    --auto-upgrade false `
    --scope cluster `
    --release-namespace arc `
    --version 1.38.0 `
    --config Microsoft.CustomLocation.ServiceAccount=sa-bootstrapper
} else {
  Write-Host "The arc data services extension '$arcDataServicesExtensionName' already exists. Skipping creation."
}

Write-Host "`n"

Do {
    Write-Host "Waiting for bootstrapper pod, hold tight..."
    Start-Sleep -Seconds 20
    $podStatus = $(if (kubectl get pods -n arc | Select-String "bootstrapper" | Select-String "Running" -Quiet) { "Ready!" }Else { "Nope" })
} while ($podStatus -eq "Nope")
Write-Host "Bootstrapper pod is ready!"

$connectedClusterId = az connectedk8s show --name $aksClusterName --resource-group $Env:resourceGroup --query id -o tsv
$extensionId = az k8s-extension show --name arc-data-services --cluster-type connectedClusters --cluster-name $aksClusterName --resource-group $Env:resourceGroup --query id -o tsv

# Verify data services extension is created
if ($extensionId -ne '') {
  Write-Host "Data services extension created sucussfully on $aksClusterName. Extension Id: $extensionId"
} else {
    Write-Error "Failed to create data services extension on $aksClusterName. Extension Id: $extensionId"
    Exit 1
}

Write-Host "Creating custom location on $aksClusterName"
try {
  $existingCustomLocation = az customlocation list --resource-group $Env:resourceGroup --query "[?name=='$aksCustomLocation']" -o tsv
  if (-not $existingCustomLocation) {
    Write-Host "The custom location '$aksCustomLocation' does not exist. Creating it now..."
    az customlocation create --name $aksCustomLocation --resource-group $Env:resourceGroup --namespace arc --host-resource-id $connectedClusterId --cluster-extension-ids $extensionId --only-show-errors
  } else {
    Write-Host "The custom location '$aksCustomLocation' already exists. Skipping creation."
  }
} catch {
    Write-Host "Error creating custom location: $_" -ForegroundColor Red
    Exit 1
}

# Deploying the Azure Arc Data Controller
Write-Header "Deploying Azure Arc Data Controllers on Kubernetes cluster"
Write-Host "`n"

# Check if the data controller already exists
$existingDataController = az arcdata dc list --resource-group $Env:resourceGroup --query "[?name=='$dataController']" -o tsv

if (-not $existingDataController) {
  Write-Host "The data controller '$dataController' does not exist. Creating it now..."
  $aksCustomLocationId = $(az customlocation show --name $aksCustomLocation --resource-group $Env:resourceGroup --query id -o tsv)
  Copy-Item "$Env:HCIBoxDir\dataController.parameters.json" -Destination "$Env:HCIBoxDir\dataController-stage.parameters.json"

  $dataControllerParams = "$Env:HCIBoxDir\dataController-stage.parameters.json"

  (Get-Content -Path $dataControllerParams) -replace 'dataControllerName-stage', $dataController | Set-Content -Path $dataControllerParams
  (Get-Content -Path $dataControllerParams) -replace 'resourceGroup-stage', $Env:resourceGroup | Set-Content -Path $dataControllerParams
  (Get-Content -Path $dataControllerParams) -replace 'azdataUsername-stage', $AZDATA_USERNAME | Set-Content -Path $dataControllerParams
  (Get-Content -Path $dataControllerParams) -replace 'azdataPassword-stage', $AZDATA_PASSWORD | Set-Content -Path $dataControllerParams
  (Get-Content -Path $dataControllerParams) -replace 'customLocation-stage', $aksCustomLocationId | Set-Content -Path $dataControllerParams
  (Get-Content -Path $dataControllerParams) -replace 'subscriptionId-stage', $Env:subscriptionId | Set-Content -Path $dataControllerParams
  (Get-Content -Path $dataControllerParams) -replace 'logAnalyticsWorkspaceId-stage', $workspaceId | Set-Content -Path $dataControllerParams
  (Get-Content -Path $dataControllerParams) -replace 'logAnalyticsPrimaryKey-stage', $workspaceKey | Set-Content -Path $dataControllerParams
  (Get-Content -Path $dataControllerParams) -replace 'storageClass-stage', 'default' | Set-Content -Path $dataControllerParams
  (Get-Content -Path $dataControllerParams) -replace 'spnClientId-stage', $Env:spnClientId | Set-Content -Path $dataControllerParams
  (Get-Content -Path $dataControllerParams) -replace 'spnTenantId-stage', $Env:spnTenantId | Set-Content -Path $dataControllerParams
  (Get-Content -Path $dataControllerParams) -replace 'spnClientSecret-stage', $Env:spnClientSecret | Set-Content -Path $dataControllerParams

  Write-Host "Deploying arc data controller on $aksClusterName"
  Write-Host "`n"
  az deployment group create --resource-group $Env:resourceGroup --name $dataController --template-file "$Env:HCIBoxDir\dataController.json" --parameters $dataControllerParams
  Write-Host "`n"

  Do {
    Write-Host "Waiting for data controller. Hold tight, this might take a few minutes..."
    Start-Sleep -Seconds 45
    $dcStatus = $(if (kubectl get datacontroller -n arc | Select-String "Ready" -Quiet) { "Ready!" }Else { "Nope" })
  } while ($dcStatus -eq "Nope")
  Write-Host "Azure Arc data controller is ready on $aksClusterName!"
  Write-Host "`n"
  Remove-Item "$Env:HCIBoxDir\dataController-stage.parameters.json" -Force
} else {
  Write-Host "The data controller '$dataController' already exists. Skipping creation."
}

# Enable metrics autoUpload
Write-Header "Enabling metrics and logs auto-upload"
$Env:WORKSPACE_ID = $workspaceId
$Env:WORKSPACE_SHARED_KEY = $workspaceKey

$Env:MSI_OBJECT_ID = (az k8s-extension show --resource-group $Env:resourceGroup  --cluster-name $aksClusterName --cluster-type connectedClusters --name arc-data-services | convertFrom-json).identity.principalId
az role assignment create --assignee-object-id $Env:MSI_OBJECT_ID --assignee-principal-type ServicePrincipal --role 'Monitoring Metrics Publisher' --scope "/subscriptions/$Env:subscriptionId/resourceGroups/$Env:resourceGroup"
az arcdata dc update --name $dataController --resource-group $Env:resourceGroup --auto-upload-metrics true
az arcdata dc update --name $dataController --resource-group $Env:resourceGroup --auto-upload-logs true

Write-Header "Deploying SQLMI"
# Deploy SQL MI data services

# Deployment environment variables
$sqlInstanceName = "$aksClusterName-sql"

# Deploying Azure Arc SQL Managed Instance
Write-Host "`n"
Write-Host "Deploying Azure Arc SQL Managed Instance"
Write-Host "`n"

$dataControllerId = $(az resource show --resource-group $Env:resourceGroup --name $dataController --resource-type "Microsoft.AzureArcData/dataControllers" --query id -o tsv)

################################################
# Localize ARM template
################################################
$ServiceType = "LoadBalancer"
$readableSecondaries = $ServiceType

# Resource Requests
$vCoresRequest = "2"
$memoryRequest = "4Gi"
$vCoresLimit =  "4"
$memoryLimit = "8Gi"

# Storage
$StorageClassName = "default"
$dataStorageSize = "5Gi"
$logsStorageSize = "5Gi"
$dataLogsStorageSize = "5Gi"

# High Availability
$replicas = 3 # Deploy SQL MI "Business Critical" tier
#######################################################

# Check if the SQL Managed Instance already exists
$existingSqlInstance =  az sql mi-arc list --resource-group $Env:resourceGroup --query "[?name=='$sqlInstanceName']" -o tsv

if ($existingSqlInstance -eq "Found 0 Arc-enabled SQL Managed Instances.") {
  Write-Host "The SQL Managed Instance '$sqlInstanceName' does not exist. Creating it now..."
  
  # Proceed with the deployment
  $SQLParams = "$Env:HCIBoxDir\sqlmi.parameters.json"

  (Get-Content -Path $SQLParams) -replace 'resourceGroup-stage',$Env:resourceGroup | Set-Content -Path $SQLParams
  (Get-Content -Path $SQLParams) -replace 'dataControllerId-stage',$dataControllerId | Set-Content -Path $SQLParams
  (Get-Content -Path $SQLParams) -replace 'customLocation-stage',$aksCustomLocationId | Set-Content -Path $SQLParams
  (Get-Content -Path $SQLParams) -replace 'subscriptionId-stage',$Env:subscriptionId | Set-Content -Path $SQLParams
  (Get-Content -Path $SQLParams) -replace 'azdataUsername-stage',$AZDATA_USERNAME | Set-Content -Path $SQLParams
  (Get-Content -Path $SQLParams) -replace 'azdataPassword-stage',$AZDATA_PASSWORD | Set-Content -Path $SQLParams
  (Get-Content -Path $SQLParams) -replace 'serviceType-stage',$ServiceType | Set-Content -Path $SQLParams
  (Get-Content -Path $SQLParams) -replace 'readableSecondaries-stage',$readableSecondaries | Set-Content -Path $SQLParams
  (Get-Content -Path $SQLParams) -replace 'vCoresRequest-stage',$vCoresRequest | Set-Content -Path $SQLParams
  (Get-Content -Path $SQLParams) -replace 'memoryRequest-stage',$memoryRequest | Set-Content -Path $SQLParams
  (Get-Content -Path $SQLParams) -replace 'vCoresLimit-stage',$vCoresLimit | Set-Content -Path $SQLParams
  (Get-Content -Path $SQLParams) -replace 'memoryLimit-stage',$memoryLimit | Set-Content -Path $SQLParams
  (Get-Content -Path $SQLParams) -replace 'dataStorageClassName-stage',$StorageClassName | Set-Content -Path $SQLParams
  (Get-Content -Path $SQLParams) -replace 'logsStorageClassName-stage',$StorageClassName | Set-Content -Path $SQLParams
  (Get-Content -Path $SQLParams) -replace 'dataLogStorageClassName-stage',$StorageClassName | Set-Content -Path $SQLParams
  (Get-Content -Path $SQLParams) -replace 'dataSize-stage',$dataStorageSize | Set-Content -Path $SQLParams
  (Get-Content -Path $SQLParams) -replace 'logsSize-stage',$logsStorageSize | Set-Content -Path $SQLParams
  (Get-Content -Path $SQLParams) -replace 'dataLogSize-stage',$dataLogsStorageSize | Set-Content -Path $SQLParams
  (Get-Content -Path $SQLParams) -replace 'replicasStage' ,$replicas | Set-Content -Path $SQLParams
  (Get-Content -Path $SQLParams) -replace 'sqlInstanceName-stage' ,$sqlInstanceName | Set-Content -Path $SQLParams
  (Get-Content -Path $SQLParams) -replace 'port-stage' , 11433 | Set-Content -Path $SQLParams

  az deployment group create --resource-group $Env:resourceGroup --template-file "$Env:HCIBoxDir\sqlmi.json" --parameters $SQLParams
  Write-Host "`n"

  Do {
    Write-Host "Waiting for SQL Managed Instance. Hold tight, this might take a few minutes...(45s sleeping loop)"
    Start-Sleep -Seconds 45
    $dcStatus = $(if (kubectl get sqlmanagedinstances -n arc | Select-String "Ready" -Quiet) { "Ready!" } Else { "Nope" })
  } while ($dcStatus -eq "Nope")
  Write-Host "Azure Arc SQL Managed Instance is ready!"
  Write-Host "`n"
} else {
  Write-Host "The SQL Managed Instance '$sqlInstanceName' already exists. Skipping creation."
}

<# Downloading demo database and restoring onto SQL MI
$podname = "jumpstart-sql-0"
Write-Host "Downloading AdventureWorks database for MS SQL... (1/2)"
kubectl exec $podname -n arc -c arc-sqlmi -- wget https://github.com/Microsoft/sql-server-samples/releases/download/adventureworks/AdventureWorks2019.bak -O /var/opt/mssql/data/AdventureWorks2019.bak 2>&1 | Out-Null
Write-Host "Restoring AdventureWorks database for MS SQL. (2/2)"
kubectl exec $podname -n arc -c arc-sqlmi -- /opt/mssql-tools/bin/sqlcmd -S localhost -U $Env:AZDATA_USERNAME -P $Env:AZDATA_PASSWORD -Q "RESTORE DATABASE AdventureWorks2019 FROM  DISK = N'/var/opt/mssql/data/AdventureWorks2019.bak' WITH MOVE 'AdventureWorks2019' TO '/var/opt/mssql/data/AdventureWorks2019.mdf', MOVE 'AdventureWorks2019_Log' TO '/var/opt/mssql/data/AdventureWorks2019_Log.ldf'" 2>&1 $null

# Creating Azure Data Studio settings for SQL Managed Instance connection
Write-Host ""
Write-Host "Creating Azure Data Studio settings for SQL Managed Instance connection"
$settingsTemplate = "$Env:ArcBoxDir\settingsTemplate.json"

# Retrieving SQL MI connection endpoint
$sqlstring = kubectl get sqlmanagedinstances jumpstart-sql -n arc -o=jsonpath='{.status.endpoints.primary}'

# Replace placeholder values in settingsTemplate.json
(Get-Content -Path $settingsTemplate) -replace 'arc_sql_mi',$sqlstring | Set-Content -Path $settingsTemplate
(Get-Content -Path $settingsTemplate) -replace 'sa_username',$Env:AZDATA_USERNAME | Set-Content -Path $settingsTemplate
(Get-Content -Path $settingsTemplate) -replace 'sa_password',$Env:AZDATA_PASSWORD | Set-Content -Path $settingsTemplate
(Get-Content -Path $settingsTemplate) -replace 'false','true' | Set-Content -Path $settingsTemplate

# Unzip SqlQueryStress
Expand-Archive -Path $Env:ArcBoxDir\SqlQueryStress.zip -DestinationPath $Env:ArcBoxDir\SqlQueryStress

# Create SQLQueryStress desktop shortcut
Write-Host "`n"
Write-Host "Creating SQLQueryStress Desktop shortcut"
Write-Host "`n"
$TargetFile = "$Env:ArcBoxDir\SqlQueryStress\SqlQueryStress.exe"
$ShortcutFile = "C:\Users\$Env:adminUsername\Desktop\SqlQueryStress.lnk"
$WScriptShell = New-Object -ComObject WScript.Shell
$Shortcut = $WScriptShell.CreateShortcut($ShortcutFile)
$Shortcut.TargetPath = $TargetFile
$Shortcut.Save()
#>

# Later in the script, you can close the process like this:
if ($null -ne $proxyProcess  -and !$proxyProcess.HasExited) {
  Write-Host "Stopping the proxy process..."
  Stop-Process -Id $proxyProcess.Id -Force
}
else {
  Write-Host "Proxy process is not running or has already exited."
}

# Create VSCode desktop shortcut
Write-Header "Creating VSCode Desktop Shortcut"
$TargetFile = "C:\Users\arcdemo\AppData\Local\Programs\Microsoft VS Code\Code.exe"
$ShortcutFile = "C:\Users\$Env:adminUsername\Desktop\Microsoft VS Code.lnk"
$WScriptShell = New-Object -ComObject WScript.Shell
$Shortcut = $WScriptShell.CreateShortcut($ShortcutFile)
$Shortcut.TargetPath = $TargetFile
$Shortcut.Save()

# Creating Microsoft SQL Server Management Studio (SSMS) desktop shortcut
Write-Host "`n"
Write-Host "Creating Microsoft SQL Server Management Studio (SSMS) desktop shortcut"
Write-Host "`n"
$TargetFile = "C:\Program Files (x86)\Microsoft SQL Server Management Studio 20\Common7\IDE\ssms.exe"
$ShortcutFile = "C:\Users\$Env:adminUsername\Desktop\Microsoft SQL Server Management Studio.lnk"
$WScriptShell = New-Object -ComObject WScript.Shell
$Shortcut = $WScriptShell.CreateShortcut($ShortcutFile)
$Shortcut.TargetPath = $TargetFile
$Shortcut.Save()

Write-Host "`n"
Stop-Transcript