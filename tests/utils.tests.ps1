#Requires -version 5.1

$module_name= "ameren-utils"
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
                $more_string = $my_text.split("`n")
                $x = _parse_ini_content -Text $more_string
                $x | should -not -benullorempty
                $x | should -not -match 'comment'
                $x | should -not -match 'bogus'
                            }
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
            {get-ini} | should -Throw
        }

        It "good params" {
            $obj = get-ini -path $file 
            write-verbose (ConvertTo-Json $obj)
            $obj | should -not -BeNullOrEmpty
            $obj.count|should -be 2
            $obj.containsKey("foo")| should -be $true 
            $obj.containsKey("foo1")| should -be $true 
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

Describe "Join-EnvToConfig Tests" {
    Context "env and config test" {
        BeforeAll {
            $config_hash = @{
                  "s1" = @{"one" = "one"; "two" = "two"};
                  "s2" = @{"three" = "three"; "four" = "four"};
                  "monkey" = "eyeballs"
            };
        }

        It "no manipulation"{
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
            $content = get-content $empty_yaml_file
            (!$content) | should -be $true
            #get-jyaml -YamlFile $empty_yaml_file
            {get-jyaml -YamlFile $empty_yaml_file} | Should -throw -ExceptionType([System.IO.FileLoadException])
        }

        It "malformed yaml" -tag "disabled" {
            $true | should -be $true
        }
    }
}
