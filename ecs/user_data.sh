#!/bin/bash
sudo apt update
DD_AGENT_MAJOR_VERSION=7 DD_API_KEY=${api_key} DD_SITE="datadoghq.eu" bash -c "$(curl -L https://s3.amazonaws.com/dd-agent/scripts/install_script.sh)"
sudo echo "init_config:
instances:
  - name: My_service
    url: http://${alb_url}" > /etc/datadog-agent/conf.d/http_check.yaml
sudo systemctl stop datadog-agent
sudo systemctl start datadog-agent
