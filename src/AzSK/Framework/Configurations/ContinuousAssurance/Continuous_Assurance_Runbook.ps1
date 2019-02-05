﻿$AzSKRunbookVersion = "[#runbookVersion#]"

#Telemetry functions -- start here
function SetCommonProperties([psobject] $EventObj) {
    $notAvailable = "NA"
    $eventObj.data.baseData.properties.Add("JobId",$PsPrivateMetaData.JobId.Guid)
	$eventObj.data.baseData.properties.Add("SubscriptionId",$RunAsConnection.SubscriptionID)
	$eventObj.data.baseData.properties.Add("AzSKRunbookVersion", $AzSKRunbookVersion)
}

function GetEventBaseObject([string] $EventName) {
    $eventObj = "" | Select-Object data, iKey, name, tags, time
    $eventObj.iKey = $telemetryKey
    $eventObj.name = "Microsoft.ApplicationInsights." + $telemetryKey.Replace("-", "") + ".Event"
    $eventObj.time = [datetime]::UtcNow.ToString("o")

    $eventObj.tags = "" | Select-Object ai.internal.sdkVersion
    $eventObj.tags.'ai.internal.sdkVersion' = "dotnet: 2.1.0.26048"

    $eventObj.data = "" | Select-Object baseData, baseType
    $eventObj.data.baseType = "EventData"
    $eventObj.data.baseData = "" | Select-Object ver, name, measurements, properties

    $eventObj.data.baseData.ver = 2
    $eventObj.data.baseData.name = $EventName

    $eventObj.data.baseData.measurements = New-Object 'system.collections.generic.dictionary[string,double]'
    $eventObj.data.baseData.properties = New-Object 'system.collections.generic.dictionary[string,string]'

    return $eventObj;
}

function PublishEvent([string] $EventName, [hashtable] $Properties, [hashtable] $Metrics) {
    try {
		#return if telemetry key is empty
        if ([string]::IsNullOrWhiteSpace($telemetryKey)) { return; };

        $eventObj = GetEventBaseObject -EventName $EventName
        SetCommonProperties -EventObj $eventObj

        if ($null -ne $Properties) {
            $Properties.Keys | ForEach-Object {
                try {
                    if (!$eventObj.data.baseData.properties.ContainsKey($_)) {
                        $eventObj.data.baseData.properties.Add($_ , $Properties[$_].ToString())
                    }
                }
                catch
				{
					# Left blank intentionally
					# Error while sending CA events to telemetry. No need to break the execution.
				}
            }
        }
        if ($null -ne $Metrics) {
            $Metrics.Keys | ForEach-Object {
                try {
                    $metric = $Metrics[$_] -as [double]
                    if (!$eventObj.data.baseData.measurements.ContainsKey($_) -and $null -ne $metric) {
                        $eventObj.data.baseData.measurements.Add($_ , $Metrics[$_])
                    }
                }
                catch {
					# Left blank intentionally
					# Error while sending CA events to telemetry. No need to break the execution.
				}
            }
        }

        $eventJson = ConvertTo-Json $eventObj -Depth 100 -Compress

        Invoke-WebRequest -Uri "https://dc.services.visualstudio.com/v2/track" `
            -Method Post `
            -ContentType "application/x-json-stream" `
            -Body $eventJson `
            -UseBasicParsing | Out-Null
    }
    catch {
		# Left blank intentionally
		# Error while sending CA events to telemetry. No need to break the execution.
    }
}
#Telemetry functions -- end here

