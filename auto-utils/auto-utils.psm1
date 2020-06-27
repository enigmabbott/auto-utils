#REQUIRES -VERSION 5.1
#Requires -Module powershell-yaml 
#Requires -Module jiraPS

#TODO but namespaces on module calls: Microsoft.PowerShell.Core\New-PSSession
#TODO INPUT as string stream


#RIP OUT the  PSFConfig stuff
#what do we really want to store: credentials or session ... thats it

#returns an array of epic hashtables
function Get-JYaml {
    param(
        [CmdletBinding()]
        [Parameter(Mandatory)]
        [ValidateScript({
            if( -Not ($_ | Test-Path) ){
                throw "File or folder does not exist"
            }
            return $true
        })]
        [String]$YamlFile
    )

    $yaml_array_of_hashtables = @{};
    $yaml_struct; # could be hash (1 epic) or an array of epics

    try {
        $yaml_struct = get-content $YamlFile | ConvertFrom-Yaml;

        if(! $yaml_struct){
            throw [System.IO.FileLoadException]"yaml file is empty"
        }

        if (-Not $yaml_struct -is [hashtable] or -not $yaml_struct -is [array]){
            throw [System.IO.FileLoadException]"bad yaml is not a hashtable or array"
        } 

        if ($yaml_struct -is [hashtable]){
            $yaml_array_of_hashtables +=   $yaml_struct

        }else {
            $yaml_array_of_hashtables =   $yaml_struct
        }

    } catch {
        Write-PSFMessage -Level Warning -Message "invalid yaml file: $YamlFile" -ErrorRecord $_
        throw
    }

    Write-PSFMessage -message "Loaded yaml file: $YamlFile" -verbose
    return $yaml_array_of_hashtables;
}

#yaml file struct likes like this:

function Sync-JYaml {
    param(
        [CmdletBinding()]
        [Parameter()]
        [String]$YamlFile
        [array]$YamlArray #this is an array of Hashes (from Get-JYaml)
        #.... bunch more jira stuff

        #--force this would update exsting epic... otherwise overwrite
    )

#validate args
    if(-not $YamlArray and -not $YamlFile) {
        throw ("-YamlFile or -YamlArray are required params")
    }

    if( -Not $YamlArray ) {
        $YamlArray = Get-JYaml -YamlFile $YamlFile
    }

#setup session and load config
#this defines overall state of the session and takes the place of invocating an instance object which has similar properties
#hoping this is the powershell way...
    $ConfigHash = _jyaml_init_config -OuterBound $PSBoundParameters

#this needs to be outside of the init to avoid circular dependency
#this also serves an initial handshake check w/ jira as this will always make an http request
    $ConfigHash = _resolve_any_additional_fields -ConfigHash $ConfigHash

#make sure yaml won't bomb mid import
    _validate_jyaml($YamlArray) #should be fatal if missing required or has unknown params

#we are good to proceed
    foreach ($epic in $YamlArray ) {
        $epic_params = @{IssueType = "Epic"}
        $epic.keys |where-object { $_ -notmatch "Stories" }| foreach-object  { $epic_params[$_] =$epic[$_] }
        $epic_params = _validate_epic_params  -EpicParams $epic_params

        try {
            $epic = new-JiraIssue @epic_params
        }

        #Set-JiraIssue -Issue $id.key -Assignee 'E141355'

<#
$parameters = @{
     Fields = @{
        customfield_10210 = "VRA  Developer"  ## As a:
        customfield_10202 = "create a script that will generate Mini ISO file to boot the server for network access"   ##   I want:
        customfield_10203 = "we can connect to Kickstart server to pull the OS Files "   ## So that :
        customfield_10101 = "IA-56"  ## link to Epic
    }
}
#>

Set-JiraIssue @parameters -Issue $id.key

    }
}

function Get-JYamlPSFName { "auto.util.jyaml_config"}

