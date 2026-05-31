#!/bin/bash

sudo dnf update -y

sudo dnf install -y curl policycoreutils openssh-server
# 이메일 알림을 SMTP로 보낼 거면 postfix는 생략하고 외부 SMTP 권장

curl --location "https://packages.gitlab.com/install/repositories/gitlab/gitlab-ce/script.rpm.sh" | sudo bash

sudo EXTERNAL_URL="https://gitlab.example.com" dnf install -y gitlab-ce
