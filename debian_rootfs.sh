#!/bin/bash
# SPDX-License-Identifier: CC0-1.0
# Copyright (C) 2022 Intel Corporation. All rights reserved.

mkdir -p "$1/etc/apt/"
apt_conf=/etc/apt/apt.conf
[ -f "$apt_conf" ] && cp -L "$apt_conf" "$1/$apt_conf" || true

mkdir -p "$1/etc/apt/apt.conf.d"
apt_proxy=/etc/apt/apt.conf.d
[ -f "$apt_proxy" ] && cp -L "$apt_proxy" "$1/$apt_proxy" || true