#returns bool
function _config_is_too_old {
    param(
        [Parameter(Mandatory)]
        [string] $date_string,
        [int] $threshold
    )

    $force = $false

    $now_date = Get-Date

    try {
        $creation_date [datetime] $date_string
        $delta = New-TimeSpan -start $creation_date -end $now_date

        if($delta.Days > $threshold) {
            $force = true;
        }
    } catch {
        Write-PSFMessage -Level Warning -Message "bad date-time format in description... resetting" -Verbose
        $force = $true
    }

    return $force;
}

#int in days of how long the PSFProperty env cache can live before a refresh
#note this can be overwritten in config file
function _default_ttl_cache { 7 } 

function  _jyaml_init_config {
    param(
        [array]$OuterBound
        [bool]$force
    )

#check propertyConfig cache
#TODO: put a time to live cache-key
    $ConfigHash = Get-PSFConfig -Name Get-JYamlPSFName

    if (-not $force and $ConfigHash) {
        $threshold_in_days = if ($ConfigHash[TTL_CONFIG_DAYS]) { $ConfigHash[TTL_CONFIG_DAYS]) } else { _default_ttl_cache}
        $force = _config_is_too_old -date_string $ConfigHash.description -threshold $threshold_in_days
    }

    if(-Not $ConfigHash or $force) {
        $ConfigHash = _check_config_for_credentials -ConfigHash $ConfigHash;# or FATAL
        $ConfigHash = _validate_config_for_required_params -ConfigHash $ConfigHash
        Set-PSFConfig -FullName Get-JYamlPSFName -Value $ConfigHash -Description ( Get-Date -Format "dddd MM/dd/yyyy HH:mm").ToString()

    }

    #always override cache w/ cli... BUT NOTE we don't set them in PSProperty

    if($OuterBound) {
        $ConfigHash = _resolve_env_config -OuterBound $OuterBound; # or FATAL
    }

    return $ConfigHash
}
                                  
function Delete-JYamlConfig {}
    $hash = Get-PSFConfig -name Get-JYamlPSFName
                                  
    if($hash){                    
        Delete-PSFConfig -name Get-JYamlPSFName
    }                             
                                  
    return $true                  
}                                 
                                  
function Sync-JYaml {             

}

function _validate_jyaml {
    param(
        [Parameter(Mandatory)]
        [array]$YamlArray #this is an array of Hashes (from Get-JYaml)
    )
}

function  _resolve_any_additional_fields {
    param(
        [Parameter(Mandatory)]
        [hashtable]$ConfigHash
    )

    [array]$all_jfields = Get-JCustomFieldHash -ConfigHash $ConfigHash 
}

