import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'dart:async';

class WallDisplayApp extends StatelessWidget {
  const WallDisplayApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Washroom Hygiene Display',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        brightness: Brightness.dark,
        fontFamily: 'Roboto',
      ),
      home: const WallDisplay(washroomId: 'WR_001'),
      debugShowCheckedModeBanner: false,
    );
  }
}

class WallDisplay extends StatefulWidget {
  final String washroomId;
  const WallDisplay({super.key, required this.washroomId});

  @override
  State<WallDisplay> createState() => _WallDisplayState();
}

class _WallDisplayState extends State<WallDisplay>
    with TickerProviderStateMixin {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  double _hygieneScore = 0;
  Map<String, dynamic> _componentScores = {};
  List<dynamic> _anomalies = [];
  String _lastUpdated = 'N/A';
  bool _isConnected = true;

  late AnimationController _pulseController;
  late AnimationController _scoreController;
  late Animation<double> _scoreAnimation;

  StreamSubscription<DatabaseEvent>? _dataSub;
  StreamSubscription<DatabaseEvent>? _connSub;

  @override
  void initState() {
    super.initState();

    _pulseController = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    )..repeat(reverse: true);

    _scoreController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );

    _scoreAnimation = Tween<double>(begin: 0, end: _hygieneScore).animate(
      CurvedAnimation(parent: _scoreController, curve: Curves.easeOutCubic),
    );

    _listenToRealtimeData();
    _listenConnection();
  }

  void _listenToRealtimeData() {
    final ref = _db.child('washrooms/${widget.washroomId}/current');

    _dataSub = ref.onValue.listen(
      (event) {
        final value = event.snapshot.value;

        if (value == null) return;

        // ✅ Safe Map conversion (handles Map<dynamic,dynamic>)
        final data = Map<String, dynamic>.from(value as Map);

        final double newScore = (data['score'] ?? 0).toDouble();

        final compRaw = data['component_scores'];
        final Map<String, dynamic> comp = compRaw is Map
            ? Map<String, dynamic>.from(compRaw)
            : {};

        final anomaliesRaw = data['anomalies'];
        final List<dynamic> anomalies = anomaliesRaw is List
            ? anomaliesRaw
            : [];

        setState(() {
          // ✅ Animate score change smoothly
          _scoreAnimation = Tween<double>(begin: _hygieneScore, end: newScore)
              .animate(
                CurvedAnimation(
                  parent: _scoreController,
                  curve: Curves.easeOutCubic,
                ),
              );

          _scoreController.forward(from: 0);

          _hygieneScore = newScore;
          _componentScores = comp;
          _anomalies = anomalies;

          final ts = data['timestamp'];
          _lastUpdated = _formatTimestamp(ts?.toString() ?? '');

          _isConnected = true;
        });
      },
      onError: (e) {
        debugPrint("Realtime DB Error: $e");
        setState(() {
          _isConnected = false;
        });
      },
    );
  }

  void _listenConnection() {
    _connSub = _db.child('.info/connected').onValue.listen((event) {
      final val = event.snapshot.value;
      setState(() {
        _isConnected = val is bool ? val : false;
      });
    });
  }

  String _formatTimestamp(String timestamp) {
    try {
      final dt = DateTime.parse(timestamp);
      return '${dt.hour.toString().padLeft(2, '0')}:'
          '${dt.minute.toString().padLeft(2, '0')}:'
          '${dt.second.toString().padLeft(2, '0')}';
    } catch (e) {
      return 'N/A';
    }
  }

  Color _getScoreColor(double score) {
    if (score >= 70) return Colors.green;
    if (score >= 50) return Colors.orange;
    return Colors.red;
  }

  String _getScoreLabel(double score) {
    if (score >= 90) return 'EXCELLENT';
    if (score >= 70) return 'GOOD';
    if (score >= 50) return 'FAIR';
    if (score >= 30) return 'POOR';
    return 'CRITICAL';
  }

  IconData _getScoreIcon(double score) {
    if (score >= 70) return Icons.sentiment_very_satisfied;
    if (score >= 50) return Icons.sentiment_neutral;
    return Icons.sentiment_very_dissatisfied;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.black,
              _getScoreColor(_hygieneScore).withOpacity(0.1),
              Colors.black,
            ],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              _buildHeader(),
              Expanded(child: _buildMainScore()),
              _buildComponentScores(),
              _buildAnomalies(),
              _buildFooter(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.all(20),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              const Icon(Icons.wc, size: 40, color: Colors.white70),
              const SizedBox(width: 15),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'WASHROOM HYGIENE',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                      letterSpacing: 2,
                    ),
                  ),
                  Text(
                    'ID: ${widget.washroomId}',
                    style: const TextStyle(fontSize: 14, color: Colors.white60),
                  ),
                ],
              ),
            ],
          ),
          Row(
            children: [
              if (!_isConnected)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 15,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.red.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.red),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.wifi_off, color: Colors.red, size: 20),
                      SizedBox(width: 8),
                      Text('OFFLINE', style: TextStyle(color: Colors.red)),
                    ],
                  ),
                )
              else
                FadeTransition(
                  opacity: _pulseController,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 15,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.green.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Colors.green),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.circle, color: Colors.green, size: 12),
                        SizedBox(width: 8),
                        Text('LIVE', style: TextStyle(color: Colors.green)),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMainScore() {
    return Center(
      child: AnimatedBuilder(
        animation: _scoreAnimation,
        builder: (context, child) {
          return Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 350,
                height: 350,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: _getScoreColor(
                        _scoreAnimation.value,
                      ).withOpacity(0.5),
                      blurRadius: 100,
                      spreadRadius: 30,
                    ),
                  ],
                ),
              ),
              Container(
                width: 320,
                height: 320,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: _getScoreColor(_scoreAnimation.value),
                    width: 12,
                  ),
                  gradient: RadialGradient(
                    colors: [
                      _getScoreColor(_scoreAnimation.value).withOpacity(0.1),
                      Colors.black,
                    ],
                  ),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      _getScoreIcon(_scoreAnimation.value),
                      size: 80,
                      color: _getScoreColor(_scoreAnimation.value),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      '${_scoreAnimation.value.toInt()}%',
                      style: TextStyle(
                        fontSize: 90,
                        fontWeight: FontWeight.bold,
                        color: _getScoreColor(_scoreAnimation.value),
                        shadows: [
                          Shadow(
                            color: _getScoreColor(
                              _scoreAnimation.value,
                            ).withOpacity(0.5),
                            blurRadius: 20,
                          ),
                        ],
                      ),
                    ),
                    Text(
                      _getScoreLabel(_scoreAnimation.value),
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w300,
                        color: Colors.white70,
                        letterSpacing: 4,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildComponentScores() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 20),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _buildComponentCard(
            'Air Quality',
            (_componentScores['air_quality'] ?? 0).toDouble(),
            Icons.air,
          ),
          _buildComponentCard(
            'Floor',
            (_componentScores['floor_moisture'] ?? 0).toDouble(),
            Icons.water_drop,
          ),
          _buildComponentCard(
            'Humidity',
            (_componentScores['humidity'] ?? 0).toDouble(),
            Icons.opacity,
          ),
          _buildComponentCard(
            'Temperature',
            (_componentScores['temperature'] ?? 0).toDouble(),
            Icons.thermostat,
          ),
        ],
      ),
    );
  }

  Widget _buildComponentCard(String label, double value, IconData icon) {
    return Container(
      width: 140,
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(
          color: _getScoreColor(value).withOpacity(0.3),
          width: 2,
        ),
      ),
      child: Column(
        children: [
          Icon(icon, color: _getScoreColor(value), size: 30),
          const SizedBox(height: 10),
          Text(
            '${value.toInt()}%',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: _getScoreColor(value),
            ),
          ),
          Text(
            label,
            style: const TextStyle(fontSize: 12, color: Colors.white60),
          ),
        ],
      ),
    );
  }

  Widget _buildAnomalies() {
    if (_anomalies.isEmpty) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 40, vertical: 10),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.red.withOpacity(0.1),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: Colors.red.withOpacity(0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.warning, color: Colors.red),
              SizedBox(width: 10),
              Text(
                'ANOMALIES DETECTED',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.red,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ..._anomalies.take(3).map((anomaly) {
            final anomalyData = anomaly is Map
                ? Map<String, dynamic>.from(anomaly)
                : <String, dynamic>{};

            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                children: [
                  const Icon(Icons.error_outline, color: Colors.red, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      anomalyData['message']?.toString() ?? 'Unknown anomaly',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildFooter() {
    return Container(
      padding: const EdgeInsets.all(20),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            'Last Updated: $_lastUpdated',
            style: const TextStyle(color: Colors.white38, fontSize: 14),
          ),
          const Text(
            '© Smart Hygiene IoT System',
            style: TextStyle(color: Colors.white38, fontSize: 14),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _dataSub?.cancel();
    _connSub?.cancel();
    _pulseController.dispose();
    _scoreController.dispose();
    super.dispose();
  }
}
