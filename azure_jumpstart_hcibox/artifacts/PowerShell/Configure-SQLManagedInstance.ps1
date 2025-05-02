$WarningPreference = "SilentlyContinue"
$ErrorActionPreference = "Stop"
$ProgressPreference = 'SilentlyContinue'

# Import Configuration Module
$HCIBoxConfig = Import-PowerShellDataFile -Path $Env:HCIBoxConfigFile
Start-Transcript -Path "$($HCIBoxConfig.Paths.LogsDir)\Configure-SQLManagedInstance.log"

$aksClusterName = ($HCIBoxConfig.AKSworkloadClusterName).toLower()
$cliDir = New-Item -Path "$Env:HCIBoxDir\.cli\" -Name ".sqlmi" -ItemType Directory
if (-not $($cliDir.Parent.Attributes.HasFlag([System.IO.FileAttributes]::Hidden))) {
    $folder = Get-Item $cliDir.Parent.FullName -ErrorAction SilentlyContinue
    $folder.Attributes += [System.IO.FileAttributes]::Hidden
}

Write-Header "Az CLI Login"
az login --service-principal --username $Env:spnClientID --password=$Env:spnClientSecret --tenant $Env:spnTenantId
az account set -s $env:subscriptionId

# Login to Azure PowerShell with service principal provided by user
$spnpassword = ConvertTo-SecureString $env:spnClientSecret -AsPlainText -Force
$spncredential = New-Object System.Management.Automation.PSCredential ($env:spnClientId, $spnpassword)
Connect-AzAccount -ServicePrincipal -Credential $spncredential -Tenant $env:spntenantId -Subscription $env:subscriptionId

# Use SDNAdminPassword from HCIBox configuration
$AZDATA_USERNAME = $Env:adminUsername
$AZDATA_PASSWORD = $HCIBoxConfig.SDNAdminPassword


# Making extension install dynamic
Write-Header "Installing Azure CLI extensions"
az config set extension.use_dynamic_install=yes_without_prompt

# Installing Azure CLI extensions
az extension add --name connectedk8s --version 1.9.3
az extension add --name arcdata
az extension add --name k8s-extension
az extension add --name customlocation
az -v

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
azdata --version

# Getting AKS clusters' credentials
az aksarc get-credentials --name $aksClusterName --resource-group $Env:resourceGroup --admin

# Get Log Analytics workspace details
$workspaceId = $(az resource show --resource-group $Env:resourceGroup --name $Env:workspaceName --resource-type "Microsoft.OperationalInsights/workspaces" --query properties.customerId -o tsv)
$workspaceKey = $(az monitor log-analytics workspace get-shared-keys --resource-group $Env:resourceGroup --workspace-name $Env:workspaceName --query primarySharedKey -o tsv)
$workspaceResourceId = $(az resource show --resource-group $Env:resourceGroup --name $Env:workspaceName --resource-type "Microsoft.OperationalInsights/workspaces" --query id -o tsv)

# Enabling Container Insights and Azure Policy cluster extension on Arc-enabled cluster
Write-Host "`n"
Write-Host "Enabling Container Insights cluster extension"
Write-Host "Checking K8s Nodes"
kubectl get nodes
Write-Host "`n"

az k8s-extension create --cluster-name $aksClusterName --resource-group $Env:resourceGroup --cluster-type connectedClusters --extension-type Microsoft.AzureMonitor.Containers --configuration-settings logAnalyticsWorkspaceResourceID=$workspaceResourceId --no-wait
Write-Host "`n"

Write-Header "Deploying Azure Arc Data Controllers on Kubernetes cluster"
$aksCustomLocation = "$aksClusterName-cl"
$dataController = "$aksClusterName-dc"

Write-Host "Deploying arc data services extension on $aksClusterName"
Write-Host "`n"
az k8s-extension create --name arc-data-services `
--extension-type microsoft.arcdataservices `
--cluster-type connectedClusters `
--cluster-name $aksClusterName `
--resource-group $Env:resourceGroup `
--auto-upgrade false `
--scope cluster `
--release-namespace arc `
--version 1.37.0 `
--config Microsoft.CustomLocation.ServiceAccount=sa-bootstrapper

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
}
else {
    Write-Error "Failed to create data services extension on $aksClusterName. Extension Id: $extensionId"
    Exit 1
}            

Write-Host "Creating custom location on $clusterName"
try {
    az customlocation create --name $aksCustomLocation --resource-group $Env:resourceGroup --namespace arc --host-resource-id $connectedClusterId --cluster-extension-ids $extensionId --only-show-errors
} catch {
    Write-Host "Error creating custom location: $_" -ForegroundColor Red
    Exit 1
}

# Deploying the Azure Arc Data Controller
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
(Get-Content -Path $dataControllerParams) -replace 'storageClass-stage', $cluster.storageClassName | Set-Content -Path $dataControllerParams
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
Write-Host "Azure Arc data controller is ready on $clusterName!"
Write-Host "`n"
Remove-Item "$Env:ArcBoxDir\dataController-$context-stage.parameters.json" -Force

Write-Header "Deploying SQLMI"
# Deploy SQL MI data services
& "$Env:ArcBoxDir\DeploySQLMIADAuth.ps1"

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
    $dcStatus = $(if(kubectl get sqlmanagedinstances -n arc | Select-String "Ready" -Quiet){"Ready!"}Else{"Nope"})
    } while ($dcStatus -eq "Nope")
Write-Host "Azure Arc SQL Managed Instance is ready!"
Write-Host "`n"

# Downloading demo database and restoring onto SQL MI
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

