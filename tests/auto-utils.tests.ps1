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
                $file = $global:TEST_CONFIG_DIR + "foo.ini"
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
                #$verbosepreference = "Continue"
                $file = _resolve_config_file;
                $file | should -be $config_file

                {_jyaml_init_config} | Should -throw -ExceptionType([System.IO.FileLoadException])
                {_jyaml_init_config -JiraUrl "mybar"} | Should -throw -ExceptionType([System.IO.FileLoadException])
            }

            #we require an ini.. and ENV can override ini values but we can't have ENV vars w/o corresponding ini
            It "no ini and ENV"  {
                #$VerbosePreference = "Continue"
                $key = _config_jira_url_key
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
            BeforeAll {
                $my_text = @"
- epic name: Epic foo
  summary: This is an Epic
  description: My Epic description
  stories:
    - summary:  Story1 
      description: story s1 has a short description
"@

                [array]$array_of_hash = Get-Jyaml -YamlString $my_text #note explicit cast to array so struct w 1 element doesn't flatten out
                $array_of_hash | Should -not -benullorempty
                #$array_of_hash | Should -BeOfType [array] #not sure why this doesn't work
                $array_of_hash.count | Should -Be 1
                $array_of_hash[0] | Should -BeOfType [hashtable]
                $array_of_hash[0].summary | Should -be "This is an Epic"
            }

            It "jira yaml with bad-wrong jira-fields" {
                $config_hash = @{
                    "foo" = "foo" ;
                    "project" = "MONK";
                    "JiraFields" = @{
                        "field1" = "foo" ;
                        "field2" = "bar";
                        "monkey" = "eyeballs"
                    };
                };

                {_validate_jyaml -YamlArray $array_of_hash -ConfigHash $config_hash} | should -Throw -ExceptionType ([System.IO.InvalidDataException])
            }

            It "jira yaml with all good fields" {
                $config_hash = @{
                    "foo" = "foo" ;
                    "project" = "MONK";
                    "JiraFields" = @{
                        "summary" = "foo" ;
                        "description" = "bar";
                        "stories" = "eyeballs";
                        "epic name" = "eyeballs";
                    };
                };

                (_validate_jyaml -YamlArray $array_of_hash -ConfigHash $config_hash) | should -Be $true
            }

            It "jira yaml with subtasks bad value" {
                #$VerbosePreference = "Continue"
                $my_text = @"
- epic name: Epic foo
  summary: This is an Epic
  description: My Epic description
  stories:
    - summary:  Story1 
      description: story s1 has a short description
      subtasks:
        - summary: s1 st1 summary
          description: s1 st1 description
          bad-field: hey
"@
                $config_hash = @{
                    "foo" = "foo" ;
                    "project" = "MONK";
                    "JiraFields" = @{
                        "summary" = "foo" ;
                        "description" = "bar";
                        "stories" = "eyeballs";
                        "epic name" = "eyeballs";
                        "subtasks" = "foo";
                    };
                };

                [array]$array_of_hash = Get-Jyaml -YamlString $my_text #note explicit cast to array so struct w 1 element doesn't flatten out
                $array_of_hash | Should -not -benullorempty
                {_validate_jyaml -YamlArray $array_of_hash -ConfigHash $config_hash} | should -Throw -ExceptionType ([System.IO.InvalidDataException])
            }

            It "project resolution from config and yaml" { #this is redundant w/ next test
                $project_name = "MYPROJ"
                $my_epic= @"
- epic name: Epic foo
  summary: This is an Epic
  description: My Epic description
"@

                $config_hash = @{
                    "foo" = "foo" ;
                    "Project" = $project_name
                    "JiraFields" = @{
                        "summary" = "foo" ;
                        "description" = "bar";
                        "stories" = "eyeballs";
                        "epic name" = "eyeballs";
                        "subtasks" = "foo";
                    };
                };

                [array]$array_of_hash = Get-Jyaml -YamlString $my_epic #note explicit cast to array so struct w 1 element doesn't flatten out
                $array_of_hash | Should -not -benullorempty
                $array_of_hash.count| Should -be 1

                $project = _resolve_jira_project -IssueStruct $array_of_hash[0] -ConfigHash $config_hash 
                $project | Should -not -BeNullOrEmpty
                $project | Should -Be $project_name

                $config_hash.Remove("Project")
                $project_name2 = "MYPROJ2"
                $my_epic= @"
- epic name: Epic foo
  summary: This is an Epic
  description: My Epic description
  project: $project_name2
"@
                [array]$array_of_hash = Get-Jyaml -YamlString $my_epic #note explicit cast to array so struct w 1 element doesn't flatten out
                $array_of_hash | Should -not -benullorempty
                $array_of_hash.count| Should -be 1

                $project = _resolve_jira_project -IssueStruct $array_of_hash[0] -ConfigHash $config_hash
                $project | Should -not -BeNullOrEmpty
                $project | Should -Be $project_name2
            }

            It "project supplied or not" {
                #$VerbosePreference = "Continue"
                $my_text = @"
- epic name: Epic foo
  summary: This is an Epic
  description: My Epic description
"@
                $config_hash = @{
                    "foo" = "foo" ;
                    "JiraFields" = @{
                        "summary" = "foo" ;
                        "project" = "foo" ;
                        "description" = "bar";
                        "epic name" = "eyeballs";
                    };
                };
#no project field at all
                [array]$array_of_hash = Get-Jyaml -YamlString $my_text #note explicit cast to array so struct w 1 element doesn't flatten out
                $array_of_hash | Should -not -benullorempty
                {_validate_jyaml -YamlArray $array_of_hash -ConfigHash $config_hash} | should -Throw -ExceptionType ([System.MissingFieldException])

#global/config project field set
                $config_hash["project"] = "myProject"
                (_validate_jyaml -YamlArray $array_of_hash -ConfigHash $config_hash) | should -Be $true

#project supplied by issue
                $config_hash.remove("project")
                $array_of_hash[0]["project"] = "myProject"
                (_validate_jyaml -YamlArray $array_of_hash -ConfigHash $config_hash) | should -Be $true
            }
        }

        Context "issue related functions"  {
            It "_issue_is_epic" {
                $my_epic= @"
- epic name: Epic foo
  summary: This is an Epic
  description: My Epic description
"@

                $config_hash = @{
                    "foo" = "foo" ;
                    "JiraFields" = @{
                        "summary" = "foo" ;
                        "description" = "bar";
                        "stories" = "eyeballs";
                        "epic name" = "eyeballs";
                        "subtasks" = "foo";
                    };
                };

                [array]$array_of_hash = Get-Jyaml -YamlString $my_epic #note explicit cast to array so struct w 1 element doesn't flatten out
                $array_of_hash | Should -not -benullorempty
                $array_of_hash.count| Should -be 1

                (_issue_is_epic -IssueStruct $array_of_hash[0] -ConfigHash $config_hash) | Should -be $true

                $my_non_epic= @"
- summary: This is an Epic
  description: My Epic description
"@
              [array]$array_of_hash = Get-Jyaml -YamlString $my_non_epic #note explicit cast to array so struct w 1 element doesn't flatten out
                $array_of_hash | Should -not -benullorempty
                $array_of_hash.count| Should -be 1

                (_issue_is_epic -IssueStruct $array_of_hash[0] -ConfigHash $config_hash) | Should -be $false
            }
        }

        Context "issue search" -tag "THIS"{
            It "already cached"  {
                $project_name = "FBALLS"
                $fake_summary = "this is a summary"
                $fake_issue = @{summary = $fake_summary};
                $config_hash = @{
                    "foo" = "foo" ;
                    "Project" = $project_name; 
                    "_issues" = @{$project_name = @{$fake_summary = $fake_issue}}; 
                    "JiraFields" = @{
                        "summary" = "foo" ;
                        "description" = "bar";
                        "stories" = "eyeballs";
                        "epic name" = "eyeballs";
                        "subtasks" = "foo";
                    };
                };

                $issue = _jira_issue_search -ConfigHash $config_hash -Project $project_name -Summary $fake_summary

                $issue | Should -not -benullorempty
                ($issue -is [hashtable]) | Should -Be $true
                $issue.ContainsKey("summary") | Should -Be $true
                $issue.summary | Should -Be $fake_summary
            }

            It "fetch issues" {

                $file = $global:TEST_CONFIG_DIR + "example_issues.json"
                $struct = get-content $file | ConvertFrom-Json
                $struct | Should -not -benullorempty
                $struct.count | Should -be 2
                $fake_summary = $struct[0].summary

                mock JiraPS\Get-JiraIssue {
                    $struct
                }

                $project_name = "ABB"
                $config_hash = @{
                    "foo" = "foo" ;
                    "Project" = $project_name; 
                    "JiraFields" = @{
                        "summary" = "foo" ;
                        "description" = "bar";
                        "stories" = "eyeballs";
                        "epic name" = "eyeballs";
                        "subtasks" = "foo";
                    };
                };

                $issue = _jira_issue_search -ConfigHash $config_hash -Project $project_name -Summary $fake_summary
                $issue | Should -not -benullorempty
                $issue.summary | Should -be $fake_summary
            }

        }
    }
}

