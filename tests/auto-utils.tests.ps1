#Requires -version 5.1
$module_name= "auto-utils"
$base= split-path $PSScriptroot
$module_path =  "$base/$module_name/$module_name.psm1"
import-module -name $module_path -force

$global:TEST_CONFIG_DIR =  $PSScriptroot + "\var\";

Describe "module: $module_name"{
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
