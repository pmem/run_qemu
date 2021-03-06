#!/bin/bash
# SPDX-License-Identifier: CC0-1.0
# Copyright (C) 2021 Intel Corporation. All rights reserved.

mkdir -p "$1/etc/pacman.d/"
mirrorlist=/etc/pacman.d/mirrorlist
[ -f "$mirrorlist" ] && cp -L "$mirrorlist" "$1/$mirrorlist"
