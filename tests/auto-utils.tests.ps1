#Requires -version 5.1

$module_name= "auto-utils"
$base= split-path $PSScriptroot
$module_path =  "$base/$module_name/$module_name.psm1"
import-module $module_path -force

$global:TEST_CONFIG_DIR =  $PSScriptroot + "\var\";

InModuleScope $module_name {
    Describe "test not exported functions" -tag "internal" {
        Context "simple ini file" {
            BeforeAll {
                if($env:vb){ $verbosepreference = $env:vb }
                $file = $global:TEST_CONFIG_DIR +"foo.ini"
            }
            #declaring this 2x is whack... please help; errors if you don't do it
            $file = $global:TEST_CONFIG_DIR +"foo.ini"

            IT "ini exists" {
                write-verbose "file: $file"
                $file | Should -Exist
            }

            It "ini file provided: $file" {
                $content = (get-content -path $file | out-string)
                $x = _parse_ini_content -Text $content
                $x | should -not -benullorempty
            }

            It "txt provided" {
                $my_text = @"
[monkey]
#this is a comment
       some bogus stuff
eyes=foo
balls=bar
[section2]
foo=bar
"@
                $string_array= $my_text.split("`n")
                $x = _parse_ini_content -Text $string_array
                $x | should -not -benullorempty
                $x | should -not -match 'comment'
                $x | should -not -match 'bogus'

            }
        }

        Context "parse config" {
            BeforeAll {
                remove-JiraSession
                mock _credential_wrapper -MockWith  {
                    $User = "Domain01\User01"
                    $PWord = ConvertTo-SecureString -String "P@sSwOrd" -AsPlainText -Force
                    return New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $User, $PWord 
                }

                $cf_name = "foo.configrc"
                $config_file = Join-Path $TestDrive $cf_name 
                mock _resolve_config_file -MockWith { $config_file }

                Set-JiraConfigServer -Server "foo"
            }

            It "no ini no ENV" {
                $verbosepreference = "Continue"
                $file = _resolve_config_file;
                $file | should -be $config_file

                {_jyaml_init_config} | Should -throw -ExceptionType([System.IO.FileLoadException])
                {_jyaml_init_config -JiraUrl "mybar"} | Should -throw -ExceptionType([System.IO.FileLoadException])

            }

            #we require an ini.. and ENV can override ini values but we can't have ENV vars w/o corresponding ini
            It "no ini and ENV"  {
                $VerbosePreference = "Continue"
                $key = _config_url_key
                $fake_url = "https://awesomeATL.jira.com"
                $env_var_name =  '$env:' +$key
                $ex_string =  $env_var_name + ' = "' + $fake_url +'"'
                invoke-expression $ex_string
                $val = invoke-expression $env_var_name
                $val | should -be $fake_url
                {_jyaml_init_config} | Should -throw -ExceptionType([System.IO.FileLoadException])
                $unwind = "remove-item Env:$key"

                invoke-expression $unwind

            }
        }

        Context "_validate_jyaml" {

        }
    }
}

Describe "basic ini parser tests"  -tag "external" {
    Context "simple ini file" {
        BeforeAll {
                if($env:vb){ $verbosepreference = $env:vb }
                $file = $global:TEST_CONFIG_DIR +"foo.ini"
        }

        It "bad params" {
            {Get-Ini} | should -Throw
        }

        It "good params" {
            $obj = Get-Ini -path $file
            write-verbose (ConvertTo-Json $obj)
            $obj | should -not -BeNullOrEmpty
            $obj.count|should -be 2
            $obj.containsKey("foo")| should -be $true
            $obj.containsKey("foo1")| should -be $true
        }

        It "txt provided" {
            $my_text = @"
[monkey]
#this is a comment
eyes=foo
balls=bar
"@

            $string_array = $my_text.split("`n")
            $hash = Get-Ini -Text $string_array -NoSections
            $hash | should -not -benullorempty
            $hash.ContainsKey("eyes") | should -be $true

            $my_text = @"
eyes=foo
balls=bar
"@

            $string_array = $my_text.split("`n")
            $hash = Get-Ini -Text $string_array -NoSections
            $hash | should -not -benullorempty
            $hash.ContainsKey("eyes") | should -be $true
        }
    }
}

