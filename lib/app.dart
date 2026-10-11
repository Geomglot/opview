// opview app shell
// dark theme, single screen, no navigation needed

import 'package:flutter/material.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/selfdrive/ui/onroad/augmented_road_view.dart';
import 'package:opview/services/app_settings.dart';
import 'package:opview/services/connection_manager.dart';

class OpviewApp extends StatefulWidget {
  const OpviewApp({super.key});

  @override
  State<OpviewApp> createState() => _OpviewAppState();
}

class _OpviewAppState extends State<OpviewApp> with WidgetsBindingObserver {
  late final UIState _uiState;
  late final ConnectionManager _connectionManager;
  final AppSettings _settings = AppSettings();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _uiState = UIState();
    _connectionManager = ConnectionManager(_uiState);
    _connectionManager.start();
    _settings.load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // async cleanup — best-effort, State.dispose() is sync
    _connectionManager.dispose();
    _uiState.dispose();
    _settings.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      debugPrint('[opview] app resumed, reconnecting');
      _connectionManager.reconnect();
    } else if (state == AppLifecycleState.paused) {
      debugPrint('[opview] app paused, stopping');
      _connectionManager.pause();
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
        listenable: Listenable.merge([_uiState, _settings]),
        builder: (context, _) => AugmentedRoadView(
          uiState: _uiState,
          videoRenderer: _connectionManager.videoRenderer,
          loadManualHost: _connectionManager.loadManualHost,
          onSetManualHost: _connectionManager.setManualHost,
          currentHost: () => _connectionManager.host,
          settings: _settings,
        ),
      ),
    );
  }
}
