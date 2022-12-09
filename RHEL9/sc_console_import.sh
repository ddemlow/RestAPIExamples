#!/bin/bash
#run script on node console to initiate ubuntu 20_04 import to current cluster
#could do this using curl, rest api but for now will use sc command
sc vm import uri "https://github.com/ddemlow/RestAPIExamples/raw/master/rhel9-cloud-init" definitionFile "rhel9-cloud-init.xml" name test wait yes
#note - this vm image needs cloud-init to be useable