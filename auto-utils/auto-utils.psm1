#REQUIRES -VERSION 5.1
#Requires -Module powershell-yaml
#Requires -Module jiraPS

#NOTES on conventions
# private functions: _my_private_function
# public functions:  Verb-Noun

#TODO but namespaces on module calls: Microsoft.PowerShell.Core\New-PSSession
#TODO INPUT as string stream

#returns an array of epic hashtables
#this requires on config or ENV... straightup/basic function
function Get-JYaml {
    param(
        [Parameter(
            Mandatory,
            HelpMessage="Enter Path to Yaml File containing JIRA Issues."
        )]
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

        if (( $yaml_struct -isnot [hashtable]) -or ( $yaml_struct -isnot [array])){
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
        [Parameter( HelpMessage="Enter Path to Yaml File containing JIRA Issues.")]
        [String]$YamlFile,
        [Parameter( HelpMessage="Output of Get-JYaml")] #array of hashtables
        [array]$YamlArray,
        [Parameter(HelpMessage="Config has already been resolved")]
        [hashtable]$ConfigHash,
        [Parameter(ValueFromRemainingArguments, HelpMessage="Any param that is your config can be overwritten as -CLI Argument")]
        $BonusParams

        #maybe provide -force this would update exsting epic... otherwise overwrite
    )

#validate args
    if(-not $YamlArray -and -not $YamlFile) {
        throw ("-YamlFile or -YamlArray are required params")
    }

    if( -Not $YamlArray ) {
        $YamlArray = Get-JYaml -YamlFile $YamlFile
    }

    if(-not $ConfigHash){
#setup session and load config
#this defines overall state of the session and takes the place of invocating an instance object which has similar properties
#hoping this is the powershell way...
#$ConfigHash = _jyaml_init_config -PassThruParams $BonusParams
        $ConfigHash = _jyaml_init_config @BonusParams

        $fields_hash = Get-JCustomFieldHash  -ConfigHash $ConfigHash
        if(-not $fields_hash ){
            throw "Could not fetch jira custom fields.. FATAL";
        }

        $ConfigHash[(_config_jira_fields_key) ] = $fields_hash
    }

#make sure yaml won't bomb mid import
    _validate_jyaml($YamlArray) #should be fatal if missing required or has unknown params

#might want create a generic PreJiraIssue class call methods rather than work on raw data-structures
    foreach ($epic in $YamlArray ) {
        $epic_params = @{IssueType = "Epic"}
        $epic.keys | where-object { $_ -notmatch "Stories" }| foreach-object  { $epic_params[$_] =$epic[$_] }
        $epic_params = _validate_epic_params  -EpicParams $epic_params

        try {
            $epic = new-JiraIssue @epic_params
        }catch {
            throw "failed to create issue"
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

        #Set-JiraIssue @parameters -Issue $id.key

    }
}

#returns bool
function _is_older_than { #perhaps make this public? maybe there's already one out there?
    param(
        [Parameter(Mandatory)]
        [string] $date_string,
        [int] $threshold
    )

    $is_older_than = $false

    $now_date = Get-Date

    try {
        $creation_date = [datetime] $date_string
        $delta = New-TimeSpan -start $creation_date -end $now_date

        if($delta.Days -lt $threshold) {
            $is_older_than = true;
        }
    } catch {
        Write-PSFMessage -Level Warning -Message "bad date-time format in description... resetting" -Verbose
        $is_older_than = $true
    }

    return $is_older_than;
}

<#
$investigate this vs using the jira-session
     $Credential = Get-StoredCredential -Target $cmTarget
        #prompt for credential
        $Credential = get-credential

        $storedCredential = @{
                Target         = $cmTarget
                UserName       = $Credential.UserName
                SecurePassword = $Credential.Password
            }

        $null = New-StoredCredential @storedCredential -Comment "for use with the Jira module"
        #Remove-StoredCredential -Target $cmTarget -ErrorAction Ignore
#>

function _jyaml_init_config {
    param(
        [Parameter(ValueFromRemainingArguments, HelpMessage="Any param that is your config can be overwritten as -CLI Argument")]
        [array]$PassThruParams
    )

#always override config w/ cli... BUT NOTE we don't set them in PSProperty
    if($PassThruParams) {
        $ConfigHash = _resolve_env_config @PassThruParams; # or FATAL
    }

    $jserver = JiraPS\Get-JiraConfigServer;
    $jira_uri_key = _config_url_key
    $reset_server_flag = $false

    if($ConfigHash[$jira_uri_key ] ){
        $uri_from_config = $ConfigHash[ $jira_uri_key ];

        if( $jserver -and ($uri_form_config -ne $jserver )){
            Write-PSFMessage -message "config differs from Get-JiraConfigServer.. setting to: $uri_from_config " -verbose
            JiraPS\Set-JiraConfigServer $uri_from_config
            $reset_server_flag = $true

        } elseif ( -not $jserver ){
            Write-PSFMessage -message "set JiraConfigServer to: $uri_from_config " -verbose
            JiraPS\Set-JiraConfigServer $uri_from_config
            $reset_server_flag = $true

        }

    } elseif (-not $jserver ) {
        throw "need $jira_uri_key in config or as cli argument"
    }

    $jira_session = JiraPS\Get-JiraSession

    if( $reset_server_flag ) {$jira_session = $null }

    if( $ConfigHash["credential"] ){
         Write-PSFMessage -message "Resetting credential " -verbose
         $jira_session = New-JiraSession -Credential $ConfigHash["credential"]

    } elseif (!$jira_session){
        $jserver = JiraPS\Get-JiraConfigServer;
        $params = @{"Message" = "Enter params for JIRA: $jserver" }

        $user_key = _config_user_key ;
        if($ConfigHash[$user_key]){
            $params["username"] =  $ConfigHash[$user_key]
        }

        $jira_session = New-JiraSession -Credential (get-credential @parms)
    }

    return $ConfigHash
}

function _validate_jyaml {
    param(
        [Parameter(Mandatory, HelpMessage="Requred From Get-JYaml")] #array of hashes
        [array]$YamlArray,
        [Parameter(Mandatory,HelpMessage="Config should already be resolved")]
        [hashtable]$ConfigHash
    );

    $fields = $ConfigHash[(_config_jira_fields_key)]

    if(-not $fields){
        throw "jira fields should be resolved earlier... this is a developer error"
    }

    $errors = $false

    foreach ($proto_issue in $YamlArray){
        foreach ($key in $proto_issue.keys){
            if(-not $fields[$key]){
                Write-PSFMessage -Level Warning -message "Invalid yaml; key: $key is not among the supported fields of your jira instance" -verbose;
                $errors = $true
            }
        }
    }

    if($errors){
        throw [System.IO.InvalidDataException]"Bad Yaml";
    }

    return $true
}

function Get-JCustomFieldHash {
    param(
        [Parameter(HelpMessage="Config has already been resolved")]
        [hashtable]$ConfigHash,
        [Parameter(ValueFromRemainingArguments, HelpMessage="Any param that is your config can be overwritten as -CLI Argument")]
        $BonusParams

    );

    if(-not $ConfigHash){
        $ConfigHash = _jyaml_init_config @BonusParams
    }

    $fields =  Get-JiraField

    $field_hash = @{}
#support both name and ID
    $fields | foreach-item {
        $field_hash[$_.ID] = $_;
        $field_hash[$_.name] = $_
        };

    return $field_hash;
}

function _config_url_key { "JiraUrl"}
function _config_user_key { "JiraUser"}
function _config_jira_fields_key{ "JiraFields" }  #this is resolved and shouldn't be provided
function _config_ini_name { ".poshjiraclientrc"}

#returns bolean
function  _validate_config_for_required_params {
    param(
        [Parameter(Mandatory)]
        [hashtable]$ConfigHash
    )

   foreach ( $required in @("JiraUrl", "JiraProject", "credential")) {
        if( -not $ConfigHash[$required]) {
            throw [System.MissingFieldException]"missing field: $required"
        }
    }

    return $true;
}

function _resolve_env_config { #returns a hash from ini, ENV, and cli params
    param(
        [Parameter(ValueFromRemainingArguments, HelpMessage="Any param that is your config can be overwritten as -CLI Argument")]
        [array]$PassThruParams
    )

    $env_hashtable = @{}
    $file = _resolve_config_file
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

    $env_hashtable = Join-EnvToConfig -ConfigHash $env_hashtable

    if($PassThruParams) {
        $hash_PassThruParams = Convert-ArrayToHash @PassThruParams
        @($hash_PassThruParams.keys) | foreach-object { $env_hashtable[$_] = $hash_PassThruParams[$_] }
    }

    return $env_hashtable
}

function _resolve_config_file {
    foreach ($p in @($Env:HOME,  (get-location).path) ) {
        $maybe_rc = Join-Path -Path $p -ChildPath (_config_ini_name)
        if(Test-Path -Path $p and Test-Path -Path $maybe_rc) {
            return $maybe_rc
        }
    }
    return;
}

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
        [Parameter( HelpMessage="this is the content of your ini file; be sure to: gc foo.ini | out-string")]
        [string[]]$Text
    )

    Process {
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

#this is a basic/common thing in perl... googled and googled and couldn't find native Posh way
#rolling my own
#perl example: my %hash = @array; #note array must be even
function Convert-ArrayToHash  {
    param(
        [parameter(HelpMessage= "be sure to splat your arrays when invoking", ValueFromRemainingArguments)]
        [array]$array
        )

    if(($array.length) % 2 -ne 0) {
        throw [System.InvalidCastException]"odd number of elements in array can not be converted to hash"
    }

    $hash = @{};

    for ($i = 0;  $i -lt $array.length ; $i++){
        if ($i % 2  -ne 0 ){ Continue}

        #trim off "-"
        $key = $array[$i].toString();
        if($key -match "^-"){
            $key = $key.substring(1 , ($key.length - 1))
        }

        $hash[$key] = $array[$i +1];
    }

    return $hash
}

Export-ModuleMember -Function 'Get-*','Join-*','Sync-*', 'Convert-*'
