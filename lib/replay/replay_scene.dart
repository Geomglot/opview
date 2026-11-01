// The screen being replayed: the real onroad layout, over one camera picture

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:opview/replay/replay_job.dart';
import 'package:opview/selfdrive/ui/onroad/augmented_road_view.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/services/app_settings.dart';

/// laid out at the output size whatever space it is given, so the layouts see the screen they would have been on
class ReplayScene extends StatelessWidget {
  final ReplayJob job;
  final UIState uiState;
  final AppSettings settings;
  final ui.Image? picture;
  const ReplayScene({super.key, required this.job, required this.uiState, required this.settings, required this.picture});

  @override
  Widget build(BuildContext context) {
    final size = ui.Size(job.width.toDouble(), job.height.toDouble());
    return MediaQuery(
      data: MediaQueryData(size: size),
      child: Scaffold(
        backgroundColor: Colors.black,
        body: AugmentedRoadView(
          uiState: uiState,
          settings: settings,
          videoChild: picture == null ? const SizedBox.shrink() : RawImage(image: picture, fit: BoxFit.cover),
        ),
      ),
    );
  }
}
