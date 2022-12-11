#!/bin/bash
#run script on node console to initiate ubuntu 20_04 import to current cluster
#could do this using curl, rest api but for now will use sc command
sc vm import uri "https://github.com/ddemlow/RestAPIExamples/raw/master/RHEL9" definitionFile "rhel9-cloud-init.xml" name rhel9-cloud-image wait yes
#note - this vm image needs cloud-init to be useable