#function to create one time temporary helper schedule
function CreateHelperSchedule($nextRetryIntervalInMinutes)
{
    #create next run schedule
    Get-AzAutomationSchedule -AutomationAccountName $AutomationAccountName `
    -ResourceGroupName $AutomationAccountRG -Name $CAHelperScheduleName -ErrorAction SilentlyContinue | Remove-AzAutomationSchedule -Force

    New-AzAutomationSchedule -AutomationAccountName $AutomationAccountName -Name $CAHelperScheduleName `
                    -ResourceGroupName $AutomationAccountRG -StartTime $(get-date).AddMinutes($nextRetryIntervalInMinutes) `
                    -OneTime -ErrorAction Stop | Out-Null

    Register-AzAutomationScheduledRunbook -RunbookName $RunbookName -ScheduleName $CAHelperScheduleName `
                    -ResourceGroupName $AutomationAccountRG `
                    -AutomationAccountName $AutomationAccountName -ErrorAction Stop | Out-Null
	PublishEvent -EventName "CA Job Rescheduled" -Properties @{"IntervalInMinutes" = $nextRetryIntervalInMinutes}
}
#function to invoke script from server
function InvokeScript($accessToken, $policyStoreURL,$fileName, $version)
{
    [System.Uri] $validatedURI = $null;
    $URI = $global:ExecutionContext.InvokeCommand.ExpandString($policyStoreURL)
	$result = "Write-Host 'Error connecting to AzSK policy store server.'"
    if([System.Uri]::TryCreate($URI, [System.UriKind]::Absolute, [ref] $validatedURI))
    {
        if($accessToken)
        {
			$retry = 3
			while($retry -gt 0)
			{
				$retry = $retry - 1
				$result = Invoke-WebRequest $validatedUri -Headers @{"Authorization" = "Bearer $accessToken"} -UseBasicParsing
				 if ($null -ne $result -and $result.StatusCode -ge 200 -and $result.StatusCode -le 399) {
					$retry = -1;
				}
			}

        }
        else
        {
			$retry = 3
			while($retry -gt 0)
			{
				$retry = $retry - 1
				$result = Invoke-WebRequest $validatedUri -UseBasicParsing
				if ($null -ne $result -and $result.StatusCode -ge 200 -and $result.StatusCode -le 399) {
					$retry = -1;
				}
			}
        }
		Invoke-Expression $result;
    }
}

function ConvertStringToBoolean($strToConvert)
{
   if([bool]::TryParse($strToConvert, [ref] $strToConvert))
    {
        return $strToConvert
    }
    else
    {
        return $false
    }
}

######################################################################################################################
#Core runbook code. 
#This is built using the runbook code template inside \Modules\AzSK\<version>\Framework\Configurations\ContinuousAssurance
#The placeholder values for various important variables are determined 'on the fly' based on the defaults that ship in AzSK.JSON
#file in the \Modules\AzSK\<version>\Framework\Configurations folder and the local AzSKSettings.JSON file in the %localappdata%\Microsoft\AzSK
#folder for the user setting up CA. 

#In an org-specific installation, various values from AzSK.JSON can be overridden in org policy and
#are picked up from the org-specific AzSK.JSON obtained from the serverUrl location (in AzSKSettings.JSON). 
#In generic (org-neutral) setups these values are obtained from AzSK.JSON on a public CDN endpoint.
######################################################################################################################
try
{
	#start job timer
	$jobTimer = [System.Diagnostics.Stopwatch]::StartNew();

	#----------------------------------Config start------------------------------------------------------------------
	$automationAccountRG =  "[#automationAccountRG#]"
	$automationAccountName="[#automationAccountName#]"
	$telemetryKey ="[#telemetryKey#]"
	
	#This is the location from where policy is fetched at runtime. 
	#This can be an org-specific URL (when org policy is set up) or, if generic org-neutral mode is used, it will just match the CoreSetupSrcUrl (below) 
	#We will refer to this as org-policy store or org-policy url in comments below (with the above understanding)
	$onlinePolicyStoreUrl = "[#onlinePolicyStoreUrl#]"

    #This is the org-neutral CDN endpoint. This gets overridden in org-policy setup.
	$CoreSetupSrcUrl = "[#CoreSetupSrcUrl#]"

	#This setting determines if the policy store enforces authentication. Generally 'false' for org-policy or OSS (org-neutral) context.
	$enableAADAuthForOnlinePolicyStore = "[#enableAADAuthForOnlinePolicyStore#]"
    $AzureEnv = "[#AzureEnvironment#]"
	#This is the script that is primarily responsible for setting up AzSK module in the automation account.
	$runbookCoreSetupScript = "RunbookCoreSetup.ps1"

	#This is the script that is run to peform the actual scanning. This is fetched from the org-policy store if org-policy 
	#is in use. If not, it is fetched from the default AzSK CDN. 
	#This script basically allows orgs to customize/tweak the scripts that are run to perform the daily CA scans.
	$runbookScanAgentScript = "RunbookScanAgent.ps1"

	$RunbookName = "Continuous_Assurance_Runbook"

	#This schedule ensures that CA activity initiated by the Scan_Schedule actually completes. 
	#It is handy in situations where the job got terminated due to a long running scan, etc. and 
	#a bunch of other situations (import of all modules into the CA account, etc.)
	$CAHelperScheduleName = "CA_Helper_Schedule"

	#This setting allows org policy owners to explore the latest version of AzSK (while users
	#in the org may be setup to use an older version - see comment in RunbookCoreSetup.PS1)
	$UpdateToLatestVersion = "[#UpdateToLatestVersion#]"	
	
	$azureRmResourceURI = "[#ManagementUri#]"
	
	#This is the Run-As (SPN) account for the runbook. It is read from the CA Automation account.
	$RunAsConnection = Get-AutomationConnection -Name "AzureRunAsConnection"

	#-----------------------------------Config end-------------------------------------------------------------------------

	#-----------------------------------Telemetry script-------------------------------------------------------------------
	PublishEvent -EventName "CA Job Started" -Properties @{
		"OnlinePolicyStoreUrl"=$OnlinePolicyStoreUrl; `
 	   "AzureADAppId"=$RunAsConnection.ApplicationId
	}

	#------------------------------------Execute RunbookCoreSetup.ps1 to download required modules-------------------------
	
	#Login to Azure
	if(!$RunAsConnection)
	{
		throw "Cannot login to Azure from AzSK CA runbook. Connection info for AzureRunAsConnection not found."
	}
	try
	{
		Write-Output("RB: Started runbook execution...")
		
		$appId = $RunAsConnection.ApplicationId 
		Write-Output ("RB: Logging in to Azure for appId: [$appId]")
		$loginCmdlets = Get-Command -Noun "AzureRmAccount" -ErrorAction SilentlyContinue
		if($Null -ne $loginCmdlets)
		{
			#AzureRm.profile version = 5.x.x
			if($Null -ne ($loginCmdlets | Where-Object{$_.Name -eq "Connect-AzAccount"}))
			{
				Connect-AzAccount `
				-Environment $AzureEnv `
				-ServicePrincipal `
				-TenantId $RunAsConnection.TenantId `
				-ApplicationId $RunAsConnection.ApplicationId `
				-CertificateThumbprint $RunAsConnection.CertificateThumbprint | Out-Null
			}
			#AzureRm.profile version = 4.x.x
			elseif ($Null -ne ($loginCmdlets | Where-Object{$_.Name -eq "Add-AzureRmAccount"})) 
			{
				Add-AzureRmAccount `
				-EnvironmentName $AzureEnv `
				-ServicePrincipal `
				-TenantId $RunAsConnection.TenantId `
				-ApplicationId $RunAsConnection.ApplicationId `
				-CertificateThumbprint $RunAsConnection.CertificateThumbprint | Out-Null
			}
			else
			{
				throw "RB: Failed to login to Azure. Check if AzureRm.profile module is present."
			}
		}
		else
		{
			throw "RB: Failed to login to Azure. Check if AzureRm.profile module is present."
		}
		
		Set-AzContext -SubscriptionId $RunAsConnection.SubscriptionID  | Out-Null
	}
	catch
	{
		Write-Output ("RB: Failed to login to Azure with AzSK AppId: [$appId].")
		throw $_.Exception
	}


	#This is a 'pseudo-version' and corresponds to the folder on the online policy store
	#from where the current CA core setup and scan agent scripts will be fetched.
	$caScriptsFolder = "1.0.0"
	#This is used *inside* the CoreSetup invocation below to control the version update for AzSK
	$UpdateToLatestVersion = ConvertStringToBoolean($UpdateToLatestVersion)

	#------------------------------------Invoke CoreSetup script to ensure AzSK is up to date and ready for the scan -------------------
	PublishEvent -EventName "CA Job Invoke Setup Started"
	Write-Output ("RB: Invoking core setup using policyStoreURL: [" + $CoreSetupSrcUrl.Substring(0,15) + "*****]")
	InvokeScript -policyStoreURL $CoreSetupSrcUrl -fileName $runbookCoreSetupScript -version $caScriptsFolder
	Write-Output ("RB: Completed core setup script.")
	PublishEvent -EventName "CA Job Invoke Setup Completed"

	#------------------------------------Execute RunbookScanAgent.ps1 to scan subscription and resources-------------------
	#We start with a check for 'Get-AzSKAccessToken' to ensure that AzSK module is ready (and loaded)
	if((Get-Command -Name "Get-AzSKAccessToken" -ErrorAction SilentlyContinue|Measure-Object).Count -gt 0)
	{
		#If policy store authN is set to true, get a token. (mostly for org policy/OSS, this will be 'false')
		if($enableAADAuthForOnlinePolicyStore -eq "true")
		{
			Write-Output("RB: Getting token for authN to online policy store.")
			$accessToken = Get-AzSKAccessToken -ResourceAppIdURI $azureRmResourceURI
		}

		PublishEvent -EventName "CA Job Invoke Scan Started"
		Write-Output ("RB: Invoking scan agent script. PolicyStoreURL: [" + $onlinePolicyStoreUrl.Substring(0,15) + "*****]")
		InvokeScript -accessToken $accessToken -policyStoreURL $onlinePolicyStoreUrl -fileName $runbookScanAgentScript -version $caScriptsFolder
		Write-Output ("RB: Scan agent script completed.")
		PublishEvent -EventName "CA Job Invoke Scan Completed"
	}
	else
	{
		Write-Output("RB: Not triggering a scan. AzSK module not yet ready in the automation account. Will retry in the next run.")
	}
	Write-Output("RB: Runbook execution completed...")
	PublishEvent -EventName "CA Job Completed" -Metrics @{
	"TimeTakenInMs" = $jobTimer.ElapsedMilliseconds; `
	"SuccessCount" = 1
	}
}
catch
{
	Write-Output ("RB: Exception occurred in CA runbook...`r`nError details: " + ($_ | Out-String))
	PublishEvent -EventName "CA Job Error" -Properties @{ "ErrorRecord" = ($_ | Out-String) } -Metrics @{"TimeTakenInMs" =$jobTimer.ElapsedMilliseconds; "SuccessCount" = 0}
	throw;
}
#----------------------------------Runbook end-------------------------------------------------------------------------