Describe "Get-EnvHash Tests" -tag "external" {
    It "basic test"{
       $hash = Get-EnvHash
       $hash | Should -not -BeNullOrEmpty
       ($hash -is [hashtable]) | Should -Be $true
       $hash.containsKey("OS")
    }
}
Describe "Update-JYamlConfig Tests" {
    It "Update-JYamlConfig"  {
        $config_file = Join-Path $TestDrive  "foo.configrc"
        add-content -value $null -path $config_file
        mock _config_file_in_user_home {$config_file}

        $file =Update-JYamlConfig -JiraUrl "https:\foo.bar.jira.com" -JiraUser "bobby"
        (test-path $file) | should -be $true
        $generated_ini = Get-Content $file
        $generated_ini | should -not -benullorempty
        $hits = $generated_ini | Select-String -Pattern 'JiraUrl'
        $hits | should -not -benullorempty
    }
}

Describe "Join-EnvToConfig Tests" {
    Context "env and config test" {
        BeforeAll {
            $config_hash = @{
                  "s1" = @{"one" = "one"; "two" = "two"};
                  "s2" = @{"three" = "three"; "four" = "four"};
                  "monkey" = "eyeballs"
            };
        }

        It "no manipulation" {
            $hash2 = Join-EnvToConfig -configHash $config_hash
            $hash2 | should -not -BeNullOrEmpty
            $hash2.containsKey("s1") | should -be $true
            $hash2["s1"].containsKey("one") | should -be $true
            $hash2["s1"]["one"] | should -be "one"
            $hash2.containsKey("monkey") | should -be $true
            $hash2["monkey"] | should -be "eyeballs"
        }

        It "env override config" {
            $two = "two"
            $monkey = "foo"
            $env_hash = @{"one"=$two;"monkey"=$monkey};
            $hash2 = Join-EnvToConfig -configHash $config_hash -envHash $env_hash
            $hash2 | should -not -BeNullOrEmpty
            $hash2.containsKey("s1") | should -be $true
            $hash2["s1"].containsKey("one") | should -be $true
            $hash2["s1"]["one"] | should -be $two
            $hash2.containsKey("monkey") | should -be $true
            $hash2["monkey"] | should -be $monkey
        }
    }
}

Describe "yaml tests" {
    Context "Bad yaml" {
        It "empty yaml" {
            $empty_yaml_file = $global:TEST_CONFIG_DIR + "empty.yaml"
            $empty_yaml_file | should -exist
            $content = Get-Content $empty_yaml_file
            (!$content) | should -be $true
            {Get-JYaml -YamlFile $empty_yaml_file} | Should -throw -ExceptionType([System.IO.FileLoadException])
        }

    It "multiple epics yaml" {
            $base= split-path $PSScriptroot
            $yaml_file = "$base/examples/ex2.yaml"
            $yaml_file | should -exist
            $content = Get-Content $yaml_file
            $content | should -not -benullorempty
            ($struct) = Get-JYaml -YamlFile $yaml_file
            #Write-PSFMessage "foo" -Debug
            #$struct | Should -not -benullorempty
            $struct[0] | Should -not -benullorempty
            $struct[0].summary | Should -be "This is an Epic"
        }

        It "malformed yaml" -tag "disabled" {
            $true | should -be $true
        }
    }
}

Describe "Sync-JYaml" -tag "external" {
    It "bad params" {
        {Sync-JYaml} | should -Throw -ExceptionType ([System.Management.Automation.MethodInvocationException])
    }
}

Describe "Show-JYamlConfig Tests" {
    It "Show-JYamlConfig"  {
        $base= split-path $PSScriptroot
        $config_file = Join-Path $base "\examples\.poshjiraclientrc" 

        mock _config_file_in_user_home {$config_file}

        $string = Show-JYamlConfig
        $string | should -not -benullorempty
    }
}

Describe "Get-JCustomFieldHash Tests" -tag "THIS" {
    It "Get-JCustomFieldHash FAILS"  {
        $hash = Get-JCustomFieldHash
    }

    It "Get-JCustomFieldHash Success"  {

    }
}



#test jira fetch fields
#test parse jira yaml ...valid keys
#test issue create epic
#test issue create epic and child
#test issue create epic and child #fail if summary already exists
#test issue create epic and child #force allows duplicates