function Get-JCustomFieldHash {
    param(
        [Parameter()]
        [hashtable]$ConfigHash

    if(-not $ConfigHash){
        $ConfigHash =  _jyaml_init_config ;
    }

    #Get-CustomField
}

function  _validate_config_for_required_params {
    param(
        [Parameter(Mandatory)]
        [hashtable]$ConfigHash
    )

<#
     $Credential = Get-StoredCredential -Target $cmTarget
    if( -not $ConfigHash["credentials"]) {
        #prompt for credential
        $ConfigHash["credentials"] = get-credential
                    $storedCredential = @{
                Target         = $cmTarget
                UserName       = $Credential.UserName
                SecurePassword = $Credential.Password
            }
            $null = New-StoredCredential @storedCredential -Comment "for use with the Jira module"
            #Remove-StoredCredential -Target $cmTarget -ErrorAction Ignore
#>
    }

    foreach ( $required in @("JiraUrl", "JiraProject", "credentials")) {
        if( -not $ConfigHash[$required]) {
            throw [System.MissingFieldException]"missing field: $required"
        }
    }

    return $ConfigHash;
}

function _required_params {@("JiraUrl", "JiraProject", "credentials"); }
function _resolve_env_config ($OuterBound) { #returns a hash from ini, ENV, and cli params

    $env_hashtable = @{}
    $file = resolve_config_file
    if($file){
        try {
            $env_hashtable = get-ini -path $file
        }catch {
            throw [System.IO.FileLoadException]"bad ini config file: $file"
        }
    }else {
        Write-PSFMessage -message "No config file... skipping ENV load too" -verbose
        return;
    }

    $env_hashtable Join-EnvToConfig -ConfigHash $env_hashtable

    if($OuterBound) {
        @($OuterBound.keys) | foreach-object { $env_hashtable[$_] = $OuterBound[$_] }
    }

    return $env_hashtable
}

function _resolve_config_file {
    foreach ($p in @($Env:HOME,  (get-location).path) ) {
        $maybe_rc = join-path -path $p -ChildPath _ini_config_name
        if(test-path $p and test-path $maybe_rc) {
            return $maybe_rc
        }
    }
    return;
}

function _ini_config_name { ".poshjiraclientrc"}


function Get-Ini {
    Param(
        [Parameter(
                   HelpMessage="Enter the path to an INI file",
                   ValueFromPipeline,
                   ValueFromPipelineByPropertyName)]
        [Alias("fullname","pspath")]
        [ValidateScript({
            if (Test-Path $_) {
               $True
            } else {
              Throw "Cannot validate path $_"
            }
        })]
        [string]$Path,
        [Parameter(
                   HelpMessage="this is the content of your ini file; be sure to: gc foo.ini | out-string"
        )]
        [string[]]$Text
    )

    if(!$path -and !$text){
       throw " -Path or -Text are required arguments"
    }

    if(! $text) {
        $text = get-content -path $path
    }

    $ini_content = _parse_ini_content -Text $text

    if(! $ini_content){ throw "no ini content" }

    $ini_obj = @{}
    $hash = @{}
    [string]$section=""
    $section_regex = "^\[.*\]$";

    $i = 0;
    if($env:vb){ $verbosepreference = $env:vb }
    foreach ($line in $ini_content) {
        $line = $line.trim()
        if($line -match "^$"){
            continue;
        }

        $i++;

        $str = $i.tostring() + " " + $line
        write-verbose $str

        #this is not the first section.. but a subsequent section if it exists
        #we write all the collected data then redeclare a section
        #example:[my_section]
        if (($line -match $section_regex) -AND $section ) {
            $ini_obj[$section] = $hash

            #re init variables
            $hash=@{}
            $section = $line  -replace "\[|\]",""

        #Get section name. This will only run for the first section heading
        #example:[my_section]
        } elseif ($line -match $section_regex) {
            $section = $line -replace "\[|\]",""

        } elseif ($line -match "=") {
            $key,$value= $line.split("=").trim()
            $hash[$key]= $value

        } else {
            #this should probably never happen
            Write-Warning "Unexpected line $line"
        }
    }

    #get last section
    if(!$section){ $section = "default"}

    If ($hash.count -gt 0) {
        $ini_obj[$section] = $hash
    }
    return $ini_obj
}

function Join-EnvToConfig {
    Param(
        [Parameter(Mandatory, HelpMessage="config hash")]
        [hashtable]$configHash,
        [Parameter(HelpMessage="env: as hash")]
        [hashtable]$envHash
    )

    if(-not $envHash){
        $envHash = Get-EnvHash
    }

    if($env:vb){ $verbosepreference = $env:vb }
    $config_copy = $configHash.clone();
    
    foreach( $key in $config_copy.keys){
        write-verbose "key check: $key"
        if($ConfigHash[$key] -is [hashtable]){
            $configHash[$key] = 
                Join-EnvToConfig -ConfigHash $config_copy[$key] -envHash $envHash

            continue
        }

        if($envHash.containsKey($key)){
            write-verbose "Config Override by ENV: $key"
            $configHash[$key] = $envHash[$key]
        }
    }

    return $configHash
}

function Get-EnvHash {
    $hash = @{}
    foreach ($_ in (Get-ChildItem env:)){
        $hash[$_.name] = $_.value
    }

    return $hash
}

function _parse_ini_content {
    Param( [Parameter(Mandatory)] $Text)
    return  ($Text | where-object { $_ -notmatch "^#|^\s"})
}   

Export-ModuleMember -Function 'Get-*','Join-*','Sync-*'
