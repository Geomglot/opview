// opview app shell
// dark theme, single screen, no navigation needed

import 'package:flutter/material.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/selfdrive/ui/onroad/augmented_road_view.dart';
import 'package:opview/services/app_settings.dart';
import 'package:opview/services/connection_manager.dart';
import 'package:opview/services/system_service.dart';

class OpviewApp extends StatefulWidget {
  const OpviewApp({super.key});

  @override
  State<OpviewApp> createState() => _OpviewAppState();
}

class _OpviewAppState extends State<OpviewApp> with WidgetsBindingObserver {
  late final UIState _uiState;
  late final ConnectionManager _connectionManager;
  final AppSettings _settings = AppSettings();

  // the app went fully into the background (not just PiP or the notification shade)
  final _lifecycle = LifecycleReconnect();

  // picture-in-picture is offered on Home only while there is something to show,
  // and the driver has not turned it off in Settings
  bool? _pipOffered;

  void _updatePipOffer() {
    final want = _uiState.isConnected && _settings.pictureInPicture;
    if (want == _pipOffered) return;
    _pipOffered = want;
    setPipEnabled(want);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _uiState = UIState();
    _connectionManager = ConnectionManager(_uiState);
    _connectionManager.start();
    _settings.load();
    listenForPip();
    _uiState.addListener(_updatePipOffer);
    _settings.addListener(_updatePipOffer);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _uiState.removeListener(_updatePipOffer);
    _settings.removeListener(_updatePipOffer);
    // async cleanup — best-effort, State.dispose() is sync
    _connectionManager.dispose();
    _uiState.dispose();
    _settings.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (_lifecycle.onChange(state)) {
      case LifecycleAction.reconnect:
        debugPrint('[opview] app resumed, reconnecting');
        _connectionManager.reconnect();
      case LifecycleAction.pause:
        debugPrint('[opview] app paused, stopping');
        _connectionManager.pause();
      case LifecycleAction.none:
        break;
    }
  }


  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OPRivView',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: Colors.black,
      ),
      home: ListenableBuilder(
        listenable: Listenable.merge([_uiState, _settings, pipMode]),
        builder: (context, _) => AugmentedRoadView(
          uiState: _uiState,
          videoRenderer: _connectionManager.videoRenderer,
          loadManualHost: _connectionManager.loadManualHost,
          onSetManualHost: _connectionManager.setManualHost,
          currentHost: () => _connectionManager.host,
          settings: _settings,
          pip: pipMode.value,
        ),
      ),
    );
  }
}

enum LifecycleAction { none, pause, reconnect }

/// when to stop and restart the stream. A picture-in-picture window, the
/// notification shade or a dialog only make the app inactive, and the stream
/// keeps playing through them; only a real trip to the background pauses it,
/// and only coming back from that reconnects
class LifecycleReconnect {
  bool _paused = false;

  LifecycleAction onChange(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && !_paused) {
      _paused = true;
      return LifecycleAction.pause;
    }
    if (state == AppLifecycleState.resumed && _paused) {
      _paused = false;
      return LifecycleAction.reconnect;
    }
    return LifecycleAction.none;
  }
}
