// picture-in-picture layout — the small floating window while another app is in front
//
// camera and path with the lead box, the speed top-left, MAX and LIMIT top-right,
// the lead's distance and gap bottom-centre, the engagement colour as a border,
// and any alert as a one-line banner. Everything scales with the window height,
// so it reads the same at any PiP size. No gestures: Android owns touches in PiP

import 'package:flutter/material.dart';
import 'package:opview/common/transformations.dart';
import 'package:opview/selfdrive/ui/onroad/enhanced/enhanced_layout.dart';
import 'package:opview/selfdrive/ui/onroad/model_renderer.dart';
import 'package:opview/selfdrive/ui/onroad/top_row.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';

/// window height that one PiP unit is a hundredth of
const pipRefHeight = 100.0;

/// pill background, a little darker than the full-screen layouts since the window is small
const pipPillColor = Color(0xD0141414);

/// the lead pill's text: "32 m · 1.8 s"
String pipLeadText(double dRel, double vEgo, bool isMetric) =>
    '${formatLeadDistance(dRel, isMetric)} · ${formatLeadGap(dRel, vEgo)}';

class PipLayout extends StatelessWidget {
  final UIState uiState;
  final SpeedLimitDisplay speedLimitDisplay;
  final FrameTransform Function(double w, double h) frameFor;
  final Widget Function(FrameTransform frame) videoBuilder;

  const PipLayout({
    super.key,
    required this.uiState,
    required this.speedLimitDisplay,
    required this.frameFor,
    required this.videoBuilder,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth, h = c.maxHeight;
      final u = h / pipRefHeight;
      final st = uiState;
      final frame = frameFor(w, h);
      final border = 2.5 * u;
      final pad = border + 3 * u;

      final lead = st.activeLead;
      final showLead = st.isConnected && lead != null && enhancedShowsLead(st.status);
      final dRel = (lead?['dRel'] as num?)?.toDouble() ?? 0.0;
      final vRel = (lead?['vRel'] as num?)?.toDouble() ?? 0.0;
      final limit = speedLimitToShow(st) ?? 0.0;
      final showLimit = limit > 0 && st.speedLimitVisible(speedLimitDisplay);

      return Stack(
        fit: StackFit.expand,
        children: [
          videoBuilder(frame),
          if (st.isConnected)
            RepaintBoundary(
              child: CustomPaint(
                size: Size(w, h),
                painter: ModelRendererPainter(
                  state: st,
                  carSpaceTransform: frame.carToScreen,
                  contentRect: Rect.fromLTWH(0, 0, w, h),
                  pathEdgeLines: true,
                  leadReticle: true,
                  leadTags: false,  // the bottom pill has the numbers
                  showLeads: enhancedShowsLead(st.status),
                  pathOpacity: enhancedPathOpacity,
                  maxPathDistance: enhancedPathDistance,
                  pathFadeStop: enhancedPathFadeStop,
                ),
              ),
            ),

          if (st.isConnected) ...[
            // speed, top-left
            Positioned(
              key: const ValueKey('pipSpeed'),
              left: pad,
              top: pad,
              child: _Pill(
                u: u,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text('${st.displaySpeed.round()}',
                        style: TextStyle(color: Colors.white, fontSize: 20 * u, fontWeight: FontWeight.w700, height: 1.0)),
                    SizedBox(width: 2 * u),
                    Text(st.isMetric ? 'km/h' : 'mph',
                        style: TextStyle(color: const Color(0xB3FFFFFF), fontSize: 6.5 * u, fontWeight: FontWeight.w500, height: 1.0)),
                  ],
                ),
              ),
            ),

            // MAX and LIMIT, top-right
            Positioned(
              right: pad,
              top: pad,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (st.isCruiseAvailable)
                    _SmallPill(
                      key: const ValueKey('pipMax'),
                      u: u,
                      label: 'MAX',
                      value: st.isCruiseSet ? '${st.setSpeed.round()}' : '–',
                      color: st.isCruiseSet ? Colors.white : const Color(0x80FFFFFF),
                    ),
                  if (st.isCruiseAvailable && showLimit) SizedBox(height: 2.5 * u),
                  if (showLimit)
                    _SmallPill(
                      key: const ValueKey('pipLimit'),
                      u: u,
                      label: 'LIMIT',
                      value: '${(limit * st.speedConv).round()}',
                      color: Colors.white,
                    ),
                ],
              ),
            ),

            // lead distance and gap, bottom-centre
            if (showLead)
              Positioned(
                left: 0,
                right: 0,
                bottom: pad,
                child: Center(
                  child: _Pill(
                    key: const ValueKey('pipLead'),
                    u: u,
                    child: Text(
                      pipLeadText(dRel, st.vEgo, st.isMetric),
                      style: TextStyle(
                        color: leadWarnColor(leadWarnLevel(dRel, vRel)),
                        fontSize: 8 * u,
                        fontWeight: FontWeight.w600,
                        height: 1.0,
                      ),
                    ),
                  ),
                ),
              ),

            // alert banner across the bottom, over the lead pill
            if (st.alertSize != 0 && st.alertText1.isNotEmpty)
              Positioned(
                key: const ValueKey('pipAlert'),
                left: border,
                right: border,
                bottom: border,
                child: Container(
                  color: enhancedAlertColor(st.alertStatus, fullScreen: false),
                  padding: EdgeInsets.symmetric(horizontal: 4 * u, vertical: 3.5 * u),
                  alignment: Alignment.center,
                  child: Text(
                    st.alertText1,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Colors.white, fontSize: 8 * u, fontWeight: FontWeight.w700, height: 1.0),
                  ),
                ),
              ),
          ],

          // engagement border
          IgnorePointer(
            child: DecoratedBox(
              key: const ValueKey('pipBorder'),
              decoration: BoxDecoration(
                border: Border.all(color: enhancedBorderColor(st.status), width: border),
              ),
            ),
          ),

          if (!st.isConnected)
            Center(
              child: Text(
                'Connecting…',
                style: TextStyle(color: const Color(0x99FFFFFF), fontSize: 9 * u, fontWeight: FontWeight.w300),
              ),
            ),
        ],
      );
    });
  }
}

class _Pill extends StatelessWidget {
  final double u;
  final Widget child;

  const _Pill({super.key, required this.u, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 4.5 * u, vertical: 3 * u),
      decoration: BoxDecoration(color: pipPillColor, borderRadius: BorderRadius.circular(6 * u)),
      child: child,
    );
  }
}

class _SmallPill extends StatelessWidget {
  final double u;
  final String label;
  final String value;
  final Color color;

  const _SmallPill({super.key, required this.u, required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return _Pill(
      u: u,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(label,
              style: TextStyle(color: const Color(0x99FFFFFF), fontSize: 5 * u, fontWeight: FontWeight.w600, height: 1.0)),
          SizedBox(width: 2 * u),
          Text(value, style: TextStyle(color: color, fontSize: 10 * u, fontWeight: FontWeight.w700, height: 1.0)),
        ],
      ),
    );
  }
}