Describe "basic ini parser tests"  -tag "external" {
    Context "simple ini file" {
        BeforeAll {
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
            #$verbosepreference = "Continue"
            $base= split-path $PSScriptroot
            $yaml_file = "$base/examples/ex2.yaml"
            $yaml_file | should -exist
            $content = Get-Content $yaml_file
            $content | should -not -benullorempty
            ($struct) = Get-JYaml -YamlFile $yaml_file
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

Describe "Get-JCustomFieldHash Tests" {
    #this actually fetches data from a JIRA SERVER
    #we need to mock that out
    It "Get-JCustomFieldHash FAILS"  {
        mock Get-JiraField -MockWith  { throw "bad things happen" }
        {Get-JCustomFieldHash -ConfigHash @{one="one"}} | should -Throw -ExceptionType ([System.Management.Automation.RuntimeException])

        mock Get-JiraField -MockWith  { "" }
        {Get-JCustomFieldHash -ConfigHash @{one="one"}} | should -Throw -ExceptionType ([System.IO.InvalidDataException])
    }

    It "Get-JCustomFieldHash Success" {
        #$verbosepreference = "Continue"
        mock Get-JiraField -MockWith  {
                    @(
                        @{ID=1;
                          Name= "foo"
                        } 
                    );
         }

        $hash = Get-JCustomFieldHash -ConfigHash (@{one="one"})
        $hash | should -not -benullorempty
        write-verbose (ConvertTo-Json $hash)

    }
}

#test issue create epic
#test issue create epic and child
#test issue create epic and child #fail if summary already exists
#test issue create epic and child #force allows duplicates

