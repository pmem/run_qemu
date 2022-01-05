#!/bin/bash
# SPDX-License-Identifier: CC0-1.0
# Copyright (C) 2021 Intel Corporation. All rights reserved.

mkdir -p "$1/etc/dnf/"
dnf_conf=/etc/dnf/dnf.conf
[ -f "$dnf_conf" ] && cp -L "$dnf_conf" "$1/$dnf_conf" || true
