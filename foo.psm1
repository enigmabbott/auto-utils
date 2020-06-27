#REQUIRES -VERSION 5.1
#Requires -Module powershell-yaml 
#Requires -Module jiraPS

#TODO INPUT as string stream

#returns an array of epic hashtables
function get-jyaml {
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

function _state_key { "auto.util.config_key" }

#this is a cheezy way around defining a class instantiating an object and have persistence between invocations
#... i think this is the zen of powershell
function _resolve_persistant_state_hash ($override_hash)  {
    $state_key = _state_key

    $hash = Get-PSFConfig -name $state_key

    $inline = {
        $config_hash = $args[0] 
        $param_hash = $args[1]
        @($param_hash.keys) | foreach-object { $config_hash[$_] = $param_hash[$_] }
        return $config_hash
    }

    if( -not  $hash){

        $hash = _resolve_config_hash(); 
        if(-not $hash) {
            $hash= @{}
        }
    }

    if( $override_hash){
        @($override_hash.keys) | foreach-object { $hash[$_] = $override_hash[$_] }
    }

    return $hash
}

function Delete-JHash {
    $state_key = _state_key

    $hash = Get-PSFConfig -name $state_key

    if($hash){
        Delete-PSFConfig -name $state_key

    }

    return $true
}

function sync-jyaml {
    param(
        [CmdletBinding()]
        [Parameter()]
        [String]$YamlFile
        [array]$YamlArray
        #.... bunch more jira stuff

        #--force this would update exsting epic... otherwise overwrite
    )

    $ConfigHash = _resolve_config_hash(); 
    if(-not $ConfigHash) {
        $ConfigHash = @{}
    }

    #let any passed in variables override ini and ENV
    @($PSBoundParameters.keys) | foreach-object { $ConfHash[$_] = $PSBoundParameters[$_] }

    $ConfigHash = _validate_config_for_required_params -ConfigHash $ConfigHash

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

function _required_init_params {@("JiraUrl", "credentials"); }
function _resolve_config_hash {
    $file = resolve_config_file
    $ini_hashtable = @{}

    if($file){
        try {
            $ini_hashtable = get-ini -path $file
        }catch {
            throw [System.IO.FileLoadException]"bad ini config file: $file"
        }
    }else {
        Write-PSFMessage -message "No config file... skipping ENV load too" -verbose
        return;
    }

    return Join-EnvToConfig -ConfigHash $ini_hashtable
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
    [CmdletBinding()]
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
    [CmdletBinding()]
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

Export-ModuleMember -Function 'Get-EnvHash',"Get-Ini","Join-EnvToConfig","Get-Jyaml","Set-Jyaml"
