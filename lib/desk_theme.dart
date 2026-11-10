import 'dart:io';

import 'package:flutter/material.dart';

const deskCanvas = Color(0xfff4f5f2);
const deskInk = Color(0xff202a27);
const deskMuted = Color(0xff626e67);
const deskLine = Color(0xffe1e5df);
const deskAccent = Color(0xff286250);
const deskVideo = Color(0xff101714);

bool get desktop => Platform.isWindows || Platform.isLinux || Platform.isMacOS;
