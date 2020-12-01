
#BINARIES REQUIREMENTS
The script required the following tools. 
-uuidgen
-jq
-rbkcli
	this tool can be installed (https://github.com/rubrikinc/rbkcli) or can be downloaded as a portable executable from github (https://github.com/rubrikinc/rbkcli/releases).
	rbkcli is an rest API wrapper for rubrik which relies on python.

These tools must be in $PATH of the user who run the script.

#CONFIGURATION FILE
The script uses a configuration that  must include the following informations

	export rubrik_cdm_node_ip=someIP
	export rubrik_cdm_username="enteranythinghere"
	export rubrik_cdm_password="enteranythinghere"
	export rubrik_cdm_token='theverylongtoken'

Note that rubrik_cdm_token take precedence over rubrik_cdm_username and rubrik_cdm_password.
So, no matter which value is set for rubrik_cdm_username and rubrik_cdm_password.

To verify if the configuration values are correct run : "source <configurtaionfile> ; rkkcli commands -T"
This should return cluster uuid, cluster name ...
